#!/usr/bin/env python3
"""Export the trained LM for the keyboard extension:

  ../../keyboard/rescorer.mlpackage   Core ML, int8 weights, batch 1..16, L=32
                                      outputs candidate scores plus last-position
                                      logits without allocating [B, L, vocab]
  ../../keyboard/tokenizer.bin        pieces + scores for the Swift Viterbi
                                      tokenizer (format below)

tokenizer.bin (little-endian):
  magic 'KBTK' u32, version u32=1, count u32, unk_id u32
  scores  f32 x count
  offsets u32 x (count+1)      byte offsets into blob
  blob    utf8 piece bytes
"""

import argparse
import struct
import subprocess
import sys
from pathlib import Path

# NOTE: coremltools is imported lazily inside export_model(). Importing it at module
# top triggers a libc++ mutex-teardown abort on this toolchain (torch 2.11 /
# coremltools 9) at process exit — harmless to saved files, but it kills the tokenizer
# step if that runs afterward. So: write tokenizer.bin FIRST, model second.

DATA = Path(__file__).resolve().parent / "data"
OUT = Path(__file__).resolve().parents[2] / "keyboard"
L = 32   # fixed model length — must equal TinyLM.maxlen
K = 8    # fixed candidate-score slots — must equal KeyboardInferenceModel.score_slots


def export_model():
    import coremltools as ct
    import numpy as np
    import torch
    from model import KeyboardInferenceModel, TinyLM

    ckpt = torch.load(DATA / "lm.pt", map_location="cpu")
    model = TinyLM(vocab=ckpt["vocab"])
    model.load_state_dict(ckpt["model"])
    model.eval()
    inference_model = KeyboardInferenceModel(model).eval()

    example = (
        torch.zeros(1, L, dtype=torch.int32),
        torch.zeros(1, K, dtype=torch.int32),
        torch.zeros(1, K, dtype=torch.int32),
        torch.zeros(1, K, dtype=torch.float32),
        torch.zeros(1, 1, dtype=torch.int32),
    )
    traced = torch.jit.trace(inference_model, example)
    # NB: the mlprogram's compute precision defaults to FLOAT16, so `logits` is
    # declared (and returned at runtime) as FLOAT16. NeuralScorer.swift branches
    # on the multiarray's dataType — keep it that way if this ever changes.
    batch = ct.RangeDim(1, 16)
    mlm = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="tokens", shape=(batch, L), dtype=np.int32),
            ct.TensorType(name="score_positions", shape=(batch, K), dtype=np.int32),
            ct.TensorType(name="target_ids", shape=(batch, K), dtype=np.int32),
            ct.TensorType(name="score_mask", shape=(batch, K), dtype=np.float32),
            ct.TensorType(name="next_positions", shape=(batch, 1), dtype=np.int32),
        ],
        outputs=[
            ct.TensorType(name="candidate_log_probs"),
            ct.TensorType(name="next_logits"),
        ],
        minimum_deployment_target=ct.target.iOS17,
        compute_units=ct.ComputeUnit.CPU_AND_NE,
    )
    # PER-CHANNEL is load-bearing, not a tweak. The output head is TIED to the token
    # embedding (one [vocab, d] matrix), so per-TENSOR int8 gives all 6000 rows a
    # single scale; a few large rows blow up that scale and the rest collapse toward
    # zero, wrecking the logits (measured: last-position top-1 agreement 0%, cosine
    # 0.78). Per-channel gives each output row its own scale — cosine 1.0000,
    # top-5 agreement 1.00, same ~4.8 MB. Verify with tools/lm parity checks before shipping.
    op_cfg = ct.optimize.coreml.OpLinearQuantizerConfig(mode="linear_symmetric", granularity="per_channel")
    cfg = ct.optimize.coreml.OptimizationConfig(global_config=op_cfg)
    mlm = ct.optimize.coreml.linear_quantize_weights(mlm, config=cfg)
    mlm.save(str(OUT / "rescorer.mlpackage"))
    print("wrote", OUT / "rescorer.mlpackage", flush=True)


def export_tokenizer():
    # Keep SentencePiece out of the Core ML process. On some macOS combinations
    # its native runtime deadlocks with coremltools/Torch during library setup.
    import sentencepiece as spm

    sp = spm.SentencePieceProcessor(model_file=str(DATA / "spm.model"))
    n = sp.vocab_size()
    pieces = [sp.id_to_piece(i) for i in range(n)]
    scores = [sp.get_score(i) for i in range(n)]
    blob = bytearray(); offsets = [0]
    for p in pieces:
        blob += p.encode(); offsets.append(len(blob))
    with (OUT / "tokenizer.bin").open("wb") as f:
        f.write(struct.pack("<4I", 0x4B42544B, 1, n, sp.unk_id()))
        f.write(struct.pack(f"<{n}f", *scores))
        f.write(struct.pack(f"<{n + 1}I", *offsets))
        f.write(blob)
    print("wrote", OUT / "tokenizer.bin", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--part", choices=("all", "tokenizer", "model"), default="all")
    args = parser.parse_args()
    if args.part == "tokenizer":
        export_tokenizer()
    elif args.part == "model":
        export_model()
        # Some coremltools/PyTorch combinations deadlock during native-library
        # teardown. The package is fully flushed by save(), so skip that teardown.
        import os
        os._exit(0)
    else:
        # Native isolation is intentional: do not replace these subprocesses with
        # two function calls in one interpreter.
        subprocess.run([sys.executable, __file__, "--part", "tokenizer"], check=True)
        subprocess.run([sys.executable, __file__, "--part", "model"], check=True)
