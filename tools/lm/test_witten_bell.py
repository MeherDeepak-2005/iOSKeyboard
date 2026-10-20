import math
import unittest

from eval_harness import logprob


class Fixture:
    W = 3
    ids = {'a': 0, 'b': 1, 'c': 2}
    freqs = [100, 5, 1]

    def bigrams(self, previous):
        return (10, [(1, 2), (2, 1)]) if previous == 0 else None

    def trigrams(self, first, second):
        return (4, [(2, 4)]) if (first, second) == (0, 1) else None


class WittenBellTests(unittest.TestCase):
    def test_default_uses_token_frequency_and_original_unknown_floor(self):
        pack = Fixture()
        denominator = 109
        self.assertAlmostEqual(math.exp(logprob(pack, 'a', [])), 101 / denominator)
        self.assertAlmostEqual(math.exp(logprob(pack, 'c', [])), 2 / denominator)
        self.assertAlmostEqual(math.exp(logprob(pack, 'unknown', [])), .5 / denominator)
        self.assertEqual(logprob(pack, 'a', ['unknown']), logprob(pack, 'a', []))

    def test_contexts_use_stored_totals_and_sparse_floor(self):
        pack = Fixture()
        weight = 10 / 12 * 10 / 18
        self.assertAlmostEqual(math.exp(logprob(pack, 'b', ['a'])),
                               weight * 2 / 10 + (1 - weight) * 6 / 109)
        tri_weight = 4 / 5 * 4 / 12
        self.assertAlmostEqual(math.exp(logprob(pack, 'c', ['a', 'b'])),
                               tri_weight + (1 - tri_weight) * 2 / 109)
