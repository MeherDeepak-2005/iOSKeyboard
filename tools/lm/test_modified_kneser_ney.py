import math
import unittest
from pathlib import Path

from eval_harness import LangData, ModifiedKneserNey, mkn_logprob as logprob, mkn_discounts


class Fixture:
    W = 5
    ids = {'a': 0, 'b': 1, 'c': 2, 'x': 3, 'y': 4}
    # x is frequent in one context; y occurs in three distinct contexts.
    bi = {0: (999, [(3, 100), (4, 1)]),
          1: (1, [(4, 1)]), 2: (1, [(4, 1)])}
    tri = {(0, 1): (999, [(3, 4), (4, 1)]),
           (2, 1): (1, [(4, 1)])}

    def bigrams(self, previous):
        return self.bi.get(previous)

    def trigrams(self, first, second):
        return self.tri.get((first, second))

    def iter_trigrams(self):
        for (first, second), (_, entries) in self.tri.items():
            yield first, second, entries


class ModifiedKneserNeyTests(unittest.TestCase):
    def test_three_discounts_match_hand_calculation(self):
        # n1=8, n2=4, n3=2, n4=1 => Y=.5, D1=.5,D2=1.25,D3=2.
        self.assertEqual(mkn_discounts([1]*8 + [2]*4 + [3]*2 + [4]), [.5, 1.25, 2.0])
        self.assertEqual(mkn_discounts([]), [.75]*3)
        self.assertEqual(mkn_discounts([8, 100]), [.75]*3)

    def test_continuation_counts_replace_token_frequency(self):
        ld = Fixture()
        self.assertAlmostEqual(math.exp(logprob(ld, 'x', [])), 1 / 4.5)
        self.assertAlmostEqual(math.exp(logprob(ld, 'y', [])), 3 / 4.5)
        # Effective bigram counts are 1 and 2, not raw token counts.
        self.assertEqual(ld._mkn.bigrams[1][0], 3)
        self.assertAlmostEqual(ld._mkn.bigrams[1][1], 13 / 12)
        self.assertAlmostEqual(ld._mkn.bigrams[1][2][3], 2 / 3)
        self.assertAlmostEqual(ld._mkn.bigrams[1][2][4], 1.25)
        # Discounted trigram (4,1) + backoff from continuation bigram (1,2).
        expected_bi = (2 / 3) / 3 + (13 / 12) / 3 * (1 / 4.5)
        self.assertAlmostEqual(math.exp(logprob(ld, 'x', ['a', 'b'])),
                               3.25 / 5 + 1.5 / 5 * expected_bi)

    def test_missing_and_pruned_contexts_normalize(self):
        ld = Fixture()
        for ctx in [[], ['b'], ['a', 'b'], ['unknown'], ['unknown', 'b']]:
            mass = sum(math.exp(logprob(ld, word, ctx)) for word in ['x', 'y', '<unk>'])
            self.assertAlmostEqual(mass, 1)
        self.assertTrue(math.isfinite(logprob(ld, '<unk>', ['a', 'b'])))
        self.assertEqual(logprob(ld, 'x', ['unknown']), logprob(ld, 'x', []))

    def test_bigram_only_and_empty_models(self):
        ld = Fixture()
        ld.tri = {}
        model = ModifiedKneserNey(ld)
        self.assertEqual(model.bigrams[0][0], 101)  # retained sum, not stored 999
        ld.bi = {}
        self.assertEqual(logprob(ld, '<unk>', []), 0)

    def test_current_pack_is_readable_and_scores_are_finite(self):
        path = Path(__file__).resolve().parents[2] / 'keyboard/langdata.bin'
        ld = LangData(path)
        for ctx in [[], ["what's"], ['definitely', 'decided']]:
            for word in ['this', 'thus', 'correction', 'xyzunknown']:
                self.assertTrue(math.isfinite(logprob(ld, word, ctx)))
        self.assertGreater(logprob(ld, 'this', ["what's"]), logprob(ld, 'thus', ["what's"]))


if __name__ == '__main__':
    unittest.main()
