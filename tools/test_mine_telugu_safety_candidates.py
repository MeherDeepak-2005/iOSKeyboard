import csv
import importlib.util
import json
import tempfile
import unittest
import zipfile
from pathlib import Path


def load_module():
    path = Path(__file__).with_name("mine_telugu_safety_candidates.py")
    spec = importlib.util.spec_from_file_location("mine_telugu_safety_candidates", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


miner = load_module()


class TeluguSafetyCandidateTests(unittest.TestCase):
    def make_sources(self, root: Path):
        toxic = "\u0c26\u0c42\u0c37\u0c23"
        common = "\u0c2e\u0c28\u0c02"
        safe = "\u0c2e\u0c02\u0c1a\u0c3f"
        csv_path = root / "hate.csv"
        with csv_path.open("w", encoding="utf-8", newline="") as handle:
            writer = csv.DictWriter(handle, fieldnames=["Sentence", "Hate-Speech"])
            writer.writeheader()
            for _ in range(3):
                writer.writerow({"Sentence": f"{toxic} {common}", "Hate-Speech": "yes"})
            for _ in range(12):
                writer.writerow({"Sentence": f"{safe} {common}", "Hate-Speech": "no"})
        archive = root / "aksharantar.zip"
        with zipfile.ZipFile(archive, "w") as target:
            records = [
                {"native word": toxic, "english word": "dhooshana"},
                {"native word": safe, "english word": "manchi"},
            ]
            target.writestr("tel_train.json", "".join(
                json.dumps(row, ensure_ascii=False) + "\n" for row in records
            ))
        return csv_path, archive, toxic, common

    def test_sentence_labels_only_create_review_candidates(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            csv_path, archive, toxic, common = self.make_sources(root)
            output = root / "candidates.tsv"
            audit = root / "audit.json"
            result = miner.build_candidates(csv_path, output, audit,
                                             minimum_log_ratio=1.0,
                                             aksharantar=archive)
            with output.open(encoding="utf-8", newline="") as handle:
                rows = list(csv.DictReader(handle, delimiter="\t"))
            by_term = {row["term"]: row for row in rows}
            self.assertEqual(by_term[toxic]["language"], "te")
            self.assertEqual(by_term["dhooshana"]["language"], "tenglish")
            self.assertTrue(all(row["review_status"] == "candidate" for row in rows))
            self.assertNotIn(common, by_term)
            self.assertEqual(result["runtime_terms_added"], 0)
            audit_text = audit.read_text(encoding="utf-8")
            self.assertNotIn(f"{toxic} {common}", audit_text)
            self.assertNotIn("sentences", json.loads(audit_text))

    def test_aliases_reject_non_training_split(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = root / "aksharantar.zip"
            with zipfile.ZipFile(archive, "w") as target:
                target.writestr("tel_valid.json", "")
            with self.assertRaises(ValueError):
                miner.roman_aliases(archive, "tel_valid.json", set(), 3)


if __name__ == "__main__":
    unittest.main()
