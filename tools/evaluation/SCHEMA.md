# Decoder evaluation schema

Store one JSON object per line. A row is the same typing event evaluated by the
shipping decoder and a named baseline, so every quality comparison is paired.
Do not put raw private messages, email addresses, contact names, or persistent
device identifiers in this dataset. Use consented test prompts or synthetic cases
and replace `user_id` with a study-local opaque identifier.

```json
{
  "case_id": "study-001-event-0042",
  "user_id": "study-001",
  "split": "test",
  "category": "severe_typo",
  "typed": "coeevitjkn",
  "intended": "correction",
  "context": ["that", "needs"],
  "engine": {
    "suggestions": ["correction", "connection", "collection"],
    "candidates": ["correction", "connection", "collection", "condition"],
    "correction": "correction",
    "confidence": 0.93,
    "keystrokes_saved": 2,
    "latency_ms": 8.4
  },
  "baseline": {
    "suggestions": ["connection", "collection", "correction"],
    "candidates": ["connection", "collection", "correction"],
    "correction": null,
    "latency_ms": 14.2
  }
}
```

Required event fields are `case_id`, `user_id`, `split`, `typed`, `intended`,
`engine`, and `baseline`. `category` and `context` are optional. Each result must
contain `suggestions`; `candidates`, `correction`, and `latency_ms` are optional.
An absent or null correction means the typed token was preserved.

For release reports, always include the candidate list before any forced-gold
debugging injection, a calibrated `confidence` in `[0, 1]`, and non-negative
`keystrokes_saved`. Missing candidate, confidence, or savings fields are reported as
`n/a`, never silently treated as success.

Use user-level splits. Every `user_id` may occur in only one split across the
input file. Tune weights on `train` or `validation`; publish only one untouched
`test` result. Keep categories stable enough to report at least:

- `clean`: typed text already equals intended text.
- `near_typo`: ordinary one- or two-edit mistakes.
- `severe_typo`: intended word would miss a narrow edit-distance search.
- `real_word`: both typed and intended are dictionary words.
- `contraction`, `slang`, `name`, and `glide` where applicable.

Generate a paired report with:

```bash
python3 tools/evaluation/replay_report.py study.jsonl --split test
```

The script rejects duplicate case IDs, malformed results, and cross-split users.
It reports confidence intervals by resampling users rather than individual events.
That prevents prolific typists from making a small study look more certain than it
is. False-correction rate is conditioned on already-correct input; missed-correction
rate is conditioned on actual typo input, so neither denominator is diluted by
ineligible cases. The report intentionally does not claim production readiness;
physical-device memory, energy, and jetsam tests remain separate release gates.
