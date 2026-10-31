#!/usr/bin/env python3
"""Rebuild/replay the preserved decoder and published NSS graph on identical data.

python3 tools/nss/compare_paper.py --out /tmp/nss-paired
python3 tools/nss/compare_paper.py --score-only --out tools/evaluation/autocorrect/results

The --score-only mode reads nss-paper-before{,.ext,.keep}.jsonl and after equivalents.
All runs must be complete: incomplete or mismatched case sets are rejected.
"""
import argparse
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[2]
BENCH = ROOT / 'tools/evaluation/autocorrect'
BASELINE = '5f2df22065d4ac3aba3b6d76ff61c1ebc9e5fddc'
spec = importlib.util.spec_from_file_location('evaluate', BENCH/'evaluate.py')
eval = importlib.util.module_from_spec(spec)
spec.loader.exec_module(eval)


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def build(root, binary):
    subprocess.run(['xcrun', 'clang++', '-std=c++20', '-Os', '-DNDEBUG',
                    '-I', str(root/'native/DecoderCore/include'),
                    str(root/'tools/evaluation/autocorrect/IOSBench.cpp'),
                    *map(str, sorted((root/'native/DecoderCore/src').glob('*.cpp'))),
                    '-o', str(binary)], check=True)


def replay(binary, model, out, name):
    for corpus, suffix in [('cases.tsv',''),('ext-cases.tsv','.ext'),('keep-cases.tsv','.keep')]:
        subprocess.run([str(binary), str(ROOT/'keyboard/langdata.bin'), str(ROOT/'keyboard/safety.kbguard'),
                        str(BENCH/'corpus'/corpus), str(out/f'{name}{suffix}.jsonl')],
                       env={**os.environ, 'KB_NSS': str(model)}, check=True)


def read(out, name):
    data, process = {}, []
    for suffix in ['', '.ext', '.keep']:
        path = out/f'{name}{suffix}.jsonl'
        rows = [json.loads(line) for line in path.read_text().splitlines()]
        if not rows or rows[-1].get('kind') != 'done':
            raise ValueError(f'incomplete benchmark: {path}')
        cases = [r for r in rows if 'id' in r]
        if rows[-1]['events'] != len(cases):
            raise ValueError(f'event count mismatch: {path}')
        data.update({r['id']:r for r in cases})
        process += [r for r in rows if r.get('kind') == 'process' and r.get('at') == 'end']
    return data, process


def score(out, report_path):
    before, before_memory = read(out, 'nss-paper-before')
    after, after_memory = read(out, 'nss-paper-after')
    if before.keys() != after.keys():
        raise ValueError('unpaired case IDs')
    meta = json.loads((BENCH/'corpus/cases-meta.json').read_text())
    for path in sorted((BENCH/'corpus').glob('*-cases-meta.json')):
        meta.update(json.loads(path.read_text()))
    meta = {k:v for k,v in meta.items() if v['set'] in ('hard','apos') or eval.half(v) == 'held'}
    report = {'baseline_commit':BASELINE, 'total_paired_cases':len(before), 'split':'held',
              'metrics':{}, 'memory':{'before':before_memory,'after':after_memory},
              'model_before_sha256':digest(ROOT/'tools/nss/artifacts/baseline-step8000.nsslm'),
              'model_after_sha256':digest(ROOT/'keyboard/nss-english.nsslm'),
              'lexicon_sha256':digest(ROOT/'keyboard/langdata.bin'),
              'corpus_sha256':{p.name:digest(p) for p in sorted((BENCH/'corpus').glob('*cases.tsv'))},
              'compiler':subprocess.check_output(['clang++','--version'],text=True).splitlines()[0],
              'flags':['-std=c++20','-Os','-DNDEBUG']}
    for label, (ids, pred, up, guard) in eval.metrics(meta).items():
        ids = [i for i in ids if i in before]
        if not ids: continue
        a = [bool(pred(before[i],meta[i])) for i in ids]
        b = [bool(pred(after[i],meta[i])) for i in ids]
        gained = sum(y and not x for x,y in zip(a,b)); lost = sum(x and not y for x,y in zip(a,b))
        p = eval.mcnemar(gained,lost)
        report['metrics'][label] = dict(n=len(ids), before=100*sum(a)/len(a), after=100*sum(b)/len(b),
                                       gained=gained,lost=lost,p=p,higher_is_better=up,
                                       guardrail=guard,failed=guard and p<.05 and (gained<lost if up else gained>lost))
    typo = [i for i,m in meta.items() if m['set'] in ('ecps','syn') and i in before]
    nw = [i for i,m in meta.items() if m['set']=='nw' and i in before]
    for q in [.5,.95,.99]:
        report['metrics'][f'typo_request_p{int(q*100)}_ms'] = {name:eval.quantile([rows[i]['ms'] for i in typo],q) for name,rows in [('before',before),('after',after)]}
    if nw:
        report['metrics']['keystroke_p95_ms'] = {name:eval.quantile([v for i in nw for v in rows[i].get('msk',[])],.95) for name,rows in [('before',before),('after',after)]}
    report_path.parent.mkdir(parents=True,exist_ok=True)
    report_path.write_text(json.dumps(report,indent=2,allow_nan=False)+'\n')
    for label, r in report['metrics'].items():
        print(f'{label:48} {r["before"]:9.3f} -> {r["after"]:9.3f}')
    return report


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out',type=Path,required=True)
    parser.add_argument('--score-only',action='store_true')
    parser.add_argument('--report',type=Path,default=ROOT/'docs/nss-paper/comparison.json')
    args=parser.parse_args();out=args.out.resolve();out.mkdir(parents=True,exist_ok=True)
    if not args.score_only:
        with tempfile.TemporaryDirectory(prefix='nss-reference-') as directory:
            base=Path(directory); archive=base/'baseline.tar'
            subprocess.run(['git','-C',str(ROOT),'archive','--format=tar','-o',str(archive),BASELINE],check=True)
            source=base/'source';source.mkdir()
            with tarfile.open(archive) as tar: tar.extractall(source,filter='data')
            build(source,out/'before');build(ROOT,out/'after')
            replay(out/'before',ROOT/'tools/nss/artifacts/baseline-step8000.nsslm',out,'nss-paper-before')
            replay(out/'after',ROOT/'keyboard/nss-english.nsslm',out,'nss-paper-after')
    score(out,args.report)

if __name__=='__main__': main()
