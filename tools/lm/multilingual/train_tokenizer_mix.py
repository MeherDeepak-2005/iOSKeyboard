#!/usr/bin/env python3
"""Train the code-mixed SentencePiece vocab over corpus_mix.txt.

Identical recipe to ../train_tokenizer.py (unigram, byte_fallback, contraction-aware
split_by_unicode_script=False) so the exported int8 math and the Swift tokenizer path
are unchanged — the ONLY differences are the corpus (now trilingual) and one extra
register symbol, ``<hlit>`` (romanized Hindi), alongside the existing tags.

Vocab stays 6000 by default. It is NOT the AI-suggested 8192 BPE:
  * embeddings are tied (vocab x d_model), so 6000 x 256 = 1.54M params; jumping to
    8192 adds ~0.5M params / ~0.5 MB int8. Affordable, not free — bump only if you
    measure real fragmentation on romanized spellings.
  * byte_fallback already guarantees nothing is ever OOV, so rare romanized spellings
    ("aapu", "vundhi") degrade to a few extra pieces rather than <unk>. The keyboard
    still ranks them; it just spends a couple more GRU steps.
  * a BPE swap would change the piece inventory and force you to rebuild qwen_spm's
    replacement AND re-verify the Core ML parity tests. Not worth it for a first cut.

  python train_tokenizer_mix.py [--vocab-size 6000] [--corpus ../data/corpus_mix.txt]

Output: ../data/spm_mix.model (+ .vocab). Point train_gru.py --tokenizer and the
extension's INTERNAL_GRU_TOKENIZER_MODEL at it; install_internal_gru.sh rebuilds
gru_tokenizer.bin from it automatically.
"""

import argparse
from pathlib import Path

import sentencepiece as spm

DATA = Path(__file__).resolve().parent.parent / "data"


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--corpus", type=Path, default=DATA / "corpus_mix.txt")
    ap.add_argument("--vocab-size", type=int, default=6000)
    ap.add_argument("--model-prefix", type=Path, default=DATA / "spm_mix")
    args = ap.parse_args()

    if not args.corpus.exists():
        raise SystemExit(f"missing {args.corpus} — run build_codemix_corpus.py first")

    spm.SentencePieceTrainer.train(
        input=str(args.corpus),
        model_prefix=str(args.model_prefix),
        model_type="unigram",
        vocab_size=args.vocab_size,
        character_coverage=0.9999,               # keep near-full char set for romanized variance
        byte_fallback=True,                      # never OOV
        split_by_unicode_script=False,           # let pieces cross apostrophes (contractions)
        # <hlit> added; the other three match ../train_tokenizer.py so <en>/<te>/<xlit>
        # tagged data (incl. the existing corpus.txt) tokenizes identically.
        user_defined_symbols=["<en>", "<te>", "<xlit>", "<hlit>"],
        pad_id=3, unk_id=0, bos_id=1, eos_id=2,
        input_sentence_size=4_000_000,
        shuffle_input_sentence=True,
    )
    print("wrote", args.model_prefix.with_suffix(".model"))


if __name__ == "__main__":
    main()
