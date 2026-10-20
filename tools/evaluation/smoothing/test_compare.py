import math
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from compare import Models, NAMES


class Pack:
    W = 5
    words = ['a', 'b', 'c', 'x', 'y']
    ids = {w: i for i, w in enumerate(words)}
    freqs = [100, 90, 20, 10, 1]
    bi = {0: (999, [(3, 100), (4, 1)]), 1: (1, [(4, 1)]), 2: (1, [(4, 1)])}
    tri = {(0, 1): (999, [(3, 4), (4, 1)]), (2, 1): (1, [(4, 1)])}

    def bigrams(self, ctx):
        return self.bi.get(ctx)

    def trigrams(self, a, b):
        return self.tri.get((a, b))

    def iter_trigrams(self):
        for (a, b), (_, entries) in self.tri.items():
            yield a, b, entries


class ComparisonTests(unittest.TestCase):
    def test_reduced_topk_is_exact_full_vocabulary_ranking(self):
        models = Models(Pack())
        for name in NAMES:
            for ctx in [(), ('a',), ('b',), ('a', 'b'), ('unknown', 'b'), ('unknown',)]:
                brute = tuple(sorted(range(Pack.W), key=lambda w: (models.lp(name, w, ctx), Pack.words[w]), reverse=True)[:3])
                self.assertEqual(models.top3(name, ctx), brute)

    def test_witten_bell_matches_previous_production_formula(self):
        models = Models(Pack())
        def interpolate(total, types, count, backoff):
            confidence = total / (total + 8.)
            weight = total / (total + types) * confidence
            return weight * count / total + (1 - weight) * backoff
        for wid in (0, 3, 4, None):
            p = (Pack.freqs[wid] + 1 if wid is not None else .5) / (sum(Pack.freqs) + Pack.W)
            p = interpolate(1, 1, 1 if wid == 4 else 0, p)
            p = interpolate(999, 2, {3: 4, 4: 1}.get(wid, 0), p)
            self.assertAlmostEqual(models.lp(NAMES[0], wid, ('a', 'b')), math.log(p), places=12)


if __name__ == '__main__':
    unittest.main()
