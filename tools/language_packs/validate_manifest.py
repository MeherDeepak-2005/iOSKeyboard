#!/usr/bin/env python3
"""Validate language-pack provenance, containment, and artifact hashes."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path

SHA256 = re.compile(r"^[0-9a-f]{64}$")
ARTIFACT_NAMES = (
    "layout",
    "lexicon",
    "transliteration_lexicon",
    "transliteration_fst",
    "language_model",
    "safety",
    "benchmark",
)
PRODUCTION_ARTIFACTS = set(ARTIFACT_NAMES)
TOP_LEVEL_KEYS = {
    "schema_version", "identifier", "version", "locale", "input_modes",
    "normalization", "minimum_ios", "release_status", "benchmark_version",
    "benchmark_hash", "native_speaker_reviewed", "artifacts", "provenance", "build",
}


class ManifestError(ValueError):
    pass


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise ManifestError(message)


def validate_manifest(path: Path) -> dict:
    path = path.resolve()
    manifest = json.loads(path.read_text(encoding="utf-8"))
    _require(isinstance(manifest, dict), "manifest root must be an object")
    _require(set(manifest) <= TOP_LEVEL_KEYS,
             "unknown manifest keys: " + ", ".join(sorted(set(manifest) - TOP_LEVEL_KEYS)))
    schema_version = manifest.get("schema_version")
    _require(schema_version in {1, 2}, "unsupported schema_version")
    _require(isinstance(manifest.get("identifier"), str) and manifest["identifier"],
             "identifier is required")
    _require(isinstance(manifest.get("version"), int) and manifest["version"] > 0,
             "version must be positive")
    _require(manifest.get("normalization") == "NFC", "normalization must be NFC")
    _require(isinstance(manifest.get("locale"), str) and manifest["locale"],
             "locale is required")
    _require(isinstance(manifest.get("minimum_ios"), str) and
             re.fullmatch(r"[0-9]+\.[0-9]+", manifest["minimum_ios"]),
             "minimum_ios must be a major.minor string")
    _require(isinstance(manifest.get("benchmark_version"), str) and
             manifest["benchmark_version"], "benchmark_version is required")
    _require(isinstance(manifest.get("native_speaker_reviewed"), bool),
             "native_speaker_reviewed must be boolean")
    _require(manifest.get("release_status") in {"research", "validated", "production"},
             "invalid release_status")
    modes = manifest.get("input_modes")
    _require(isinstance(modes, list) and modes and
             set(modes) <= {"english", "tenglish", "tenglish_to_telugu",
                            "roman_telugu", "telugu"}, "invalid input_modes")

    if schema_version == 2:
        benchmark_hash = manifest.get("benchmark_hash")
        _require(benchmark_hash is None or bool(SHA256.fullmatch(benchmark_hash)),
                 "benchmark_hash must be null or a sha256")

    artifacts = manifest.get("artifacts")
    _require(isinstance(artifacts, dict) and set(artifacts) == set(ARTIFACT_NAMES),
             "artifacts must contain the complete fixed artifact set")
    root = path.parent
    for name, record in artifacts.items():
        if record is None:
            continue
        _require(isinstance(record, dict), f"{name} artifact must be an object")
        relative = Path(record.get("path", ""))
        _require(not relative.is_absolute() and ".." not in relative.parts,
                 f"{name} artifact path escapes its pack")
        unresolved = root / relative
        _require(not unresolved.is_symlink(), f"{name} artifact must not be a symlink")
        artifact = unresolved.resolve()
        _require(artifact.is_relative_to(root), f"{name} artifact path escapes its pack")
        _require(artifact.is_file() and not artifact.is_symlink(),
                 f"{name} artifact is missing or is a symlink")
        expected = record.get("sha256", "")
        _require(bool(SHA256.fullmatch(expected)), f"{name} has an invalid sha256")
        _require(file_sha256(artifact) == expected, f"{name} hash mismatch")
        _require(artifact.stat().st_size == record.get("bytes"), f"{name} size mismatch")

    provenance = manifest.get("provenance")
    _require(isinstance(provenance, list) and provenance, "provenance is required")
    for index, source in enumerate(provenance):
        _require(isinstance(source, dict), f"provenance[{index}] must be an object")
        for field in ("name", "url", "license", "license_url"):
            _require(isinstance(source.get(field), str) and source[field],
                     f"provenance[{index}].{field} is required")
        _require(bool(SHA256.fullmatch(source.get("sha256", ""))),
                 f"provenance[{index}] has an invalid sha256")
        _require(source.get("purpose") in
                 {"training", "calibration", "evaluation", "layout", "safety"},
                 f"provenance[{index}] has an invalid purpose")
        _require(source.get("split") in {"train", "validation", "test", "none"},
                 f"provenance[{index}] has an invalid split")
        if source.get("purpose") == "training":
            _require(source.get("split") == "train",
                     "validation/test data cannot be declared as training input")
        if schema_version == 2:
            for field in ("source_revision", "attribution"):
                _require(isinstance(source.get(field), str) and source[field],
                         f"provenance[{index}].{field} is required")
            for field in ("research_only", "release_eligible"):
                _require(isinstance(source.get(field), bool),
                         f"provenance[{index}].{field} must be boolean")

    if manifest["release_status"] == "production":
        missing = sorted(name for name in PRODUCTION_ARTIFACTS if artifacts[name] is None)
        _require(not missing, "production pack missing artifacts: " + ", ".join(missing))
        _require(manifest.get("native_speaker_reviewed") is True,
                 "production pack requires native-speaker review")
        if schema_version == 2:
            _require(bool(SHA256.fullmatch(manifest.get("benchmark_hash") or "")),
                     "production pack requires a benchmark_hash")
            blocked = [source["name"] for source in provenance
                       if source["research_only"] or not source["release_eligible"]]
            _require(not blocked,
                     "production pack contains research-only sources: " + ", ".join(blocked))
    return manifest


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("manifest", type=Path)
    args = parser.parse_args()
    manifest = validate_manifest(args.manifest)
    print(f"valid {manifest['identifier']} v{manifest['version']} "
          f"({manifest['release_status']})")


if __name__ == "__main__":
    main()
