#!/usr/bin/env python3
"""Verify optimized Core ML outputs against the original PyTorch LM.

Run on macOS after export_coreml.py. The test checks numerical score error and
top-k agreement; it also fails immediately if an old [B, L, V] package remains.
"""

from pathlib import Path
import sys

import coremltools as ct
import numpy as np
import torch

sys.path.insert(0, str(Path(__file__).resolve().parent))
from model import KeyboardInferenceModel, TinyLM

HERE = Path(__file__).resolve().parent
DATA = HERE / "data"
PACKAGE = HERE.parents[1] / "keyboard" / "rescorer.mlpackage"


def main():
    checkpoint = torch.load(DATA / "lm.pt", map_location="cpu")
    lm = TinyLM(vocab=checkpoint["vocab"])
    lm.load_state_dict(checkpoint["model"])
    model = KeyboardInferenceModel(lm).eval()

    rng = np.random.default_rng(17)
    batch, length, slots = 4, 32, model.score_slots
    inputs = {
        "tokens": rng.integers(0, checkpoint["vocab"], (batch, length), dtype=np.int32),
        "score_positions": rng.integers(0, length, (batch, slots), dtype=np.int32),
        "target_ids": rng.integers(0, checkpoint["vocab"], (batch, slots), dtype=np.int32),
        "score_mask": rng.integers(0, 2, (batch, slots)).astype(np.float32),
        "next_positions": rng.integers(0, length, (batch, 1), dtype=np.int32),
    }
    with torch.no_grad():
        expected_scores, expected_logits = model(*(torch.from_numpy(inputs[name]) for name in (
            "tokens", "score_positions", "target_ids", "score_mask", "next_positions"
        )))

    coreml = ct.models.MLModel(str(PACKAGE), compute_units=ct.ComputeUnit.CPU_ONLY)
    outputs = coreml.predict(inputs)
    if set(outputs) != {"candidate_log_probs", "next_logits"}:
        raise RuntimeError(f"stale Core ML interface: {sorted(outputs)}; rerun export_coreml.py")

    # Normalize shapes before comparing: Core ML may return [B, 1] scores and
    # [B, 1, V] logits where torch gives [B] and [B, V]. Without the reshape the
    # score subtraction silently broadcasts to [B, B] and the top-5 rows become
    # arrays of arrays (unhashable in set()).
    actual_scores = np.asarray(outputs["candidate_log_probs"]).reshape(-1)
    actual_logits = np.asarray(outputs["next_logits"]).reshape(batch, -1)
    expected_scores_np = expected_scores.numpy().reshape(-1)
    expected_logits_np = expected_logits.numpy().reshape(batch, -1)
    score_error = np.max(np.abs(actual_scores - expected_scores_np))
    expected_top5 = np.argsort(expected_logits_np, axis=1)[:, -5:]
    actual_top5 = np.argsort(actual_logits, axis=1)[:, -5:]
    top5_overlap = np.mean([
        len(set(a.tolist()).intersection(e.tolist())) / 5
        for a, e in zip(actual_top5, expected_top5)
    ])
    print(f"candidate max abs error: {score_error:.5f}")
    print(f"next-logit top-5 overlap: {top5_overlap:.3f}")
    if score_error > 0.15 or top5_overlap < 0.95:
        raise SystemExit("Core ML parity failed")


if __name__ == "__main__":
    main()
