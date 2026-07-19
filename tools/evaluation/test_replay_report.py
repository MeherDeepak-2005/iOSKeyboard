#!/usr/bin/env python3

import json
import tempfile
import unittest
from pathlib import Path

import replay_report


class ReplayReportTests(unittest.TestCase):
    def row(self, case_id: str, user_id: str, intended: str = "hello") -> dict:
        return {
            "case_id": case_id,
            "user_id": user_id,
            "split": "test",
            "category": "near_typo",
            "typed": "hrllo",
            "intended": intended,
            "engine": {
                "suggestions": ["hello", "help", "hero"],
                "candidates": ["hello", "help", "hero"],
                "correction": "hello",
                "latency_ms": 4.0,
            },
            "baseline": {
                "suggestions": ["hero", "help", "hello"],
                "candidates": ["hero", "help", "hello"],
                "correction": None,
                "latency_ms": 9.0,
            },
        }

    def write_rows(self, rows: list[dict]) -> Path:
        temp = tempfile.NamedTemporaryFile(mode="w", suffix=".jsonl", delete=False)
        with temp:
            for row in rows:
                temp.write(json.dumps(row) + "\n")
        return Path(temp.name)

    def test_metrics_and_report(self) -> None:
        rows = [self.row("a", "u1"), self.row("b", "u2")]
        metrics = replay_report.aggregate(rows, "engine")
        self.assertEqual(metrics["correction_accuracy"], 1.0)
        self.assertEqual(metrics["suggestion_top1"], 1.0)
        output = replay_report.report(rows, "test", bootstrap=100, seed=1)
        self.assertIn("+100.00 pp", output)
        self.assertIn("exact McNemar", output)

    def test_cross_split_user_is_rejected(self) -> None:
        first = self.row("a", "same-user")
        second = self.row("b", "same-user")
        second["split"] = "validation"
        path = self.write_rows([first, second])
        with self.assertRaises(replay_report.SchemaError):
            replay_report.load_rows(path)

    def test_duplicate_case_is_rejected(self) -> None:
        path = self.write_rows([self.row("same", "u1"), self.row("same", "u2")])
        with self.assertRaises(replay_report.SchemaError):
            replay_report.load_rows(path)


if __name__ == "__main__":
    unittest.main()
