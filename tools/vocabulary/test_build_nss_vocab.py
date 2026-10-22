"""Selection, apostrophe mapping and determinism checks for build_nss_vocab.py."""
import bz2
from collections import Counter
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_nss_vocab as nss


class NSSVocabularyTests(unittest.TestCase):
    def test_frequency_words_apostrophes_map_back_to_lexicon_spellings(self):
        lexicon = {"don't", "ill", "i'll", "hello"}
        evidence = Counter({"i'll": 3, "ill": 1})
        counts, total = nss.map_frequency_words(
            [("dont", 10), ("ill", 40), ("hello", 5), ("zzz", 7), ("123", 9)], lexicon, evidence)
        self.assertEqual(total, 62)                      # digits are not word tokens
        self.assertEqual(counts["don't"], 10)
        self.assertAlmostEqual(counts["i'll"], 40 * 3.5 / 5)
        self.assertAlmostEqual(counts["ill"], 40 * 1.5 / 5)
        self.assertEqual(counts["hello"], 5)

    def test_single_source_artifacts_need_strong_conversational_evidence(self):
        lexicon = {"the", "frodo", "lol", "quark", "monday"}
        sources = {
            "frequency-words": (Counter({"the": 900, "frodo": 50, "lol": 9_000}), 1_000_000),
            "tatoeba": (Counter({"the": 500, "quark": 4}), 1_000),
            "wikitext": (Counter({"the": 800, "quark": 9}), 1_000),
        }
        scores, _ = nss.score_words(sources, nss.DEFAULT_WEIGHTS, lexicon)
        chosen, rules = nss.select(scores, sources, lexicon, size=10, min_count=3,
                                   min_sources=2, conversational_ppm=20)
        rule = dict(chosen)
        self.assertEqual(rule["the"], "multi-source")
        self.assertEqual(rule["quark"], "multi-source")
        self.assertEqual(rule["frodo"], "conversational")   # 50 ppm clears the 20 ppm bar
        self.assertEqual(rule["lol"], "forced")
        self.assertEqual(rule["monday"], "forced")          # absent from every corpus
        chosen, _ = nss.select(scores, sources, lexicon, size=10, min_count=3,
                               min_sources=2, conversational_ppm=100)
        self.assertNotIn("frodo", dict(chosen))

    def test_size_cap_keeps_forced_words_and_ranks_by_score(self):
        lexicon = {"a", "b", "c", "i"}
        sources = {"tatoeba": (Counter({"a": 30, "b": 20, "c": 10, "i": 1}), 100),
                   "wikitext": (Counter({"a": 30, "b": 20, "c": 10, "i": 1}), 100)}
        scores, used = nss.score_words(sources, nss.DEFAULT_WEIGHTS, lexicon)
        self.assertAlmostEqual(sum(used.values()), 1.0)
        chosen, _ = nss.select(scores, sources, lexicon, size=2, min_count=1,
                               min_sources=2, conversational_ppm=20)
        self.assertEqual([word for word, _ in chosen], ["a", "i"])

    def test_geometric_mix_damps_a_single_corpus_spike(self):
        lexicon = {"tom", "house"}
        sources = {"frequency-words": (Counter({"tom": 10, "house": 100}), 100_000),
                   "tatoeba": (Counter({"tom": 5_000, "house": 100}), 100_000),
                   "wikitext": (Counter({"tom": 5, "house": 100}), 100_000)}
        arithmetic, _ = nss.score_words(sources, nss.DEFAULT_WEIGHTS, lexicon, "arithmetic")
        geometric, _ = nss.score_words(sources, nss.DEFAULT_WEIGHTS, lexicon, "geometric")
        self.assertGreater(arithmetic["tom"], arithmetic["house"])
        self.assertLess(geometric["tom"], geometric["house"])

    def test_included_words_are_kept_but_only_from_the_lexicon(self):
        lexicon = {"covid", "the", "zebra"}
        sources = {"tatoeba": (Counter({"the": 9, "zebra": 5, "covid": 4}), 100),
                   "wikitext": (Counter({"the": 9, "zebra": 5}), 100)}
        scores, _ = nss.score_words(sources, nss.DEFAULT_WEIGHTS, lexicon)
        chosen, rules = nss.select(scores, sources, lexicon, size=2, min_count=1, min_sources=2,
                                   conversational_ppm=20, include=["covid", "selfie"])
        self.assertEqual(dict(chosen), {"the": "multi-source", "covid": "forced"})
        self.assertEqual(rules["forced"], 1)

    def test_end_to_end_output_is_deterministic(self):
        lexicon = {"hello", "world", "don't", "i", "the"}
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            langdata = root / "langdata.bin"
            langdata.write_bytes(b"fixture")
            tatoeba = root / "tatoeba.tsv.bz2"
            with bz2.open(tatoeba, "wt", encoding="utf-8") as handle:
                handle.write("1\teng\tHello world, I don't know the world.\n2\tfra\tBonjour\n")
            chat = root / "chat.txt"
            chat.write_text("hello hello world i don't\n", encoding="utf-8")
            frequency = root / "en_full.txt"
            frequency.write_text("the 50\nhello 40\ndont 30\n", encoding="utf-8")
            outputs = []
            for run in range(2):
                out = root / f"out{run}"
                argv = ["--size", "4", "--langdata", str(langdata), "--tatoeba", str(tatoeba),
                        "--no-wikitext", "--chat", str(chat), "--frequency-words", str(frequency),
                        "--heldout", str(root / "missing.json.bz2"), "--min-count", "1",
                        "--out-dir", str(out), "--skip-hash-check"]
                with patch.object(nss, "load_lexicon", return_value=(lexicon, 2)):
                    nss.main(argv)
                outputs.append((out / "english-nss-vocab-4.tsv").read_text(encoding="utf-8"))
            self.assertEqual(outputs[0], outputs[1])
            rows = [line.split("\t") for line in outputs[0].splitlines()[1:]]
            self.assertEqual([row[1] for row in rows[:4]], nss.SPECIALS)
            self.assertEqual(len(rows), 8)
            self.assertIn("don't", [row[1] for row in rows])
            manifest = json.loads((root / "out0" / "english-nss-vocab-4.json").read_text())
            self.assertEqual(manifest["vocabulary"]["model_vocab_size"], 8)
            self.assertEqual(set(manifest["weights_used"]), {"chat", "frequency-words", "tatoeba"})


if __name__ == "__main__":
    unittest.main()
