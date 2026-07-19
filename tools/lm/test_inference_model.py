#!/usr/bin/env python3
"""Exactness tests for the memory-bounded keyboard inference wrapper."""

import unittest
import sys
from pathlib import Path

import torch

sys.path.insert(0, str(Path(__file__).resolve().parent))
from model import KeyboardInferenceModel, TinyLM, apply_smooth_quant, count_parameters


class KeyboardInferenceModelTests(unittest.TestCase):
    def test_compact_outputs_match_full_sequence_logits(self):
        torch.manual_seed(7)
        lm = TinyLM(vocab=101, d=32, layers=2, heads=4, ff=64).eval()
        model = KeyboardInferenceModel(lm).eval()
        batch, length, slots = 3, 32, model.score_slots
        tokens = torch.randint(0, 101, (batch, length), dtype=torch.int32)
        positions = torch.randint(0, length, (batch, slots), dtype=torch.int32)
        targets = torch.randint(0, 101, (batch, slots), dtype=torch.int32)
        mask = torch.randint(0, 2, (batch, slots)).float()
        next_positions = torch.randint(0, length, (batch, 1), dtype=torch.int32)

        with torch.no_grad():
            full = lm(tokens)
            selected_rows = torch.gather(
                full.log_softmax(-1), 1,
                positions.long().unsqueeze(-1).expand(-1, -1, full.shape[-1]),
            )
            expected_scores = (
                selected_rows.gather(2, targets.long().unsqueeze(-1)).squeeze(-1) * mask
            ).sum(1)
            expected_next = torch.gather(
                full, 1,
                next_positions.long().unsqueeze(-1).expand(-1, -1, full.shape[-1]),
            ).squeeze(1)
            scores, next_logits = model(tokens, positions, targets, mask, next_positions)

        torch.testing.assert_close(scores, expected_scores)
        torch.testing.assert_close(next_logits, expected_next)

    def test_wrapper_traces_with_variable_batch(self):
        lm = TinyLM(vocab=101, d=32, layers=1, heads=4, ff=64).eval()
        model = KeyboardInferenceModel(lm).eval()
        example = (
            torch.zeros(1, 32, dtype=torch.int32),
            torch.zeros(1, 8, dtype=torch.int32),
            torch.zeros(1, 8, dtype=torch.int32),
            torch.zeros(1, 8),
            torch.zeros(1, 1, dtype=torch.int32),
        )
        traced = torch.jit.trace(model, example)
        batch = tuple(x.expand(4, *x.shape[1:]).clone() for x in example)
        eager = model(*batch)
        actual = traced(*batch)
        torch.testing.assert_close(actual[0], eager[0])
        torch.testing.assert_close(actual[1], eager[1])

    def test_smooth_quant_transform_preserves_outputs_and_tied_head(self):
        torch.manual_seed(11)
        lm = TinyLM(vocab=101, d=32, layers=2, heads=4, ff=64).eval()
        tokens = torch.randint(0, 101, (3, 32), dtype=torch.int32)
        before_count = count_parameters(lm)
        with torch.no_grad():
            expected = lm(tokens)

        input_absmax = {
            name: torch.linspace(0.5, 3.0, module.in_features)
            for name, module in lm.named_modules()
            if name != "head" and isinstance(module, torch.nn.Linear)
        }
        summary = apply_smooth_quant(lm, input_absmax, alpha=0.5)
        with torch.no_grad():
            actual = lm(tokens)

        self.assertTrue(summary)
        self.assertEqual(count_parameters(lm), before_count)
        self.assertIs(lm.head.weight, lm.emb.weight)
        torch.testing.assert_close(actual, expected, atol=2e-5, rtol=2e-5)


if __name__ == "__main__":
    unittest.main()
