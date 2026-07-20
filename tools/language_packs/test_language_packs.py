import argparse
import bz2
import importlib.util
import json
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))


def load(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, ROOT / filename)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


builder = load("build_tenglish_lexicon", "build_tenglish_lexicon.py")
telugu_builder = load("build_telugu_pack", "build_telugu_pack.py")
validator = load("validate_manifest", "validate_manifest.py")
compactor = load("ngram_compaction", "ngram_compaction.py")
corpus_preparer = load("prepare_telugu_corpus", "prepare_telugu_corpus.py")
range_sampler = load("sample_hf_text_ranges", "sample_hf_text_ranges.py")


class LanguagePackTests(unittest.TestCase):
    def test_ngram_compaction_enforces_exact_byte_budget(self):
        groups = {
            0: [(1, 10), (2, 5)],
            1: [(3, 9)],
        }
        retained, stats = compactor.compact_contexts(
            groups, context_record_bytes=10, continuation_record_bytes=6,
            byte_budget=22, max_continuations=4,
        )
        self.assertEqual(retained, {0: [(1, 10), (2, 5)]})
        self.assertEqual(stats["encoded_bytes"], 22)
        self.assertEqual(stats["dropped_context_count"], 1)

    def test_remote_range_sampling_stays_inside_disjoint_strata(self):
        starts = [
            range_sampler._range_start(b"fixture", index, 8, 8_000_000, 100_000)
            for index in range(8)
        ]
        self.assertEqual(starts, [
            range_sampler._range_start(b"fixture", index, 8, 8_000_000, 100_000)
            for index in range(8)
        ])
        for index, start in enumerate(starts):
            self.assertGreaterEqual(start, index * 1_000_000)
            self.assertLessEqual(start + 100_000, (index + 1) * 1_000_000)

    def test_corpus_preparer_filters_and_is_deterministic(self):
        with tempfile.TemporaryDirectory() as value:
            root = Path(value)
            first = root / "first.txt"
            second = root / "second.txt"
            first.write_text(
                "నేను ఇంటికి వెళ్తున్నాను. ఇది చాలా బాగుంది.\n"
                "నేను ఇంటికి వెళ్తున్నాను.\n"
                "https://example.com నేను ఇంటికి వెళ్తున్నాను.\n",
                encoding="utf-8",
            )
            second.write_text("మీరు ఎలా ఉన్నారు? అతను ఇక్కడ ఉన్నాడు.\n", encoding="utf-8")

            def run(inputs: list[Path], suffix: str):
                output = root / f"corpus-{suffix}.txt.bz2"
                report = root / f"report-{suffix}.json"
                result = corpus_preparer.prepare(argparse.Namespace(
                    input=inputs, format="auto", text_field="text", language="telugu",
                    source_id="fixture", output=output, report=report,
                    max_sentences=4, min_tokens=2, max_tokens=20,
                    min_script_ratio=0.75, max_fragment_characters=2000,
                ))
                return output, result

            one, first_report = run([first, second], "one")
            two, second_report = run([second, first], "two")
            with bz2.open(one, "rt", encoding="utf-8") as handle:
                one_rows = handle.read()
            with bz2.open(two, "rt", encoding="utf-8") as handle:
                two_rows = handle.read()
            self.assertEqual(one_rows, two_rows)
            self.assertEqual(first_report["output"]["sentences"], 4)
            self.assertEqual(second_report["output"]["sentences"], 4)
            self.assertNotIn("example", one_rows)

    def fixture_zip(self, root: Path) -> Path:
        path = root / "aksharantar.zip"
        rows = [
            {"native word": "నేను", "english word": "nenu", "source": "Dakshina"},
            {"native word": "నెను", "english word": "nenu", "source": "AK-NEF", "score": -1},
            {"native word": "మీరు", "english word": "meeru", "source": "Ak-Freq"},
            {"native word": "not telugu", "english word": "invalid", "source": "Ak-Freq"},
        ]
        payload = "".join(json.dumps(row, ensure_ascii=False) + "\n" for row in rows)
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr("tel_train.json", payload)
            archive.writestr("tel_valid.json", payload)
        return path

    def test_builds_hash_verified_research_pack(self):
        with tempfile.TemporaryDirectory() as value:
            root = Path(value)
            args = argparse.Namespace(input_zip=self.fixture_zip(root),
                                      member="tel_train.json", output_dir=root / "pack",
                                      identifier="test", version=1, max_keys=100,
                                      max_variants=4, license_ack=True)
            path = builder.build_pack(args)
            manifest = validator.validate_manifest(path)
            self.assertEqual(manifest["release_status"], "research")
            self.assertEqual(manifest["build"]["key_count"], 2)
            self.assertEqual(manifest["build"]["variant_count"], 3)

    def test_rejects_evaluation_split_as_training_input(self):
        with tempfile.TemporaryDirectory() as value:
            root = Path(value)
            database = builder.sqlite3.connect(":memory:")
            with self.assertRaisesRegex(ValueError, "training member"):
                builder.ingest(self.fixture_zip(root), "tel_valid.json", database)

    def test_reviewed_core_aliases_are_validated_and_pinned(self):
        with tempfile.TemporaryDirectory() as value:
            root = Path(value)
            database = builder.sqlite3.connect(":memory:")
            builder.ingest(self.fixture_zip(root), "tel_train.json", database)
            core = root / "core.tsv"
            core.write_text(
                "roman\tnative\tweight\treview_status\tnote\n"
                "meeru\tమీరు\t10\tapproved\tcore pronoun\n",
                encoding="utf-8",
            )
            count, digest = builder.ingest_reviewed_core(core, database)
            self.assertEqual(count, 1)
            self.assertEqual(digest, builder.sha256(core))
            row = database.execute(
                "SELECT native, weight FROM pairs WHERE roman = 'meeru'"
            ).fetchone()
            self.assertEqual(row, ("మీరు", 10.0))

    def test_direct_roman_corpus_promotes_attested_runtime_keys(self):
        with tempfile.TemporaryDirectory() as value:
            root = Path(value)
            database = builder.sqlite3.connect(":memory:")
            builder.ingest(self.fixture_zip(root), "tel_train.json", database)
            builder.select_keys(database, 1, [(["meeru"], 100)])
            selected = database.execute("SELECT roman FROM selected").fetchone()
            self.assertEqual(selected, ("meeru",))

    def test_roman_lm_stores_corpus_ranked_starters(self):
        groups, _ = builder._group_roman_ngrams(
            [(["meeru", "nenu"], 2), (["meeru"], 4)],
            {"nenu": 0, "meeru": 1},
        )
        self.assertEqual(groups[builder.ROMAN_START_CONTEXT], [(1, 6), (0, 2)])

    def test_layout_compiler_rejects_unclassified_script_keys(self):
        with tempfile.TemporaryDirectory() as value:
            root = Path(value)
            source = json.loads((ROOT / "sources/te-IN/apple-mobile-2020.json")
                                .read_text(encoding="utf-8"))
            source["composition"]["consonants"].remove(ord("హ"))
            broken = root / "layout.json"
            broken.write_text(json.dumps(source, ensure_ascii=False), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "absent from composition metadata"):
                telugu_builder.compile_layout(broken, root / "layout.kbpack")

    def test_telugu_pack_is_deterministic_and_attributes_contributors(self):
        with tempfile.TemporaryDirectory() as value:
            root = Path(value)
            archive = self.fixture_zip(root)
            tatoeba = root / "tel_sentences.tsv.bz2"
            with bz2.open(tatoeba, "wt", encoding="utf-8") as handle:
                handle.write("1\ttel\tనేను మీరు\tAlice\t2026-01-01\t2026-01-01\n")
                handle.write("2\ttel\tమీరు వచ్చారు\tBob\t2026-01-01\t2026-01-01\n")

            def build(output: Path) -> Path:
                return telugu_builder.build(argparse.Namespace(
                    layout=ROOT / "sources/te-IN/apple-mobile-2020.json",
                    aksharantar=archive, member="tel_train.json",
                    tatoeba=tatoeba, output_dir=output, max_words=8,
                    max_roman_keys=8, max_variants=3, license_ack=True,
                ))

            first = build(root / "first")
            second = build(root / "second")
            manifest = validator.validate_manifest(first)
            self.assertEqual(manifest["build"]["tatoeba_contributors"],
                             ["Alice", "Bob"])
            self.assertEqual((first.parent / "telugu_layout.kbpack").read_bytes(),
                             (second.parent / "telugu_layout.kbpack").read_bytes())
            self.assertEqual((first.parent / "telugu_langdata.bin").read_bytes(),
                             (second.parent / "telugu_langdata.bin").read_bytes())
            self.assertEqual((first.parent / "tenglish_lexicon.bin").read_bytes(),
                             (second.parent / "tenglish_lexicon.bin").read_bytes())
            self.assertEqual((first.parent / "telugu_langdata.bin").read_bytes()[:4],
                             b"KBTD")
            self.assertEqual((first.parent / "tenglish_lexicon.bin").read_bytes()[:4],
                             b"KBXL")
            self.assertEqual(int.from_bytes(
                (first.parent / "tenglish_lexicon.bin").read_bytes()[4:8], "little"), 3)
            self.assertGreater(manifest["build"]["roman_bigram_context_count"], 0)

    def test_corpus_manifest_is_hash_pinned_and_source_capped(self):
        with tempfile.TemporaryDirectory() as value:
            root = Path(value)
            corpus = root / "telugu.txt"
            corpus.write_text(
                "నేను మీరు\nమీరు నేను\nఇది బాగుంది\n",
                encoding="utf-8",
            )
            source = {
                "id": "fixture", "name": "Fixture", "path": corpus.name,
                "url": "https://example.invalid/fixture",
                "license": "Fixture", "licenseURL": "https://example.invalid/license",
                "sha256": telugu_builder.file_sha256(corpus),
                "sourceRevision": "1", "attribution": "Fixture",
                "split": "train", "purpose": "training", "language": "telugu",
                "domain": "conversational", "format": "text", "countWeight": 3,
                "maxSentences": 2, "researchOnly": True, "releaseEligible": False,
            }
            manifest = root / "corpora.json"
            manifest.write_text(json.dumps({"schemaVersion": 1, "sources": [source]}),
                                encoding="utf-8")
            native, roman, provenance, stats = telugu_builder.read_corpus_manifest(manifest)
            self.assertEqual(len(native), 2)
            self.assertEqual(roman, [])
            self.assertTrue(all(weight == 3 for _, weight in native))
            self.assertTrue(provenance[0]["research_only"])
            self.assertEqual(stats["fixture"]["selected"], 2)

            source["sha256"] = "0" * 64
            manifest.write_text(json.dumps({"schemaVersion": 1, "sources": [source]}),
                                encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "hash mismatch"):
                telugu_builder.read_corpus_manifest(manifest)

            source["sha256"] = telugu_builder.file_sha256(corpus)
            source["releaseEligible"] = True
            manifest.write_text(json.dumps({"schemaVersion": 1, "sources": [source]}),
                                encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "research-only"):
                telugu_builder.read_corpus_manifest(manifest)


if __name__ == "__main__":
    unittest.main()
