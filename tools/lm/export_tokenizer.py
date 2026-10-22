#!/usr/bin/env python3
"""Package a SentencePiece model as the keyboard's compact ``KBTK`` tokenizer blob.

The neural search prior bundles this blob beside its Core ML model. Reading the
protobuf directly keeps clean Xcode machines free of a ``sentencepiece`` install.
"""

from __future__ import annotations

import argparse
import struct
from pathlib import Path


def _read_protobuf_varint(data: bytes, offset: int) -> tuple[int, int]:
    value = 0
    shift = 0
    while offset < len(data) and shift < 70:
        byte = data[offset]
        offset += 1
        value |= (byte & 0x7F) << shift
        if byte < 0x80:
            return value, offset
        shift += 7
    raise ValueError("invalid protobuf varint in SentencePiece model")


def _protobuf_fields(data: bytes):
    """Yield protobuf fields without requiring generated SentencePiece bindings."""
    offset = 0
    while offset < len(data):
        key, offset = _read_protobuf_varint(data, offset)
        field_number, wire_type = key >> 3, key & 0x07
        if field_number == 0:
            raise ValueError("invalid protobuf field number in SentencePiece model")
        if wire_type == 0:
            value, offset = _read_protobuf_varint(data, offset)
        elif wire_type == 1:
            end = offset + 8
            if end > len(data):
                raise ValueError("truncated fixed64 protobuf field")
            value, offset = data[offset:end], end
        elif wire_type == 2:
            length, offset = _read_protobuf_varint(data, offset)
            end = offset + length
            if end > len(data):
                raise ValueError("truncated length-delimited protobuf field")
            value, offset = data[offset:end], end
        elif wire_type == 5:
            end = offset + 4
            if end > len(data):
                raise ValueError("truncated fixed32 protobuf field")
            value, offset = data[offset:end], end
        else:
            raise ValueError(f"unsupported protobuf wire type {wire_type}")
        yield field_number, wire_type, value


def _read_sentencepiece_model(path: Path) -> tuple[list[str], list[float], int]:
    """Read the stable ModelProto piece fields used by the iOS tokenizer.

    This build-time fallback keeps Xcode builds reproducible without relying on a
    developer's global Python environment. It deliberately reads only repeated
    SentencePiece records (piece, score, type); the UNKNOWN record supplies unk_id.
    """
    pieces: list[str] = []
    scores: list[float] = []
    unknown_id: int | None = None
    for field_number, wire_type, value in _protobuf_fields(path.read_bytes()):
        if field_number != 1 or wire_type != 2:
            continue
        piece = ""
        score = 0.0
        piece_type = 1
        for nested_number, nested_wire, nested_value in _protobuf_fields(value):
            if nested_number == 1 and nested_wire == 2:
                piece = nested_value.decode("utf-8")
            elif nested_number == 2 and nested_wire == 5:
                score = struct.unpack("<f", nested_value)[0]
            elif nested_number == 3 and nested_wire == 0:
                piece_type = nested_value
        if not piece:
            raise ValueError("SentencePiece record has no text")
        if piece_type == 2:
            if unknown_id is not None:
                raise ValueError("SentencePiece model has multiple UNKNOWN pieces")
            unknown_id = len(pieces)
        pieces.append(piece)
        scores.append(score)
    if not pieces or unknown_id is None:
        raise ValueError("SentencePiece model has no pieces or UNKNOWN piece")
    return pieces, scores, unknown_id


def export_tokenizer(sentencepiece_path: Path, output: Path) -> None:
    try:
        import sentencepiece as spm
    except ModuleNotFoundError:
        pieces, scores, unknown_id = _read_sentencepiece_model(sentencepiece_path)
    else:
        processor = spm.SentencePieceProcessor(model_file=str(sentencepiece_path))
        pieces = [processor.id_to_piece(index) for index in range(processor.vocab_size())]
        scores = [processor.get_score(index) for index in range(processor.vocab_size())]
        unknown_id = processor.unk_id()
    count = len(pieces)
    blob = bytearray()
    offsets = [0]
    for piece in pieces:
        blob += piece.encode("utf-8")
        offsets.append(len(blob))

    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_name(f".{output.name}.tmp")
    with temporary.open("wb") as handle:
        handle.write(struct.pack("<4I", 0x4B42544B, 1, count, unknown_id))
        handle.write(struct.pack(f"<{count}f", *scores))
        handle.write(struct.pack(f"<{count + 1}I", *offsets))
        handle.write(blob)
    temporary.replace(output)
    print(f"wrote {output} ({count:,} pieces)", flush=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sentencepiece", type=Path, required=True)
    parser.add_argument("--tokenizer-output", type=Path, required=True)
    args = parser.parse_args()
    export_tokenizer(args.sentencepiece, args.tokenizer_output)


if __name__ == "__main__":
    main()
