"""Deterministic byte-budget compaction for mmap n-gram tables."""

from __future__ import annotations


def compact_contexts(
    groups: dict[int, list[tuple[int, int]]],
    *,
    context_record_bytes: int,
    continuation_record_bytes: int,
    byte_budget: int,
    max_continuations: int,
) -> tuple[dict[int, list[tuple[int, int]]], dict[str, int]]:
    """Keep the strongest contexts without allowing corpus size to grow the pack.

    `groups` must already order each continuation list by descending count and stable
    word ID. Contexts are ranked by total evidence, then peak evidence, then ID. The
    returned dictionary may be encoded in sorted-key order without affecting ranking.
    """
    if context_record_bytes <= 0 or continuation_record_bytes <= 0:
        raise ValueError("record sizes must be positive")
    if byte_budget < 0:
        raise ValueError("n-gram byte budget must be non-negative")
    if max_continuations <= 0:
        raise ValueError("max continuations must be positive")

    observed_continuations = sum(len(values) for values in groups.values())
    ranked = sorted(
        groups.items(),
        key=lambda item: (
            -sum(count for _, count in item[1]),
            -(item[1][0][1] if item[1] else 0),
            item[0],
        ),
    )
    retained: dict[int, list[tuple[int, int]]] = {}
    encoded_bytes = 0
    for context, values in ranked:
        selected = values[:max_continuations]
        if not selected:
            continue
        cost = context_record_bytes + continuation_record_bytes * len(selected)
        if encoded_bytes + cost > byte_budget:
            continue
        retained[context] = selected
        encoded_bytes += cost

    retained_continuations = sum(len(values) for values in retained.values())
    return retained, {
        "byte_budget": byte_budget,
        "encoded_bytes": encoded_bytes,
        "max_continuations_per_context": max_continuations,
        "observed_context_count": len(groups),
        "observed_continuation_count": observed_continuations,
        "retained_context_count": len(retained),
        "retained_continuation_count": retained_continuations,
        "dropped_context_count": len(groups) - len(retained),
        "dropped_continuation_count": observed_continuations - retained_continuations,
    }
