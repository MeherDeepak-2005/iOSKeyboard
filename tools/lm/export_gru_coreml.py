#!/usr/bin/env python3
"""Export KeyboardGRULM.forward_step to a Core ML model (roadmap Plan 3 deployment).

The recurrent state is an EXPLICIT input/output, not a managed Core ML StateType: the
in-trie decoder must BRANCH the state across beam / continuation paths, which a single
managed state cannot do. One prediction = score one more token from a given state, and
the caller threads state_out back in as state_in for the next step.

  python export_gru_coreml.py --checkpoint data/gru.pt --out data/gru.mlpackage

Requires coremltools (Colab: `pip install coremltools`). Verifies Core ML == PyTorch
within fp16 tolerance before saving. `--benchmark` needs no coremltools — it times the
PyTorch forward_step so you can size the in-trie beam against the latency budget.
"""
import argparse
import time

import numpy as np
import torch

from model import load_inference_checkpoint


class GRUStep(torch.nn.Module):
    """One streaming step, fixed shapes (no shape-derived dynamic ops to lower)."""

    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, token, state):          # token [1, 1] int32; state [layers, 1, hidden]
        logits, new_state = self.model.forward_step(token[:, 0], state)
        return logits, new_state              # logits [1, vocab]; new_state [layers, 1, hidden]


def benchmark(step, layers, hidden, vocab, iters=2000):
    token = torch.randint(0, vocab, (1, 1), dtype=torch.int32)
    state = torch.zeros(layers, 1, hidden)
    with torch.no_grad():
        for _ in range(50):                   # warm up
            _, state = step(token, state)
        start = time.perf_counter()
        for _ in range(iters):
            _, state = step(token, state)
        per = (time.perf_counter() - start) / iters * 1e6
    print(f"PyTorch forward_step (CPU): {per:.1f} us/step  "
          f"-> a {int(1000/max(per/1000,1e-9))}-step beam fits in ~1 ms")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--checkpoint", default="data/gru.pt")
    ap.add_argument("--out", default="data/gru.mlpackage")
    ap.add_argument("--precision", default="fp16", choices=["fp16", "fp32"])
    ap.add_argument("--benchmark", action="store_true",
                    help="time PyTorch forward_step and exit (no coremltools needed)")
    args = ap.parse_args()

    model, _ = load_inference_checkpoint(args.checkpoint)
    model.eval()
    cfg = model.config
    layers, hidden, vocab = cfg.layers, cfg.hidden, cfg.vocab_size
    step = GRUStep(model).eval()

    # Streaming parity: forward_step threaded == batched forward (the deploy invariant).
    ids = torch.randint(0, vocab, (1, 12), dtype=torch.int64)
    with torch.no_grad():
        full = model(ids)[0]
        state = model.empty_state(batch=1)
        streamed = []
        for pos in range(ids.shape[1]):
            logit, state = model.forward_step(ids[:, pos], state)
            streamed.append(logit[0])
        drift = float((full - torch.stack(streamed)).abs().max())
    print(f"streaming parity drift: {drift:.2e}  ({'OK' if drift < 1e-3 else 'FAIL'})")

    if args.benchmark:
        benchmark(step, layers, hidden, vocab)
        return

    token = torch.zeros(1, 1, dtype=torch.int32)
    seed = torch.zeros(layers, 1, hidden, dtype=torch.float32)
    with torch.no_grad():
        traced = torch.jit.trace(step, (token, seed))

    import coremltools as ct
    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="token", shape=(1, 1), dtype=np.int32),
            ct.TensorType(name="state_in", shape=(layers, 1, hidden), dtype=np.float32),
        ],
        outputs=[ct.TensorType(name="logits"), ct.TensorType(name="state_out")],
        minimum_deployment_target=ct.target.iOS18,
        compute_precision=ct.precision.FLOAT16 if args.precision == "fp16" else ct.precision.FLOAT32,
        compute_units=ct.ComputeUnit.ALL,
    )

    # Core ML vs PyTorch on random tokens/states.
    max_err = 0.0
    for _ in range(16):
        t = torch.randint(0, vocab, (1, 1), dtype=torch.int32)
        s = torch.randn(layers, 1, hidden)
        with torch.no_grad():
            ref, _ = step(t, s)
        out = mlmodel.predict({"token": t.numpy(), "state_in": s.numpy().astype(np.float32)})
        max_err = max(max_err, float(np.abs(out["logits"] - ref.numpy()).max()))
    tol = 0.5 if args.precision == "fp16" else 1e-2
    print(f"Core ML vs PyTorch max logit error: {max_err:.4e}  "
          f"({'OK' if max_err < tol else 'HIGH — inspect'})")

    mlmodel.save(args.out)
    print("saved", args.out)


if __name__ == "__main__":
    main()
