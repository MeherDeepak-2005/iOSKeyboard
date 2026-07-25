#!/usr/bin/env python3
"""Export a BATCHED GRU scorer to Core ML — the perf lever from GRU_INTEGRATION.md §5.

The single-step export (export_gru_coreml.py) is what the in-trie beam needs (it branches state
across paths). This one is for the SCORING path: given the context state (threaded once on-device by
the persisted single-step model) plus a batch of candidate token rows, it returns one
log P(word | context) per row in a SINGLE Core ML call — collapsing the per-candidate-per-token
round trips streamScore makes. `forward_step` already takes a batch dim, so this is just the batched
forward gathered at the candidate positions; it matches streamScore exactly, verified below.

  python export_gru_score_coreml.py --checkpoint data/gru.pt --out data/gru_score.mlpackage

Row layout (mirrors streamScore): for a k-piece candidate w0..w_{k-1} after a context whose last
token is `prev`, the GRU is fed [prev, w0, .., w_{k-2}] from the context state and scored against
targets [w0, .., w_{k-1}]; mask selects the k real positions. B rows, T time steps, fixed for tracing.
"""
import argparse
import numpy as np
import torch

from model import load_inference_checkpoint

B_DEFAULT = 32          # candidate batch (matches GRULanguagePrior score() cap)
T_DEFAULT = 16          # max scored pieces per candidate (longer words fall back to single-step)


class GRUBatchScore(torch.nn.Module):
    """One call: [B,T] candidate rows + shared context state -> [B] summed log-probs."""

    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, tokens, state_in, targets, mask):
        # tokens [B,T] int32, state_in [layers,B,hidden] f32, targets [B,T] int32, mask [B,T] f32
        states, _ = self.model.hidden_states(tokens.long(), state_in)   # [B,T,hidden] (normed)
        logits = self.model.head(states)                                # [B,T,vocab]
        logp = torch.log_softmax(logits, dim=-1)
        gathered = logp.gather(2, targets.long().unsqueeze(-1)).squeeze(-1)  # [B,T]
        return (gathered * mask).sum(dim=1)                             # [B]


def context_state(model, ctx_tokens, pad_id):
    """Thread context through forward_step exactly as Swift runContext does: return the state after
    consuming [pad, t0..t_{n-2}] and the last context token (the first `prev` fed to a candidate)."""
    state = model.empty_state(batch=1)
    prev = torch.tensor([pad_id], dtype=torch.long)
    for tok in ctx_tokens:
        _, state = model.forward_step(prev, state)
        prev = torch.tensor([tok], dtype=torch.long)
    return state, ctx_tokens[-1]


def streamed_score(model, ctx_tokens, cand_tokens, pad_id):
    """Ground-truth log P(candidate | context) = streamScore's inner loop, one candidate."""
    state, prev = context_state(model, ctx_tokens, pad_id)
    lp = 0.0
    p = prev
    for tok in cand_tokens:
        logits, state = model.forward_step(torch.tensor([p], dtype=torch.long), state)
        lp += float(torch.log_softmax(logits[0], -1)[tok])
        p = tok
    return lp


def build_batch(model, ctx_tokens, cands, B, T, pad_id):
    """Fill [B,T] tokens/targets/mask + broadcast the context state to [layers,B,hidden]."""
    state, prev = context_state(model, ctx_tokens, pad_id)
    layers, hidden = state.shape[0], state.shape[2]
    tokens = np.zeros((B, T), dtype=np.int32)
    targets = np.zeros((B, T), dtype=np.int32)
    mask = np.zeros((B, T), dtype=np.float32)
    for b, cand in enumerate(cands[:B]):
        k = min(len(cand), T)
        row_in = [prev] + list(cand[:k - 1])          # [prev, w0..w_{k-2}]
        for t in range(k):
            tokens[b, t] = row_in[t] if t < len(row_in) else pad_id
            targets[b, t] = cand[t]
            mask[b, t] = 1.0
    state_in = np.repeat(state.detach().numpy().astype(np.float32), B, axis=1)  # [layers,B,hidden]
    return tokens, state_in, targets, mask


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--checkpoint", default="data/gru.pt")
    ap.add_argument("--out", default="data/gru_score.mlpackage")
    ap.add_argument("--tokenizer", default="data/qwen_spm.model")
    ap.add_argument("--batch", type=int, default=B_DEFAULT)
    ap.add_argument("--time", type=int, default=T_DEFAULT)
    ap.add_argument("--precision", default="fp16", choices=["fp16", "fp32"])
    args = ap.parse_args()

    model, _ = load_inference_checkpoint(args.checkpoint)
    model.eval()
    cfg = model.config
    layers, hidden = cfg.layers, cfg.hidden
    B, T = args.batch, args.time
    score = GRUBatchScore(model).eval()

    ex_tokens = torch.zeros(B, T, dtype=torch.int32)
    ex_state = torch.zeros(layers, B, hidden, dtype=torch.float32)
    ex_targets = torch.zeros(B, T, dtype=torch.int32)
    ex_mask = torch.zeros(B, T, dtype=torch.float32)
    with torch.no_grad():
        traced = torch.jit.trace(score, (ex_tokens, ex_state, ex_targets, ex_mask))

    import coremltools as ct
    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="tokens", shape=(B, T), dtype=np.int32),
            ct.TensorType(name="state_in", shape=(layers, B, hidden), dtype=np.float32),
            ct.TensorType(name="targets", shape=(B, T), dtype=np.int32),
            ct.TensorType(name="mask", shape=(B, T), dtype=np.float32),
        ],
        outputs=[ct.TensorType(name="log_probs", dtype=np.float32)],
        minimum_deployment_target=ct.target.iOS18,
        compute_precision=ct.precision.FLOAT16 if args.precision == "fp16" else ct.precision.FLOAT32,
        compute_units=ct.ComputeUnit.ALL,
    )

    mlmodel.save(args.out)
    print("saved", args.out, f"(B={B}, T={T}, {args.precision})")

    # Parity: the batched SCORER module reproduces single-step streamScore EXACTLY (pure PyTorch —
    # same recurrence, so this is the logic check that the [B,T] gather/mask layout is right). Core
    # ML == this module is what conversion guarantees for the GRU ops (already established by
    # export_gru_coreml.py's Core ML==PyTorch check) and is verified on the Core ML RUNTIME by the
    # simulator test `gruBatchedCoreMLScoresMatchReference` — coremltools' in-process predict crashes
    # (libc++ mutex) on this batched graph, so runtime verification lives on-device where it matters.
    import sentencepiece as spm
    sp = spm.SentencePieceProcessor(model_file=args.tokenizer)
    pad_id = sp.piece_to_id("<pad>"); pad_id = 0 if pad_id == sp.unk_id() else pad_id
    en_id = sp.piece_to_id("<en>"); en_id = None if en_id == sp.unk_id() else en_id

    def enc_ctx(words):
        ids = [en_id] if en_id is not None else []
        t = " ".join(words).lower().strip()
        if t:
            ids += sp.encode(t, out_type=int)
        return ids or [pad_id]

    contexts = [["i", "am", "going", "to"], ["what", "are", "you"], ["happy"]]
    words = ["the", "work", "school", "onboarding", "uncomfortable", "encyclopedia",
             "doing", "birthday", "tomorrow", "restaurant"]
    worst = 0.0
    for ctx in contexts:
        ctx_tokens = enc_ctx(ctx)
        cands = [sp.encode(w.lower(), out_type=int) for w in words]
        tokens, state_in, targets, mask = build_batch(model, ctx_tokens, cands, B, T, pad_id)
        with torch.no_grad():
            batched = score(torch.tensor(tokens), torch.tensor(state_in),
                            torch.tensor(targets), torch.tensor(mask)).numpy()
        for b in range(len(words)):
            stream = streamed_score(model, ctx_tokens, cands[b], pad_id)
            worst = max(worst, abs(float(batched[b]) - stream))
    print(f"batched SCORER module vs single-step streamScore: max |Δ| = {worst:.2e}  "
          f"({'OK' if worst < 1e-3 else 'FAIL'})")


if __name__ == "__main__":
    main()
