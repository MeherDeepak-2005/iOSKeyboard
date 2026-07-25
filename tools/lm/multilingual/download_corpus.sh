#!/bin/sh
set -eu
# Download the romanized code-mix sources. Corrects the earlier draft's bugs:
#   * CC-100 romanized splits are named hi_rom / te_rom (NOT hi_Latn/te_Latn), and each
#     is a SINGLE .txt.xz file, not chunked — the old `for i in 0 1` loop downloaded the
#     same URL twice and clobbered it.
#   * We do NOT download CC-100 English (en.txt.xz is ~80 GB). English already exists in
#     this repo's pipeline (OpenSubtitles/Leipzig via ../prepare_data.py -> ../data/corpus.txt),
#     so reuse that as the <en> source.
#   * Sangraha is a Hugging Face DATASET (ai4bharat/sangraha), not a GitHub repo you
#     sparse-checkout a `romanized/` folder from.
#
# Every URL below is marked VERIFY: confirm it resolves before a long run — upstream paths
# move. Sizes are approximate. Re-running is safe (each step skips if output exists).

cd "$(dirname "$0")"
mkdir -p raw
cd raw

echo ">>> [1/4] fastText LID model (optional; used only to REJECT native-script noise)"
# ~126 MB. VERIFY: https://fasttext.cc/docs/en/language-identification.html
if [ ! -f lid.176.bin ]; then
  curl -fL --retry 3 -o lid.176.bin \
    "https://dl.fbaipublicfiles.com/fasttext/supervised-models/lid.176.bin"
fi

echo ">>> [2/4] CC-100 romanized Hindi + Telugu (single .xz each)"
# VERIFY: https://data.statmt.org/cc-100/  (look for the *_rom entries in the table)
for lang in hi_rom te_rom; do
  if [ ! -f "cc100_${lang}.txt.xz" ]; then
    echo "  downloading cc100 ${lang} ..."
    curl -fL --retry 3 -o "cc100_${lang}.txt.xz" \
      "https://data.statmt.org/cc-100/${lang}.txt.xz"
  fi
done

echo ">>> [3/4] Google Dakshina (romanized lexicons + sentences for hi, te)"
# ~2 GB tar; we keep it for its romanization lexicons (attested spelling variants).
# VERIFY: https://github.com/google-research-datasets/dakshina
if [ ! -d dakshina_dataset_v1.0 ]; then
  curl -fL --retry 3 -o dakshina.tar \
    "https://storage.googleapis.com/gresearch/dakshina/dakshina_dataset_v1.0.tar"
  tar -xf dakshina.tar \
    "dakshina_dataset_v1.0/hi/romanized" "dakshina_dataset_v1.0/hi/lexicons" \
    "dakshina_dataset_v1.0/te/romanized" "dakshina_dataset_v1.0/te/lexicons" 2>/dev/null || \
    tar -xf dakshina.tar         # fall back to full extract if selective paths differ
  rm -f dakshina.tar
fi

echo ">>> [4/4] AI4Bharat Sangraha romanized subset (Hugging Face dataset) — OPTIONAL/large"
# The romanized subset is big; pull only Hindi + Telugu shards. Needs: pip install huggingface_hub
# VERIFY the in-repo paths first: https://huggingface.co/datasets/ai4bharat/sangraha/tree/main
if ! command -v huggingface-cli >/dev/null 2>&1; then
  echo "  (skip) huggingface-cli not installed — pip install huggingface_hub to enable"
else
  if [ ! -d sangraha ]; then
    huggingface-cli download ai4bharat/sangraha --repo-type dataset --local-dir sangraha \
      --include "verified/hin/*rom*" "verified/tel/*rom*" || \
      echo "  (warn) Sangraha include-paths did not match; inspect the dataset tree and adjust --include"
  fi
fi

cat <<'EOF'

Done (whatever resolved). Social-conversational data (the register closest to typing)
is NOT auto-downloadable — collect it yourself and drop cleaned .txt files in raw/:
  * YouTube comments on Telugu/Hindi channels (YouTube Data API) filtered by token-level LID
  * Reddit dumps: r/india, r/hyderabad, r/telugu, r/Ni_Bondha (Academic Torrents Pushshift archives)
  * CMU Hinglish DoG, SemEval-2020 Task 9 SentiMix, PHINC  (small but on-register)

Next:
  python build_codemix_corpus.py \
    --en   ../data/corpus.txt \
    --hlit raw/cc100_hi_rom.txt.xz \
    --xlit raw/cc100_te_rom.txt.xz \
    --lid-model raw/lid.176.bin
EOF
