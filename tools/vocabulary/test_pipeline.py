"""Admission, leakage, probability and release-artifact regression checks."""
import bz2
from collections import Counter
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parent))
import import_sources as importer
import build_language_data as builder
from fetch_sources import cleanup, SOURCES, digest

class PipelineTests(unittest.TestCase):
    def test_unsupported_spans_do_not_create_false_adjacencies(self):
        for span in ["2026", "café", "wi-fi", "https://example.com", "me@example.com"]:
            tokens = importer.tokenize("hello " + span + " friend")
            self.assertIn(None, tokens, span)
            self.assertNotIn(("hello", "friend"), importer.count_contexts([tokens], {"hello", "friend"})[2])
        self.assertEqual(importer.tokenize("I'm ready"), ["i'm", "ready"])

    def test_related_document_names_share_split(self):
        self.assertEqual(importer.document_split("genre/book-1.txt"), importer.document_split("genre/book-2.txt"))
        self.assertFalse(importer.eligible("dont", curated=True))
        self.assertFalse(importer.eligible("café", curated=True))
        self.assertFalse(importer.eligible("u", curated=True))

    def test_usage_evidence_is_required_for_automatic_additions(self):
        catalog = {}
        importer.add_evidence(catalog, "epistemic", "wordnet")
        with patch.object(importer, "curated_terms", return_value={}):
            entries, _ = importer.select_entries(catalog, {}, {"epistemic": 499}, Counter(), Counter(), 4)
            self.assertEqual(entries, [])
            entries, _ = importer.select_entries(catalog, {}, {"epistemic": 999999}, Counter(), Counter(), 4)
            self.assertEqual(entries[0]["frequency_prior"], 20000)

    def test_pruning_keeps_true_context_denominator(self):
        groups = importer.context_groups(Counter({("hello", "friend"): 5, ("hello", "there"): 2}), 3, 10)
        self.assertEqual(groups, [{"context": ["hello"], "total": 7, "entries": [["friend", 5]]}])
        bi, _, totals = builder.merge_contexts({"hello": 0, "friend": 1}, {0: [(1, 4)]}, {},
            {"sources": {"masc": {"bigrams": groups, "trigrams": []}}})
        self.assertEqual(bi[0], [(1, 9)])
        self.assertEqual(totals["bigrams"][0], 11)

    def test_baseline_frequencies_retained_and_duplicate_rejected(self):
        snapshot = {"baseline_words": 2, "entries": [{"word": "colour", "frequency_prior": 100, "sources": ["esdb"]}]}
        self.assertEqual(builder.merge_expansion([("the", 1000), ("hello", 50)], snapshot),
            [("the", 1000), ("colour", 100), ("hello", 50)])
        snapshot["entries"].append(snapshot["entries"][0])
        with self.assertRaises(ValueError):
            builder.merge_expansion([("the", 1000), ("hello", 50)], snapshot)

    def test_oversize_candidate_does_not_replace_installed_artifact(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "pack.bin"
            path.write_bytes(b"existing")
            with patch.object(builder, "LANGDATA_CAP", 1), self.assertRaises(ValueError):
                builder.write_bin([("hello", 100)], {}, {}, [], output=path)
            self.assertEqual(path.read_bytes(), b"existing")
            self.assertFalse(path.with_suffix(".bin.tmp").exists())

    def test_failed_serialization_removes_temporary_file(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "pack.bin"
            path.write_bytes(b"existing")
            with self.assertRaises(Exception):
                builder.write_bin([("hello", -1)], {}, {}, [], output=path)
            self.assertEqual(path.read_bytes(), b"existing")
            self.assertFalse(path.with_suffix(".bin.tmp").exists())

    def test_duplicate_or_impossible_context_counts_are_rejected(self):
        group = {"context": ["hello"], "total": 1, "entries": [["friend", 2]]}
        snapshot = {"sources": {"masc": {"bigrams": [group], "trigrams": []}}}
        with self.assertRaises(ValueError):
            builder.merge_contexts({"hello": 0, "friend": 1}, {}, {}, snapshot)
        group["total"] = 4
        group["entries"].append(["friend", 2])
        with self.assertRaises(ValueError):
            builder.merge_contexts({"hello": 0, "friend": 1}, {}, {}, snapshot)

    def test_cleanup_preserves_unrecognized_or_changed_files(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)
            untouched = path / "my-notes.txt"
            untouched.write_text("keep")
            recognized = path / SOURCES["masc"]["file"]
            recognized.write_bytes(b"different content")
            with self.assertRaises(ValueError):
                cleanup(path)
            self.assertTrue(untouched.exists())
            self.assertTrue(recognized.exists())

    def test_vendored_snapshot_checksums_and_document_split(self):
        manifest, snapshot, contexts = builder.load_expansion(builder.EXPANSION_MANIFEST)
        self.assertEqual(len(snapshot["entries"]), 632)
        families = {}
        for document in manifest["documents"]:
            family = document["family"]
            if family in families:
                self.assertEqual(families[family], document["split"])
            families[family] = document["split"]
        record = manifest["artifacts"]["heldout"]
        heldout_path = importer.ROOT / record["path"]
        self.assertEqual(digest(heldout_path), record["sha256"])
        heldout = json.loads(bz2.decompress(heldout_path.read_bytes()))
        for row in heldout["sentences"]:
            self.assertEqual(importer.document_split(row["document"]), "test")
        self.assertTrue(contexts["sources"]["masc"]["bigrams"])

if __name__ == "__main__":
    unittest.main()
