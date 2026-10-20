#!/usr/bin/env python3
"""Verify imported CoreV4 assets and every admitted spelling in the active pack."""
import hashlib
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
    pack=Pack(ROOT/'keyboard/langdata.bin')
    forms={w.decode() for w in pack.vocabulary()[0]}
    core=set((folder/'english-all.txt').read_text().splitlines())
    missing=core-forms
    if missing != core & EXCLUDE:
        raise ValueError('unexpected missing CoreV4 forms: '+repr(sorted(missing)))
    if pack.version!=6:
        raise ValueError('full vocabulary requires KBLM v6')
    result={'original_assets_verified':len(manifest['assets']), 'export_checksums_verified':len(manifest['exports']),
        'core_stored_forms':len(core), 'core_forms_in_active_pack':len(core & forms),
        'intentional_contraction_exclusions':sorted(missing),'active_pack_forms':len(forms),
        'active_pack_sha256':hashlib.sha256(pack.data).hexdigest()}
    print(json.dumps(result,indent=2))
if __name__=='__main__': main()
