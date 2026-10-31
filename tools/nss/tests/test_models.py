import unittest

import torch

from nss.losses import cross_entropy_sum
from nss.models import ARCHITECTURES, build
from nss.ring import ContextRing
from nss.vocab import BOS, EOS

SMALL = {
    "lstm-cifg": {"arch": "lstm", "embed": 16, "hidden": 24, "proj": 16, "cifg": True},
    "lstm": {"arch": "lstm", "embed": 16, "hidden": 24, "proj": 16, "cifg": False, "layers": 2},
    "lstm-untied": {"arch": "lstm", "embed": 16, "hidden": 24, "proj": None, "cifg": True, "tied": False},
    "gru": {"arch": "gru", "embed": 16, "hidden": 24, "proj": 16},
    "transformer": {"arch": "transformer", "embed": 16, "dim": 32, "layers": 2, "heads": 4, "ffn": 40, "window": 5},
    "ssm": {"arch": "ssm", "embed": 16, "dim": 24, "state": 20, "layers": 2, "ffn": 32},
}
VOCAB = 50


def stream(length: int, seed: int) -> torch.Tensor:
    """Several sentences back to back: <bos> words <eos> <bos> ..."""
    generator = torch.Generator().manual_seed(seed)
    tokens = torch.randint(4, VOCAB, (length,), generator=generator)
    tokens[0] = BOS
    for at in (7, 8, 17, 18):   # <eos> then <bos>
        tokens[at] = EOS if at in (7, 17) else BOS
    return tokens


class StreamingParityTests(unittest.TestCase):
    def setUp(self):
        torch.manual_seed(0)

    def test_registry_has_every_architecture(self):
        self.assertEqual(set(ARCHITECTURES), {"lstm", "gru", "transformer", "ssm"})

    def test_step_equals_forward_and_chunks_carry_state(self):
        for name, config in SMALL.items():
            with self.subTest(name):
                model = build(config, VOCAB).eval()
                tokens = torch.stack([stream(30, 1), stream(30, 2)])
                full, _ = model(tokens)
                first, state = model(tokens[:, :11])
                second, _ = model(tokens[:, 11:], state)
                torch.testing.assert_close(torch.cat([first, second], 1), full, atol=1e-5, rtol=1e-5)
                state = None
                for t in range(tokens.shape[1]):
                    step, state = model.step(tokens[:, t], state)
                    torch.testing.assert_close(step, full[:, t], atol=1e-5, rtol=1e-5)

    def test_bos_isolates_sentences(self):
        for name, config in SMALL.items():
            with self.subTest(name):
                model = build(config, VOCAB).eval()
                sentence = torch.tensor([[BOS, 5, 6, 7, 9]])
                alone, _ = model(sentence)
                after, _ = model(torch.cat([torch.tensor([[BOS, 11, 12, EOS]]), sentence], 1))
                torch.testing.assert_close(after[:, 4:], alone, atol=1e-5, rtol=1e-5)

    def test_chunked_cross_entropy_matches_dense(self):
        features = torch.randn(37, 8, dtype=torch.float64, requires_grad=True)
        weight = torch.randn(20, 8, dtype=torch.float64, requires_grad=True)
        bias = torch.randn(20, dtype=torch.float64, requires_grad=True)
        targets = torch.randint(0, 20, (37,))
        torch.autograd.gradcheck(lambda f, w, b: cross_entropy_sum(f, w, b, targets, 5), (features, weight, bias))
        dense = torch.nn.functional.cross_entropy(features @ weight.t() + bias, targets, reduction="sum")
        torch.testing.assert_close(cross_entropy_sum(features, weight, bias, targets, 5), dense)
        keep = torch.rand(37) > 0.3
        torch.autograd.gradcheck(lambda f, w, b: cross_entropy_sum(f, w, b, targets, 5, keep), (features, weight, bias))
        masked = torch.nn.functional.cross_entropy((features @ weight.t() + bias)[keep], targets[keep], reduction="sum")
        torch.testing.assert_close(cross_entropy_sum(features, weight, bias, targets, 5, keep), masked)


class RingTests(unittest.TestCase):
    def setUp(self):
        torch.manual_seed(0)
        self.model = build(SMALL["lstm-cifg"], VOCAB).eval()

    def reference(self, context):
        features, _ = self.model(torch.tensor([[BOS, *context]]))
        return features[0, -1]

    def test_reads_each_committed_word_once(self):
        ring = ContextRing(self.model, capacity=6, window=4)
        result = ring.sync([5, 6])
        self.assertEqual((result.reused, result.stepped), (0, 2))
        torch.testing.assert_close(result.features[0], self.reference([5, 6]))
        self.assertEqual(ring.sync([5, 6]).stepped, 0)        # next keystroke, same word
        self.assertEqual(ring.sync([5, 6, 7]).stepped, 1)     # committed one more word
        result = ring.sync([5, 6])                            # backspace into the previous word
        self.assertEqual(result.stepped, 0)
        torch.testing.assert_close(result.features[0], self.reference([5, 6]))
        result = ring.sync([5, 6, 8])                         # replaced the last word
        self.assertEqual(result.stepped, 1)
        torch.testing.assert_close(result.features[0], self.reference([5, 6, 8]))

    def test_sliding_window_keeps_the_whole_sentence(self):
        ring = ContextRing(self.model, capacity=6, window=4)
        for length in range(1, 5):
            ring.sync([10 + i for i in range(length)])
        # The host now sends only the last 4 words: [11, 12, 13, 14].
        result = ring.sync([11, 12, 13, 14])
        self.assertEqual(result.stepped, 1)
        torch.testing.assert_close(result.features[0], self.reference([10, 11, 12, 13, 14]))

    def test_new_sentence_and_eviction(self):
        ring = ContextRing(self.model, capacity=6, window=4)
        words = list(range(10, 20))
        for end in range(4, len(words) + 1):          # a 10-word sentence, window of 4
            ring.sync(words[end - 4:end])
        self.assertEqual(ring.length, 10)
        result = ring.sync([30, 31])                  # a new sentence restarts at the root
        self.assertEqual((result.reused, result.stepped), (0, 2))
        torch.testing.assert_close(result.features[0], self.reference([30, 31]))
        cold = ContextRing(self.model, capacity=6, window=4)
        result = cold.sync([40, 41, 42, 43])          # unseen window: read from the root
        torch.testing.assert_close(result.features[0], self.reference([40, 41, 42, 43]))


if __name__ == "__main__":
    unittest.main()
