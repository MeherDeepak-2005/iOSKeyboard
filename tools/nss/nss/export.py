"""Export a trained recurrent NSS model to the runtime's `.nsslm` file.

    python -m nss.export runs/NAME/best.pt --out ../../keyboard/nss-english.nsslm

Matrices are int8 with one fp32 scale per row (symmetric, round to nearest); biases stay
fp32. The C++ runtime (native/DecoderCore NeuralLanguageModel) memory-maps the file and
dequantizes rows on the fly, so resident weights are the file's clean pages. Writes
<out>.manifest.json (hashes, architecture, sizes, quantization error, unk policy) and
<out>.goldens.json (reference log-probabilities from the dequantized model, which the
C++ tests must reproduce). Only the LSTM/CIFG and GRU families have a runtime kernel.

The header also carries the mean log P(<unk>|context) over the validation sets' word
positions: the runtime centers the typed literal's context shift on it (Engine.cpp).

Layout (little-endian): a 256-byte header, a table of 32-byte section records
(id, kind, rows, cols, offset, bytes), then 64-byte-aligned sections. Kind 1 is an int8
[rows x cols] matrix followed by fp32 scales[rows]; kind 2 is fp32 [rows x cols]; kind 3
is the vocabulary (uint32 offsets[rows + 1], then UTF-8 bytes).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import struct
from pathlib import Path

import numpy as np
import torch

from . import DATA
from .models import build
from .vocab import BOS, EOS, PAD, UNK, Vocabulary

MAGIC = b"NSLM"
VERSION = 1
ARCH_IDS = {"lstm": 1, "gru": 2}
FLAG_CIFG, FLAG_TIED, FLAG_PROJECTION = 1, 2, 4
INT8, FLOAT32, VOCABULARY = 1, 2, 3
EMBEDDING, OUTPUT, OUTPUT_BIAS, GRU_PROJECTION, VOCAB_SECTION = 1, 2, 3, 9, 100
HEADER_BYTES, RECORD_BYTES, ALIGN = 256, 32, 64


def layer_id(layer: int, part: int) -> int:
    """part 0: gate weights, 1: gate bias, 2: LSTM projection."""
    return 10 + 4 * layer + part


def quantize(matrix: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    matrix = np.asarray(matrix, np.float32)
    scales = np.abs(matrix).max(1) / 127.0
    scales[scales == 0] = 1.0
    q = np.clip(np.rint(matrix / scales[:, None]), -127, 127).astype(np.int8)
    return q, scales.astype(np.float32)


def dequantize(q: np.ndarray, scales: np.ndarray) -> np.ndarray:
    return q.astype(np.float32) * scales[:, None]


def tensors(model) -> list[tuple[int, int, np.ndarray]]:
    """(section id, kind, array) in file order; matrices are fp32 here, quantized on write."""
    out = [(EMBEDDING, INT8, model.embedding.weight.detach().cpu().numpy())]
    if not model.tied:
        out.append((OUTPUT, INT8, model.output.detach().cpu().numpy()))
    out.append((OUTPUT_BIAS, FLOAT32, model.output_bias.detach().cpu().numpy()[None]))
    for layer in range(model.layers):
        gates = torch.cat([model.w_input[layer], model.w_recurrent[layer]], 1)
        out.append((layer_id(layer, 0), INT8, gates.detach().cpu().numpy()))
        if model.arch == "lstm":
            out.append((layer_id(layer, 1), FLOAT32, model.bias[layer].detach().cpu().numpy()[None]))
            if model.proj:
                out.append((layer_id(layer, 2), INT8, model.w_proj[layer].detach().cpu().numpy()))
        else:
            bias = torch.stack([model.b_input[layer], model.b_recurrent[layer]])
            out.append((layer_id(layer, 1), FLOAT32, bias.detach().cpu().numpy()))
    if model.arch == "gru" and model.proj:
        out.append((GRU_PROJECTION, INT8, model.w_proj[0].detach().cpu().numpy()))
    return out


def quantized_copy(model):
    """The model the runtime will run: every exported int8 matrix replaced by q * scale."""
    import copy
    clone = copy.deepcopy(model).cpu().eval()
    with torch.no_grad():
        for section, kind, array in tensors(clone):
            if kind != INT8:
                continue
            restored = torch.from_numpy(dequantize(*quantize(array)))
            if section == EMBEDDING:
                clone.embedding.weight.copy_(restored)
            elif section == OUTPUT:
                clone.output.copy_(restored)
            elif section == GRU_PROJECTION:
                clone.w_proj[0].copy_(restored)
            else:
                layer, part = divmod(section - 10, 4)
                if part == 0:
                    width = clone.w_input[layer].shape[1]
                    clone.w_input[layer].copy_(restored[:, :width])
                    clone.w_recurrent[layer].copy_(restored[:, width:])
                else:
                    clone.w_proj[layer].copy_(restored)
    return clone


def pad_to(buffer: bytearray, alignment: int) -> None:
    buffer.extend(b"\0" * (-len(buffer) % alignment))


@torch.no_grad()
def unk_log_center(model, data: Path, sentences: int = 4000) -> float:
    """Mean log P(<unk>|context) of the decoder distribution over validation word positions."""
    from .data import Shard
    from .metrics import sentence_batches, word_log_probs
    from .vocab import EOS
    total, count = 0.0, 0
    for source in ("tatoeba", "wikitext"):
        shard = Shard.load(data, source, "valid")
        shard = Shard(shard.tokens, shard.offsets[:sentences + 1])
        for inputs, targets, mask in sentence_batches(shard):
            features, _ = model(torch.from_numpy(inputs))
            keep = torch.from_numpy(mask) & (torch.from_numpy(targets) != EOS)
            values = word_log_probs(model.logits(features[keep]))[:, UNK].double()
            total += float(values.sum())
            count += int(values.numel())
    return total / count


def write(model, vocab: Vocabulary, unk_share: float, langdata_sha: str, path: Path, unk_center: float = 0.0) -> dict:
    if model.arch not in ARCH_IDS:
        raise SystemExit(f"no runtime kernel for {model.arch!r}; export supports {sorted(ARCH_IDS)}")
    flags = (FLAG_CIFG if getattr(model, "cifg", False) else 0) | (FLAG_TIED if model.tied else 0) \
        | (FLAG_PROJECTION if model.proj else 0)
    sections = tensors(model)
    blob = b"".join(word.encode("utf-8") for word in vocab.words)
    lengths = np.cumsum([0] + [len(word.encode("utf-8")) for word in vocab.words]).astype(np.uint32)
    body, records, errors = bytearray(), [], {}
    start = HEADER_BYTES + RECORD_BYTES * (len(sections) + 1)
    start += -start % ALIGN
    for section, kind, array in sections:
        pad_to(body, ALIGN)
        offset = start + len(body)
        rows, cols = array.shape
        if kind == INT8:
            q, scales = quantize(array)
            errors[str(section)] = float(np.abs(dequantize(q, scales) - array).max())
            body.extend(q.tobytes())
            pad_to(body, 4)
            body.extend(scales.tobytes())
        else:
            body.extend(np.ascontiguousarray(array, np.float32).tobytes())
        records.append((section, kind, rows, cols, offset, start + len(body) - offset))
    pad_to(body, ALIGN)
    offset = start + len(body)
    body.extend(lengths.tobytes())
    body.extend(blob)
    records.append((VOCAB_SECTION, VOCABULARY, len(vocab), 0, offset, start + len(body) - offset))

    header = bytearray(HEADER_BYTES)
    struct.pack_into("<4s10I4IfIf", header, 0, MAGIC, VERSION, ARCH_IDS[model.arch], flags, len(vocab),
                     model.embed, model.hidden, model.proj or 0, model.layers, model.features, 0,
                     PAD, UNK, BOS, EOS, unk_share, len(records), unk_center)
    header[80:112] = bytes.fromhex(vocab.sha256)
    header[112:144] = bytes.fromhex(langdata_sha)
    table = b"".join(struct.pack("<4I2Q", *record) for record in records)
    payload = bytes(header) + table
    payload += b"\0" * (start - len(payload)) + bytes(body)
    path.write_bytes(payload)
    return {"bytes": len(payload), "max_abs_quantization_error": errors}


def goldens(model, vocab: Vocabulary, unk_share: float, lexicon, unk_center: float = 0.0) -> dict:
    """Reference values from the dequantized model, for the C++ parity tests."""
    from .lexicon import UnkPolicy
    from .nss import NeuralSearchSpace

    policy = UnkPolicy.build(lexicon, vocab, unk_share)
    space = NeuralSearchSpace(model, vocab, lexicon, policy)
    contexts = [[], ["i"], ["i", "am", "going", "to"], ["thank"], ["see", "you"], ["what", "are", "you", "doing"],
                ["the", "president", "of", "the"], ["can", "you", "send", "me", "the"], ["talking", "to"],
                ["Hello", "'there'"], ["xqzzy"]]
    words = ["the", "you", "be", "going", "to", "morning", "united", "dinner", "photos", "tomorrow", "covid",
             "sesquipedalian", "abandonned", "xqzzy", "i'm", "'cause", "zebra"]
    cases = []
    for context in contexts:
        space.update(context)
        arcs = space.arcs(-15.0)
        cases.append({"context": context,
                      "ids": space.context_ids(context),
                      "scores": {word: space.log_probability(word) for word in words},
                      "unk": space.unk_log_probability(),
                      "arc_count": len(arcs), "top": arcs[:10],
                      "extend": {f"{a} {b}": space.sequence([a, b]) for a, b in (("of", "the"), ("going", "to"), ("covid", "test"))}})
    return {"unk_lexicon_share": unk_share, "unk_log_center": unk_center, "oov_mass": policy.oov_mass,
            "oov_words": policy.oov_words, "tolerance": 2e-3, "cases": cases}


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("checkpoint", type=Path)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--data", type=Path, default=DATA)
    args = parser.parse_args(argv)
    from .lexicon import Lexicon

    checkpoint = torch.load(args.checkpoint, map_location="cpu", weights_only=False)
    vocab = Vocabulary.load()
    if checkpoint["vocabulary_sha256"] != vocab.sha256:
        raise SystemExit("checkpoint was trained on a different vocabulary")
    lexicon = Lexicon.load()
    if checkpoint["langdata_sha256"] != lexicon.sha256:
        print("note: keyboard/langdata.bin changed since the training data was built", flush=True)
    model = build(checkpoint["config"]["model"], len(vocab))
    model.load_state_dict(checkpoint["model"])
    model.eval()
    share = float(checkpoint["unk_lexicon_share"])
    reference = quantized_copy(model)
    center = unk_log_center(reference, args.data)
    info = write(model, vocab, share, lexicon.sha256, args.out, center)
    manifest = {
        "schema_version": 1, "format": f"NSLM v{VERSION}", "file": args.out.name, "bytes": info["bytes"],
        "sha256": hashlib.sha256(args.out.read_bytes()).hexdigest(),
        "architecture": model.config(), "parameters": model.parameter_count(),
        "vocabulary_sha256": vocab.sha256, "langdata_sha256": lexicon.sha256,
        "unk_policy": {"formula": "P(w|ctx) = P(<unk>|ctx) * share * u(w) / oov_mass for lexicon words outside the vocabulary",
                       "unk_lexicon_share": share, "mean_log_unk_validation": center},
        "quantization": {"scheme": "int8 symmetric per row, fp32 scales; biases fp32",
                         "max_abs_error": info["max_abs_quantization_error"]},
        "training": {"step": checkpoint["step"], "config": checkpoint["config"], "valid": checkpoint.get("valid"),
                     "data_weights": checkpoint["data"]["weights"]},
        "source_checkpoint_sha256": hashlib.sha256(args.checkpoint.read_bytes()).hexdigest(),
    }
    args.out.with_suffix(".manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    args.out.with_suffix(".goldens.json").write_text(json.dumps(goldens(reference, vocab, share, lexicon, center), indent=1) + "\n")
    print(f"wrote {args.out} ({info['bytes']:,} bytes)")


if __name__ == "__main__":
    main()
