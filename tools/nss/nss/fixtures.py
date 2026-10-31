"""Tiny random NSS models for the C++ runtime tests (native/tests/fixtures/nss).

    python -m nss.fixtures

One model per runtime kernel (CIFG-LSTM tied, two-layer LSTM untied without projection,
GRU with projection) over a 300-word vocabulary, each with the goldens export.py writes.
The scores are meaningless; the tests only check that C++ reproduces Python exactly.
"""

from __future__ import annotations

from . import REPO
import json

import torch

from .export import goldens, quantized_copy, write
from .lexicon import Lexicon
from .models import build
from .vocab import Vocabulary

OUT = REPO / "native" / "tests" / "fixtures" / "nss"
MODELS = {
    "cifg-tied": {"arch": "lstm", "embed": 8, "hidden": 12, "proj": 8, "cifg": True, "tied": True},
    "lstm-untied": {"arch": "lstm", "embed": 8, "hidden": 10, "proj": None, "cifg": False, "layers": 2, "tied": False},
    "gru-projected": {"arch": "gru", "embed": 8, "hidden": 12, "proj": 8, "tied": True},
}


def main() -> None:
    full = Vocabulary.load()
    extra = [w for w in ("i'm", "going", "photos", "tomorrow", "morning", "dinner") if w not in full.words[:300]]
    vocab = Vocabulary.from_words(full.words[:300] + extra)
    lexicon = Lexicon.load()
    OUT.mkdir(parents=True, exist_ok=True)
    for index, (name, config) in enumerate(MODELS.items()):
        torch.manual_seed(index)
        model = build(config, len(vocab)).eval()
        with torch.no_grad():   # spread the output so arcs and <unk> are not uniform
            model.output_bias.normal_(0, 2)
        path = OUT / f"{name}.nsslm"
        write(model, vocab, 0.4, lexicon.sha256, path, unk_center=-3.0)
        # The runtime runs the int8 model; compare against exactly that.
        reference = quantized_copy(model)
        path.with_suffix(".goldens.json").write_text(json.dumps(goldens(reference, vocab, 0.4, lexicon, -3.0), indent=1) + "\n")
        print(path, path.stat().st_size)


if __name__ == "__main__":
    main()
