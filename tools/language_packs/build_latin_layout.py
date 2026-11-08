#!/usr/bin/env python3
"""Compile a reviewable Latin keyboard layout (JSON) into the runtime layout pack.

The keyboard extension reads only the compiled binary plist. Key order, pages,
long-press variants, per-field keys and the decoders' letter grid all live in the
JSON source, not in Swift or C++:

    python3 tools/language_packs/build_latin_layout.py \
        tools/language_packs/sources/en-US/qwerty.json keyboard/english_layout.kbpack

The compiled form is canonical: every key is a dictionary, and the letter grid's
rows are derived from the letters page, so the decoders cannot disagree with it.
"""

from __future__ import annotations

import argparse
import json
import plistlib
import unicodedata
from pathlib import Path

SCHEMA_VERSION = 1
FORMAT = "latin-layout"
PAGE_IDS = ("letters", "numbers", "symbols", "numberPad")
PAGE_TARGETS = {"letters", "numbers", "symbols"}
WIDTHS = {"unit", "flex", "modifier", "utility", "return"}
CONTROLS = {
    "shift", "delete", "page", "globe", "emoji", "space", "return",
    "fieldExtras", "padAuxiliary", "currency",
}
FIELD_KINDS = {"email", "url", "webSearch", "twitter"}
MAX_KEY_SCALARS = 8


class LayoutError(ValueError):
    pass


def _text(value: object, what: str) -> str:
    if not isinstance(value, str) or not value:
        raise LayoutError(f"{what} must be a non-empty string")
    normalized = unicodedata.normalize("NFC", value)
    if normalized != value:
        raise LayoutError(f"{what} {value!r} is not NFC")
    if len(value) > MAX_KEY_SCALARS or any(unicodedata.category(c).startswith("C") for c in value):
        raise LayoutError(f"{what} {value!r} is not a printable key value")
    return value


def _key(item: object, where: str) -> dict:
    """Canonical key: {"key": text} or {"control": name}, plus optional fields."""
    if isinstance(item, str):
        return {"key": _text(item, f"{where} key")}
    if not isinstance(item, dict):
        raise LayoutError(f"{where}: a key is a string or an object")
    unknown = set(item) - {"key", "control", "target", "label", "width", "accessibilityLabel"}
    if unknown:
        raise LayoutError(f"{where}: unknown key fields {sorted(unknown)}")
    if ("key" in item) == ("control" in item):
        raise LayoutError(f"{where}: a key has exactly one of 'key' or 'control'")
    out: dict = {}
    if "key" in item:
        out["key"] = _text(item["key"], f"{where} key")
    else:
        control = item["control"]
        if control not in CONTROLS:
            raise LayoutError(f"{where}: unknown control {control!r}")
        out["control"] = control
        if control == "page":
            if item.get("target") not in PAGE_TARGETS:
                raise LayoutError(f"{where}: page control needs a target in {sorted(PAGE_TARGETS)}")
            out["target"] = item["target"]
            out["label"] = _text(item.get("label"), f"{where} page label")
        elif "target" in item or "label" in item:
            raise LayoutError(f"{where}: only a page control has a target or label")
    if "width" in item:
        if item["width"] not in WIDTHS:
            raise LayoutError(f"{where}: unknown width {item['width']!r}")
        out["width"] = item["width"]
    if "accessibilityLabel" in item:
        out["accessibilityLabel"] = _text(item["accessibilityLabel"], f"{where} accessibilityLabel")
    return out


def _row(row: object, where: str) -> list[dict]:
    if not isinstance(row, list) or not row:
        raise LayoutError(f"{where} must be a non-empty list")
    return [_key(item, f"{where}[{i}]") for i, item in enumerate(row)]


def compile_document(document: dict) -> dict:
    if document.get("schemaVersion") != SCHEMA_VERSION or document.get("format") != FORMAT:
        raise LayoutError("unsupported layout schema or format")
    if document.get("normalization") != "NFC":
        raise LayoutError("layout normalization must be NFC")
    for field in ("identifier", "locale"):
        _text_field = document.get(field)
        if not isinstance(_text_field, str) or not _text_field:
            raise LayoutError(f"layout is missing {field}")
    if not isinstance(document.get("version"), int) or document["version"] < 1:
        raise LayoutError("layout version must be a positive integer")

    pages_in = document.get("pages")
    if not isinstance(pages_in, list):
        raise LayoutError("layout pages must be a list")
    ids = [page.get("id") for page in pages_in]
    if sorted(ids) != sorted(PAGE_IDS):
        raise LayoutError(f"layout must have exactly the pages {PAGE_IDS}, found {ids}")

    pages = []
    for page in pages_in:
        pid = page["id"]
        unknown = set(page) - {"id", "rows", "bottomRow", "longPressVariants"}
        if unknown:
            raise LayoutError(f"page {pid}: unknown fields {sorted(unknown)}")
        rows = page.get("rows")
        if not isinstance(rows, list) or not rows:
            raise LayoutError(f"page {pid} has no rows")
        out = {"id": pid, "rows": [_row(r, f"{pid}.rows[{i}]") for i, r in enumerate(rows)],
               "longPressVariants": bool(page.get("longPressVariants", True))}
        if pid == "numberPad":
            if "bottomRow" in page:
                raise LayoutError("numberPad lays out its own last row; it has no bottomRow")
        else:
            out["bottomRow"] = _row(page.get("bottomRow"), f"{pid}.bottomRow")
            controls = [k.get("control") for k in out["bottomRow"]]
            if controls.count("space") != 1 or controls.count("return") != 1:
                raise LayoutError(f"{pid}.bottomRow needs one space and one return key")
        pages.append(out)
    by_id = {page["id"]: page for page in pages}

    # The decoders' grid: one row per letter row, in order, letters a-z only.
    letters = by_id["letters"]
    grid_rows = ["".join(k["key"] for k in row if "key" in k) for row in letters["rows"]]
    flat = "".join(grid_rows)
    if not flat.isascii() or not flat.isalpha() or not flat.islower() or len(set(flat)) != len(flat):
        raise LayoutError("letters page keys must be distinct lowercase ASCII letters")
    if set(flat) != set("abcdefghijklmnopqrstuvwxyz"):
        raise LayoutError("letters page must hold all 26 letters")
    grid = document.get("letterGrid") or {}
    offsets = grid.get("rowOffsets")
    if not isinstance(offsets, list) or len(offsets) != len(grid_rows) \
            or not all(isinstance(v, (int, float)) and 0 <= v < 4 for v in offsets):
        raise LayoutError("letterGrid.rowOffsets needs one offset (0..4) per letter row")
    if [k.get("control") for k in letters["rows"][-1] if "control" in k] != ["shift", "delete"]:
        raise LayoutError("the last letter row is shift, letters, delete")

    extras_in = document.get("fieldExtras", {})
    if not isinstance(extras_in, dict) or not set(extras_in) <= FIELD_KINDS:
        raise LayoutError(f"fieldExtras keys must be among {sorted(FIELD_KINDS)}")
    extras = {kind: [_text(v, f"fieldExtras.{kind}") for v in values]
              for kind, values in extras_in.items()}
    alternatives_in = document.get("alternatives", {})
    if not isinstance(alternatives_in, dict):
        raise LayoutError("alternatives must map a key to its long-press variants")
    alternatives = {_text(base, "alternatives key"): [_text(v, f"alternatives.{base}") for v in values]
                    for base, values in alternatives_in.items()}

    return {
        "schemaVersion": SCHEMA_VERSION,
        "format": FORMAT,
        "identifier": document["identifier"],
        "version": document["version"],
        "locale": document["locale"],
        "letterGrid": {"rows": grid_rows, "rowOffsets": [float(v) for v in offsets]},
        "pages": pages,
        "fieldExtras": extras,
        "alternatives": alternatives,
    }


def compile_layout(source: Path, output: Path) -> dict:
    compiled = compile_document(json.loads(source.read_text(encoding="utf-8")))
    output.write_bytes(plistlib.dumps(compiled, fmt=plistlib.FMT_BINARY, sort_keys=True))
    return compiled


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    compiled = compile_layout(args.source, args.output)
    print(f"{args.output}: {compiled['identifier']} v{compiled['version']}, "
          f"grid {compiled['letterGrid']['rows']}, {args.output.stat().st_size} bytes")


if __name__ == "__main__":
    main()
