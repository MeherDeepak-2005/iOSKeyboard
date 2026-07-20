#!/usr/bin/env python3
"""Paired, user-clustered evaluation for keyboard decoder captures."""

from __future__ import annotations

import argparse
import json
import math
import random
import statistics
import sys
import unicodedata
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any, Iterable


ENGINES = ("engine", "baseline")


class SchemaError(ValueError):
    pass


def normalized(value: str) -> str:
    return unicodedata.normalize("NFC", value).casefold()


def require_string(row: dict[str, Any], key: str, line: int) -> str:
    value = row.get(key)
    if not isinstance(value, str) or not value:
        raise SchemaError(f"line {line}: {key!r} must be a non-empty string")
    return value


def validate_result(value: Any, key: str, line: int) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise SchemaError(f"line {line}: {key!r} must be an object")
    suggestions = value.get("suggestions")
    if not isinstance(suggestions, list) or not all(isinstance(v, str) for v in suggestions):
        raise SchemaError(f"line {line}: {key}.suggestions must be a string array")
    candidates = value.get("candidates")
    if candidates is not None and (
        not isinstance(candidates, list) or not all(isinstance(v, str) for v in candidates)
    ):
        raise SchemaError(f"line {line}: {key}.candidates must be a string array")
    correction = value.get("correction")
    if correction is not None and not isinstance(correction, str):
        raise SchemaError(f"line {line}: {key}.correction must be a string or null")
    latency = value.get("latency_ms")
    if latency is not None and (
        isinstance(latency, bool) or not isinstance(latency, (int, float)) or latency < 0
    ):
        raise SchemaError(f"line {line}: {key}.latency_ms must be non-negative")
    confidence = value.get("confidence")
    if confidence is not None and (
        isinstance(confidence, bool) or not isinstance(confidence, (int, float))
        or not 0 <= confidence <= 1
    ):
        raise SchemaError(f"line {line}: {key}.confidence must be between 0 and 1")
    saved = value.get("keystrokes_saved")
    if saved is not None and (
        isinstance(saved, bool) or not isinstance(saved, (int, float)) or saved < 0
    ):
        raise SchemaError(f"line {line}: {key}.keystrokes_saved must be non-negative")
    return value


def load_rows(path: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    seen_cases: set[str] = set()
    user_splits: dict[str, str] = {}
    with path.open(encoding="utf-8") as handle:
        for line_number, raw in enumerate(handle, 1):
            if not raw.strip():
                continue
            try:
                row = json.loads(raw)
            except json.JSONDecodeError as error:
                raise SchemaError(f"line {line_number}: invalid JSON: {error.msg}") from error
            if not isinstance(row, dict):
                raise SchemaError(f"line {line_number}: row must be an object")
            case_id = require_string(row, "case_id", line_number)
            user_id = require_string(row, "user_id", line_number)
            split = require_string(row, "split", line_number)
            require_string(row, "typed", line_number)
            require_string(row, "intended", line_number)
            if case_id in seen_cases:
                raise SchemaError(f"line {line_number}: duplicate case_id {case_id!r}")
            seen_cases.add(case_id)
            prior_split = user_splits.setdefault(user_id, split)
            if prior_split != split:
                raise SchemaError(
                    f"line {line_number}: user_id {user_id!r} occurs in both "
                    f"{prior_split!r} and {split!r}"
                )
            for engine in ENGINES:
                row[engine] = validate_result(row.get(engine), engine, line_number)
            rows.append(row)
    if not rows:
        raise SchemaError("input contains no events")
    return rows


def resolved_word(row: dict[str, Any], engine: str) -> str:
    correction = row[engine].get("correction")
    return correction if correction else row["typed"]


def event_metrics(row: dict[str, Any], engine: str) -> dict[str, float]:
    intended = normalized(row["intended"])
    typed = normalized(row["typed"])
    result = row[engine]
    resolved = normalized(resolved_word(row, engine))
    suggestions = [normalized(word) for word in result["suggestions"]]
    raw_candidates = result.get("candidates")
    candidates = [normalized(word) for word in raw_candidates or []]
    correct = float(resolved == intended)
    confidence = result.get("confidence")
    return {
        "correction_accuracy": correct,
        "false_correction": (float(resolved != intended)
                             if typed == intended else math.nan),
        "missed_correction": (float(resolved != intended)
                              if typed != intended else math.nan),
        "modified": float(resolved != typed),
        "suggestion_top1": float(bool(suggestions) and suggestions[0] == intended),
        "suggestion_top3": float(intended in suggestions[:3]),
        "candidate_recall": (float(intended in candidates)
                             if raw_candidates is not None else math.nan),
        "keystroke_savings": float(result.get("keystrokes_saved", math.nan)),
        "brier_score": ((float(confidence) - correct) ** 2
                        if confidence is not None else math.nan),
    }


def mean(values: Iterable[float]) -> float:
    values = [value for value in values if not math.isnan(value)]
    return sum(values) / len(values) if values else math.nan


def percentile(values: list[float], fraction: float) -> float:
    if not values:
        return math.nan
    ordered = sorted(values)
    position = (len(ordered) - 1) * fraction
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    return ordered[lower] + (ordered[upper] - ordered[lower]) * (position - lower)


def aggregate(rows: list[dict[str, Any]], engine: str) -> dict[str, float]:
    metrics = [event_metrics(row, engine) for row in rows]
    result = {key: mean(metric[key] for metric in metrics) for key in metrics[0]}
    latencies = [float(row[engine]["latency_ms"]) for row in rows if row[engine].get("latency_ms") is not None]
    result.update(
        latency_p50_ms=percentile(latencies, 0.50),
        latency_p95_ms=percentile(latencies, 0.95),
        latency_p99_ms=percentile(latencies, 0.99),
    )
    return result


def clustered_interval(
    rows: list[dict[str, Any]], metric: str, samples: int, seed: int
) -> tuple[float, float]:
    by_user: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for row in rows:
        by_user[row["user_id"]].append(row)
    users = sorted(by_user)
    if len(users) < 2 or samples <= 0:
        return math.nan, math.nan
    if math.isnan(mean(event_metrics(row, "engine")[metric] for row in rows)) or \
       math.isnan(mean(event_metrics(row, "baseline")[metric] for row in rows)):
        return math.nan, math.nan
    rng = random.Random(seed)
    deltas: list[float] = []
    for _ in range(samples):
        draw: list[dict[str, Any]] = []
        for user in rng.choices(users, k=len(users)):
            draw.extend(by_user[user])
        engine_value = mean(event_metrics(row, "engine")[metric] for row in draw)
        baseline_value = mean(event_metrics(row, "baseline")[metric] for row in draw)
        deltas.append(engine_value - baseline_value)
    return percentile(deltas, 0.025), percentile(deltas, 0.975)


def mcnemar_exact(rows: list[dict[str, Any]]) -> tuple[int, int, float]:
    engine_only = 0
    baseline_only = 0
    for row in rows:
        engine_ok = event_metrics(row, "engine")["correction_accuracy"] == 1
        baseline_ok = event_metrics(row, "baseline")["correction_accuracy"] == 1
        engine_only += int(engine_ok and not baseline_ok)
        baseline_only += int(baseline_ok and not engine_ok)
    discordant = engine_only + baseline_only
    if discordant == 0:
        return engine_only, baseline_only, 1.0
    tail = min(engine_only, baseline_only)
    probability = 2 * sum(math.comb(discordant, k) for k in range(tail + 1)) / (2**discordant)
    return engine_only, baseline_only, min(1.0, probability)


def percentage(value: float) -> str:
    return "n/a" if math.isnan(value) else f"{value * 100:.2f}%"


def milliseconds(value: float) -> str:
    return "n/a" if math.isnan(value) else f"{value:.2f}"


def report(rows: list[dict[str, Any]], split: str, bootstrap: int, seed: int) -> str:
    engine = aggregate(rows, "engine")
    baseline = aggregate(rows, "baseline")
    quality = [
        ("Correction accuracy", "correction_accuracy", "percent"),
        ("False-correction rate", "false_correction", "percent"),
        ("Missed-correction rate", "missed_correction", "percent"),
        ("Suggestion top-1", "suggestion_top1", "percent"),
        ("Suggestion top-3", "suggestion_top3", "percent"),
        ("Candidate-oracle recall", "candidate_recall", "percent"),
        ("Word modification rate", "modified", "percent"),
        ("Mean keystrokes saved", "keystroke_savings", "number"),
        ("Calibration Brier score", "brier_score", "number"),
    ]
    lines = [
        "# Paired decoder report",
        "",
        f"Split: `{split}`  ",
        f"Events: {len(rows)}  ",
        f"Users: {len({row['user_id'] for row in rows})}  ",
        f"Bootstrap: {bootstrap} user-cluster samples (seed {seed})",
        "",
        "| Metric | Engine | Baseline | Paired delta | 95% user-cluster CI |",
        "|---|---:|---:|---:|---:|",
    ]
    for label, key, kind in quality:
        delta = engine[key] - baseline[key]
        low, high = clustered_interval(rows, key, bootstrap, seed)
        if kind == "percent":
            engine_text, baseline_text = percentage(engine[key]), percentage(baseline[key])
            delta_text = "n/a" if math.isnan(delta) else f"{delta * 100:+.2f} pp"
            interval = "n/a" if math.isnan(low) else f"[{low * 100:+.2f}, {high * 100:+.2f}] pp"
        else:
            engine_text = "n/a" if math.isnan(engine[key]) else f"{engine[key]:.4f}"
            baseline_text = "n/a" if math.isnan(baseline[key]) else f"{baseline[key]:.4f}"
            delta_text = "n/a" if math.isnan(delta) else f"{delta:+.4f}"
            interval = "n/a" if math.isnan(low) else f"[{low:+.4f}, {high:+.4f}]"
        lines.append(
            f"| {label} | {engine_text} | {baseline_text} | {delta_text} | {interval} |"
        )
    lines.extend(
        [
            "",
            "| Latency | Engine ms | Baseline ms |",
            "|---|---:|---:|",
            f"| p50 | {milliseconds(engine['latency_p50_ms'])} | {milliseconds(baseline['latency_p50_ms'])} |",
            f"| p95 | {milliseconds(engine['latency_p95_ms'])} | {milliseconds(baseline['latency_p95_ms'])} |",
            f"| p99 | {milliseconds(engine['latency_p99_ms'])} | {milliseconds(baseline['latency_p99_ms'])} |",
        ]
    )
    engine_only, baseline_only, p_value = mcnemar_exact(rows)
    lines.extend(
        [
            "",
            "## Paired significance",
            "",
            f"Correction cases won only by engine: {engine_only}; only by baseline: "
            f"{baseline_only}; exact McNemar p={p_value:.6f}.",
            "",
            "## Category slices",
            "",
            "| Category | Events | Engine correction | Baseline correction | Delta |",
            "|---|---:|---:|---:|---:|",
        ]
    )
    groups: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for row in rows:
        groups[str(row.get("category") or "uncategorized")].append(row)
    for category in sorted(groups):
        group = groups[category]
        e = aggregate(group, "engine")["correction_accuracy"]
        b = aggregate(group, "baseline")["correction_accuracy"]
        lines.append(f"| {category} | {len(group)} | {percentage(e)} | {percentage(b)} | {(e - b) * 100:+.2f} pp |")
    lines.extend(
        [
            "",
            "A positive accuracy or recall delta favors the engine; a negative false-",
            "correction, missed-correction, modification, or latency delta favors it.",
            "Do not ship from this report alone: run physical-device memory, energy,",
            "thermal, accessibility, and jetsam gates on the exact release archive.",
        ]
    )
    return "\n".join(lines) + "\n"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path, help="paired JSONL capture")
    parser.add_argument("--split", default="test", help="split to report (default: test)")
    parser.add_argument("--bootstrap", type=int, default=5000, help="user-cluster samples")
    parser.add_argument("--seed", type=int, default=20260719)
    parser.add_argument("--output", type=Path, help="write Markdown report to this path")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        all_rows = load_rows(args.input)
        rows = [row for row in all_rows if row["split"] == args.split]
        if not rows:
            raise SchemaError(f"no events found for split {args.split!r}")
        text = report(rows, args.split, max(args.bootstrap, 0), args.seed)
    except (OSError, SchemaError) as error:
        print(f"evaluation error: {error}", file=sys.stderr)
        return 2
    if args.output:
        args.output.write_text(text, encoding="utf-8")
    else:
        print(text, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
