#!/usr/bin/env python3

import json
import tempfile
import unittest
from pathlib import Path

import numpy as np

import train_ranker


class RankerTests(unittest.TestCase):
    def candidate(self, word, spatial, ngram, source="fuzzyLexicon"):
        return {
            "word": word,
            "spatial_cost": spatial,
            "ngram_log_probability": ngram,
            "neural_log_probability": ngram,
            "log_frequency": 5,
            "source": source,
        }

    def test_fit_ranks_the_gold_without_forced_insertion(self):
        cases = []
        for split in ("train", "validation", "test"):
            for _ in range(3):
                typed = "mjght"
                rows = [
                    self.candidate("might", 0.6, -1.0),
                    self.candidate("night", 1.0, -4.0),
                    self.candidate("mjght", 0.0, -8.0, "typed"),
                ]
                cases.append({
                    "split": split,
                    "typed": typed,
                    "intended": "might",
                    "words": [row["word"] for row in rows],
                    "x": np.stack([train_ranker.candidate_features(row, typed) for row in rows]),
                    "gold": 0,
                })
        train = [case for case in cases if case["split"] == "train"]
        matrix = np.concatenate([case["x"] for case in train])
        mean, scale = matrix.mean(axis=0), matrix.std(axis=0)
        scale[scale < 1e-6] = 1
        weights = train_ranker.fit(train, mean, scale, 150, 0.04, 1e-3)
        metrics = train_ranker.evaluate(
            [case for case in cases if case["split"] == "test"],
            weights, mean, scale, 1.0,
        )
        self.assertEqual(metrics["oracle_recall"], 1.0)
        self.assertEqual(metrics["top1_end_to_end"], 1.0)

    def test_cross_split_user_is_rejected(self):
        rows = []
        for split in ("train", "validation"):
            rows.append({
                "user_id": "same-user",
                "split": split,
                "typed": "teh",
                "intended": "the",
                "candidates": [self.candidate("the", 0.8, -1)],
            })
        with tempfile.NamedTemporaryFile(mode="w", suffix=".jsonl", delete=False) as handle:
            for row in rows:
                handle.write(json.dumps(row) + "\n")
            path = Path(handle.name)
        try:
            with self.assertRaises(ValueError):
                train_ranker.load_cases(path)
        finally:
            path.unlink(missing_ok=True)

    def test_false_correction_rate_uses_only_clean_inputs(self):
        rows = [
            self.candidate("night", 0, 0),
            self.candidate("might", 1, -1, "typed"),
        ]
        clean = {
            "split": "test", "typed": "might", "intended": "might",
            "words": [row["word"] for row in rows],
            "x": np.stack([train_ranker.candidate_features(row, "might") for row in rows]),
            "gold": 1,
        }
        typo = dict(clean, typed="mjght", intended="might")
        matrix = np.concatenate([clean["x"], typo["x"]])
        mean = np.zeros(matrix.shape[1])
        scale = np.ones(matrix.shape[1])
        weights = np.zeros(matrix.shape[1])
        metrics = train_ranker.evaluate([clean, typo], weights, mean, scale, 1.0)
        self.assertEqual(metrics["false_correction_cases"], 1)
        self.assertEqual(metrics["false_correction_rate"], 1.0)


if __name__ == "__main__":
    unittest.main()
