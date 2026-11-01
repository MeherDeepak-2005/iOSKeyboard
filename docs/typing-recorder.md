# Typing recorder (schema 2)

Opt-in, on-device research log written by `keyboard/Shared/KBTypingRecorder.swift` from the
keyboard extension (`demo_keyboard/Controller/KeyboardViewController+Recording.swift`). Turn it on
in the app: Keyboard health → Typing research. Export there produces `export.jsonl` (one JSON event
per line). Nothing is uploaded; secure, email, phone, URL, number, one-time-code and username fields
are never recorded (`permitsTypingData`).

## Common fields

| field | meaning |
|---|---|
| `schema` | 2 |
| `time`, `uptime` | wall clock (ISO 8601) and `systemUptime` seconds; order events by `uptime` within a `process` |
| `session` | text-field session (`fieldRevision`); a new field or document reset starts a new one |
| `word` | word session ID: every event for one word shares it; it advances on each commit |
| `relatedWord` | for `undo`/`glide-selection`, the word session the edit refers back to |
| `layout` | layout revision (rotation, keyboard resize) — taps are only comparable within one |
| `model`, `requestedModel`, `language`, `build` | decoder tier that produced the evidence, language mode, build number |

## Events

| kind | written when | key fields |
|---|---|---|
| `touch-down` / `touch-up` / `touch-cancel` | every finger on a key | `text` (key label), `dx`/`dy` (key widths from the key centre), `touchID`, `uptime` = touch timestamp |
| `key` | a key's output reached the field | `text`, `dx`/`dy`, `intervalMs` (gap to the previous key or Backspace) |
| `backspace` | a plain Backspace | `text` = the character removed; `evidence` `in-word` when it removed a letter of the word being typed |
| `key-fix` | a letter erased inside its word was retyped as a different letter | `text` = erased letter, `replacement` = retyped letter, `dx`/`dy` of the retyped tap |
| `suggestions` | the strip was shown | `text` = typed word, `replacement` = autocorrect candidate, `candidates`, `candidateEvidence` (channel/LM scores) |
| `autocorrection` | the engine replaced a word | `text` typed, `replacement` committed |
| `commit` | a word was finalized | `text` committed, `typed` literal, `keystrokes` [{key, dx, dy, intervalMs}], `durationMs` first letter → commit, `backspaces`, `evidence` |
| `suggestion-pick`, `prediction-pick`, `glide-selection` | the user chose a strip entry | `text` replaced, `replacement` chosen |
| `undo` | Backspace or the strip undid a correction | `text` correction, `replacement` restored word, `relatedWord` |
| `manual-replacement` | the user erased a word and typed a different one | `text` erased, `replacement` typed |
| `glide-began`, `session-end` | gesture start, field closed | — |

## Labels for training

Commits are observations, not labels: an autocorrection (`automatic-unverified`) or a literal word
(`literal-unverified`) may be wrong. Use these as supervision:

- **Per-key error model** (did the user mean another key?): `key-fix` pairs (typed → retyped,
  with the retyped tap's offset); `backspace` with `in-word` followed by `key` events; keystroke
  offsets of commits that were never edited afterwards (no later `undo`/`manual-replacement` with
  the same `relatedWord` or the same text).
- **Word corrections**: `undo` (the restored word is the label, the correction was wrong),
  `manual-replacement` (`replacement` is the label for `text`), `suggestion-pick` and
  `glide-selection` (explicit choices), and autocorrections followed by more typing with no undo.
- **Typing speed**: `intervalMs` on keys (gaps over 5 s are pauses), `durationMs` and `keystrokes`
  per commit (characters per minute = 60000 × len / durationMs).

The aggregate counterparts on the Keyboard health screen (no text) are `keyTaps`, `keyErasures`,
`keyConfusions`, `backspaceTaps` and `interKeyIntervalBins` in `KBDiagnostics.Snapshot`.

Limits: 5 MiB per file, two generations; files older than 7 days are pruned; events over 64
characters are truncated; at most 512 events wait in memory.
