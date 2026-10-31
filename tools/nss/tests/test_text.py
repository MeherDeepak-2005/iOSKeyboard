import unittest

from nss.lexicon import Lexicon, UnkPolicy
from nss.text import sentences, words
from nss.vocab import BOS, UNK, Vocabulary


class TextTests(unittest.TestCase):
    def test_matches_keyboard_context_parsing(self):
        # Digits and hyphens separate; apostrophes (incl. U+2019) stay inside words.
        self.assertEqual(words("I have 2 well-known cats’ toys"),
                         ["i", "have", "well", "known", "cats'", "toys"])
        self.assertEqual(words("don’t   stop"), ["don't", "stop"])
        self.assertEqual(words("rock ' n ' roll"), ["rock", "n", "roll"])

    def test_sentence_boundaries(self):
        self.assertEqual(sentences("Hello. How are you?\nFine!"), [["hello"], ["how", "are", "you"], ["fine"]])
        # U+2026 is a separator for the keyboard, not a sentence end.
        self.assertEqual(sentences("wait… what"), [["wait", "what"]])
        self.assertEqual(sentences("... !!"), [])


class VocabularyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.vocab = Vocabulary.load()

    def test_specials_and_size(self):
        self.assertEqual(len(self.vocab), 30004)
        self.assertEqual(self.vocab.words[BOS], "<bos>")

    def test_context_and_candidate_lookup(self):
        self.assertEqual(self.vocab.id("'hello'"), self.vocab.exact("hello"))
        self.assertEqual(self.vocab.exact("'hello'"), UNK)
        self.assertEqual(self.vocab.id("<bos>"), UNK)
        self.assertEqual(self.vocab.id("zzzzqx"), UNK)

    def test_unk_policy_covers_lexicon_outside_vocabulary(self):
        lexicon = Lexicon.load()
        policy = UnkPolicy.build(lexicon, self.vocab, 0.5)
        self.assertGreater(policy.oov_words, 50_000)
        self.assertLess(policy.log_word_given_unk(1.0), 0)


if __name__ == "__main__":
    unittest.main()
