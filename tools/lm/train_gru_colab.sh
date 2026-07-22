#!/usr/bin/env bash
# =============================================================================
# GRU keyboard LM — full CUDA pipeline for Google Colab (pretrain → fine-tune →
# distill → evaluate). Produces the streaming in-trie search-prior challenger.
#
# COLAB USAGE
#   1. Runtime -> Change runtime type -> Hardware accelerator: GPU (T4 / A100).
#   2. Put tools/lm/ (this script + *.py) and the data files under one folder,
#      e.g. upload to /content/lm  OR  mount Drive and point LM_DIR at it.
#      Required in $DATA_DIR (default $LM_DIR/data):
#        corpus.txt  gru_finetune.txt  messaging_heldout.txt
#        qwen_spm.model  qwen_pretrain.pt        (tokenizer + distill teacher)
#      (gru_finetune.txt is rebuilt automatically from dailydialog.txt +
#       sms_train.txt if those are present and it is missing.)
#   3. Run:   !bash /content/lm/train_gru_colab.sh
#      Faster smoke:  !PRETRAIN_EPOCHS=1 FINETUNE_EPOCHS=1 DISTILL_EPOCHS=1 bash .../train_gru_colab.sh
#      Skip distill:  !DO_DISTILL=0 bash .../train_gru_colab.sh
#      Save to Drive: !DRIVE_OUT=/content/drive/MyDrive/gru bash .../train_gru_colab.sh
#
# Progress: each Python stage prints a live tqdm bar (epoch, loss, it/s); this
# script prints a timestamped banner + elapsed time around every stage.
# =============================================================================
set -euo pipefail

# Reduce CUDA fragmentation (Colab's error message recommends this).
export PYTORCH_CUDA_ALLOC_CONF="${PYTORCH_CUDA_ALLOC_CONF:-expandable_segments:True}"

# ------------------------------- config --------------------------------------
LM_DIR="${LM_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
DATA_DIR="${DATA_DIR:-$LM_DIR/data}"
TOKENIZER="${TOKENIZER:-$DATA_DIR/qwen_spm.model}"   # shared with the distill teacher (6k)
# The 10.6M distill teacher. Prefer the MESSAGING-adapted finetune.pt over the broad
# qwen_pretrain.pt — the distill runs before the messaging fine-tune, and a stronger
# base teacher helps more (finetune.pt reportedly ~54 messaging ppl vs the GRU's ~250).
TEACHER="${TEACHER:-$DATA_DIR/qwen_pretrain.pt}"
CORPUS="${CORPUS:-$DATA_DIR/corpus.txt}"
FINETUNE_DATA="${FINETUNE_DATA:-$DATA_DIR/gru_finetune.txt}"
HELDOUT="${HELDOUT:-$DATA_DIR/messaging_heldout.txt}"
PRETRAIN_EPOCHS="${PRETRAIN_EPOCHS:-6}"
FINETUNE_EPOCHS="${FINETUNE_EPOCHS:-4}"
DISTILL_EPOCHS="${DISTILL_EPOCHS:-4}"
# Sized for a 15 GB T4: the [B, L, 6000] logits (x2 during distillation) are the
# memory bound, not the 2.3M GRU. 16384 tok -> ~500 seq/batch -> ~0.4 GB logits.
# Raise it on a bigger GPU (A100 40 GB: 65536 is fine); lower it if you still OOM.
BATCH_TOKENS="${BATCH_TOKENS:-16384}"
DO_DISTILL="${DO_DISTILL:-1}"
DRIVE_OUT="${DRIVE_OUT:-}"                            # optional checkpoint mirror

GRU="$DATA_DIR/gru.pt"

# ------------------------------- helpers -------------------------------------
START=$(date +%s)
elapsed() { local s=$(( $(date +%s) - START )); printf '%dm%02ds' $((s / 60)) $((s % 60)); }
banner() {
  echo
  echo "============================================================"
  echo ">> $*   ::   $(date '+%H:%M:%S')   (+$(elapsed))"
  echo "============================================================"
}

# --------------------------- environment -------------------------------------
banner "Environment + dependencies"
pip install -q sentencepiece tqdm
python3 - <<'PY'
import sys, torch
print("torch", torch.__version__, "| CUDA available:", torch.cuda.is_available())
if not torch.cuda.is_available():
    sys.exit("!! No CUDA GPU. Colab: Runtime -> Change runtime type -> GPU (T4/A100).")
print("GPU:", torch.cuda.get_device_name(0),
      f"| {torch.cuda.get_device_properties(0).total_memory / 1e9:.1f} GB")
PY

# --------------------------- input checks ------------------------------------
banner "Checking inputs in $DATA_DIR"
# Rebuild the messaging fine-tune set if it is missing but its sources exist.
if [[ ! -f "$FINETUNE_DATA" && -f "$DATA_DIR/dailydialog.txt" && -f "$DATA_DIR/sms_train.txt" ]]; then
  echo "  gru_finetune.txt missing -> rebuilding from dailydialog.txt + sms_train.txt"
  ( cd "$LM_DIR" && python3 prepare_gru_finetune.py )
fi

missing=0
check() { if [[ -f "$1" ]]; then echo "  ok        $1"; else echo "  MISSING   $1  ($2)"; missing=1; fi; }
check "$CORPUS"                "pretrain corpus"
check "$FINETUNE_DATA"         "messaging fine-tune set"
check "$HELDOUT"               "held-out eval set"
check "$TOKENIZER"             "SentencePiece tokenizer"
check "$LM_DIR/train_gru.py"   "trainer"
check "$LM_DIR/eval_gru.py"    "evaluator"
check "$LM_DIR/model.py"       "model definitions"
if [[ "$DO_DISTILL" == "1" ]]; then
  check "$TEACHER"             "distill teacher — or set DO_DISTILL=0"
fi
if [[ "$missing" != "0" ]]; then
  echo; echo "Upload the missing files into $DATA_DIR (or override DATA_DIR / individual paths)."
  exit 1
fi

cd "$LM_DIR"
COMMON=(--device cuda --tokenizer "$TOKENIZER" --batch-tokens "$BATCH_TOKENS")

# ORDER MATTERS: pretrain -> distill -> fine-tune. The messaging fine-tune must be the
# LAST stage, or a corpus-register distill reverts the adaptation (observed: messaging
# top-1 21.7% collapsed to 9.8% when distill ran last on the corpus).

# ------------------------------- stage 1 -------------------------------------
banner "Stage 1/4  PRETRAIN  (full corpus, ${PRETRAIN_EPOCHS} epochs)"
python3 train_gru.py "${COMMON[@]}" --data "$CORPUS" --out "$GRU" --epochs "$PRETRAIN_EPOCHS"

# ------------------------------- stage 2 -------------------------------------
if [[ "$DO_DISTILL" == "1" ]]; then
  banner "Stage 2/4  DISTILL  (teacher soft targets on the corpus, ${DISTILL_EPOCHS} epochs)"
  python3 train_gru.py "${COMMON[@]}" --finetune --data "$CORPUS" \
    --teacher "$TEACHER" --out "$GRU" --epochs "$DISTILL_EPOCHS"
else
  banner "Stage 2/4  DISTILL  (skipped — DO_DISTILL=0)"
fi

# ------------------------------- stage 3 -------------------------------------
banner "Stage 3/4  FINE-TUNE  (messaging register — LAST, ${FINETUNE_EPOCHS} epochs)"
python3 train_gru.py "${COMMON[@]}" --finetune --data "$FINETUNE_DATA" \
  --out "$GRU" --epochs "$FINETUNE_EPOCHS"

# ------------------------------- stage 4 -------------------------------------
banner "Stage 4/4  EVALUATE  (held-out messaging)"
python3 eval_gru.py --checkpoint "$GRU" --tokenizer "$TOKENIZER" \
  --heldout "$HELDOUT" --device cuda

# ------------------------------- mirror --------------------------------------
if [[ -n "$DRIVE_OUT" ]]; then
  banner "Mirroring checkpoint to $DRIVE_OUT"
  mkdir -p "$DRIVE_OUT"
  cp "$GRU" "$DRIVE_OUT/"
  echo "  mirrored: $(ls -1 "$DRIVE_OUT")"
fi

banner "DONE  —  total $(elapsed)"
