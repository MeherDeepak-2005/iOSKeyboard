import unittest
import torch
from model import GRUModelConfig, KeyboardGRULM
from export_gru_score_coreml import GRUBatchScore, build_batch, streamed_score, boundary_mask
from generate_next_words import GRUGenerator


class GRUCompleteWordTests(unittest.TestCase):
    def setUp(self):
        torch.manual_seed(7)
        self.model = KeyboardGRULM(GRUModelConfig(vocab_size=24, d_model=8, hidden=8, layers=2)).eval()
        self.ends = [i % 3 == 0 for i in range(24)]

    def test_batch_matches_exact_streaming_including_boundary(self):
        cands = [[3], [2, 5], [4, 6, 8], [9, 8, 2, 4]]
        arrays = build_batch(self.model, [1, 3, 2], cands, 6, 8, 0)
        with torch.no_grad():
            scores = GRUBatchScore(self.model, self.ends)(*(torch.tensor(a) for a in arrays))
            for index, cand in enumerate(cands):
                expected = streamed_score(self.model, [1, 3, 2], cand, 0, self.ends)
                self.assertAlmostEqual(float(scores[index]), expected, places=5)

    def test_boundary_changes_score_of_same_piece_sequence(self):
        with torch.no_grad():
            with_ending = streamed_score(self.model, [1, 2], [4, 5], 0, self.ends)
            all_tokens_end = streamed_score(self.model, [1, 2], [4, 5], 0, [True] * 24)
        self.assertLess(with_ending, all_tokens_end)

    def test_chunking_covers_tail_and_preserves_scores(self):
        cands = [[i % 24, (i + 1) % 24] for i in range(48)]
        got = []
        with torch.no_grad():
            for start in range(0, len(cands), 32):
                chunk = cands[start:start + 32]
                arrays = build_batch(self.model, [1, 2], chunk, 32, 8, 0)
                got.extend(GRUBatchScore(self.model, self.ends)(*(torch.tensor(a) for a in arrays))[:len(chunk)].tolist())
            self.assertEqual(len(got), 48)
            for score, cand in zip(got, cands):
                self.assertAlmostEqual(score, streamed_score(self.model, [1, 2], cand, 0, self.ends), places=5)

    def test_batch_refuses_silent_row_or_boundary_truncation(self):
        with self.assertRaises(ValueError):
            build_batch(self.model, [1], [[2]] * 33, 32, 8, 0)
        with self.assertRaises(ValueError):
            build_batch(self.model, [1], [[2] * 8], 32, 8, 0)

    def test_boundary_mask_matches_english_runtime_convention(self):
        self.assertEqual(boundary_mask(["▁the", "ing", "<pad>", ".", "▁q", "'s"]),
                         [True, False, True, True, True, False])

    def test_generation_filters_before_topk_and_before_word_limit(self):
        gen = GRUGenerator.__new__(GRUGenerator)
        gen.vocab = 12
        gen.pieces = ["▁bad" + chr(97+i) for i in range(9)] + ["▁qa", "▁qb", "▁qc"]
        gen.is_start_content = [True] * 12
        gen.is_cont_content = [False] * 12
        gen._boundary_mask = torch.ones(12, dtype=torch.bool)
        gen.encode_context = lambda _: [0]
        gen._run_context = lambda _: (None, 0)
        gen._step = lambda prev, state: (-torch.arange(12, dtype=torch.float32), None)
        result = gen.generate(["fixture"], k=1, branch=8, max_pieces=1,
                              first_letters={"q"}, lexicon={"qc"})
        self.assertEqual([word for word, _ in result], ["qc"])


if __name__ == "__main__":
    unittest.main()
