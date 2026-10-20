"""Dependency-free, fail-closed checks shared by research model exporters."""
import hashlib
import json
import math
from pathlib import Path


def require_parity(error, tolerance, label):
    if not math.isfinite(error) or error > tolerance:
        raise ValueError(f"{label}: error {error!r} exceeds tolerance {tolerance}")


def steps_per_budget(microseconds_per_step, budget_ms=1.0):
    if not math.isfinite(microseconds_per_step) or microseconds_per_step <= 0:
        raise ValueError("step time must be finite and positive")
    return int(budget_ms * 1000 / microseconds_per_step)


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def write_manifest(output, checkpoint, config, verification, tokenizer=None):
    """Sidecar provenance, including whether Core ML runtime parity was checked."""
    output = Path(output)
    package = hashlib.sha256()
    for path in sorted(output.rglob("*")):
        if path.is_file():
            package.update(str(path.relative_to(output)).encode())
            package.update(bytes.fromhex(sha256(path)))
    manifest = {"schema_version": 1, "checkpoint_sha256": sha256(checkpoint),
                "package_sha256": package.hexdigest(), "model_config": config,
                "verification": verification}
    if tokenizer is not None:
        manifest["tokenizer_sha256"] = sha256(tokenizer)
    output.with_suffix(".manifest.json").write_text(
        json.dumps(manifest, indent=2) + "\n", encoding="utf-8")


def write_score_goldens(output, model, checkpoint, tokenizer):
    """Reference scores use the exact same checkpoint/tokenizer as the export."""
    import sentencepiece as spm
    import torch
    from export_gru_score_coreml import boundary_mask, streamed_score
    sp = spm.SentencePieceProcessor(model_file=str(tokenizer))
    context = ["i", "am", "going", "to"]
    words = ["the", "work", "school", "onboarding", "uncomfortable", "encyclopedia"]
    ends = boundary_mask([sp.id_to_piece(i) for i in range(sp.vocab_size())])
    en = sp.piece_to_id("<en>")
    tokens = ([en] if en != sp.unk_id() else []) + sp.encode(" ".join(context), out_type=int)
    pad = sp.piece_to_id("<pad>")
    pad = pad if pad != sp.unk_id() else 0
    with torch.no_grad():
        scores = {word: streamed_score(model, tokens or [pad], sp.encode(word, out_type=int), pad, ends)
                  for word in words}
    Path(output).with_suffix(".goldens.json").write_text(json.dumps({
        "score_version": 2, "checkpoint_sha256": sha256(checkpoint),
        "tokenizer_sha256": sha256(tokenizer), "context": context, "scores": scores,
    }, indent=2) + "\n", encoding="utf-8")
