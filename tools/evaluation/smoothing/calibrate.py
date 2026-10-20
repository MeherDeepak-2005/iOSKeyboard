#!/usr/bin/env python3
"""Fit on development production-gate evidence; audit frozen policy separately.

python3 tools/evaluation/smoothing/calibrate.py fit
python3 tools/evaluation/smoothing/calibrate.py report
"""
from collections import Counter, defaultdict
import argparse
import hashlib
import itertools
import json
import math
from pathlib import Path
import random
import statistics

from compare import ROOT, sha

OUT = ROOT/'tools/evaluation/results/correction-calibration-2026-10-19'
BASELINE = dict(oovMargin=3., realWordMargin=5., closeRescueMargin=3., closeRescueGap=0., minimumCloseGap=0., closeRescueMaxCost=1.6)


def accepts(gate, policy):
    margin = gate['typedMargin']
    gap = gate.get('candidateGap')
    meets = lambda threshold: gap is None or gap >= threshold
    kind = gate['kind']
    if kind == 'realWord': return margin > policy['realWordMargin']
    if kind == 'severe': return margin > math.log(10) and meets(math.log(2))
    if kind == 'loose': return margin > policy['oovMargin'] and meets(1.)
    assert kind == 'close'
    if not meets(policy['minimumCloseGap']): return False
    return margin > policy['oovMargin'] or (gate['allowsCloseRescue'] and gate['spatialCost'] <= policy['closeRescueMaxCost'] and margin > policy['closeRescueMargin'] and meets(policy['closeRescueGap']))


def choice(row, policy):
    gate = row.get('gate')
    if gate is None: return row['choice']
    return gate['candidate'] if accepts(gate, policy) else row['typed']


def read(path):
    return [json.loads(line) for line in path.read_text().splitlines() if line]


def counts(rows, policy=None):
    out = defaultdict(Counter)
    for row in rows:
        selected = choice(row, policy) if policy is not None else row['choice']
        keys = ['all', row['kind'], 'clean' if row['kind'].startswith('clean') else 'typo']
        for key in keys:
            out[key]['cases'] += 1
            out[key]['correct'] += selected == row['intended']
            out[key]['wrong_commit'] += selected != row['typed'] and selected != row['intended']
            out[key]['changed'] += selected != row['typed']
            out[key]['unfixed'] += selected == row['typed'] and selected != row['intended']
    return {k:dict(v) for k,v in out.items()}


def fit():
    # Validation outcomes are neither scored nor summarized during selection.
    rows=[r for r in read(OUT/'baseline-engine.jsonl') if r['split']=='development']
    assert rows
    for r in rows: assert choice(r,BASELINE)==r['choice'], r['id']
    baseline=counts(rows,BASELINE)
    profiles=[]
    for margin,gap,minimum,maxcost in itertools.product([0.,.5,1.,1.5,2.,2.5,3.], [.5,1.,1.5,2.,2.5,3.,4.,5.,6.,8.], [0.,.25,.5,.75,1.,1.5,2.], [.6,1.,1.2,1.6]):
        policy={**BASELINE,'closeRescueMargin':margin,'closeRescueGap':gap,'minimumCloseGap':minimum,'closeRescueMaxCost':maxcost}
        metrics=counts(rows,policy)
        safe=all(metrics[k]['wrong_commit']<=baseline[k]['wrong_commit'] for k in baseline if k.startswith('clean_') or k.startswith('typo_'))
        profiles.append(dict(policy=policy,metrics=metrics,safe=safe))
    profiles.append(dict(policy=BASELINE,metrics=baseline,safe=True))
    safe=[p for p in profiles if p['safe']]
    def key(p):
        m=p['metrics'];policy=p['policy']
        distance=abs(policy['closeRescueMargin']-3)+policy['closeRescueGap']+policy['minimumCloseGap']+abs(policy['closeRescueMaxCost']-1.6)
        return (m['typo']['correct'],-m['typo']['wrong_commit'],-m['clean']['wrong_commit'],-distance)
    best=max(safe,key=key)
    assert best['metrics']['typo']['correct']>=baseline['typo']['correct']
    frozen={'policy':best['policy'],'baseline_policy':BASELINE,'selection':'Maximize correct typo commits with no increase in wrong commits in any development typo or clean category; tie-break fewer errors then smallest parameter change.',
            'selected_on':'development only','configurations':len(profiles),'safe_configurations':len(safe),
            'baseline_development':baseline,'selected_development':best['metrics'],
            'dataset_manifest_sha256':sha(OUT/'dataset-manifest.json'),'baseline_engine_sha256':sha(OUT/'baseline-engine.jsonl'),
            'calibrator_sha256':sha(Path(__file__))}
    (OUT/'frozen-policy.json').write_text(json.dumps(frozen,indent=2)+'\n')
    # Full grid is a development artifact; never refit after inspecting validation.
    (OUT/'development-grid.json').write_text(json.dumps(profiles,indent=2)+'\n')
    buckets=defaultdict(Counter)
    for r in rows:
        g=r.get('gate')
        if not g: continue
        m=g['typedMargin'];gap=g.get('candidateGap')
        mb='<1' if m<1 else '1-2' if m<2 else '2-3' if m<3 else '3-5' if m<5 else '>=5'
        gb='none' if gap is None else '<0.5' if gap<.5 else '0.5-1' if gap<1 else '1-2' if gap<2 else '2-3' if gap<3 else '>=3'
        key=f"{r['kind']}|{g['kind']}|margin={mb}|gap={gb}|rescuable={g['allowsCloseRescue']}"
        buckets[key]['cases']+=1
        buckets[key]['winner_is_gold']+=g['candidate']==r['intended']
        buckets[key]['baseline_correct']+=r['choice']==r['intended']
        buckets[key]['selected_correct']+=choice(r,best['policy'])==r['intended']
    (OUT/'development-gap-analysis.json').write_text(json.dumps(buckets,indent=2)+'\n')
    print(json.dumps(frozen,indent=2))


def paired_interval(rows, metric, baseline, tuned):
    groups=defaultdict(lambda:[0,0])
    for r in rows:
        before=baseline[r['id']];after=tuned[r['id']]
        def value(c):
            if metric=='correct':return int(c==r['intended'])
            return int(c!=r['typed'] and c!=r['intended'])
        groups[r['family']][0]+=value(after)-value(before)
        groups[r['family']][1]+=1
    rng=random.Random(4419026);groups=list(groups.values());samples=[]
    for _ in range(5000):
        sample=rng.choices(groups,k=len(groups));samples.append(sum(x[0] for x in sample)/sum(x[1] for x in sample))
    samples.sort();return [samples[125],samples[4875]]


def report():
    frozen=json.loads((OUT/'frozen-policy.json').read_text())
    assert frozen['baseline_engine_sha256']==sha(OUT/'baseline-engine.jsonl')
    policy=frozen['policy']
    validation=[r for r in read(OUT/'baseline-engine.jsonl') if r['split']=='validation']
    actual=read(OUT/'selected-validation-engine.jsonl')
    assert {r['id'] for r in validation}=={r['id'] for r in actual}
    mismatches=[r['id'] for r in actual if choice(r,policy)!=r['choice']]
    assert not mismatches, mismatches[:10]
    # Compare both exact policy functions against identical final-engine evidence.
    baseline={r['id']:choice(r,BASELINE) for r in actual}
    tuned={r['id']:r['choice'] for r in actual}
    replay_prediction={r['id']:choice(r,policy) for r in validation}
    changed_pool=[r['id'] for r in actual if replay_prediction[r['id']]!=r['choice']]
    prior_baseline={r['id']:r['choice'] for r in validation}
    baseline_drift=[r['id'] for r in actual if prior_baseline[r['id']]!=baseline[r['id']]]
    paired=[]
    for label in ['typo','clean','typo_single','typo_multi','typo_real_word','clean_known','clean_oov','clean_contraction']:
        selected=[r for r in actual if (r['kind'].startswith('typo') if label=='typo' else r['kind'].startswith('clean') if label=='clean' else r['kind']==label)]
        paired.append({'slice':label,'cases':len(selected),'baseline':counts(selected,BASELINE)['all'],
                       'selected':counts(selected)['all'],
                       'correct_difference_95_ci':paired_interval(selected,'correct',baseline,tuned),
                       'wrong_commit_difference_95_ci':paired_interval(selected,'wrong_commit',baseline,tuned)})
    report={'frozen_policy':policy,'policy_sha256':sha(OUT/'frozen-policy.json'),
            'dataset_manifest':json.loads((OUT/'dataset-manifest.json').read_text()),
            'full_engine_validation':paired,
            'validation_cases':len(actual),'incremental_cases':sum(r['incremental'] for r in actual),
            'actual_engine_policy_mismatches':mismatches,
            'selected_vs_captured_baseline_pool_mismatch_ids':changed_pool,
            'baseline_drift_ids':baseline_drift,
            'comparison':'Baseline and selected policy use identical final full-engine gate evidence; direct/guarded outcomes with no gate are held fixed. Selected decisions verified against real DecodeSnapshot.correction.',
            'validation_engine_sha256':sha(OUT/'selected-validation-engine.jsonl'),
            'examples':[dict(id=r['id'],typed=r['typed'],intended=r['intended'],baseline=baseline[r['id']],selected=r['choice'],gate=r.get('gate')) for r in actual if baseline[r['id']]!=r['choice']][:40]}
    (OUT/'validation-summary.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({k:v for k,v in report.items() if k not in ['dataset_manifest','examples']},indent=2))


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('command',choices=['fit','report']);args=parser.parse_args()
    fit() if args.command=='fit' else report()
