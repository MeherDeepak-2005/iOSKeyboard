import unittest
from frequency_backoff import FrequencyBackoff


class Pack:
    W = 3
    freqs = [100, 5, 1]
    ids = {'a': 0, 'b': 1, 'c': 2}

    def bigrams(self, previous):
        return (1000, [(1, 2), (2, 1)]) if previous == 0 else None

    def trigrams(self, first, second):
        return (1000, [(2, 2)])


class FrequencyBackoffTests(unittest.TestCase):
    def test_mass_includes_unknown_and_survives_pruned_totals(self):
        model = FrequencyBackoff(Pack())
        for context in ([], ['a'], ['a', 'b'], ['unknown']):
            self.assertAlmostEqual(sum(model.probability(w, context) for w in (0, 1, 2, None)), 1)

    def test_zero_strength_is_interpolated_witten_bell(self):
        model = FrequencyBackoff(Pack(), strength=0)
        base = model.probability(1, [])
        self.assertAlmostEqual(model.probability(1, ['a']), (2 + 2 * base) / 5)

    def test_sparse_context_shrinks_toward_frequency(self):
        plain = FrequencyBackoff(Pack(), strength=0)
        conservative = FrequencyBackoff(Pack(), strength=8)
        base = plain.probability(0, [])
        self.assertLess(abs(conservative.probability(0, ['a']) - base),
                        abs(plain.probability(0, ['a']) - base))
