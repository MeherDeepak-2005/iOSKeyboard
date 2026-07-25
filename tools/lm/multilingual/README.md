# Multilingual (code-mixed) GRU training pipeline

Takes the **verified monolingual GRU** (`gru-integration` branch) to trilingual —
English + romanized Hindi (Hinglish) + romanized Telugu (Tenglish) — by changing only
the **data and the tokenizer**. The GRU architecture, the Core ML export, the
`DecodeContract`/`TrieSearchPrior` engine, and the Swift side are **untouched**.

This is deliberately a thin layer over the scripts that already exist in `../`:

| Stage | Script | Output |
|---|---|---|
| 1. Download sources | `download_corpus.sh` | `raw/*` |
| 2. Clean + tag + split | `build_codemix_corpus.py` | `../data/corpus_mix.txt`, `..._mix.val.txt` |
| 3. Train tokenizer | `train_tokenizer_mix.py` | `../data/spm_mix.model` |
| 4. Train GRU | **existing** `../train_gru.py` | `../data/gru_mix.pt` |
| 5. Export Core ML | **existing** `../export_gru_coreml.py` + `../export_gru_score_coreml.py` | `gru.mlpackage`, `gru_score.mlpackage` |
| 6. Bundle | **existing** `../install_internal_gru.sh` | rebuilds `gru_tokenizer.bin` from `spm_mix.model` automatically |

## Why this shape (vs. the "retrieval rewrite" pitch)

The register-tag mechanism you already ship (`<en>/<te>/<xlit>` as SentencePiece
user-defined symbols, conditioning the GRU from token one, with per-register validation)
**is** the code-switching solution. A code-mixed GRU learns `P(khush | "i am feeling")`
directly — no retrieval index, no binary embeddings, no FAISS. `<xlit>` already means
"romanized Indic"; we reuse it for Tenglish and add `<hlit>` for Hinglish.

Corrections applied vs. the earlier draft scripts:
- **Tokenizer stays a 6k *unigram*** (tied-embedding budget), not an 8192 BPE with
  `pad_id=0`. That BPE would break the tied-embedding param math and force a re-verify of
  the Core ML parity tests.
- **CC-100 romanized splits are `hi_rom`/`te_rom`**, one `.xz` file each — not
  `hi_Latn`/`te_Latn`, not chunked. The old download loop fetched the same URL twice.
- **No CC-100 English** (80 GB); reuse this repo's existing `../data/corpus.txt`.
- **Sangraha is a HF dataset**, not a GitHub sparse-checkout.
- **LID cannot bucket romanized text.** fastText LID on Latin-script Hindi mostly returns
  `en`/noise. We trust language-sorted sources and use LID (optional) only to *reject*
  leaked native-script / other-language lines.

## Run it

```bash
cd tools/lm/multilingual
sh download_corpus.sh            # verify the VERIFY: URLs first; social data is manual

# add any social .txt you collected to the --hlit/--xlit lists
python build_codemix_corpus.py \
  --en   ../data/corpus.txt \
  --hlit raw/cc100_hi_rom.txt.xz \
  --xlit raw/cc100_te_rom.txt.xz \
  --lid-model raw/lid.176.bin \
  --max-per-register 1500000

python train_tokenizer_mix.py    # -> ../data/spm_mix.model  (6000; --vocab-size 8000 to bump)

# Existing trainer, pointed at the new corpus + tokenizer. Pretrain then finetune,
# exactly like the monolingual GRU. Per-register val ppl (incl. <hlit>) prints each epoch.
cd ..
python train_gru.py --tokenizer data/spm_mix.model --data data/corpus_mix.txt \
                    --out data/gru_mix.pt --epochs 3
# optional messaging-register finetune (build a code-mixed finetune set the same way):
# python train_gru.py --finetune --tokenizer data/spm_mix.model \
#                     --data data/corpus_mix_finetune.txt --out data/gru_mix.pt --lr 2e-4
```

Watch the **per-register validation perplexity** (`val ppl <en>/<hlit>/<xlit>`). If
`<hlit>`/`<xlit>` climb while `<en>` falls, English volume is drowning the Indic
registers — raise `--max-per-register` on the minority side or cap English, then rebuild
the corpus. This is the honest catastrophic-forgetting signal; per-register val is why
you don't need the pitch's manual "40/30/30 dice-roll" sampler (and that sampler's
`self.english *= ...` bucket-padding double-counts length — avoid it).

## Export + bundle (unchanged scripts)

```bash
# from tools/lm, in your conda `ml` env
python export_gru_coreml.py        # gru.pt weights -> gru.mlpackage  (point it at gru_mix.pt)
python export_gru_score_coreml.py  # batched scorer -> gru_score.mlpackage
```

Then set, in `Config/Secrets.xcconfig` (see `.example`):
```
INTERNAL_GRU_ENABLED         = YES
INTERNAL_GRU_MODEL_PACKAGE   = .../gru.mlpackage
INTERNAL_GRU_SCORE_PACKAGE   = .../gru_score.mlpackage
INTERNAL_GRU_TOKENIZER_MODEL = .../data/spm_mix.model
```
Build with `-D INTERNAL_GRU`. `install_internal_gru.sh` recompiles the model **and
rebuilds `gru_tokenizer.bin` from `spm_mix.model`** — the Swift tokenizer then encodes
prefixes into the exact ids the retrained GRU expects. Re-run the Core ML↔PyTorch parity
tests (`gruCoreMLScoresMatchPyTorchReference`) after export.

## Out of scope here — the trie (Stage 1, Swift/asset side)

Merging romanized Hindi/Telugu wordlists + Dakshina spelling variants into the on-device
trie is a **separate** task in `../build_language_data.py`, which emits the mmap'd
`langdata.bin`. Do **not** hack it blindly: its inputs are checksum-pinned, release-immutable
(ESDB v2, hermitdave FrequencyWords at a pinned commit, a vendored Tatoeba snapshot), and
`verify_release_artifacts.py` guards them. Adding registers means extending that builder's
inputs deliberately and re-running its verifier — track it on its own, not in this LM step.
The GRU (this pipeline) attacks next-word prediction and code-switching; the trie merge
attacks whether "khush" can be *typed/corrected* at all. Both are needed for the full
product; they ship independently.
```
