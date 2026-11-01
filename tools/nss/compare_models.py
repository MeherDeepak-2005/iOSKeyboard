"""Compare NSS checkpoints on the same held-out sets.

    cd tools/nss && python compare_models.py OUT.json NAME=runs/X/best.pt [NAME=...]

Every model is scored as exported (int8 rows, nss.export.quantized_copy) on the data-v2
test splits (soda dialogues; tatoeba without most Tom/Mary sentences; wikitext), the
original data/ tatoeba test and MASC held-out (identical in both corpora), with
nss.metrics.evaluate; then on MASC against the production Witten-Bell n-gram
(nss.evaluate.masc_comparison). nss.evaluate scores one checkpoint on the sets of the
corpus it was given; models trained on data/ and data-v2/ need the shared sets. OUT.json
keeps earlier models' entries.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import numpy as np
import torch

from nss import DATA, WORKSPACE
from nss.data import Shard
from nss.evaluate import masc_comparison
from nss.export import quantized_copy
from nss.lexicon import Lexicon, UnkPolicy
from nss.metrics import evaluate
from nss.models import build
from nss.vocab import Vocabulary

V2 = WORKSPACE / "data-v2"
SETS = [("soda", V2, "soda"), ("tatoeba-v2", V2, "tatoeba"), ("wikitext", V2, "wikitext"),
        ("tatoeba-v1", DATA, "tatoeba"), ("masc", V2, "masc")]


def main() -> None:
    out = Path(sys.argv[1])
    device = torch.device("cpu")
    vocab, lexicon = Vocabulary.load(), Lexicon.load()
    report = json.loads(out.read_text()) if out.exists() else {}
    for spec in sys.argv[2:]:
        name, path = spec.split("=", 1)
        checkpoint = torch.load(path, map_location="cpu", weights_only=False)
        if checkpoint["vocabulary_sha256"] != vocab.sha256:
            raise SystemExit(f"{path} was trained on a different vocabulary")
        model = build(checkpoint["config"]["model"], len(vocab))
        model.load_state_dict(checkpoint["model"])
        model.eval()
        int8 = quantized_copy(model).to(device)
        entry = {"checkpoint": path, "step": checkpoint["step"], "unk_lexicon_share": float(checkpoint["unk_lexicon_share"]),
                 "data_weights": checkpoint["data"]["weights"], "sets": {}}
        for label, root, source in SETS:
            shard = Shard.load(root, source, "test")
            scored = np.load(root / "masc.test.scored.npy") if source == "masc" else None
            entry["sets"][label] = evaluate(int8, shard, device, scored)
            print(name, label, json.dumps({k: round(v, 4) for k, v in entry["sets"][label].items()}), flush=True)
        policy = UnkPolicy.build(lexicon, vocab, entry["unk_lexicon_share"])
        entry["masc_vs_ngram"] = masc_comparison(int8, vocab, lexicon, policy, device)
        for register, row in entry["masc_vs_ngram"].items():
            print(name, "masc-vs-ngram", register, json.dumps({k: round(v, 4) for k, v in row.items()}), flush=True)
        report[name] = entry
        out.write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
