# Dev Branch Report — Autocorrect Ranking Fixes + Full-System Evaluation

Date: 2026-07-20 · Branch: `dev` (worktree `keyboard-dev`, base = snapshot 69285b0 of the uncommitted production pass)

## Why this branch exists

A ChatGPT/Codex session works concurrently in the main checkout (write access to the
working tree, read-only `.git`). Per instruction, this head was diverted onto `dev`;
a git worktree isolates the two working trees while sharing history.

## Live end-to-end typo battery (new methodology)

`keyboardUITests.testTypoCorrectionBattery` types 40 words (22 clean, 18 spatially
plausible QWERTY slips — adjacent-key subs, transpositions, cognitive misspellings,
and one 6-edit mash "coeevitjkn"→correction) key-by-key on the REAL extension against
the app's `-keyboard-runtime-host` field, reads the suggestion strip before each
space, and verifies the committed word after.

| Build | Typos corrected | Intended in top-3 | False corrections |
|---|---|---|---|
| Baseline (production pass) | 14/18 (77.8%) | 18/18 | 0/22 |
| Fixes 1–2 (run 2) | 16/18 (88.9%) | 17/18 | 0/22 |
| All three fixes (final) | **17/18 (94.4%)** | 17/18 | 0/22 |

The one remaining miss is deliberate: "coeevitjkn" after "…receive" keeps the typed
string because the candidate pool (physician/communion, fed by over-confident
1-count "receive …" bigrams) is a 0.22-nat coin flip — the runner-up gate refuses
to commit it, and the strip stays honest (no shading). The sparse-bigram scorer
floor (follow-up below) restores that commit by draining the junk pool's fuel.

All four baseline misses were RANKING failures — the intended word was in the strip
every time (generation recall 18/18):

| typed | committed (baseline) | mechanism |
|---|---|---|
| sebd | see | "you see" bigram beat 1-sub-adjacent "send" via context injection |
| coudl | for | "running for" bigram beat transposition "could" (spatial cost ~4 vs 0.8) |
| recieve | decided | "definitely decided" bigram beat transposition "receive" |
| coeevitjkn | (uncorrected) | Witten-Bell OOV divergence stalled the rescue margin below the 3.0 gate |

## Engine fixes (this branch)

1. **Channel-dominance guard** (`Keyboardengine.swift`, `looseCandidateWindow = 1.6`).
   Context-injected and broad-recovery candidates now enter the pool (display AND
   decision) only within `closestCost + 1.6` whenever the normal-budget search found
   any candidate. The loose pools exist for when the normal search fails; they no
   longer leapfrog it. Rescue path (no close candidate) stays unrestricted.

2. **Witten-Bell OOV-row alignment** (`NgramScorer.score`). Swift skipped bi/tri
   interpolation for rows without a word id, leaving the typed-OOV row on a
   context-free floor while every unseen candidate paid the (1−w) discount — rescue
   margins shrank exactly when context was known. `eval_harness.py logprob()` always
   interpolated OOV rows; the margins were calibrated there. Swift now matches the
   harness (`count = id.flatMap { stats.counts[$0] } ?? 0`).

3. **Runner-up dominance gate** (`looseRunnerUpMargin = 1.0`, near-forms exempt).
   A loose-pool winner only auto-commits when it beats the best UNRELATED contender
   (unit edit distance > 2) by ≥ 1 nat. At spatial cost ~7 the channel cannot
   discriminate, and without LM separation the rescue was a frequency coin flip
   (run 2 committed "physician" for "coeevitjkn" after fix 2 enabled the fire).
   Calibrated from evidence dumps: the legit rescue coeevitjkn→correction leads
   coercion by 1.26 nats in every context; the junk pool physician/communion/
   corrections is separated by 0.22. Below the gate the pool still fills the strip
   for a one-tap fix.

   The dump also exposed a scorer weakness worth a follow-up: Witten-Bell gives
   count-1 successors in tiny context tables ~2% probability ("receive physician"
   lm −3.61 vs unigram −13) — `interpolate()` needs a total/count floor, mirrored
   in `eval_harness.py`.

Pinned by `keyboardTests.looseCandidatesCannotBeatCloseChannelMatches` (all four live
scenarios + severe golden with context). Full suite: 66/66 pass.

## Offline harness baselines (v5 data, n=250 synthetic)

| Severity | top-1 | top-3 | oracle |
|---|---|---|---|
| 1-edit | 81.6% | 98.4% | 100% |
| 2-edit | 73.6% | 84.8% | 85.2% |
| 3-edit | 50.8% | 55.2% | 56.0% |

top-3 ≈ oracle at 2+ edits: candidate generation, not ranking, is the ceiling —
consistent with the production report's NSS-lite recommendation.

## Quality ratings (Evaluate → Breakdown verdicts)

| Subsystem | Rating | Notes |
|---|---|---|
| Candidate generation ≤1 edit | 9/10 | oracle 100% |
| Candidate generation 2+ edits | 5/10 | hard prune ceiling; NSS-lite is the fix |
| Ranking/decision (post-fix) | 8/10 | guards in place; neural-tier margins still uncalibrated |
| Primary suggestion slot | 9/10 | consistently correct post-fix |
| Flank suggestion slots | 5/10 | split fragments ("se bd"), FrequencyWords junk ("tiu"), lowercase proper nouns ("tehran") |
| False-correction behavior | 10/10 | 0/44 clean words across live runs |
| Binary data discipline | 9/10 | v5/KBTD/KBXL all mmap, bounds-checked, hash-manifested; builders unit-tested (27/27) |
| Emoji memory management | 4/10 | EmojiAtlas disabled (App Review 5.2.5 concern) — CoreText glyph-cache bloat (+~29 MB measured previously) is back |
| Telugu native composition | 7/10 | grapheme-safe, NFC, append-only host edits; needs native review |
| Tenglish transliteration | 6/10 | clean reader + honest gating; 12k-key bootstrap only, no FST/LM |

## Known items deliberately not fixed here

- **EmojiAtlas trade-off**: production pass removed it for App Review 5.2.5 risk;
  memory cost returns. Decision needs the owner: ship text-rendering + memory risk, or
  resolve the artwork question with App Review. The code survives behind
  `EMOJI_ATLAS_EXPERIMENT`.
- **Vocab hygiene**: "tiu" and lowercase proper nouns pollute flank slots — fix in
  `tools/build_language_data.py` (junk exclusion; capitalization is a case-policy
  question), requires langdata rebuild.
- **Emoji selection bug** (commit c9ff326 note): `testEmojiSelectionProbe` added to
  hunt it empirically; grid/insertion path code-reads clean.
- Debug/neural-tier decision margins were calibrated on the n-gram; the blend needs
  its own calibration pass (production report already tracks this).
