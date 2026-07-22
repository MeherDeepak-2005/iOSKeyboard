#!/usr/bin/env python3
"""Exactness tests for the streaming GRU LM (roadmap Plan 3)."""

import sys
import tempfile
import unittest
from dataclasses import asdict
from pathlib import Path

import torch

sys.path.insert(0, str(Path(__file__).resolve().parent))
from model import (GRUModelConfig, KeyboardGRULM, count_parameters,
                   load_inference_checkpoint)


class KeyboardGRULMTests(unittest.TestCase):
    def _model(self, **overrides):
        config = GRUModelConfig(**{"vocab_size": 200, "d_model": 64,
                                   "hidden": 64, "layers": 2, **overrides})
        return KeyboardGRULM(config).eval(), config

    def test_streaming_step_matches_batched_forward(self):
        # The deployment property: threading forward_step token-by-token must reproduce
        # the batched forward exactly (else the in-loop search prior scores differently
        # from what training optimized).
        torch.manual_seed(0)
        model, _ = self._model()
        tokens = torch.randint(0, 200, (1, 24))
        with torch.no_grad():
            batched = model(tokens)[0]
            state = model.empty_state(batch=1)
            streamed = []
            for position in range(tokens.shape[1]):
                logits, state = model.forward_step(tokens[:, position], state)
                streamed.append(logits[0])
            streamed = torch.stack(streamed)
        self.assertLess((batched - streamed).abs().max().item(), 1e-4)

    def test_streaming_parity_holds_across_batch(self):
        torch.manual_seed(1)
        model, _ = self._model()
        tokens = torch.randint(0, 200, (5, 16))
        with torch.no_grad():
            batched = model(tokens)
            state = model.empty_state(batch=5)
            streamed = []
            for position in range(tokens.shape[1]):
                logits, state = model.forward_step(tokens[:, position], state)
                streamed.append(logits)
            streamed = torch.stack(streamed, dim=1)
        self.assertLess((batched - streamed).abs().max().item(), 1e-4)

    def test_head_is_tied_to_embedding(self):
        model, _ = self._model()
        self.assertIs(model.head.weight, model.embedding.weight)

    def test_default_config_stays_in_the_two_to_four_million_band(self):
        model = KeyboardGRULM(GRUModelConfig()).eval()   # shipping defaults, 6k vocab
        millions = count_parameters(model) / 1e6
        self.assertTrue(2.0 <= millions <= 4.0, f"{millions:.2f}M outside 2-4M target")

    def test_checkpoint_round_trip_reconstructs_the_model(self):
        model, config = self._model()
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "gru.pt"
            torch.save({"model": model.state_dict(), "model_type": "gru",
                        "model_config": asdict(config), "vocab": config.vocab_size}, path)
            restored, checkpoint = load_inference_checkpoint(path)
        self.assertIsInstance(restored, KeyboardGRULM)
        self.assertEqual(checkpoint["model_type"], "gru")
        tokens = torch.randint(0, config.vocab_size, (2, 12))
        with torch.no_grad():
            self.assertTrue(torch.allclose(model(tokens), restored(tokens), atol=1e-5))


if __name__ == "__main__":
    unittest.main()
