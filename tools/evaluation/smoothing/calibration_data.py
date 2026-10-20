#!/usr/bin/env python3
"""Freeze family-disjoint development/validation requests before calibration."""
import bz2
from collections import Counter
import hashlib
import json
from pathlib import Path
import random
import sys

from compare import ROOT, LangData, family, sha
sys.path.insert(0, str(ROOT/'tools/lm'))
from eval_harness import corrupt

OUT = ROOT/'tools/evaluation/results/correction-calibration-2026-10-19'
SEED = 4419026


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    ld = LangData(ROOT/'keyboard/langdata.bin')
    heldout = ROOT/'tools/data/english-masc-heldout-v1.json.bz2'
    manifest = json.loads((ROOT/'tools/data/english-expansion-v1.manifest.json').read_text())
    assert sha(heldout) == manifest['artifacts']['heldout']['sha256']
    data = json.loads(bz2.decompress(heldout.read_bytes()))
    pools = {split: {'known': [], 'unknown': [], 'contraction': []} for split in ('development', 'validation')}
    families = {split: set() for split in pools}
    for sentence in data['sentences']:
        fam = family(sentence['document'])
        split = 'development' if int(hashlib.sha256(('mkn-calibration-v1:'+fam).encode()).hexdigest()[:8],16)%10 < 6 else 'validation'
        families[split].add(fam)
        context = []
        for word in sentence['tokens']:
            if word is None:
                context=[]
                continue
            if context and 4 <= len(word) <= 24 and word.isascii():
                kind = 'known' if word in ld.ids else 'unknown'
                if word.isalpha():
                    pools[split][kind].append((fam,word,context[-8:]))
                elif "'" in word and word in ld.ids:
                    pools[split]['contraction'].append((fam,word,context[-8:]))
            context.append(word)
    assert not families['development'] & families['validation']
    rng = random.Random(SEED)
    rows=[]
    for split,pool in pools.items():
        for entries in pool.values(): rng.shuffle(entries)
        for kind,entries,quota in [('clean_known',pool['known'],1000),('clean_oov',pool['unknown'],10000),('clean_contraction',pool['contraction'],100)]:
            for fam,word,ctx in entries[:quota]:
                rows.append(dict(split=split,family=fam,kind=kind,typed=word,intended=word,context=[] if rng.random()<.1 else ctx))
        for kind,edits,known,quota in [('typo_single',1,False,1000),('typo_multi',2,False,400),('typo_real_word',1,True,250)]:
            chosen=0; seen=set()
            for _ in range(8):
                for fam,word,ctx in pool['known']:
                    typo=corrupt(word,rng,edits=edits)
                    key=(fam,typo,word,tuple(ctx))
                    if typo==word or not typo.isalpha() or (typo in ld.ids)!=known or key in seen: continue
                    seen.add(key)
                    rows.append(dict(split=split,family=fam,kind=kind,typed=typo,intended=word,context=[] if rng.random()<.1 else ctx))
                    chosen+=1
                    if chosen>=quota: break
                if chosen>=quota: break
    rng.shuffle(rows)
    for index,row in enumerate(rows): row['id']=index
    for split in pools:
        selected=[r for r in rows if r['split']==split]
        (OUT/f'{split}.jsonl').write_text(''.join(json.dumps(r)+'\n' for r in selected))
    (OUT/'all.jsonl').write_text(''.join(json.dumps(r)+'\n' for r in rows))
    details={'seed':SEED,'split_rule':'SHA256(mkn-calibration-v1:+family) first 32 bits mod 10 < 6 -> development',
             'counts':dict(Counter(r['split']+':'+r['kind'] for r in rows)),
             'families':{s:sorted(f) for s,f in families.items()},
             'pack_sha256':sha(ROOT/'keyboard/langdata.bin'),'heldout_sha256':sha(heldout),
             'all_requests_sha256':sha(OUT/'all.jsonl'),
             'limits':['Underlying MASC corpus aggregate was inspected in earlier smoothing comparison; this is a new family-disjoint calibration split, not a newly blinded corpus.',
                       'Synthetic errors; source OOV spellings are preservation labels, not independently reviewed names.',
                       'Gold intended word is supplied only to evaluator, never to the engine. No personalization learning during replay.']}
    (OUT/'dataset-manifest.json').write_text(json.dumps(details,indent=2)+'\n')
    print(json.dumps(details['counts'],indent=2))


if __name__=='__main__': main()
