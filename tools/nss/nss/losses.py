"""Full-softmax cross-entropy over the 30k vocabulary without materializing all logits.

A [tokens x 30k] logit matrix for a 6k-token batch is ~0.7 GB in fp32, plus as much
again for its gradient. This computes the loss and gradients in row chunks and
recomputes each chunk's logits in backward, so peak memory is one chunk. The loss is
exact (no sampling): P(<unk>|context) must be calibrated, and sampled softmax biases
exactly the rare-class probabilities the <unk> fallback depends on.
"""

from __future__ import annotations

import torch


class ChunkedCrossEntropy(torch.autograd.Function):
    """Rows weighted 0/1 rather than dropped: every batch keeps one shape, so MPS reuses
    its compiled kernels (a boolean-masked row count differs per batch and recompiles)."""

    @staticmethod
    def forward(ctx, features, weight, bias, targets, rows_weight, chunk):
        total = features.new_zeros(())
        for start in range(0, features.shape[0], chunk):
            logits = torch.addmm(bias, features[start:start + chunk], weight.t())
            picked = logits.gather(1, targets[start:start + chunk, None]).squeeze(1)
            total = total + ((torch.logsumexp(logits, -1) - picked) * rows_weight[start:start + chunk]).sum()
        ctx.save_for_backward(features, weight, bias, targets, rows_weight)
        ctx.chunk = chunk
        return total

    @staticmethod
    def backward(ctx, grad):
        features, weight, bias, targets, rows_weight = ctx.saved_tensors
        grad_features = torch.empty_like(features)
        grad_weight = torch.zeros_like(weight)
        grad_bias = torch.zeros_like(bias)
        for start in range(0, features.shape[0], ctx.chunk):
            rows = features[start:start + ctx.chunk]
            probabilities = torch.softmax(torch.addmm(bias, rows, weight.t()), -1)
            probabilities[torch.arange(rows.shape[0], device=rows.device), targets[start:start + ctx.chunk]] -= 1
            probabilities *= rows_weight[start:start + ctx.chunk, None]
            grad_features[start:start + ctx.chunk] = probabilities @ weight
            grad_weight.addmm_(probabilities.t(), rows)
            grad_bias += probabilities.sum(0)
        return grad_features * grad, grad_weight * grad, grad_bias * grad, None, None, None


def cross_entropy_sum(features: torch.Tensor, weight: torch.Tensor, bias: torch.Tensor,
                      targets: torch.Tensor, chunk: int = 1024, rows_weight: torch.Tensor | None = None) -> torch.Tensor:
    """Summed exact cross-entropy of `targets` given `features` [N, D], each row weighted
    by `rows_weight` (default 1)."""
    if rows_weight is None:
        rows_weight = features.new_ones(features.shape[0])
    return ChunkedCrossEntropy.apply(features.contiguous(), weight, bias, targets, rows_weight.to(features.dtype), chunk)
