#!/usr/bin/env python3
"""Export the keyboard LM as a calibrated Core ML W8A8 model.

The production package keeps the existing Swift interface:

  tokens, score_positions, target_ids, score_mask, next_positions
      -> candidate_log_probs, next_logits

The default checkpoint is the supplied 10.6M-parameter English pretraining
checkpoint. Core ML activation calibration and model conversion run in separate
processes from SentencePiece because those native libraries have deadlocked during
interpreter teardown on some macOS/Python combinations.

The final package is W8A8: eligible matrix operations have INT8 weights and INT8
activations. LayerNorm, softmax, indexing, and public scores remain floating point;
Core ML does not provide an all-INT8 implementation for those operations.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import struct
import subprocess
import sys
from collections import Counter
from pathlib import Path


HERE = Path(__file__).resolve().parent
DATA = HERE / "data"
KEYBOARD = HERE.parents[1] / "keyboard"
DEFAULT_CHECKPOINT = DATA / "qwen_pretrain.pt"
DEFAULT_SENTENCEPIECE = DATA / "qwen_spm.model"
DEFAULT_CALIBRATION_TEXT = DATA / "messaging_heldout.txt"
DEFAULT_CALIBRATION_CACHE = DATA / "qwen_coreml_calibration.npz"
DEFAULT_OUTPUT = KEYBOARD / "rescorer.mlpackage"
DEFAULT_TOKENIZER_OUTPUT = KEYBOARD / "tokenizer.bin"
DEFAULT_MANIFEST = HERE / "coreml_export_manifest.json"

L = 32
K = 8
MAX_BATCH = 16
MAX_PACKAGE_MB = 12.0
WORD_RE = re.compile(r"[A-Za-z]+(?:['’][A-Za-z]+)*")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def manifest_path(path: Path) -> str:
    """Use portable repository-relative paths in the generated shipping record."""
    repository = HERE.parents[1]
    try:
        return str(path.resolve().relative_to(repository))
    except ValueError:
        return str(path)


def package_bytes(path: Path) -> int:
    return sum(item.stat().st_size for item in path.rglob("*") if item.is_file())


def load_checkpoint(path: Path):
    import torch
    from model import count_parameters, load_inference_checkpoint

    model, checkpoint = load_inference_checkpoint(path)
    print(
        f"loaded {type(model).__name__}: {count_parameters(model):,} parameters "
        f"(stage={checkpoint.get('stage', 'legacy')})",
        flush=True,
    )
    return model, checkpoint


def export_tokenizer(sentencepiece_path: Path, output: Path) -> None:
    import sentencepiece as spm

    processor = spm.SentencePieceProcessor(model_file=str(sentencepiece_path))
    count = processor.vocab_size()
    pieces = [processor.id_to_piece(index) for index in range(count)]
    scores = [processor.get_score(index) for index in range(count)]
    blob = bytearray()
    offsets = [0]
    for piece in pieces:
        blob += piece.encode("utf-8")
        offsets.append(len(blob))

    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("wb") as handle:
        handle.write(struct.pack("<4I", 0x4B42544B, 1, count, processor.unk_id()))
        handle.write(struct.pack(f"<{count}f", *scores))
        handle.write(struct.pack(f"<{count + 1}I", *offsets))
        handle.write(blob)
    print(f"wrote {output} ({count:,} pieces)", flush=True)


def calibration_records(path: Path) -> list[tuple[str, str]]:
    records: list[tuple[str, str]] = []
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        words = [match.group(0).replace("’", "'").lower() for match in WORD_RE.finditer(raw)]
        if len(words) < 2:
            continue
        # Two positions per line broaden activation ranges without importing a
        # corpus-sized calibration set into memory.
        positions = {len(words) - 1, max(1, len(words) // 2)}
        for position in sorted(positions):
            context = " ".join(words[max(0, position - 12):position])
            candidate = words[position]
            if context and candidate:
                records.append((context, candidate))
    if not records:
        raise RuntimeError(f"no calibration records found in {path}")
    return records


def build_calibration_cache(
    sentencepiece_path: Path,
    text_path: Path,
    output: Path,
    sample_count: int,
) -> None:
    import numpy as np
    import sentencepiece as spm

    processor = spm.SentencePieceProcessor(model_file=str(sentencepiece_path))
    mode_id = processor.piece_to_id("<en>")
    if mode_id < 0:
        raise RuntimeError("the tokenizer is missing the required <en> mode token")
    records = calibration_records(text_path)
    rng = np.random.default_rng(17)
    order = rng.permutation(len(records))
    needed = sample_count * MAX_BATCH
    selected = [records[int(order[index % len(order)])] for index in range(needed)]

    payload: dict[str, np.ndarray] = {
        "sample_count": np.asarray([sample_count], dtype=np.int32),
    }
    pad_id = processor.pad_id() if processor.pad_id() >= 0 else 0
    for sample_index in range(sample_count):
        tokens = np.full((MAX_BATCH, L), pad_id, dtype=np.int32)
        score_positions = np.zeros((MAX_BATCH, K), dtype=np.int32)
        target_ids = np.zeros((MAX_BATCH, K), dtype=np.int32)
        score_mask = np.zeros((MAX_BATCH, K), dtype=np.float32)
        next_positions = np.zeros((MAX_BATCH, 1), dtype=np.int32)

        for batch_index in range(MAX_BATCH):
            context_text, candidate_text = selected[sample_index * MAX_BATCH + batch_index]
            context = [mode_id] + processor.encode(context_text, out_type=int)
            candidate = processor.encode(" " + candidate_text, out_type=int)
            if not candidate:
                candidate = [processor.unk_id()]
            candidate = candidate[:K]
            if len(context) + len(candidate) >= L:
                context = context[-max(1, L - len(candidate) - 1):]
            row = context + candidate
            tokens[batch_index, :len(row)] = np.asarray(row, dtype=np.int32)
            next_positions[batch_index, 0] = len(row) - 1
            for slot, token_id in enumerate(candidate):
                score_positions[batch_index, slot] = len(context) - 1 + slot
                target_ids[batch_index, slot] = token_id
                score_mask[batch_index, slot] = 1

        prefix = f"sample_{sample_index:03d}_"
        payload[prefix + "tokens"] = tokens
        payload[prefix + "score_positions"] = score_positions
        payload[prefix + "target_ids"] = target_ids
        payload[prefix + "score_mask"] = score_mask
        payload[prefix + "next_positions"] = next_positions

    output.parent.mkdir(parents=True, exist_ok=True)
    np.savez_compressed(output, **payload)
    print(
        f"wrote {output}: {sample_count} batches / {needed} messaging examples",
        flush=True,
    )


def load_calibration_cache(path: Path) -> list[dict[str, object]]:
    import numpy as np

    with np.load(path) as archive:
        sample_count = int(archive["sample_count"][0])
        result = []
        for sample_index in range(sample_count):
            prefix = f"sample_{sample_index:03d}_"
            result.append({
                name: archive[prefix + name]
                for name in (
                    "tokens", "score_positions", "target_ids", "score_mask", "next_positions"
                )
            })
    return result


def collect_linear_input_absmax(model, samples) -> dict[str, object]:
    """Collect per-channel maxima used by the inference-only SmoothQuant transform."""
    import torch

    maxima: dict[str, torch.Tensor] = {}
    hooks = []
    for name, module in model.named_modules():
        if name == "head" or not isinstance(module, torch.nn.Linear):
            continue

        def capture(_module, inputs, _output, layer_name=name):
            values = inputs[0].detach().abs()
            axes = tuple(range(values.ndim - 1))
            current = values.amax(dim=axes).cpu()
            previous = maxima.get(layer_name)
            maxima[layer_name] = current if previous is None else torch.maximum(previous, current)

        hooks.append(module.register_forward_hook(capture))

    try:
        with torch.inference_mode():
            for sample in samples:
                model.hidden(torch.from_numpy(sample["tokens"]).to(torch.int64))
    finally:
        for hook in hooks:
            hook.remove()
    return maxima


def mil_op_counts(model) -> Counter:
    counts: Counter = Counter()
    program = getattr(model, "_mil_program", None)
    if program is None:
        return counts

    def walk(block) -> None:
        for operation in block.operations:
            counts[operation.op_type] += 1
            for nested in operation.blocks:
                walk(nested)

    for function in program.functions.values():
        walk(function)
    return counts


def vocabulary_head_ops(model, vocab_size: int) -> list[str]:
    """Return linear operations whose output axis is the tokenizer vocabulary."""
    result: list[str] = []
    program = getattr(model, "_mil_program", None)
    if program is None:
        return result

    def walk(block) -> None:
        for operation in block.operations:
            if operation.op_type == "linear":
                shape = operation.outputs[0].shape
                if shape and shape[-1] == vocab_size:
                    result.append(operation.name)
            for nested in operation.blocks:
                walk(nested)

    for function in program.functions.values():
        walk(function)
    return result


def degenerate_linear_ops(model, samples) -> dict[str, list[str]]:
    """Find linear ops whose calibrated input/output range is exactly zero.

    Core ML Tools 9's experimental suffix pass does not apply the zero-scale
    safeguard used by its prefix pass and otherwise raises ``scale cannot be 0``.
    Such an op has no information to quantize for this interface, so leaving that
    isolated operation floating point is both numerically exact and preferable to
    inventing a scale. Remove this compatibility guard once the public API handles
    degenerate activation ranges itself.
    """
    import math
    from coremltools.optimize.coreml.experimental._post_training_quantization import (
        _get_activation_calibration_stats,
    )

    stats = _get_activation_calibration_stats(model, samples)
    bad: dict[str, list[str]] = {}
    program = getattr(model, "_mil_program", None)
    if program is None:
        return bad

    def is_degenerate(variable) -> bool:
        value = stats.get(variable.name)
        if not value:
            return False
        minimum = float(value.get("rmin", 0))
        maximum = float(value.get("rmax", 0))
        return not (math.isfinite(minimum) and math.isfinite(maximum)) or max(
            abs(minimum), abs(maximum)
        ) <= 1e-12

    def walk(block) -> None:
        for operation in block.operations:
            if operation.op_type == "linear":
                variables = [operation.inputs["x"], operation.outputs[0]]
                names = [variable.name for variable in variables if is_degenerate(variable)]
                if names:
                    bad[operation.name] = names
            for nested in operation.blocks:
                walk(nested)

    for function in program.functions.values():
        walk(function)
    return bad


def smoke_compare(reference, quantized, samples) -> dict[str, float]:
    import numpy as np

    candidate_agreement = []
    next_top1_agreement = []
    next_top5_overlap = []
    score_errors = []
    correlations = []
    for inputs in samples[:8]:
        expected = reference.predict(inputs)
        actual = quantized.predict(inputs)
        expected_scores = np.asarray(expected["candidate_log_probs"]).reshape(-1)
        actual_scores = np.asarray(actual["candidate_log_probs"]).reshape(-1)
        score_errors.append(float(np.max(np.abs(expected_scores - actual_scores))))
        candidate_agreement.append(int(expected_scores.argmax() == actual_scores.argmax()))

        expected_logits = np.asarray(expected["next_logits"]).reshape(MAX_BATCH, -1)
        actual_logits = np.asarray(actual["next_logits"]).reshape(MAX_BATCH, -1)
        for expected_row, actual_row in zip(expected_logits, actual_logits):
            next_top1_agreement.append(int(expected_row.argmax() == actual_row.argmax()))
            expected_top5 = set(np.argpartition(expected_row, -5)[-5:].tolist())
            actual_top5 = set(np.argpartition(actual_row, -5)[-5:].tolist())
            next_top5_overlap.append(len(expected_top5 & actual_top5) / 5)
            correlation = np.corrcoef(expected_row.astype(np.float64), actual_row.astype(np.float64))[0, 1]
            correlations.append(float(correlation) if np.isfinite(correlation) else 0.0)

    return {
        "candidate_top1_agreement": float(np.mean(candidate_agreement)),
        "candidate_max_abs_error": max(score_errors),
        "next_top1_agreement": float(np.mean(next_top1_agreement)),
        "next_top5_overlap": float(np.mean(next_top5_overlap)),
        "minimum_logit_correlation": min(correlations),
        "mean_logit_correlation": float(np.mean(correlations)),
    }


def export_model(args) -> None:
    import coremltools as ct
    import numpy as np
    import torch
    from coremltools.optimize.coreml import (
        OpLinearQuantizerConfig,
        OptimizationConfig,
        linear_quantize_weights,
    )
    from coremltools.optimize.coreml.experimental import (
        OpActivationLinearQuantizerConfig,
        linear_quantize_activations,
    )
    from model import KeyboardInferenceModel, apply_smooth_quant, count_parameters

    model, checkpoint = load_checkpoint(args.checkpoint)
    samples = load_calibration_cache(args.calibration_cache)
    if not samples:
        raise RuntimeError("activation calibration cache is empty")
    max_length = getattr(model, "maxlen", None)
    embedding = model.emb if hasattr(model, "emb") else model.embedding
    vocab_size = embedding.num_embeddings
    if max_length != L:
        raise RuntimeError(f"checkpoint length {max_length} does not match export length {L}")
    if checkpoint.get("tokenizer_sha256"):
        actual_hash = sha256(args.sentencepiece)
        if checkpoint["tokenizer_sha256"] != actual_hash:
            raise RuntimeError("checkpoint and SentencePiece tokenizer hashes do not match")

    smooth_summary = {}
    smooth_equivalence = {}
    if args.smooth_alpha > 0:
        probe_names = (
            "tokens", "score_positions", "target_ids", "score_mask", "next_positions"
        )
        baseline_wrapper = KeyboardInferenceModel(model).eval()
        probe = tuple(torch.from_numpy(samples[0][name]) for name in probe_names)
        with torch.inference_mode():
            baseline_scores, baseline_logits = baseline_wrapper(*probe)
        print(f"collecting SmoothQuant ranges (alpha={args.smooth_alpha:.2f})...", flush=True)
        input_absmax = collect_linear_input_absmax(model, samples)
        smooth_summary = apply_smooth_quant(model, input_absmax, args.smooth_alpha)
        smoothed_wrapper = KeyboardInferenceModel(model).eval()
        with torch.inference_mode():
            smooth_scores, smooth_logits = smoothed_wrapper(*probe)
        smooth_equivalence = {
            "candidate_max_abs_error": float((baseline_scores - smooth_scores).abs().max()),
            "next_logit_max_abs_error": float((baseline_logits - smooth_logits).abs().max()),
        }
        if max(smooth_equivalence.values()) > 0.002:
            raise RuntimeError(f"SmoothQuant changed the FP model: {smooth_equivalence}")
        print(f"SmoothQuant FP equivalence: {smooth_equivalence}", flush=True)

    wrapper = KeyboardInferenceModel(model).eval()
    example = (
        torch.zeros(MAX_BATCH, L, dtype=torch.int32),
        torch.zeros(MAX_BATCH, K, dtype=torch.int32),
        torch.zeros(MAX_BATCH, K, dtype=torch.int32),
        torch.zeros(MAX_BATCH, K, dtype=torch.float32),
        torch.zeros(MAX_BATCH, 1, dtype=torch.int32),
    )
    print("tracing the compact PyTorch inference graph...", flush=True)
    with torch.inference_mode():
        traced = torch.jit.freeze(torch.jit.trace(wrapper, example, strict=True))

    print("converting the in-memory reference graph to Core ML FP16...", flush=True)
    reference = ct.convert(
        traced,
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.iOS17,
        compute_precision=ct.precision.FLOAT16,
        compute_units=ct.ComputeUnit.CPU_AND_NE,
        inputs=[
            ct.TensorType(name="tokens", shape=(MAX_BATCH, L), dtype=np.int32),
            ct.TensorType(name="score_positions", shape=(MAX_BATCH, K), dtype=np.int32),
            ct.TensorType(name="target_ids", shape=(MAX_BATCH, K), dtype=np.int32),
            ct.TensorType(name="score_mask", shape=(MAX_BATCH, K), dtype=np.float32),
            ct.TensorType(name="next_positions", shape=(MAX_BATCH, 1), dtype=np.int32),
        ],
        outputs=[
            ct.TensorType(name="candidate_log_probs"),
            ct.TensorType(name="next_logits"),
        ],
    )
    reference.author = "Glyph keyboard"
    reference.short_description = "10.6M English keyboard candidate and next-word scorer"
    reference.user_defined_metadata["checkpoint_stage"] = str(checkpoint.get("stage", "legacy"))
    reference.user_defined_metadata["parameter_count"] = str(count_parameters(model))
    reference.user_defined_metadata["vocab_size"] = str(vocab_size)
    reference.user_defined_metadata["max_length"] = str(L)

    print(f"calibrating INT8 activations with {len(samples)} representative batches...", flush=True)
    # Core ML Tools 9's global pass also selects integer ``add`` ops used to build
    # gather indices, then attempts to attach a floating-point activation scale to
    # an INT32 tensor. Quantize only ``linear``: these are the transformer's QKV,
    # projection, feed-forward, and tied vocabulary-head operations that map to the
    # Neural Engine's INT8 x INT8 kernels. Index arithmetic must stay integer.
    degenerate = degenerate_linear_ops(reference, samples)
    if degenerate:
        print(
            "leaving zero-range linear activations in FP16: "
            + ", ".join(sorted(degenerate)),
            flush=True,
        )
    activation_exclusions = dict(degenerate)
    head_ops = vocabulary_head_ops(reference, vocab_size)
    if args.activation_scope == "transformer":
        for name in head_ops:
            activation_exclusions[name] = ["vocabulary head diagnostic exclusion"]
        print(
            "diagnostic mode: leaving vocabulary-head activations in FP16: "
            + ", ".join(head_ops),
            flush=True,
        )
    activation_config = OptimizationConfig(
        op_type_configs={
            "linear": OpActivationLinearQuantizerConfig(mode="linear")
        },
        op_name_configs={name: None for name in activation_exclusions},
    )
    activation_int8 = linear_quantize_activations(reference, activation_config, samples)

    print("quantizing eligible weights to per-channel INT8...", flush=True)
    weight_config = OptimizationConfig(global_config=OpLinearQuantizerConfig(
        mode="linear",
        dtype="int8",
        granularity="per_channel",
        weight_threshold=0,
    ))
    weight_int8 = linear_quantize_weights(reference, config=weight_config)
    w8a8 = linear_quantize_weights(activation_int8, config=weight_config)
    w8a8.author = reference.author
    w8a8.short_description = reference.short_description
    w8a8.user_defined_metadata.update(reference.user_defined_metadata)
    w8a8.user_defined_metadata["quantization"] = "W8A8"

    counts = mil_op_counts(w8a8)
    required = {
        "weight_int8": counts["constexpr_affine_dequantize"] > 0,
        "activation_int8": counts["quantize"] > 0 and counts["dequantize"] > 0,
    }
    if not all(required.values()):
        raise RuntimeError(f"W8A8 graph verification failed: {required}; ops={dict(counts)}")

    activation_parity = smoke_compare(reference, activation_int8, samples)
    weight_parity = smoke_compare(reference, weight_int8, samples)
    parity = smoke_compare(reference, w8a8, samples)
    print(
        json.dumps(
            {
                "activation_only_parity": activation_parity,
                "weight_only_parity": weight_parity,
                "w8a8_parity": parity,
            },
            indent=2,
            sort_keys=True,
        ),
        flush=True,
    )
    # These are conversion-parity gates, not language-quality gates. The latter must
    # be measured separately against the current model before changing blend weights.
    parity_passed = (
        parity["candidate_top1_agreement"] >= 0.875
        and parity["next_top1_agreement"] >= 0.95
        and parity["next_top5_overlap"] >= 0.90
        and parity["mean_logit_correlation"] >= 0.98
    )
    if not parity_passed:
        raise RuntimeError(f"W8A8 numerical parity gate failed: {parity}")

    if args.output.exists():
        shutil.rmtree(args.output)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    print(f"saving production W8A8 package: {args.output}", flush=True)
    w8a8.save(args.output)
    size_mb = package_bytes(args.output) / 1_000_000
    size_passed = size_mb <= MAX_PACKAGE_MB
    manifest = {
        "checkpoint": manifest_path(args.checkpoint),
        "checkpoint_sha256": sha256(args.checkpoint),
        "checkpoint_stage": checkpoint.get("stage", "legacy"),
        "sentencepiece": manifest_path(args.sentencepiece),
        "sentencepiece_sha256": sha256(args.sentencepiece),
        "parameters": count_parameters(model),
        "architecture": {
            "vocab_size": vocab_size,
            "max_length": L,
            "batch_size": MAX_BATCH,
            "score_slots": K,
        },
        "quantization": "W8A8" if args.activation_scope == "all" else "transformer-W8A8-head-W8",
        "activation_scope": args.activation_scope,
        "smooth_quant_alpha": args.smooth_alpha,
        "smooth_quant_layers": smooth_summary,
        "smooth_quant_fp_equivalence": smooth_equivalence,
        "mil_ops": dict(sorted(counts.items())),
        "activation_exclusions": activation_exclusions,
        "w8a8_checks": required,
        "activation_only_parity": activation_parity,
        "weight_only_parity": weight_parity,
        "parity": parity,
        "parity_passed": parity_passed,
        "package": manifest_path(args.output),
        "package_mb": size_mb,
        "package_gate_mb": MAX_PACKAGE_MB,
        "package_gate_passed": size_passed,
    }
    args.manifest.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    print(json.dumps(manifest, indent=2, sort_keys=True), flush=True)
    if not size_passed:
        raise RuntimeError(f"W8A8 package is {size_mb:.2f} MB; gate is {MAX_PACKAGE_MB:.2f} MB")


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--part", choices=("all", "tokenizer", "calibration", "model"), default="all")
    parser.add_argument("--checkpoint", type=Path, default=DEFAULT_CHECKPOINT)
    parser.add_argument("--sentencepiece", type=Path, default=DEFAULT_SENTENCEPIECE)
    parser.add_argument("--calibration-text", type=Path, default=DEFAULT_CALIBRATION_TEXT)
    parser.add_argument("--calibration-cache", type=Path, default=DEFAULT_CALIBRATION_CACHE)
    parser.add_argument("--calibration-samples", type=int, default=32)
    parser.add_argument(
        "--activation-scope",
        choices=("all", "transformer"),
        default="all",
        help="Use transformer only to diagnose vocabulary-head activation sensitivity",
    )
    parser.add_argument(
        "--smooth-alpha",
        type=float,
        default=0.5,
        help="Apply inference-only SmoothQuant to transformer linears (0 disables it)",
    )
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--tokenizer-output", type=Path, default=DEFAULT_TOKENIZER_OUTPUT)
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    return parser.parse_args()


def subprocess_args(args, part: str) -> list[str]:
    return [
        sys.executable,
        str(Path(__file__).resolve()),
        "--part", part,
        "--checkpoint", str(args.checkpoint),
        "--sentencepiece", str(args.sentencepiece),
        "--calibration-text", str(args.calibration_text),
        "--calibration-cache", str(args.calibration_cache),
        "--calibration-samples", str(args.calibration_samples),
        "--activation-scope", args.activation_scope,
        "--smooth-alpha", str(args.smooth_alpha),
        "--output", str(args.output),
        "--tokenizer-output", str(args.tokenizer_output),
        "--manifest", str(args.manifest),
    ]


def main() -> None:
    args = parse_args()
    if args.part == "tokenizer":
        export_tokenizer(args.sentencepiece, args.tokenizer_output)
    elif args.part == "calibration":
        build_calibration_cache(
            args.sentencepiece,
            args.calibration_text,
            args.calibration_cache,
            args.calibration_samples,
        )
    elif args.part == "model":
        export_model(args)
        # Avoid a known native-library teardown deadlock after Core ML save().
        sys.stdout.flush()
        os._exit(0)
    else:
        subprocess.run(subprocess_args(args, "tokenizer"), check=True)
        subprocess.run(subprocess_args(args, "calibration"), check=True)
        subprocess.run(subprocess_args(args, "model"), check=True)


if __name__ == "__main__":
    main()
