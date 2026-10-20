"""Experimental frequency-backed context smoothing; not a production replacement.

P(w|h) = [c(h,w) + (T(h)+strength)*P(w|suffix(h))] / [N(h)+T(h)+strength]

N is the sum of retained counts, T the number of retained successors. The
unigram distribution includes one unknown bucket. strength=0 is interpolated
Witten-Bell; 8 is an exploratory sparse-context prior, not a fitted optimum.
This is a standard shrinkage construction, not a claim of a novel estimator.
Run this file to audit the saved severe candidates under all three models.
"""
import json
import math
from functools import lru_cache

from compare import ROOT, LangData, Models, sha


class FrequencyBackoff:
    def __init__(self, data, strength=8.0):
        if not math.isfinite(strength) or strength < 0:
            raise ValueError('strength must be finite and nonnegative')
        self.data = data
        self.strength = strength
        self.total = sum(data.freqs) + data.W + 0.5

    @lru_cache(maxsize=100000)
    def rows(self, context):
        ids = [self.data.ids.get(w) for w in context]
        hits = []
        if ids and ids[-1] is not None:
            hits.append(self.data.bigrams(ids[-1]))
        if len(ids) == 2 and None not in ids:
            hits.append(self.data.trigrams(*ids))
        return tuple(dict(hit[1]) for hit in hits if hit and hit[1])

    def probability(self, wid, context):
        p = (self.data.freqs[wid] + 1 if wid is not None else .5) / self.total
        for counts in self.rows(tuple(context[-2:])):
            prior_mass = len(counts) + self.strength
            p = (counts.get(wid, 0) + prior_mass * p) / (sum(counts.values()) + prior_mass)
        return p

    def lp(self, wid, context):
        return math.log(self.probability(wid, context))


def main():
    pack = ROOT / 'keyboard/langdata.bin'
    directory = ROOT / 'tools/evaluation/results/correction-calibration-2026-10-19'
    audit = json.loads((directory / 'severe-baseline-audit.json').read_text())
    ld = LangData(pack)
    old = Models(ld)
    experimental = FrequencyBackoff(ld)
    results = []
    for case in audit['rows']:
        if case['policy'] != 'baseline':
            continue
        result = {'context': case['context'], 'models': {}}
        for name in ('witten_bell', 'modified_kneser_ney', 'frequency_backoff'):
            scored = []
            for candidate in case['candidates']:
                wid = ld.ids.get(candidate['word'])
                lp = (experimental.lp(wid, case['context']) if name == 'frequency_backoff'
                      else old.lp(name, wid, case['context']))
                score = lp - candidate['spatial_cost'] + .3 * candidate['log_frequency']
                scored.append({'word': candidate['word'], 'score': score})
            scored.sort(key=lambda row: row['score'], reverse=True)
            result['models'][name] = scored
        results.append(result)
    report = {'pack_sha256': sha(pack), 'strength': experimental.strength,
              'status': 'Exploratory fixed-candidate ranking audit, not full engine validation or promotion.',
              'rows': results}
    output = directory / 'frequency-backoff-audit.json'
    output.write_text(json.dumps(report, indent=2) + '\n')
    for row in results:
        print(row['context'], {name: scores[0]['word'] for name, scores in row['models'].items()})
    print(output)


if __name__ == '__main__':
    main()
