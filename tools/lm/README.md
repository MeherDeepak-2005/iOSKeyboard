# Neural rescorer pipeline (Phase B/C)

Trains the tiny LM that replaces the n-gram prior behind the engine's
`LanguageScorer` seam, and exports it for the keyboard extension.

## Pipeline

```bash
pip install sentencepiece torch coremltools numpy

python3 prepare_data.py                 # builds data/corpus.txt (tagged lines)
python3 train_tokenizer.py              # -> data/spm.model (6k pieces)
python3 train_lm.py                     # -> data/lm.pt        (~4.7M params)
python3 eval_harness.py                 # n-gram baseline vs +neural, top-1/top-3
python3 export_coreml.py                # -> ../../keyboard/rescorer.mlpackage
                                        #    ../../keyboard/tokenizer.bin
```

Then in Xcode: add `rescorer.mlpackage` + `tokenizer.bin` to the `keyboard/`
folder's membershipExceptions for the demo_keyboard target (same as
`langdata.bin` — see project.pbxproj). `NeuralScorer.bundled()` finds them at
launch and the engine switches from the pure n-gram prior to the blended one
automatically. No other code changes.

## Data registers

- `<en>`   conversational + news English (Leipzig; add OpenSubtitles for more)
- `<te>`   Telugu script (AI4Bharat Sangraha — pass --sangraha DIR after a
           manual download, it's too big to auto-fetch)
- `<xlit>` romanized Telugu (Dakshina; plus synthetic romanization of Sangraha
           via IndicXlit if you want volume)

`prepare_data.py` builds an English-only corpus by default so the pipeline runs
end-to-end today; pass the flags to add Telugu when the datasets are on disk.

## Budgets the defaults respect

4 layers / d256 / 6k vocab / tied embeddings ≈ 4.7M params ≈ 4.7 MB int8.
Scoring 12 candidates: one batched forward, ~7-10 ms CPU on-device.
Context window 32 tokens (~8 words + candidate).
