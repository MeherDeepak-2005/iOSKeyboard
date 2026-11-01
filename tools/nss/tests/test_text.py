import unittest

from nss.lexicon import Lexicon, UnkPolicy
from nss import build_corpus
from nss.text import cased_sentences, sentences, words
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


    def test_cased_sentences_keep_the_words(self):
        text = "I met Sarah in London. 'Hello' – don’t   STOP!\nwait… What"
        self.assertEqual([[w for w, _ in c] for c in cased_sentences(text)], sentences(text))
        self.assertEqual(cased_sentences("we met Sarah"), [[("we", False), ("met", False), ("sarah", True)]])
        # Acronyms and single letters are not names: "OK", "TV", the "U" of "U.S."
        self.assertEqual(cased_sentences("ok OK TV U Sarah's"), [[("ok", False), ("ok", False), ("tv", False), ("u", False), ("sarah's", True)]])


class NameUnkTests(unittest.TestCase):
    def test_capitalized_names_become_unk(self):
        build_corpus._init(str(build_corpus.DEFAULT_VOCAB), str(build_corpus.DEFAULT_LANGDATA), frozenset({"sarah"}), 1.0)
        vocab = build_corpus._vocab
        self.assertNotEqual(vocab.id("sarah"), UNK)
        _, ids, lengths, stats = build_corpus._encode(("chat", "k", "I met Sarah. Sarah is here.\nhey sarah"))
        first, second, third = ids[:lengths[0]], ids[lengths[0]:lengths[0] + lengths[1]], ids[lengths[0] + lengths[1]:]
        self.assertEqual(first[3], UNK)    # inside a sentence, capitalized
        self.assertEqual(second[1], UNK)   # opening a sentence
        self.assertEqual(third[2], vocab.id("sarah"))   # lowercase: a word, not a name
        self.assertEqual(stats["names"], 2)
        build_corpus._init(str(build_corpus.DEFAULT_VOCAB), str(build_corpus.DEFAULT_LANGDATA))
        _, ids, _, stats = build_corpus._encode(("chat", "k", "I met Sarah."))
        self.assertEqual(stats["names"], 0)
        self.assertEqual(ids[3], vocab.id("sarah"))


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
