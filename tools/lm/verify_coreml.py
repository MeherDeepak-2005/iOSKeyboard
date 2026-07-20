#!/usr/bin/env python3
"""Verify the bundled W8A8 Core ML scorer against its PyTorch checkpoint."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import coremltools as ct
import numpy as np
import torch

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from export_coreml import int8_weight_op_count, load_calibration_cache, sha256
from model import KeyboardInferenceModel, load_inference_checkpoint

DEFAULT_CHECKPOINT = HERE / "data" / "qwen_pretrain.pt"
DEFAULT_CALIBRATION = HERE / "data" / "qwen_coreml_calibration.npz"
DEFAULT_PACKAGE = HERE.parents[1] / "keyboard" / "rescorer.mlpackage"
DEFAULT_MANIFEST = HERE / "coreml_export_manifest.json"
INPUT_NAMES = ("tokens", "score_positions", "target_ids", "score_mask", "next_positions")


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--checkpoint", type=Path, default=DEFAULT_CHECKPOINT)
    parser.add_argument("--calibration-cache", type=Path, default=DEFAULT_CALIBRATION)
    parser.add_argument("--package", type=Path, default=DEFAULT_PACKAGE)
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    return parser.parse_args()


def top5(values: np.ndarray) -> set[int]:
    return set(np.argpartition(values, -5)[-5:].tolist())


def main() -> None:
    args = parse_args()
    manifest = json.loads(args.manifest.read_text())
    if manifest.get("quantization") != "W8A8":
        raise RuntimeError("manifest does not describe a full W8A8 export")
    if manifest.get("checkpoint_sha256") != sha256(args.checkpoint):
        raise RuntimeError("manifest/checkpoint hash mismatch")
    if manifest.get("architecture", {}).get("batch_size") != 16:
        raise RuntimeError("production model must use the fixed batch size of 16")
    op_counts = manifest.get("mil_ops", {})
    if not (
        int8_weight_op_count(op_counts) > 0
        and op_counts.get("quantize", 0) > 0
        and op_counts.get("dequantize", 0) > 0
    ):
        raise RuntimeError(f"manifest has no W8A8 graph evidence: {op_counts}")

    lm, checkpoint = load_inference_checkpoint(args.checkpoint)
    wrapper = KeyboardInferenceModel(lm).eval()
    coreml = ct.models.MLModel(str(args.package), compute_units=ct.ComputeUnit.CPU_ONLY)
    metadata = coreml.user_defined_metadata
    if metadata.get("quantization") != "W8A8":
        raise RuntimeError(f"Core ML metadata is not W8A8: {metadata}")
    if metadata.get("checkpoint_stage") != str(checkpoint.get("stage", "legacy")):
        raise RuntimeError("Core ML/checkpoint stage mismatch")

    spec = coreml.get_spec()
    shapes = {
        feature.name: list(feature.type.multiArrayType.shape)
        for feature in spec.description.input
    }
    expected_shapes = {
        "tokens": [16, 32],
        "score_positions": [16, 8],
        "target_ids": [16, 8],
        "score_mask": [16, 8],
        "next_positions": [16, 1],
    }
    if shapes != expected_shapes:
        raise RuntimeError(f"unexpected Core ML input contract: {shapes}")

    candidate_agreement = []
    next_agreement = []
    next_top5_overlap = []
    score_errors = []
    correlations = []
    samples = load_calibration_cache(args.calibration_cache)[:8]
    with torch.inference_mode():
        for inputs in samples:
            expected_scores, expected_logits = wrapper(*(
                torch.from_numpy(inputs[name]) for name in INPUT_NAMES
            ))
            outputs = coreml.predict(inputs)
            if set(outputs) != {"candidate_log_probs", "next_logits"}:
                raise RuntimeError(f"unexpected Core ML outputs: {sorted(outputs)}")

            actual_scores = np.asarray(outputs["candidate_log_probs"]).reshape(-1)
            actual_logits = np.asarray(outputs["next_logits"]).reshape(16, -1)
            expected_scores_np = expected_scores.numpy().reshape(-1)
            expected_logits_np = expected_logits.numpy().reshape(16, -1)
            score_errors.append(float(np.max(np.abs(actual_scores - expected_scores_np))))
            candidate_agreement.append(int(actual_scores.argmax() == expected_scores_np.argmax()))
            for actual, expected in zip(actual_logits, expected_logits_np):
                next_agreement.append(int(actual.argmax() == expected.argmax()))
                next_top5_overlap.append(len(top5(actual) & top5(expected)) / 5)
                correlation = np.corrcoef(actual.astype(np.float64), expected.astype(np.float64))[0, 1]
                correlations.append(float(correlation) if np.isfinite(correlation) else 0.0)

    metrics = {
        "candidate_top1_agreement": float(np.mean(candidate_agreement)),
        "candidate_max_abs_error": max(score_errors),
        "next_top1_agreement": float(np.mean(next_agreement)),
        "next_top5_overlap": float(np.mean(next_top5_overlap)),
        "minimum_logit_correlation": min(correlations),
        "mean_logit_correlation": float(np.mean(correlations)),
    }
    print(json.dumps(metrics, indent=2, sort_keys=True))
    if not (
        metrics["candidate_top1_agreement"] >= 0.875
        and metrics["next_top1_agreement"] >= 0.95
        and metrics["next_top5_overlap"] >= 0.90
        and metrics["mean_logit_correlation"] >= 0.98
    ):
        raise SystemExit("Core ML W8A8 parity failed")


if __name__ == "__main__":
    main()
