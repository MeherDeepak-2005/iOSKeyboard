#!/usr/bin/env python3
"""Export complete-word GRU scores: piece log probabilities plus ending probability.

Version 2 reserves one time position for the ending event. Legacy packages are
rejected by Swift and use exact streaming instead. Runtime parity is optional
because some coremltools hosts cannot execute a batched GRU; an unverified export
is explicitly marked research-only in the provenance sidecar.
"""
import argparse
from dataclasses import asdict
import numpy as np
import torch
from model import load_inference_checkpoint
from export_validation import require_parity, write_manifest, write_score_goldens

B_DEFAULT = 32
T_DEFAULT = 16


def boundary_mask(pieces):
    def continuation(piece):
        return (not piece.startswith("▁") and bool(piece)
                and all("a" <= c <= "z" or c == "'" for c in piece.lower()))
    return [not continuation(piece) for piece in pieces]


class GRUBatchScore(torch.nn.Module):
    def __init__(self, model, ends_word):
        super().__init__()
        self.model = model
        self.register_buffer("ends_word", torch.tensor(ends_word, dtype=torch.bool))

    def forward(self, tokens, state_in, targets, mask, boundary_positions):
        states, _ = self.model.hidden_states(tokens.long(), state_in)
        logits = self.model.head(states)
        logp = torch.log_softmax(logits, dim=-1)
        pieces = logp.gather(2, targets.long().unsqueeze(-1)).squeeze(-1)
        positions = boundary_positions.long().view(-1, 1, 1).expand(-1, 1, logp.shape[-1])
        ending = logp.gather(1, positions).squeeze(1)
        ending = torch.where(self.ends_word, ending, torch.full_like(ending, -1e9))
        return (pieces * mask).sum(dim=1) + torch.logsumexp(ending, dim=-1)


def context_state(model, ctx_tokens, pad_id):
    state = model.empty_state(batch=1)
    prev = torch.tensor([pad_id], dtype=torch.long)
    for tok in ctx_tokens:
        _, state = model.forward_step(prev, state)
        prev = torch.tensor([tok], dtype=torch.long)
    return state, ctx_tokens[-1] if ctx_tokens else pad_id


def streamed_score(model, ctx_tokens, cand_tokens, pad_id, ends_word):
    state, prev = context_state(model, ctx_tokens, pad_id)
    lp = 0.0
    for tok in cand_tokens:
        logits, state = model.forward_step(torch.tensor([prev]), state)
        lp += float(torch.log_softmax(logits[0], -1)[tok])
        prev = tok
    logits, _ = model.forward_step(torch.tensor([prev]), state)
    ending = torch.log_softmax(logits[0], -1)[torch.tensor(ends_word, dtype=torch.bool)]
    return lp + float(torch.logsumexp(ending, dim=0))


def build_batch(model, ctx_tokens, cands, B, T, pad_id):
    if len(cands) > B or any(len(cand) >= T for cand in cands):
        raise ValueError("caller must chunk rows and reserve the boundary position")
    state, prev = context_state(model, ctx_tokens, pad_id)
    tokens = np.full((B, T), pad_id, dtype=np.int32)
    targets = np.zeros((B, T), dtype=np.int32)
    mask = np.zeros((B, T), dtype=np.float32)
    boundaries = np.zeros(B, dtype=np.int32)
    for b, cand in enumerate(cands):
        if not cand:
            raise ValueError("empty candidates cannot be scored")
        k = len(cand)
        tokens[b, :k + 1] = [prev] + list(cand)
        targets[b, :k] = cand
        mask[b, :k] = 1
        boundaries[b] = k
    state_in = np.repeat(state.detach().numpy().astype(np.float32), B, axis=1)
    return tokens, state_in, targets, mask, boundaries


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--checkpoint", default="data/gru.pt")
    ap.add_argument("--out", default="data/gru_score.mlpackage")
    ap.add_argument("--tokenizer", default="data/qwen_spm.model")
    ap.add_argument("--batch", type=int, default=B_DEFAULT)
    ap.add_argument("--time", type=int, default=T_DEFAULT)
    ap.add_argument("--precision", default="fp16", choices=["fp16", "fp32"])
    ap.add_argument("--verify-coreml", action="store_true", help="execute runtime parity on a supported host")
    args = ap.parse_args()
    if args.batch <= 0 or args.time < 2:
        ap.error("batch must be positive and time must reserve a boundary position")
    model, _ = load_inference_checkpoint(args.checkpoint)
    model.eval()
    cfg = model.config
    B, T = args.batch, args.time
    import sentencepiece as spm
    sp = spm.SentencePieceProcessor(model_file=args.tokenizer)
    if sp.vocab_size() != cfg.vocab_size:
        raise ValueError("checkpoint and tokenizer vocabulary sizes differ")
    ends_word = boundary_mask([sp.id_to_piece(i) for i in range(sp.vocab_size())])
    score = GRUBatchScore(model, ends_word).eval()
    pad_id = sp.piece_to_id("<pad>")
    pad_id = 0 if pad_id == sp.unk_id() else pad_id
    en_id = sp.piece_to_id("<en>")
    en_id = None if en_id == sp.unk_id() else en_id
    contexts = [["i", "am", "going", "to"], ["what", "are", "you"], ["happy"]]
    words = ["the", "work", "school", "onboarding", "uncomfortable", "encyclopedia",
             "doing", "birthday", "tomorrow", "restaurant"]
    fixtures = []
    worst = 0.0
    with torch.no_grad():
        for context in contexts:
            ctx = ([en_id] if en_id is not None else []) + sp.encode(" ".join(context), out_type=int)
            cands = [sp.encode(word, out_type=int) for word in words]
            for start in range(0, len(cands), B):
                chunk = cands[start:start + B]
                arrays = build_batch(model, ctx or [pad_id], chunk, B, T, pad_id)
                expected = score(*(torch.tensor(array) for array in arrays)).numpy()
                for index, cand in enumerate(chunk):
                    reference = streamed_score(model, ctx or [pad_id], cand, pad_id, ends_word)
                    worst = max(worst, abs(float(expected[index]) - reference))
                fixtures.append((arrays, expected))
    require_parity(worst, 1e-3, "batched vs streaming complete-word score")
    print(f"PyTorch complete-word parity: max error {worst:.2e}")
    with torch.no_grad():
        traced = torch.jit.trace(score, tuple(torch.tensor(array) for array in fixtures[0][0]))
    import coremltools as ct
    mlmodel = ct.convert(traced, inputs=[
        ct.TensorType(name="tokens", shape=(B, T), dtype=np.int32),
        ct.TensorType(name="state_in", shape=(cfg.layers, B, cfg.hidden), dtype=np.float32),
        ct.TensorType(name="targets", shape=(B, T), dtype=np.int32),
        ct.TensorType(name="mask", shape=(B, T), dtype=np.float32),
        ct.TensorType(name="boundary_positions", shape=(B,), dtype=np.int32),
    ], outputs=[ct.TensorType(name="log_probs", dtype=np.float32)],
        minimum_deployment_target=ct.target.iOS18,
        compute_precision=ct.precision.FLOAT16 if args.precision == "fp16" else ct.precision.FLOAT32,
        compute_units=ct.ComputeUnit.ALL)
    runtime_error = None
    if args.verify_coreml:
        runtime_error = 0.0
        for arrays, expected in fixtures:
            inputs = dict(zip(["tokens", "state_in", "targets", "mask", "boundary_positions"], arrays))
            output = mlmodel.predict(inputs)["log_probs"]
            runtime_error = max(runtime_error, float(np.abs(output - expected).max()))
        require_parity(runtime_error, 0.5 if args.precision == "fp16" else 1e-2, "Core ML complete-word scores")
    mlmodel.user_defined_metadata["keyboard_score_version"] = "2"
    mlmodel.save(args.out)
    write_manifest(args.out, args.checkpoint, asdict(cfg), {
        "score_version": 2, "pytorch_parity_error": worst,
        "coreml_runtime_verified": args.verify_coreml, "coreml_runtime_error": runtime_error,
        "precision": args.precision, "batch": B, "time": T,
        "research_only": not args.verify_coreml}, tokenizer=args.tokenizer)
    write_score_goldens(args.out, model, args.checkpoint, args.tokenizer)
    print("saved", args.out, "(runtime parity verified)" if args.verify_coreml else "(research-only: runtime parity pending)")


if __name__ == "__main__":
    main()
