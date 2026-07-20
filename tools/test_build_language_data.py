import importlib.util
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).with_name("build_language_data.py")
SPEC = importlib.util.spec_from_file_location("build_language_data", MODULE_PATH)
LANGUAGE_DATA = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(LANGUAGE_DATA)


class EnglishVocabularySourceTests(unittest.TestCase):
    def test_esdb_snapshot_has_expected_tiers_and_coverage(self):
        tiers = LANGUAGE_DATA.load_esdb_tiers()
        self.assertGreaterEqual(sum(value == 60 for value in tiers.values()), 100_000)
        self.assertGreaterEqual(sum(value == 70 for value in tiers.values()), 50_000)
        self.assertEqual(tiers["haptic"], 60)

    def test_every_automatic_frequency_word_is_esdb_validated(self):
        tiers = LANGUAGE_DATA.load_esdb_tiers()
        supplemental = {
            line.partition("#")[0].split()[0].lower()
            for line in LANGUAGE_DATA.SUPPLEMENTAL.read_text(encoding="utf-8").splitlines()
            if line.partition("#")[0].strip()
        }
        vocab = LANGUAGE_DATA.build_vocab()
        self.assertGreaterEqual(len(vocab), 60_000)
        for word, _ in vocab:
            self.assertTrue(word in tiers or word in supplemental, word)


if __name__ == "__main__":
    unittest.main()
