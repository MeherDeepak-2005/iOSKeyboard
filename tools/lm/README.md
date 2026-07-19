# Experimental language-model research

This directory is an **offline research workspace**. No model, tokenizer, Core ML
runtime, or neural scorer from this directory is included in the shipping app or
keyboard extension. Production decoding currently uses the memory-mapped
`langdata.bin` n-gram model.

The scripts preserve earlier PyTorch, tokenizer, probing, and Core ML experiments
so a future model can be evaluated reproducibly. Their outputs are development
artifacts, not production deliverables. In particular, do not add
`rescorer.mlpackage`, `tokenizer.bin`, or an export manifest to an Xcode target
without completing the promotion gates below.

## Research inputs

Some scripts expect local files under `data/`, such as a checkpoint and a
SentencePiece model. Those inputs are intentionally not treated as release assets.
An old checkpoint was identified as a pretraining-stage artifact, not a completed
messaging distillation, task fine-tune, or quantization-aware training checkpoint.
Conversion parity and perplexity alone do not establish autocorrect quality.

## Promotion gates

A neural model may enter the app only after all of these are recorded in a reviewed
artifact manifest:

1. Provenance and commercial redistribution rights for every corpus, checkpoint,
   tokenizer, calibration sample, and generated artifact.
2. A user-separated, blind typo and next-word evaluation showing a statistically
   reliable gain over the shipping n-gram decoder, including false-correction rate.
3. Candidate-oracle recall proving the correct word reaches the rescorer; a larger
   model cannot recover candidates discarded before scoring.
4. Core ML graph inspection, fixed or explicitly flexible input shapes, conversion
   parity, quantization details, and deterministic source hashes.
5. Physical-device measurements across supported devices for p50/p95/p99 latency,
   peak and sustained extension footprint, energy, thermal behavior, and jetsam.
6. Stable session semantics: model readiness or memory pressure must not silently
   change the ranking tier in the middle of a word or Glide gesture.
7. Release archive inspection proving that only the reviewed package and tokenizer
   are bundled, with a remote rollback switch or version rollback plan.

## Research commands

Use an isolated, pinned Python environment. Depending on the experiment, scripts
include:

```bash
python prepare_data.py
python train_tokenizer.py
python train_lm.py
python eval_harness.py
python compare_scorers.py --help
python export_coreml.py --help
python verify_coreml.py --help
```

Consult each script before running it. Several scripts reference large local data
or optional ML packages and are not part of the Xcode build.

The production comparison and confidence-interval harness lives in
`tools/evaluation/`; use that task-level result, not token perplexity, to decide
whether a model is eligible for promotion.
