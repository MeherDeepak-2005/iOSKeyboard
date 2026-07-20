#!/usr/bin/env python3
"""Fast mathematical checks for both incremental decoder implementations."""

import unittest

import torch

from model import KeyboardStudentLM, StudentModelConfig, TinyLM


class CacheEquivalenceTests(unittest.TestCase):
    def _assert_incremental_matches_full(self, model, vocab, length):
        torch.manual_seed(17)
        model.eval()
        tokens = torch.randint(0, vocab, (2, length))
        with torch.inference_mode():
            full = model(tokens)
            cache = model.empty_cache(batch=tokens.shape[0])
            pieces = []
            for position in range(length):
                logits, cache = model.forward_cached(
                    tokens[:, position:position + 1], cache, position
                )
                pieces.append(logits)
            incremental = torch.cat(pieces, dim=1)
        self.assertTrue(
            torch.allclose(full, incremental, atol=2e-5, rtol=2e-5),
            float((full - incremental).abs().max()),
        )

    def test_legacy_cache(self):
        self._assert_incremental_matches_full(
            TinyLM(vocab=41, d=24, layers=2, heads=4, ff=48, maxlen=12), 41, 12
        )

    def test_student_cache(self):
        config = StudentModelConfig(
            vocab_size=41,
            d_model=24,
            layers=2,
            heads=4,
            ffn_dim=48,
            max_length=12,
            dropout=0,
        )
        self._assert_incremental_matches_full(KeyboardStudentLM(config), 41, 12)


if __name__ == "__main__":
    unittest.main()
