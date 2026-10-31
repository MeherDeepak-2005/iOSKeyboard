#!/usr/bin/env python3
"""Expand a frozen CIFG/tied NSLM export to a four-gate, untied LSTM.

This is an initialization, NOT new training or recovery of Google's weights.
i=sigmoid(-f_logits) preserves CIFG's i=1-f; the separate output matrix starts
as a copy of the input embedding. Quantized rows are copied without requantizing.
With the 30k/96/670/96 model this yields ~6.4M independently trainable parameters.
Used to separate the architecture change from the decoder experiment.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct


def expand(source: bytes) -> bytes:
    if source[:4] != b'NSLM':
        raise ValueError('not NSLM')
    version, arch, flags, vocab, embed, hidden, proj, layers, features = struct.unpack_from('<9I', source, 4)
    if version != 1 or arch != 1 or flags != 7 or layers != 1:
        raise ValueError('expected one-layer projected CIFG with tied embeddings')
    sections = {}
    for i in range(struct.unpack_from('<I', source, 64)[0]):
        ident, kind, rows, cols, offset, size = struct.unpack_from('<4I2Q', source, 256 + 32*i)
        if offset + size > len(source):
            raise ValueError('truncated section')
        sections[ident] = (kind, rows, cols, source[offset:offset+size])
    kind, rows, cols, data = sections[10]
    if rows != 3*hidden or kind != 1:
        raise ValueError('invalid gate matrix')
    matrix = data[:rows*cols]
    scales = data[(rows*cols+3)//4*4:]
    negative_forget = bytes((-struct.unpack('b', bytes([b]))[0]) & 255 for b in matrix[:hidden*cols])
    weights = negative_forget + matrix
    weights += bytes((-len(weights)) % 4)
    sections[10] = (kind, 4*hidden, cols, weights + scales[:4*hidden] + scales)
    kind, rows, cols, data = sections[11]
    bias = struct.unpack('<'+'f'*(3*hidden), data)
    expanded_bias = tuple(-x for x in bias[:hidden]) + bias
    sections[11] = (kind, 1, 4*hidden, struct.pack('<'+'f'*(4*hidden), *expanded_bias))
    sections[2] = sections[1]  # separate output, initially identical to embedding
    header = bytearray(source[:256])
    struct.pack_into('<I', header, 12, 4)  # projection only, no CIFG or tying
    struct.pack_into('<I', header, 64, len(sections))
    out = header + bytearray(32*len(sections))
    for i, (ident, (kind, rows, cols, data)) in enumerate(sorted(sections.items())):
        out += bytes((-len(out)) % 64)
        offset = len(out)
        struct.pack_into('<4I2Q', out, 256+32*i, ident, kind, rows, cols, offset, len(data))
        out += data
    return bytes(out)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    source = args.source.read_bytes()
    result = expand(source)
    args.output.write_bytes(result)
    v, e, h, p = struct.unpack_from('<4I', result, 16)
    parameters = 2*v*e + v + 4*h*(e+p) + 4*h + p*h
    manifest = dict(initialization='function-preserving CIFG expansion; not newly trained',
                    source_sha256=hashlib.sha256(source).hexdigest(), sha256=hashlib.sha256(result).hexdigest(),
                    bytes=len(result), parameters=parameters,
                    architecture=dict(arch='lstm', embed=e, hidden=h, proj=p, layers=1, cifg=False, tied=False))
    args.output.with_suffix('.manifest.json').write_text(json.dumps(manifest, indent=2)+'\n')
    print(json.dumps(manifest, indent=2))

if __name__ == '__main__':
    main()
