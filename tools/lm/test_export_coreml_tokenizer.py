#!/usr/bin/env python3
"""Dependency-free SentencePiece packaging checks for clean Xcode machines."""

import struct
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import export_coreml


def varint(value: int) -> bytes:
    result = bytearray()
    while value >= 0x80:
        result.append((value & 0x7F) | 0x80)
        value >>= 7
    result.append(value)
    return bytes(result)


def bytes_field(number: int, value: bytes) -> bytes:
    return varint((number << 3) | 2) + varint(len(value)) + value


def varint_field(number: int, value: int) -> bytes:
    return varint(number << 3) + varint(value)


def piece(value: str, score: float, piece_type: int) -> bytes:
    payload = bytes_field(1, value.encode("utf-8"))
    payload += varint((2 << 3) | 5) + struct.pack("<f", score)
    payload += varint_field(3, piece_type)
    return bytes_field(1, payload)


class CoreMLTokenizerExportTests(unittest.TestCase):
    def test_minimal_protobuf_reader_preserves_piece_order_scores_and_unknown_id(self):
        model = piece("<unk>", 0.0, 2)
        model += piece("<pad>", -0.5, 3)
        model += piece("▁hello", -1.25, 1)
        with tempfile.TemporaryDirectory() as value:
            source = Path(value) / "spm.model"
            source.write_bytes(model)
            pieces, scores, unknown_id = export_coreml._read_sentencepiece_model(source)
        self.assertEqual(pieces, ["<unk>", "<pad>", "▁hello"])
        self.assertEqual(unknown_id, 0)
        self.assertEqual(scores, [0.0, -0.5, -1.25])

    def test_export_works_when_sentencepiece_module_is_not_installed(self):
        model = piece("<unk>", 0.0, 2) + piece("▁ok", -1.0, 1)
        with tempfile.TemporaryDirectory() as value:
            source = Path(value) / "spm.model"
            output = Path(value) / "tokenizer.bin"
            source.write_bytes(model)
            with mock.patch.dict(sys.modules, {"sentencepiece": None}):
                export_coreml.export_tokenizer(source, output)
            header = struct.unpack_from("<4I", output.read_bytes(), 0)
        self.assertEqual(header, (0x4B42544B, 1, 2, 0))


if __name__ == "__main__":
    unittest.main()
