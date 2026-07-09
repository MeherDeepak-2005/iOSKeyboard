#!/usr/bin/env python3
"""Train the shared 6k SentencePiece unigram vocab over all registers.

Small vocab is non-negotiable: embeddings are vocab x d_model and are tied, so
6k x 256 = 1.5M params — a 32k vocab would blow the whole parameter budget.
Byte fallback guarantees nothing is ever OOV; the <en>/<te>/<xlit> tags are
user-defined symbols so each register conditions the model from token one.
"""

import sentencepiece as spm
from pathlib import Path

DATA = Path(__file__).resolve().parent / "data"

spm.SentencePieceTrainer.train(
    input=str(DATA / "corpus.txt"),
    model_prefix=str(DATA / "spm"),
    model_type="unigram",
    vocab_size=6000,
    character_coverage=0.9999,       # Telugu block must survive
    byte_fallback=True,
    # Contraction-aware vocab (the Apple-tokenizer lesson): the default
    # split_by_unicode_script=True forbids letter+punctuation pieces, so ▁don't
    # could never become one token no matter how frequent. The cleaned corpus
    # alphabet is [a-z' ] (+ Telugu block), so disabling it only lets pieces
    # cross the apostrophe — contractions earn whole-piece slots on frequency.
    split_by_unicode_script=False,
    user_defined_symbols=["<en>", "<te>", "<xlit>"],
    pad_id=3, unk_id=0, bos_id=1, eos_id=2,
    input_sentence_size=4_000_000,
    shuffle_input_sentence=True,
)
print("wrote", DATA / "spm.model")
