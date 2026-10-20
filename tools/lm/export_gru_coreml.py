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
from dataclasses import asdict
import time

import numpy as np
import torch

from model import load_inference_checkpoint
from export_validation import require_parity, steps_per_budget, write_manifest, write_score_goldens


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
          f"-> a {steps_per_budget(per)}-step beam fits in 1 ms of CPU compute (not device latency)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--checkpoint", default="data/gru.pt")
    ap.add_argument("--out", default="data/gru.mlpackage")
    ap.add_argument("--precision", default="fp16", choices=["fp16", "fp32"])
    ap.add_argument("--tokenizer", default=None, help="optional tokenizer for provenance hashing")
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
    require_parity(drift, 1e-3, "PyTorch streaming parity")
    print(f"streaming parity drift: {drift:.2e}")

    if args.benchmark:
        benchmark(step, layers, hidden, vocab)
        return

    token = torch.zeros(1, 1, dtype=torch.int32)
    seed = torch.zeros(layers, 1, hidden, dtype=torch.float32)
    with torch.no_grad():
        traced = torch.jit.trace(step, (token, seed))

    import coremltools as ct
    # The recurrent state is threaded OUT of one step and back IN to the next by the
    # in-trie decoder, so state_in and state_out must be the SAME dtype — otherwise the
    # caller feeds an fp16 array into an fp32-declared input (or vice versa) every step and
    # relies on an implicit host coercion. Pin both to fp32 explicitly. Under fp16 compute
    # the GRU still runs in fp16 internally (state is fp16-precision either way); the fp32
    # I/O containers just make the threading exact and coercion-free on the Swift side.
    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="token", shape=(1, 1), dtype=np.int32),
            ct.TensorType(name="state_in", shape=(layers, 1, hidden), dtype=np.float32),
        ],
        outputs=[
            ct.TensorType(name="logits"),
            ct.TensorType(name="state_out", dtype=np.float32),
        ],
        minimum_deployment_target=ct.target.iOS18,
        compute_precision=ct.precision.FLOAT16 if args.precision == "fp16" else ct.precision.FLOAT32,
        compute_units=ct.ComputeUnit.ALL,
    )

    # Random states plus recurrent rollout and independent branches validate BOTH outputs.
    tolerance = 0.5 if args.precision == "fp16" else 1e-2
    state_tolerance = 0.05 if args.precision == "fp16" else 1e-3
    max_err = max_state_err = 0.0
    for _ in range(8):
        reference_state = torch.randn(layers, 1, hidden)
        exported_state = reference_state.numpy().astype(np.float32)
        for _ in range(24):
            token_value = torch.randint(0, vocab, (1, 1), dtype=torch.int32)
            with torch.no_grad():
                ref, reference_state = step(token_value, reference_state)
            out = mlmodel.predict({"token": token_value.numpy(), "state_in": exported_state})
            exported_state = out["state_out"].astype(np.float32)
            max_err = max(max_err, float(np.abs(out["logits"] - ref.numpy()).max()))
            max_state_err = max(max_state_err, float(np.abs(exported_state - reference_state.numpy()).max()))
            require_parity(max_err, tolerance, "Core ML rollout logits")
            require_parity(max_state_err, state_tolerance, "Core ML rollout state")
        # Fork both implementations from the SAME state, with two different next tokens.
        for value in [0, vocab - 1]:
            branch_token = torch.tensor([[value]], dtype=torch.int32)
            with torch.no_grad():
                ref_logits, ref_state = step(branch_token, reference_state)
            out = mlmodel.predict({"token": branch_token.numpy(), "state_in": exported_state})
            require_parity(float(np.abs(out["logits"] - ref_logits.numpy()).max()), tolerance, "branch logits")
            require_parity(float(np.abs(out["state_out"] - ref_state.numpy()).max()), state_tolerance, "branch state")
    print(f"Core ML rollout errors: logits={max_err:.4e}, state={max_state_err:.4e}")
    mlmodel.user_defined_metadata["keyboard_step_version"] = "1"

    mlmodel.save(args.out)
    write_manifest(args.out, args.checkpoint, asdict(cfg), {
        "coreml_runtime_verified": True, "streaming_error": drift,
        "rollout_logit_error": max_err, "rollout_state_error": max_state_err,
        "precision": args.precision}, tokenizer=args.tokenizer)
    if args.tokenizer:
        write_score_goldens(args.out, model, args.checkpoint, args.tokenizer)
    print("saved", args.out)


if __name__ == "__main__":
    main()
