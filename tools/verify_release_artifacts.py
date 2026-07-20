#!/usr/bin/env python3
"""Audit a built keyboard extension and emit a reproducible size manifest."""

from __future__ import annotations

import argparse
import hashlib
import json
import plistlib
from pathlib import Path

LANGDATA_CAP = 11_000_000
NO_NEURAL_EXTENSION_CAP = 14_000_000
NEURAL_EXTENSION_CAP = 25_000_000
NEURAL_CONTAINER_SUFFIXES = (
    ".mlmodelc", ".mlpackage", ".mlmodel", ".pt", ".pth", ".ckpt",
    ".safetensors", ".onnx", ".tflite",
)
NEURAL_RESOURCE_NAMES = {
    "tokenizer.bin", "tokenizer.json", "tokenizer.model",
    "spm.model", "spm.vocab", "sentencepiece.model", "pytorch_model.bin",
}
REQUIRED_RELEASE_RESOURCES = {
    "emoji.bin", "langdata.bin", "safety.kbguard",
    "telugu_layout.kbpack", "telugu_langdata.bin",
    "tenglish_lexicon.bin", "telugu_pack_manifest.json",
}
RESOURCE_CAPS = {
    "langdata.bin": LANGDATA_CAP,
    "telugu_langdata.bin": 2_500_000,
    "tenglish_lexicon.bin": 1_250_000,
}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def is_neural_artifact(relative_path: str) -> bool:
    parts = tuple(part.lower() for part in Path(relative_path).parts)
    return any(part.endswith(NEURAL_CONTAINER_SUFFIXES) for part in parts) \
        or bool(parts and parts[-1] in NEURAL_RESOURCE_NAMES)


def plist_bool(value) -> bool:
    if isinstance(value, bool):
        return value
    return str(value or "").strip().lower() in {"1", "yes", "true"}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("appex", type=Path)
    parser.add_argument("--output", type=Path, default=Path("BuildArtifactManifest.json"))
    parser.add_argument("--allow-neural", action="store_true")
    args = parser.parse_args()
    if not args.appex.is_dir():
        raise SystemExit(f"extension bundle not found: {args.appex}")

    files = sorted(path for path in args.appex.rglob("*") if path.is_file())
    records = [{
        "path": str(path.relative_to(args.appex)),
        "bytes": path.stat().st_size,
        "sha256": sha256(path),
    } for path in files]
    total = sum(record["bytes"] for record in records)
    by_name = {Path(record["path"]).name: record for record in records}
    neural = [record for record in records if is_neural_artifact(record["path"])]
    cap = NEURAL_EXTENSION_CAP if args.allow_neural else NO_NEURAL_EXTENSION_CAP
    failures = []
    for name in sorted(REQUIRED_RELEASE_RESOURCES - set(by_name)):
        failures.append(f"{name} is missing")
    for name, byte_cap in RESOURCE_CAPS.items():
        record = by_name.get(name)
        if record is not None and record["bytes"] > byte_cap:
            failures.append(f"{name} exceeds {byte_cap:,} bytes")

    pack_record = by_name.get("telugu_pack_manifest.json")
    if pack_record is not None:
        try:
            pack = json.loads((args.appex / pack_record["path"]).read_text(encoding="utf-8"))
            for artifact_name in ("layout", "language_model", "transliteration_lexicon"):
                expected = pack["artifacts"][artifact_name]
                bundled = by_name.get(Path(expected["path"]).name)
                if bundled is None:
                    failures.append(f"Telugu manifest artifact is missing: {expected['path']}")
                elif bundled["bytes"] != expected["bytes"] \
                        or bundled["sha256"] != expected["sha256"]:
                    failures.append(f"Telugu manifest mismatch: {expected['path']}")
            provenance = pack.get("provenance")
            if not isinstance(provenance, list) or not provenance:
                failures.append("Telugu manifest has no source provenance")
            else:
                for source in provenance:
                    name = str(source.get("name") or "unnamed source")
                    if source.get("research_only") is not False \
                            or source.get("release_eligible") is not True:
                        failures.append(
                            f"Telugu source is not release-eligible: {name}")
        except (KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
            failures.append(f"invalid Telugu pack manifest: {error}")
    if neural and not args.allow_neural:
        failures.append("Release contains an unapproved neural model/tokenizer")

    info_path = args.appex / "Info.plist"
    if info_path.exists():
        try:
            with info_path.open("rb") as handle:
                info = plistlib.load(handle)
            if plist_bool(info.get("KLIPYMediaEnabled")):
                key = str(info.get("KLIPYAPIKey") or "").strip()
                if not key or "$(" in key:
                    failures.append("KLIPY media is enabled with an empty API key")
                if not plist_bool(info.get("KLIPYContentFilterApproved")):
                    failures.append("KLIPY media is enabled without approved Partner Panel filtering")
        except (OSError, plistlib.InvalidFileException) as error:
            failures.append(f"invalid extension Info.plist: {error}")
    if total > cap:
        failures.append(f"extension is {total:,} bytes; cap is {cap:,}")

    manifest = {
        "schemaVersion": 1,
        "bundle": args.appex.name,
        "totalBytes": total,
        "gateBytes": cap,
        "neuralArtifactsAllowed": args.allow_neural,
        "gatePassed": not failures,
        "failures": failures,
        "files": records,
    }
    args.output.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    print(f"extension: {total:,} / {cap:,} bytes")
    print(f"manifest: {args.output}")
    if failures:
        raise SystemExit("release artifact verification failed: " + "; ".join(failures))


if __name__ == "__main__":
    main()
