#!/usr/bin/env python3
"""Verify imported CoreV4 assets and every admitted spelling in the active pack."""
import hashlib
import bz2
import json
from pathlib import Path
import sys
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'tools'))
from verify_language_data import Pack
from build_language_data import EXCLUDE

def main():
    folder=ROOT/'tools/data/corev4/english'
    manifest=json.loads((folder/'manifest.json').read_text())
    for row in manifest['assets']+manifest['exports']:
        payload=(folder/row['path']).read_bytes()
        if hashlib.sha256(payload).hexdigest()!=row['sha256']:
            raise ValueError('checksum mismatch: '+row['path'])
    for row in manifest['dictionaries']:
        if hashlib.sha256((folder/row['wordlist']).read_bytes()).hexdigest()!=row['wordlist_sha256']:
            raise ValueError('dictionary wordlist checksum mismatch')
    context_manifest=json.loads((folder/'contexts/manifest.json').read_text())
    if context_manifest['schema_version']!=1 or len(context_manifest['variants'])!=len(manifest['dictionaries']):
        raise ValueError('context variant manifest mismatch')
    for row in context_manifest['variants']:
        path=folder/row['path']
        if hashlib.sha256(path.read_bytes()).hexdigest()!=row['sha256'] or path.stat().st_size!=row['bytes']:
            raise ValueError('context snapshot checksum/size mismatch: '+row['variant'])
        with bz2.open(path,'rt',encoding='utf-8') as stream:
            snapshot=json.load(stream)
        if snapshot['variant']!=row['variant'] or len(snapshot['words'])!=row['words'] \
                or len(snapshot['unigram'])!=row['words'] \
                or sum(snapshot['unigram'])!=row['unigram_total'] \
                or len(snapshot['bigram'])!=row['bigram_records'] \
                or sum(x[-1] for x in snapshot['bigram'])!=row['bigram_total'] \
                or len(snapshot['trigram'])!=row['ordered_trigram_records'] \
                or sum(x[-1] for x in snapshot['trigram'])!=row['ordered_trigram_total'] \
                or len(snapshot['next_next'])!=row['next_next_records']:
            raise ValueError('context snapshot contents mismatch: '+row['variant'])
    pack=Pack(ROOT/'keyboard/langdata.bin')
    forms={w.decode() for w in pack.vocabulary()[0]}
    core=set((folder/'english-all.txt').read_text().splitlines())
    missing=core-forms
    if missing != core & EXCLUDE:
        raise ValueError('unexpected missing CoreV4 forms: '+repr(sorted(missing)))
    if pack.version!=6:
        raise ValueError('full vocabulary requires KBLM v6')
    result={'original_assets_verified':len(manifest['assets']), 'export_checksums_verified':len(manifest['exports']),
        'context_variants_verified':len(context_manifest['variants']),
        'core_stored_forms':len(core), 'core_forms_in_active_pack':len(core & forms),
        'intentional_contraction_exclusions':sorted(missing),'active_pack_forms':len(forms),
        'active_pack_sha256':hashlib.sha256(pack.data).hexdigest()}
    print(json.dumps(result,indent=2))
if __name__=='__main__': main()
