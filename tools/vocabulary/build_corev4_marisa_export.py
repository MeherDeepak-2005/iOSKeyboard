#!/usr/bin/env python3
"""Link the CoreV4 MARISA export helper against a built CoreV4 library set.

First build CoreV4's original PAL/Core targets with
`python3 docs/corev4/tools/build_and_smoke.py` from the CoreV4 checkout.
"""
import argparse
from pathlib import Path
import shlex
import subprocess

SCRIPT = Path(__file__).with_name('corev4_marisa_export.cpp')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--core-root', type=Path, required=True)
    parser.add_argument('--build-root', type=Path, required=True,
                        help='CoreV4 build folder containing products/*.a and objects/*common-args.resp')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    root, build = args.core_root.resolve(), args.build_root.resolve()
    responses = list((build / 'objects').rglob('*common-args.resp'))
    archives = sorted((build / 'products').glob('*.a'))
    if not responses or not archives or not (root / 'v2core/core/include').is_dir():
        parser.error('CoreV4 build products or response file are missing')
    defines = [token for token in shlex.split(responses[0].read_text()) if token.startswith('-D')]
    includes = [root / 'pal/include/android', root / 'pal/include', root / 'pal/include/private/android']
    for section in ('v2core/core/include', 'pal/include', 'api/include'):
        includes.extend(p for p in (root / section).rglob('*') if p.is_dir() and '.svn' not in p.parts)
    command = ['xcrun', 'clang++', '-std=c++14', '-Os', '-Wno-null-conversion']
    command += defines + ['-I' + str(path) for path in includes]
    command += [str(SCRIPT)] + list(map(str, archives))
    command += ['-framework', 'Foundation', '-o', str(args.output)]
    subprocess.run(command, check=True)
    print(args.output)


if __name__ == '__main__': main()
