#!/usr/bin/env python3
"""Decode the seven checksum-pinned CoreV4 English context triplets.

The v2 `_2.atc` tables hold next-next associations, not ordered trigrams.
The v4 Indian table holds ordered trigrams, mostly in a MARISA trie.
Snapshots keep variants separate and use dictionary-local, one-based IDs.
"""
from __future__ import annotations

import argparse
import bz2
import ctypes
import hashlib
import json
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools/vocabulary'))
from import_corev4 import decode_dictionary

FOLDER = ROOT / 'tools/data/corev4/english'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def decrypt(path):
    data = bytearray(path.read_bytes())
    span = remaining = 1
    for i in range(len(data)):
        if remaining == 0:
            span += 1
            remaining = span
        data[i] ^= 0x65 if remaining in (span, 1) else 0x53
        remaining -= 1
    return bytes(data)


class Reader:
    def __init__(self, data):
        self.data, self.pos = data, 0

    def take(self, n):
        if self.pos + n > len(self.data):
            raise ValueError(f'truncated at byte {self.pos}')
        result = self.data[self.pos:self.pos + n]
        self.pos += n
        return result

    def u8(self): return self.take(1)[0]
    def u16(self): return int.from_bytes(self.take(2), 'big')
    def u24le(self): return int.from_bytes(self.take(3), 'little')
    def u32(self): return int.from_bytes(self.take(4), 'big')


def local_id(global_id, dict_id, word_count):
    if global_id >> 24 == dict_id and 1 <= (global_id & 0xffffff) <= word_count:
        return global_id & 0xffffff
    # A source model may refer to a system or other dictionary ID. Keep the
    # original 32-bit identifier losslessly; KBLM conversion cannot map it.
    return -global_id if global_id else 0


def parse_atc(path, word_count):
    r = Reader(decrypt(path))
    version, data_version = r.u32(), r.u32()
    edit_type, dict_id, level = r.u8(), r.u8(), r.u16()
    if version not in (2, 4) or level not in (1, 2, 3):
        raise ValueError(f'unsupported context header in {path}')
    result = dict(version=version, data_version=data_version, edit_type=edit_type,
                  dict_id=dict_id, level=level)
    if level == 1:
        if r.u32() != 1: raise ValueError('unexpected unigram row count')
        r.u32()  # Legacy row index, unused by the online reader.
        n = r.u32()
        if n != word_count: raise ValueError('unigram/dictionary size mismatch')
        values = []
        for i in range(n):
            if version == 4 and i < 283: r.u8()  # key or machine metadata
            values.append(r.u16() if version == 4 else min(r.u32() & 0xffffff, 65535))
        # Three v2 UK snapshots have a one-byte terminal marker.
        if r.pos != len(r.data):
            if version != 2 or r.take(1) != b'\x01' or r.pos != len(r.data):
                raise ValueError('unexpected unigram tail')
        result['counts'] = values
        return result
    initial = r.u32()
    groups = initial if version == 4 else 1
    max_context, min_context, freq_max, freq_min = (r.u32() for _ in range(4))
    result['header_limits'] = [max_context, min_context, freq_max, freq_min]
    records = []
    for _ in range(groups):
        app_type = r.u32() if version == 4 else 1
        rows = r.u32() if version == 4 else initial
        for _ in range(rows):
            first = r.u24le()
            if not 1 <= first <= word_count: raise ValueError('invalid context row ID')
            n = r.u16()
            for _ in range(n):
                second = local_id(r.u32(), dict_id, word_count)
                third = local_id(r.u32(), dict_id, word_count) if version == 4 and level == 3 else None
                if version == 4:
                    r.u8()  # timestamp, not frequency
                    count = r.u16()
                else:
                    count = min(r.u32() & 0xffffff, 65535)
                if count:
                    records.append([app_type, first, second, third, count])
    if version == 2 or level == 2:
        if r.pos != len(r.data): raise ValueError('unconsumed context data')
    result['records'] = records
    result['static_tail'] = r.data[r.pos:] if level == 3 and version == 4 else b''
    return result


def extract_static_trigrams(tail, helper, dict_id, word_count):
    r = Reader(tail)
    if r.u32() != 1: raise ValueError('missing static trigram trie')
    with tempfile.TemporaryDirectory(prefix='corev4-trie-') as directory:
        path = pathlib.Path(directory) / 'trie.bin'
        path.write_bytes(tail[4:])
        run = subprocess.run([str(helper), str(path)], capture_output=True, text=True, check=True)
    num_keys, trie_bytes = map(int, run.stderr.strip().split())
    counts = tail[4 + trie_bytes:]
    if len(counts) != 2 * num_keys: raise ValueError('static trie/count vector length mismatch')
    records = []
    seen = set()
    for line in run.stdout.splitlines():
        key_id, key = line.split('\t')
        key_id = int(key_id)
        if key_id in seen or not 0 <= key_id < num_keys or len(key) != 24:
            raise ValueError('invalid or duplicate static trigram key')
        seen.add(key_id)
        ids = [local_id(int(key[i:i + 8], 16), dict_id, word_count) for i in (0, 8, 16)]
        count = int.from_bytes(counts[2 * key_id:2 * key_id + 2], 'big')
        if count: records.append([1, *ids, count])
    if len(seen) != num_keys: raise ValueError('static trigram enumeration incomplete')
    return records, num_keys


def compile_codec(core_root, directory):
    header = directory / 'quicklz.h'
    source = directory / 'quicklz.cpp'
    header.write_text((core_root / 'v2core/core/include/common/quicklz.h').read_text().replace('#include "stdafx.h"', '#include <stddef.h>'))
    source.write_text((core_root / 'v2core/core/source/common/quicklz.cpp').read_text().replace('#include "kptcall.h"', ''))
    library = directory / ('quicklz.dylib' if sys.platform == 'darwin' else 'quicklz.so')
    subprocess.run(['clang++', '-std=c++17', '-O2', '-DKPTINLINE=inline', '-DQLZ_MEMORY_SAFE',
                    '-dynamiclib' if sys.platform == 'darwin' else '-shared', '-fPIC',
                    str(source), '-o', str(library)], check=True)
    codec = ctypes.CDLL(str(library))
    for name in ('qlz_size_compressed', 'qlz_size_decompressed'):
        fn = getattr(codec, name)
        fn.argtypes = [ctypes.c_void_p]
        fn.restype = ctypes.c_size_t
    codec.qlz_decompress.argtypes = [ctypes.c_void_p] * 3
    codec.qlz_decompress.restype = ctypes.c_size_t
    return codec


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--core-root', type=pathlib.Path, required=True)
    parser.add_argument('--marisa-helper', type=pathlib.Path, required=True)
    args = parser.parse_args()
    core_root = args.core_root.resolve()
    manifest = json.loads((FOLDER / 'manifest.json').read_text())
    assets = {row['path']: row for row in manifest['assets']}
    out = FOLDER / 'contexts'
    out.mkdir(exist_ok=True)
    summary = []
    with tempfile.TemporaryDirectory(prefix='corev4-codec-') as temporary:
        codec = compile_codec(core_root, pathlib.Path(temporary))
        for row in manifest['dictionaries']:
            folder = FOLDER / 'raw' / row['id']
            dictionary = FOLDER / row['dictionary']
            if sha(dictionary) != row['dictionary_sha256']:
                raise ValueError('dictionary checksum mismatch')
            words, _ = decode_dictionary(dictionary, codec)
            if len(words) != row['stored_forms'] or len(set(words)) != len(words):
                raise ValueError('dictionary order/uniqueness mismatch')
            parsed = []
            for level in range(3):
                path = next(folder.glob(f'*_{level}.atc'))
                if sha(path) != assets[path.relative_to(FOLDER).as_posix()]['sha256']:
                    raise ValueError(f'context checksum mismatch: {path}')
                data = parse_atc(path, len(words))
                if data['level'] != level + 1: raise ValueError('context level mismatch')
                parsed.append(data)
            if len({data['dict_id'] for data in parsed}) != 1:
                raise ValueError('context dictionary IDs disagree')
            third = parsed[2]
            static_keys = 0
            if third['version'] == 4:
                static, static_keys = extract_static_trigrams(third.pop('static_tail'),
                                                               args.marisa_helper, third['dict_id'], len(words))
                third['records'].extend(static)
            else:
                third.pop('static_tail')
            snapshot = dict(schema_version=1, variant=row['id'], region=row['region'],
                            dictionary_sha256=row['dictionary_sha256'], words=words,
                            unigram=parsed[0]['counts'], bigram=parsed[1]['records'],
                            trigram=third['records'] if third['version'] == 4 else [],
                            next_next=third['records'] if third['version'] == 2 else [],
                            context_versions=[x['version'] for x in parsed],
                            static_trigram_keys=static_keys)
            path = out / f"{row['id']}.json.bz2"
            with bz2.open(path, 'wt', encoding='utf-8', compresslevel=9) as handle:
                json.dump(snapshot, handle, separators=(',', ':'), ensure_ascii=False)
            summary.append(dict(variant=row['id'], region=row['region'], path=path.relative_to(FOLDER).as_posix(),
                                sha256=sha(path), bytes=path.stat().st_size, words=len(words),
                                unigram_total=sum(snapshot['unigram']), bigram_records=len(snapshot['bigram']),
                                bigram_total=sum(x[-1] for x in snapshot['bigram']),
                                ordered_trigram_records=len(snapshot['trigram']),
                                ordered_trigram_total=sum(x[-1] for x in snapshot['trigram']),
                                next_next_records=len(snapshot['next_next']),
                                static_trigram_keys=static_keys))
            print(summary[-1], flush=True)
    (out / 'manifest.json').write_text(json.dumps(dict(schema_version=1, variants=summary), indent=2) + '\n')


if __name__ == '__main__': main()
