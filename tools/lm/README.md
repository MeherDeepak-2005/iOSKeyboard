# Keyboard neural rescorer

This directory contains the PyTorch-to-Core-ML pipeline used by the keyboard's
`NeuralScorer`. It supports both the legacy 4.7M `TinyLM` checkpoint and the
10,601,472-parameter, 6-layer checkpoint supplied with the Qwen distillation
project.

## Production export

Place the supplied source artifacts at:

- `data/qwen_pretrain.pt`
- `data/qwen_spm.model`
- `data/qwen_spm.vocab`
- `data/qwen_tokenizer_metadata.json`

The source checkpoint is currently stage `pretrain`; it is not a completed
distillation, messaging fine-tune, or QAT checkpoint. The exporter records the
stage and source SHA-256 in `coreml_export_manifest.json`.

Use the pinned ML environment, then run:

```bash
python export_coreml.py
python verify_coreml.py
```

`export_coreml.py` writes:

- `../../keyboard/rescorer.mlpackage`
- `../../keyboard/tokenizer.bin`
- `coreml_export_manifest.json`

The default export uses 512 representative messaging examples, a SmoothQuant
alpha of 0.5, fixed batch 16, sequence length 32, and eight candidate score
slots. It verifies numerical parity, graph quantization operations, checkpoint
and tokenizer hashes, and a 12 MB package-size gate before saving production
artifacts.

The resulting package is W8A8 for eligible matrix operations: INT8 weights and
calibrated INT8 activations. Layer normalization, softmax, indexing, and public
scores remain floating point because Core ML does not provide an all-INT8
transformer graph for those operations. No FP16 source model package is saved or
bundled.

## Current measurements

- Parameters: 10,601,472 unique parameters, with tied token embedding/head.
- Package: approximately 10.88 MB.
- Core ML conversion parity on representative messaging inputs: 100% candidate
  top-1 agreement and at least 95% next-token top-1 agreement.
- Held-out register check on 5,000 common messaging lines: per-word perplexity
  160.8 versus 408.1 for the legacy model.

Perplexity and conversion parity do not establish on-device latency or final
autocorrect accuracy. Measure those on supported physical devices before changing
blend weights or removing the n-gram fallback.

## Runtime contract

The Core ML interface is:

```text
tokens            int32 [16, 32]
score_positions   int32 [16, 8]
target_ids        int32 [16, 8]
score_mask      float32 [16, 8]
next_positions    int32 [16, 1]

candidate_log_probs [16]
next_logits         [16, 6000]
```

`NeuralScorer` zero-pads unused batch rows and consumes only the live output
prefix. The model remains off the keystroke path and falls back to the n-gram
scorer while loading or under memory pressure.

## Legacy training pipeline

The original model can still be reproduced with:

```bash
python prepare_data.py
python train_tokenizer.py
python train_lm.py
python eval_harness.py --neural
```
