#!/usr/bin/env python3
"""Export the trained LM for the keyboard extension:

  ../../keyboard/rescorer.mlpackage   Core ML, int8 weights, batch 1..16, L=32
  ../../keyboard/tokenizer.bin        pieces + scores for the Swift Viterbi
                                      tokenizer (format below)

tokenizer.bin (little-endian):
  magic 'KBTK' u32, version u32=1, count u32, unk_id u32
  scores  f32 x count
  offsets u32 x (count+1)      byte offsets into blob
  blob    utf8 piece bytes
"""

import struct
from pathlib import Path

import sentencepiece as spm

# NOTE: coremltools is imported lazily inside export_model(). Importing it at module
# top triggers a libc++ mutex-teardown abort on this toolchain (torch 2.11 /
# coremltools 9) at process exit — harmless to saved files, but it kills the tokenizer
# step if that runs afterward. So: write tokenizer.bin FIRST, model second.

DATA = Path(__file__).resolve().parent / "data"
OUT = Path(__file__).resolve().parents[2] / "keyboard"
L = 32   # fixed model length — must equal TinyLM.maxlen


def export_model():
    import coremltools as ct
    import numpy as np
    import torch
    from model import TinyLM

    ckpt = torch.load(DATA / "lm.pt", map_location="cpu")
    model = TinyLM(vocab=ckpt["vocab"])
    model.load_state_dict(ckpt["model"])
    model.eval()

    example = torch.zeros(1, L, dtype=torch.int32)
    traced = torch.jit.trace(model, example)
    # NB: the mlprogram's compute precision defaults to FLOAT16, so `logits` is
    # declared (and returned at runtime) as FLOAT16. NeuralScorer.swift branches
    # on the multiarray's dataType — keep it that way if this ever changes.
    mlm = ct.convert(
        traced,
        inputs=[ct.TensorType(name="tokens",
                              shape=(ct.RangeDim(1, 16), L), dtype=np.int32)],
        outputs=[ct.TensorType(name="logits")],
        minimum_deployment_target=ct.target.iOS17,
        compute_units=ct.ComputeUnit.CPU_AND_NE,
    )
    op_cfg = ct.optimize.coreml.OpLinearQuantizerConfig(mode="linear_symmetric")
    cfg = ct.optimize.coreml.OptimizationConfig(global_config=op_cfg)
    mlm = ct.optimize.coreml.linear_quantize_weights(mlm, config=cfg)
    mlm.save(str(OUT / "rescorer.mlpackage"))
    print("wrote", OUT / "rescorer.mlpackage")


def export_tokenizer():
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
    print("wrote", OUT / "tokenizer.bin")


if __name__ == "__main__":
    export_tokenizer()      # first — coremltools' teardown abort can't clobber it
    export_model()
