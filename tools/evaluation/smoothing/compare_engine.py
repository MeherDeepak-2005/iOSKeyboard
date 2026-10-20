#!/usr/bin/env python3
"""Compare three priors through real KeyboardEngine.decode; no parameter fitting.

python3 tools/evaluation/smoothing/compare_engine.py run
python3 tools/evaluation/smoothing/compare_engine.py report
"""
import argparse
from collections import Counter
import json
import os
from pathlib import Path
import subprocess

from calibrate import BASELINE, counts, paired_interval, read
from compare import ROOT, sha

OUT = ROOT / 'tools/evaluation/results/engine-smoothing-2026-10-19'
CAL = ROOT / 'tools/evaluation/results/correction-calibration-2026-10-19'
MODELS = ('wittenBell', 'modifiedKneserNey', 'frequencyBackoff')
CONFIG = Path('/tmp/ioskeyboard-correction-calibration-config.json')


def prepare():
    OUT.mkdir(parents=True, exist_ok=True)
    manifest = json.loads((CAL / 'dataset-manifest.json').read_text())
    assert sha(ROOT / 'keyboard/langdata.bin') == manifest['pack_sha256']
    requests = read(CAL / 'validation.jsonl')
    # Already known regression examples are diagnostic, excluded from corpus rates.
    diagnostic = [('coeevitjkn', 'correction', c) for c in
                  ([], ['possibly', 'receive'], ['for', 'definitely', 'decided'],
                   ['could', 'definitely', 'receive'])]
    diagnostic += [('thisbis', 'this is', []), ('sebd', 'send', ['can', 'you']),
                   ('coudl', 'could', ['this', 'work', 'running']),
                   ('recieve', 'receive', ['running', 'for', 'definitely'])]
    diagnostic += [(w, w, []) for w in ('colour', 'favourite', 'organise', 'brb',
                   'ttyl', 'tysm', 'screenshots', 'passkeys', 'epistemology', 'bengaluru')]
    for i, (typed, intended, context) in enumerate(diagnostic):
        requests.append(dict(id=100000+i, split='diagnostic', family='existing-regressions',
                             kind='diagnostic', typed=typed, intended=intended, context=context))
    (OUT / 'requests.jsonl').write_text(''.join(json.dumps(r)+'\n' for r in requests))
    experiment = dict(models=MODELS, policy=BASELINE, prototype_strength=8,
        incrementalEvery=20, requests_sha256=sha(OUT / 'requests.jsonl'),
        pack_sha256=manifest['pack_sha256'], source_manifest=manifest,
        source_sha256={str(p): sha(ROOT/p) for p in (
            Path('keyboard/Engine/NgramScorer.swift'), Path('keyboard/Engine/Keyboardengine.swift'),
            Path('keyboardTests/CorrectionCalibrationTests.swift'), Path(__file__).relative_to(ROOT))},
        limits=['Previously inspected synthetic validation corpus; this is a comparative audit, not a fresh blind production test.',
                'No parameter fitting; prototype strength fixed before this comparison.',
                'Baseline gates shared across models; no MKN-specific calibrated rescues.',
                'No neural inference, touch coordinates, learned personalization, physical-device latency or energy measurement.',
                'Diagnostic examples are already known and excluded from corpus rates.'])
    (OUT / 'experiment.json').write_text(json.dumps(experiment, indent=2)+'\n')


def run():
    if CONFIG.exists():
        raise RuntimeError(f'Another replay config exists: {CONFIG}; refusing to overwrite it')
    prepare()
    for model in MODELS:
        config = dict(dataset=str(OUT/'requests.jsonl'), output=str(OUT/f'{model}.jsonl'),
                      policy=BASELINE, incrementalEvery=20, smoothing=model)
        # Sequential runs share one simulator and one evaluator fixture.
        CONFIG.write_text(json.dumps(config))
        try:
            args = ['xcodebuild', '-project', str(ROOT/'keyboard.xcodeproj'),
                    '-scheme', 'keyboard', '-configuration', 'Debug', '-destination',
                    os.environ.get('KB_CALIBRATION_DESTINATION', 'platform=iOS Simulator,name=iPhone 17 Pro'),
                    '-derivedDataPath', '/tmp/ioskeyboard-mkn-derived', 'CODE_SIGNING_ALLOWED=NO',
                    'test' if model == MODELS[0] else 'test-without-building',
                    '-only-testing:keyboardTests/CorrectionCalibrationTests/replayFrozenCalibrationRequests()']
            print(f'Running full engine: {model}', flush=True)
            with (OUT/f'{model}-xcode.log').open('w') as log:
                subprocess.run(args, stdout=log, stderr=subprocess.STDOUT, check=True, cwd=ROOT)
            rows = read(OUT/f'{model}.jsonl')
            assert len(rows) == len(read(OUT/'requests.jsonl'))
            print(f'Completed {model}: {len(rows)} real decode results', flush=True)
        finally:
            CONFIG.unlink(missing_ok=True)
    report()


def report():
    experiment = json.loads((OUT/'experiment.json').read_text())
    assert sha(OUT/'requests.jsonl') == experiment['requests_sha256']
    all_rows = {m: read(OUT/f'{m}.jsonl') for m in MODELS}
    requests = read(OUT/'requests.jsonl')
    for rows in all_rows.values():
        assert len(rows) == len(requests)
        for expected, actual in zip(requests, rows):
            assert all(expected[k] == actual[k] for k in expected), actual['id']
    corpus = {m: [r for r in rows if r['split']=='validation'] for m, rows in all_rows.items()}
    metrics = {m: counts(rows) for m, rows in corpus.items()}
    diagnostics = {m: [dict(typed=r['typed'], intended=r['intended'], context=r['context'],
                           choice=r['choice'], suggestions=r['suggestions'], passed=r['choice']==r['intended']
                           and (r['intended']==r['typed'] or r['suggestions'][0]==r['intended']))
                       for r in rows if r['split']=='diagnostic'] for m, rows in all_rows.items()}
    gaps = {}
    for model, rows in corpus.items():
        buckets = Counter()
        for r in rows:
            if not r['kind'].startswith('typo'): continue
            if r['choice']==r['intended']: category='correct_commit'
            elif r['intended'] not in {c['word'] for c in r['candidates']}: category='gold_absent_from_published_candidates'
            elif r['choice']!=r['typed']: category='wrong_commit_gold_present'
            elif r.get('gate') and r['gate']['candidate']==r['intended']: category='gold_winner_but_abstained'
            else: category='gold_present_but_not_commit_winner'
            buckets[category] += 1
        gaps[model] = dict(buckets)
    comparisons = {}
    for model in MODELS[1:]:
        base = {r['id']: r['choice'] for r in corpus[MODELS[0]]}
        other = {r['id']: r['choice'] for r in corpus[model]}
        comparisons[model] = {}
        for label in ('typo', 'clean', 'typo_single', 'typo_multi', 'typo_real_word', 'clean_oov'):
            rows = [r for r in corpus[model] if (r['kind'].startswith(label) if label in ('typo','clean') else r['kind']==label)]
            comparisons[model][label] = {metric: {
                'difference': (metrics[model][label][metric] - metrics[MODELS[0]][label][metric])/len(rows),
                'paired_family_95_ci': paired_interval(rows, metric, base, other)} for metric in ('correct', 'wrong_commit')}
    result = dict(experiment=experiment, full_engine_metrics=metrics, versus_witten_bell=comparisons,
                  diagnostic_results=diagnostics, candidate_gap_analysis=gaps,
                  incremental_cases={m:sum(r['incremental'] for r in rows) for m,rows in corpus.items()},
                  result_sha256={m:sha(OUT/f'{m}.jsonl') for m in MODELS})
    (OUT/'summary.json').write_text(json.dumps(result, indent=2)+'\n')
    lines = ['FULL KEYBOARD ENGINE: WITTEN-BELL / MKN / FREQUENCY BACKOFF', '',
             'Shared original correction policy. No threshold or prototype fitting.',
             '3099 corpus cases, plus 18 separately reported existing diagnostics.', '']
    for m in MODELS:
        typo, clean = metrics[m]['typo'], metrics[m]['clean']
        lines.append(f"{m}: correct typo commits {typo['correct']}/{typo['cases']}; wrong typo commits {typo['wrong_commit']}/{typo['cases']}; clean changes {clean['wrong_commit']}/{clean['cases']}; diagnostics passed {sum(r['passed'] for r in diagnostics[m])}/{len(diagnostics[m])}.")
        lines.append('  Candidate failures: '+json.dumps(gaps[m], sort_keys=True))
    lines += ['', 'Differences and paired document-family 95% intervals relative to Witten-Bell:']
    for m, slices in comparisons.items():
        for label in ('typo','clean'):
            lines.append(f'{m}, {label}: '+json.dumps(slices[label], sort_keys=True))
    lines += ['', 'LIMITS', *experiment['limits'], '',
              'Reproduce: python3 tools/evaluation/smoothing/compare_engine.py run',
              'No production default is changed by the runner.']
    (OUT/'REPORT.txt').write_text('\n'.join(lines)+'\n')
    print('\n'.join(lines), flush=True)


if __name__=='__main__':
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('command', choices=('run','report'))
    args=ap.parse_args()
    run() if args.command=='run' else report()
