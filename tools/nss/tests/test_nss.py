import math
import struct
import tempfile
import unittest
from pathlib import Path

import torch

from nss.export import HEADER_BYTES, MAGIC, dequantize, quantize, quantized_copy, write
from nss.lexicon import Lexicon, UnkPolicy
from nss.models import build
from nss.nss import NeuralSearchSpace
from nss.vocab import UNK, Vocabulary


class NeuralSearchSpaceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        full = Vocabulary.load()
        cls.vocab = Vocabulary.from_words(full.words[:200])
        cls.lexicon = Lexicon.load()
        cls.policy = UnkPolicy.build(cls.lexicon, cls.vocab, 0.3)
        torch.manual_seed(0)
        cls.model = build({"arch": "lstm", "embed": 8, "hidden": 12, "proj": 8, "cifg": True}, len(cls.vocab)).eval()

    def space(self):
        return NeuralSearchSpace(self.model, self.vocab, self.lexicon, self.policy)

    def test_word_distribution_is_normalized_without_specials(self):
        space = self.space()
        space.update(["i", "am"])
        words = space.log_probs[4:].exp().sum() + space.log_probs[UNK].exp()
        self.assertAlmostEqual(float(words), 1.0, places=6)
        self.assertTrue(torch.isinf(space.log_probs[[0, 2, 3]]).all())

    def test_unknown_words_share_the_unk_mass(self):
        space = self.space()
        space.update(["the"])
        word = "abandoned"   # a lexicon word outside the 200-word vocabulary
        self.assertEqual(self.vocab.exact(word), UNK)
        expected = space.unk_log_probability() + math.log(0.3) + math.log(self.lexicon.unigram_mass(word)) \
            - math.log(self.policy.oov_mass)
        self.assertAlmostEqual(space.log_probability(word), expected, places=9)
        # Summed over every lexicon word outside the vocabulary, the fallback spends
        # exactly share * P(<unk>).
        total = sum(math.exp(space.log_probability(w)) for w in self.lexicon.frequency if self.vocab.exact(w) == UNK)
        self.assertAlmostEqual(total, 0.3 * math.exp(space.unk_log_probability()), places=6)

    def test_arcs_are_sorted_above_threshold(self):
        space = self.space()
        space.update([])
        arcs = space.arcs(-6.0)
        self.assertTrue(arcs)
        self.assertTrue(all(score > -6.0 for _, score in arcs))
        self.assertEqual([s for _, s in arcs], sorted((s for _, s in arcs), reverse=True))
        self.assertNotIn("<unk>", [w for w, _ in arcs])

    def test_sequence_equals_reading_the_words(self):
        space = self.space()
        space.update(["can", "you"])
        phrase = space.sequence(["send", "the"])
        first = space.log_probability("send")
        reader = self.space()
        reader.update(["can", "you", "send"])
        self.assertAlmostEqual(phrase, first + reader.log_probability("the"), places=5)


class ExportTests(unittest.TestCase):
    def test_quantization_error_is_half_a_step(self):
        matrix = torch.randn(17, 9).numpy()
        q, scales = quantize(matrix)
        self.assertLessEqual(float(abs(dequantize(q, scales) - matrix).max()), float(scales.max()) / 2 + 1e-7)

    def test_header_and_quantized_reference(self):
        vocab = Vocabulary.from_words(Vocabulary.load().words[:50])
        model = build({"arch": "gru", "embed": 8, "hidden": 6, "proj": 8}, len(vocab)).eval()
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "m.nsslm"
            info = write(model, vocab, 0.25, "00" * 32, path, unk_center=-2.5)
            data = path.read_bytes()
        self.assertEqual(len(data), info["bytes"])
        magic, version, arch, flags, size, embed, hidden, proj, layers, features = struct.unpack_from("<4s9I", data)
        self.assertEqual((magic, version, arch, size, embed, hidden, proj, layers, features),
                         (MAGIC, 1, 2, 50, 8, 6, 8, 1, 8))
        self.assertAlmostEqual(struct.unpack_from("<f", data, 60)[0], 0.25)
        self.assertAlmostEqual(struct.unpack_from("<f", data, 68)[0], -2.5)
        self.assertEqual(data[80:112], bytes.fromhex(vocab.sha256))
        self.assertGreater(len(data), HEADER_BYTES)
        reference = quantized_copy(model)
        tokens = torch.tensor([[2, 5, 6, 7]])
        self.assertLess(float((reference(tokens)[0] - model(tokens)[0]).abs().max()), 0.05)


if __name__ == "__main__":
    unittest.main()
