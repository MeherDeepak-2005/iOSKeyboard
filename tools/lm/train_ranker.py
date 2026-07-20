#!/usr/bin/env python3
"""Fit the bounded candidate ranker from user-separated decoder traces.

Input JSONL contains one request per row:

  {"user_id":"u1", "split":"train", "typed":"mjght", "intended":"might",
   "candidates":[{"word":"might", "spatial_cost":0.8,
   "ngram_log_probability":-2.1, "neural_log_probability":-1.4,
   "log_frequency":12.0, "source":"fuzzyLexicon"}]}

Gold candidates are never injected. Oracle misses are reported and excluded from the
conditional ranking fit, preserving an honest separation between search recall and
ranking quality. The output is a versioned coefficient artifact; it is not copied to
the app bundle and defaults to ``promoted: false``.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path

import numpy as np


SOURCES = (
    "typed",
    "fuzzyLexicon",
    "completion",
    "contextInjection",
    "broadRecovery",
    "splitCorrection",
    "transliterationLexicon",
    "transliterationComposition",
)
FEATURES = (
    "spatial_cost",
    "ngram_log_probability",
    "neural_log_probability",
    "log_frequency",
    "length_delta",
    "typed_word_margin",
    "typed_exact",
) + tuple(f"source.{source}" for source in SOURCES)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def candidate_features(row, typed):
    source = str(row.get("source", "fuzzyLexicon"))
    return np.asarray(
        [
            float(row.get("spatial_cost", 0)),
            float(row.get("ngram_log_probability", 0)),
            float(row.get("neural_log_probability") or 0),
            float(row.get("log_frequency", 0)),
            abs(len(str(row.get("word", ""))) - len(typed)),
            float(row.get("typed_word_margin", 0)),
            float(str(row.get("word", "")).lower() == typed.lower()),
        ]
        + [float(source == expected) for expected in SOURCES],
        dtype=np.float64,
    )


def load_cases(path):
    cases = []
    user_splits = {}
    for line_number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not raw.strip():
            continue
        row = json.loads(raw)
        user = str(row.get("user_id", ""))
        split = str(row.get("split", ""))
        typed = str(row.get("typed", ""))
        intended = str(row.get("intended", ""))
        candidates = list(row.get("candidates") or [])
        if not user or split not in {"train", "validation", "test"}:
            raise ValueError(f"{path}:{line_number}: user_id and a valid split are required")
        if not typed or not intended or not candidates:
            raise ValueError(f"{path}:{line_number}: typed, intended, and candidates are required")
        previous = user_splits.setdefault(user, split)
        if previous != split:
            raise ValueError(f"user {user!r} leaks across {previous!r} and {split!r}")
        words = [str(candidate.get("word", "")) for candidate in candidates]
        gold = next((index for index, word in enumerate(words)
                     if word.lower() == intended.lower()), None)
        cases.append({
            "split": split,
            "typed": typed,
            "intended": intended,
            "words": words,
            "x": np.stack([candidate_features(candidate, typed) for candidate in candidates]),
            "gold": gold,
        })
    return cases


def softmax(values):
    shifted = values - np.max(values)
    exp = np.exp(shifted)
    return exp / exp.sum()


def fit(train, mean, scale, steps, learning_rate, l2):
    weights = np.zeros(len(FEATURES), dtype=np.float64)
    first = np.zeros_like(weights)
    second = np.zeros_like(weights)
    beta1, beta2 = 0.9, 0.999
    fit_cases = [case for case in train if case["gold"] is not None]
    if not fit_cases:
        raise ValueError("training split has zero oracle hits")
    for step in range(1, steps + 1):
        gradient = np.zeros_like(weights)
        for case in fit_cases:
            x = (case["x"] - mean) / scale
            probabilities = softmax(x @ weights)
            gradient += probabilities @ x - x[case["gold"]]
        gradient = gradient / len(fit_cases) + l2 * weights
        first = beta1 * first + (1 - beta1) * gradient
        second = beta2 * second + (1 - beta2) * gradient * gradient
        first_hat = first / (1 - beta1 ** step)
        second_hat = second / (1 - beta2 ** step)
        weights -= learning_rate * first_hat / (np.sqrt(second_hat) + 1e-8)
    return weights


def fit_temperature(cases, weights, mean, scale):
    eligible = [case for case in cases if case["gold"] is not None]
    if not eligible:
        return 1.0
    choices = np.geomspace(0.35, 3.0, 80)
    def nll(temperature):
        losses = []
        for case in eligible:
            logits = ((case["x"] - mean) / scale @ weights) / temperature
            losses.append(-math.log(max(softmax(logits)[case["gold"]], 1e-12)))
        return sum(losses) / len(losses)
    return float(min(choices, key=nll))


def evaluate(cases, weights, mean, scale, temperature):
    if not cases:
        return None
    top1 = top3 = oracle = false_corrections = correct_inputs = 0
    confidences = []
    correctness = []
    losses = []
    for case in cases:
        logits = ((case["x"] - mean) / scale @ weights) / temperature
        probabilities = softmax(logits)
        order = np.argsort(-logits)
        predicted = case["words"][int(order[0])]
        if case["typed"].lower() == case["intended"].lower():
            correct_inputs += 1
            false_corrections += predicted.lower() != case["intended"].lower()
        if case["gold"] is None:
            continue
        oracle += 1
        correct = int(order[0] == case["gold"])
        top1 += correct
        top3 += case["gold"] in order[:3]
        confidences.append(float(probabilities[order[0]]))
        correctness.append(correct)
        losses.append(-math.log(max(float(probabilities[case["gold"]]), 1e-12)))
    total = len(cases)
    ece = 0.0
    for lower in np.linspace(0, 0.9, 10):
        indexes = [i for i, value in enumerate(confidences) if lower <= value < lower + 0.1]
        if indexes:
            accuracy = sum(correctness[i] for i in indexes) / len(indexes)
            confidence = sum(confidences[i] for i in indexes) / len(indexes)
            ece += len(indexes) / max(1, len(confidences)) * abs(accuracy - confidence)
    return {
        "cases": total,
        "oracle_recall": oracle / total,
        "top1_conditional_on_oracle": top1 / max(1, oracle),
        "top3_conditional_on_oracle": top3 / max(1, oracle),
        "top1_end_to_end": top1 / total,
        "top3_end_to_end": top3 / total,
        "false_correction_cases": correct_inputs,
        "false_correction_rate": (false_corrections / correct_inputs
                                  if correct_inputs else None),
        "negative_log_likelihood": sum(losses) / max(1, len(losses)),
        "expected_calibration_error": ece,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("dataset", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--steps", type=int, default=1200)
    parser.add_argument("--learning-rate", type=float, default=0.03)
    parser.add_argument("--l2", type=float, default=1e-3)
    parser.add_argument("--baseline-test-top1", type=float)
    parser.add_argument("--baseline-false-correction", type=float)
    parser.add_argument("--paired-p-value", type=float,
                        help="paired blind-test significance result")
    parser.add_argument("--release-gates-passed", action="store_true",
                        help="confirm reviewed device/memory/energy gates passed")
    args = parser.parse_args()

    cases = load_cases(args.dataset)
    by_split = {name: [case for case in cases if case["split"] == name]
                for name in ("train", "validation", "test")}
    if not by_split["train"] or not by_split["validation"]:
        raise ValueError("both train and validation user splits are required")
    train_rows = np.concatenate([case["x"] for case in by_split["train"]], axis=0)
    mean = train_rows.mean(axis=0)
    scale = train_rows.std(axis=0)
    scale[scale < 1e-6] = 1
    weights = fit(by_split["train"], mean, scale, args.steps, args.learning_rate, args.l2)
    temperature = fit_temperature(by_split["validation"], weights, mean, scale)
    metrics = {
        split: evaluate(split_cases, weights, mean, scale, temperature)
        for split, split_cases in by_split.items()
    }
    test = metrics["test"]
    promoted = bool(
        test
        and args.baseline_test_top1 is not None
        and args.baseline_false_correction is not None
        and args.paired_p_value is not None
        and args.paired_p_value <= 0.05
        and args.release_gates_passed
        and test["false_correction_rate"] is not None
        and test["top1_end_to_end"] > args.baseline_test_top1
        and test["false_correction_rate"] <= args.baseline_false_correction
    )
    artifact = {
        "schema_version": 1,
        "model": "candidate-softmax-linear",
        "feature_names": list(FEATURES),
        "feature_mean": mean.tolist(),
        "feature_scale": scale.tolist(),
        "coefficients": weights.tolist(),
        "temperature": temperature,
        "dataset_sha256": sha256(args.dataset),
        "forced_gold_insertion": False,
        "metrics": metrics,
        "promoted": promoted,
        "promotion_inputs": {
            "baseline_test_top1": args.baseline_test_top1,
            "baseline_false_correction": args.baseline_false_correction,
            "paired_p_value": args.paired_p_value,
            "release_gates_passed": args.release_gates_passed,
        },
        "promotion_note": "Requires significant user-separated gain, no false-correction regression, and reviewed physical release gates",
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(artifact, indent=2, sort_keys=True) + "\n")
    print(json.dumps(metrics, indent=2, sort_keys=True))
    print(f"wrote {args.output}; promoted={promoted}")


if __name__ == "__main__":
    main()
