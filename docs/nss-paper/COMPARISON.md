# Published NSS reproduction: before/after comparison

Branch: `codex/nss-paper-replica`. Baseline checkpoint: `5f2df22065d4ac3aba3b6d76ff61c1ebc9e5fddc`. Decoder implementation: `d77aa92d8937b871ffb36515a11647853d8e22ff`.

The new decoder implements the published dynamic NSS graph and joint search, but it is **not a complete Gboard replica**. Google’s weights, training data, complete spatial channel, and some decoding settings are not published. [CONFORMANCE.md](CONFORMANCE.md) maps each published constraint to the implementation and identifies every local substitution.

## Result

The implementation is closer to the paper, but quality is mixed and it fails an existing safety guardrail. Synthetic correction improves; real-misspelling correction and several external-set scores regress. Correct ECPS words are changed more often (0.378% → 0.704%, paired McNemar p = 7.84e-7). It should remain an internal experiment, not replace the default decoder. `INTERNAL_NSS_ENABLED` remains `NO`.

**Update, 1 November 2026.** The sequential latency replay is now [below](#latency-and-memory): `d77aa92` takes 8.3 ms per typed word (4.9× the old decoder) and 50 ms per next-word prediction. Commit `428e985` cuts these to 7.0 ms and 1.5 ms. The chat-register retrain finished; it models dialogue far better but does not improve the typing benchmark. See [the follow-up](#follow-up-exact-scoring-and-retrained-models-1-november-2026).

## Method

- Replayed **96,143 paired cases**: 59,062 main, 33,503 external, and 3,578 name/slang/rare-word cases. Both complete runs have identical case IDs.
- The tables use the existing target-word-disjoint held split, with the existing hard-word/contraction fixtures included in full. This split has been used before; it is not a new blind or user-disjoint evaluation.
- Both native decoders use `clang++ -std=c++20 -Os -DNDEBUG`, identical lexicon, safety data, contexts, corpus ordering, and default commitment settings. No touch offsets or personalization are supplied.
- The baseline model is the frozen step-8000 CIFG. The new four-gate untied model is a function-preserving expansion, not retraining: 220 reference scores match within the existing tolerance. Thus this compares decoder changes and equivalent model parameterizations, not newly learned probabilities.
- Quality tests ran concurrently with host/build work. Their timing values in `comparison.json` are retained as raw observations and must not be interpreted as a controlled speed comparison. A separate sequential ABBA latency replay is reported below.
- Paired significance tests are descriptive, without multiple-comparison adjustment. Small sets, especially slang (n=8) and first-letter ECPS subsets, are weak evidence.

## Held-split quality

All values are percentages. ↑ means higher is better; ↓ means lower is better. “Guard failure” uses the existing paired p<0.05 regression rule, not a claim that other regressions are acceptable.

| Metric | n | Old | New | Change (pp) | Direction | Guard failure |
| --- | ---: | ---: | ---: | ---: | :---: | :---: |
| ECPS real misspellings fixed | 9,622 | 88.58 | 86.70 | -1.88 | ↑ | — |
| ECPS target in top 3 | 9,622 | 94.85 | 94.33 | -0.52 | ↑ | — |
| ECPS left uncorrected | 9,622 | 4.34 | 4.90 | +0.55 | ↓ | — |
| ECPS missing first letter fixed | 30 | 66.67 | 80.00 | +13.33 | ↑ | — |
| ECPS other first letter fixed | 29 | 37.93 | 48.28 | +10.34 | ↑ | — |
| ECPS first two swapped fixed | 33 | 96.97 | 100.00 | +3.03 | ↑ | — |
| Synthetic typos fixed | 5,606 | 89.98 | 91.40 | +1.43 | ↑ | — |
| Synthetic target in top 3 | 5,606 | 94.45 | 96.08 | +1.62 | ↑ | — |
| Synthetic left uncorrected | 5,606 | 2.35 | 1.80 | -0.55 | ↓ | — |
| Synthetic first letter wrong fixed | 977 | 77.58 | 87.82 | +10.24 | ↑ | — |
| syn omission fixed | 827 | 83.31 | 83.31 | +0.00 | ↑ | — |
| syn insertion fixed | 1,083 | 93.26 | 94.18 | +0.92 | ↑ | — |
| syn sub_adjacent fixed | 1,078 | 89.89 | 91.47 | +1.58 | ↑ | — |
| syn double fixed | 1,083 | 98.15 | 97.97 | -0.18 | ↑ | — |
| syn transposition fixed | 1,021 | 97.75 | 97.36 | -0.39 | ↑ | — |
| syn two_errors fixed | 514 | 61.28 | 72.76 | +11.48 | ↑ | — |
| syn omission in top 3 | 827 | 92.50 | 91.78 | -0.73 | ↑ | — |
| ext_aspell fixed | 237 | 47.26 | 48.52 | +1.27 | ↑ | — |
| ext_aspell in top 3 | 237 | 75.11 | 70.89 | -4.22 | ↑ | — |
| ext_birkbeck fixed | 15,136 | 31.07 | 29.78 | -1.29 | ↑ | — |
| ext_birkbeck in top 3 | 15,136 | 57.43 | 54.22 | -3.21 | ↑ | — |
| ext_holbrook fixed | 450 | 40.00 | 38.89 | -1.11 | ↑ | — |
| ext_holbrook in top 3 | 450 | 54.22 | 53.33 | -0.89 | ↑ | — |
| ext_wikipedia fixed | 1,100 | 74.18 | 74.73 | +0.55 | ↑ | — |
| ext_wikipedia in top 3 | 1,100 | 91.91 | 89.36 | -2.55 | ↑ | — |
| GUARD false corrections, MacKenzie clean | 1,083 | 0.18 | 0.18 | +0.00 | ↓ | — |
| GUARD false corrections, ECPS correct | 9,522 | 0.38 | 0.70 | +0.33 | ↓ | FAIL |
| GUARD hard valid words changed | 95 | 16.84 | 17.89 | +1.05 | ↓ | — |
| GUARD unknown names changed | 292 | 63.36 | 59.93 | -3.42 | ↓ | — |
| GUARD unknown slang changed | 8 | 87.50 | 100.00 | +12.50 | ↓ | — |
| GUARD rare dictionary words changed | 1,457 | 26.29 | 12.15 | -14.14 | ↓ | — |
| GUARD correct plurals stripped | 1,236 | 0.00 | 0.00 | +0.00 | ↓ | — |
| GUARD real-word errors fixed | 708 | 46.89 | 48.31 | +1.41 | ↑ | — |
| GUARD contractions restored | 80 | 95.00 | 92.50 | -2.50 | ↑ | — |
| GUARD next word in top 3 | 1,083 | 17.27 | 17.27 | +0.00 | ↑ | — |

## Latency and memory

Sequential replay on 1 November 2026 (`tools/nss/latency_paper.py`): desktop Apple M1, `clang++ -std=c++20 -Os -DNDEBUG` (Apple clang 21.0.0, clang-2100.4.1.1), nothing else running; the `after` arms ran on the working tree that was then committed unchanged as `428e985`. Sample: every 50th `ac` row of `cases.tsv` (1,127 typed words, each decoded in a fresh word session) and every 5th `nw` row (543 next-word predictions from an empty prefix, then 1,884 keystrokes; `KB_FULL_PREFIXES=1` replays every prefix whatever the suggestions). Each arm ran twice, in order and then reversed; the two runs of an arm agree within 2%. Milliseconds per request, pooled over both runs; the ratio is the median per-request time against `paper`.

| Arm | Decoder | Model | Typed word p50 / p95 | Next word p50 | Keystroke p50 / p95 | Ratio: typed / next / key | Peak RSS (MiB) |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |
| before | `5f2df22` | baseline-step8000 | 1.68 / 8.10 | 0.66 | 0.29 / 1.33 | 0.21 / 0.01 / 0.14 | 40.6 |
| paper | `d77aa92` | nss-english | 8.27 / 11.68 | 50.10 | 1.41 / 2.60 | 1 / 1 / 1 | 76.3 |
| after-paper | `428e985`, `KB_NSS_PAPER=1` | nss-english | 11.10 / 15.24 | 2.86 | 1.78 / 3.28 | 1.34 / 0.06 / 1.26 | 54.7 |
| after | `428e985` | nss-english | 7.01 / 9.53 | 1.51 | 1.23 / 2.08 | 0.84 / 0.03 / 0.88 | 56.2 |
| after-generic | `428e985` | generic-final | 6.81 / 9.22 | 1.44 | 1.17 / 2.04 | 0.81 / 0.03 / 0.84 | 52.1 |
| after-chat | `428e985` | chat-final | 6.42 / 8.85 | 1.27 | 1.14 / 1.98 | 0.77 / 0.03 / 0.82 | 53.8 |
| ngram | `428e985`, n-gram tier | — | 0.48 / 6.71 | 0.02 | 0.13 / 0.95 | 0.05 / 0.00 / 0.08 | 49.3 |

- `paper` spends 50 ms on every next-word prediction: with an empty prefix, `d77aa92` scores every lexicon word at the root. `428e985`'s `NeuralFst::best` ranks the expansion's own scores (its arcs, or the whole vocabulary distribution under exact scoring) plus the most frequent words reached through `<unk>`, without the lexicon scan.
- `ArcLookahead`, `428e985`'s published-graph lookahead (`after-paper`), gives the same output as `paper` on all 1,670 sampled requests and cuts peak RSS by 22 MiB, but each lookahead becomes a binary search: typed words are 34% and keystrokes 26% slower. The default exact scoring (`after`, the follow-up below) keeps a dense lookahead over the vocabulary's trie nodes and is 16% (typed words) and 12% (keystrokes) faster than `paper`; it changes 17% of the sampled outputs.
- The chat model is the fastest NSS arm because its graph is smaller: after "can you" it keeps 5,146 arcs above e^-15, generic-final 12,287.
- The default `428e985` arms are still about 4× slower than `before` at the median, and 13–15× slower than the n-gram for a typed word (at p95: 8.85 against 6.71 ms).

Inputs, per-run outputs and hashes: [validation/latency-2026-11-01/](validation/latency-2026-11-01/). The first replay ([validation/latency/](validation/latency/), 31 October: older compiler, 501 sampled rows with 82 keystrokes, two arms and no next-word timing) is superseded.

Full-corpus desktop process peak RSS (MiB) from the first comparison's quality runs, in main / external / keep order. Here `before` is `5f2df22` and `after` is `d77aa92`, not the `428e985` arm above:

| Decoder | Main | External | Keep |
| --- | ---: | ---: | ---: |
| before | 49.70 | 51.42 | 60.81 |
| after | 65.16 | 53.47 | 53.45 |

These are desktop process observations, including allocator behavior and mapped model/lexicon pages. They are not physical-iPhone extension memory measurements. The expanded model file grows from 3,922,400 to 7,056,928 bytes. Live heap use at the end of the main run rises from 6.83 to 23.12 MiB.

## Behavioral examples

- `howmny`: old correction `honey`; new correction `how many`.
- `howvmany`: both correct to `how many`.
- `howmanyare`: new search finds `how many are` in suggestions; the retained product commitment policy still does not auto-commit it.
- `iamhere`: neither produces the desired `i am here`; graph conformance does not establish universal multiword recovery.

Exact inputs and outputs: [targeted-examples.tsv](targeted-examples.tsv), [targeted-examples.json](targeted-examples.json). These are diagnostic examples, not additional held-out accuracy evidence.

## Follow-up: exact scoring and retrained models (1 November 2026)

This section measures the changes committed as `428e985` on top of `d77aa92`, with the harness, corpora and held split used above, built with clang-2100.4.1.1 (the tables above used clang-2100.1.1.101). They were measured on the uncommitted working tree, whose diff is identical to the commit's (`provenance.json`). Files: [validation/followup-2026-11-01/](validation/followup-2026-11-01/). The commit:

- scores vocabulary words exactly by default (`EngineOptions::nssExact`, see [tools/nss/README.md](../../tools/nss/README.md)): every vocabulary word gets its own model probability, also below the e^-15 arc threshold, and lexicon words outside the vocabulary share P(`<unk>`) by frequency. `KB_NSS_PAPER=1` restores the published graph;
- replaces the published graph's per-expansion lookahead array with `ArcLookahead`, and next-word prediction's lexicon scan with `NeuralFst::best` (latency above);
- adds raw decoding (`KB_RAW=1`): both tiers run the same joint search without the correction rules, the n-gram as `NgramFst`.

All three models are one-layer LSTMs with a 96-wide embedding, 670 cells projected to 96 and the 30k vocabulary:

| Model | Form | Training | Bytes |
| --- | --- | --- | ---: |
| `keyboard/nss-english.nsslm` (installed) | four-gate, untied: the step-8000 CIFG expanded | 8,000 steps of Tatoeba and WikiText | 7,056,928 |
| `tools/nss/artifacts/generic-final.nsslm` | CIFG, tied | the same run completed: 21,158 steps, 130M tokens | 3,922,400 |
| `tools/nss/artifacts/chat-final.nsslm` | CIFG, tied | 21,158 steps of data-v2 (`configs/cifg-lstm-96x670-chat.json`): SODA dialogues 0.45, Tatoeba without most Tom/Mary sentences 2.0, WikiText 0.3 | 3,922,400 |

The chat run stopped twice before completing; it was resumed from its step-8000 checkpoint, and the resumed losses match the original run's. The runtime reproduces its export's 220 reference scores (max |error| 7.3e-5).

### Decoder change, same model

The installed model on `d77aa92` and on `428e985`. `d77aa92` was replayed again with the current compiler; all 96,143 outputs are identical to the "New" column of the first table. Held split, percentages: every metric with p < 0.05, plus four for reference. Gained/lost counts the cases where the metric's condition became true or stopped being true, so for ↓ metrics "gained" is worse.

| Metric | | n | `d77aa92` | `428e985` | Change (pp) | Gained/lost | p | Guard failure |
| --- | :---: | ---: | ---: | ---: | ---: | ---: | ---: | :---: |
| ECPS real misspellings fixed | ↑ | 9,622 | 86.70 | 86.89 | +0.20 | 112/93 | 0.21 | — |
| ECPS target in top 3 | ↑ | 9,622 | 94.33 | 94.00 | -0.32 | 48/79 | 8e-3 | — |
| ECPS left uncorrected | ↓ | 9,622 | 4.90 | 4.34 | -0.55 | 50/103 | 2e-5 | — |
| Synthetic typos fixed | ↑ | 5,606 | 91.40 | 91.76 | +0.36 | 37/17 | 9e-3 | — |
| Synthetic left uncorrected | ↓ | 5,606 | 1.80 | 1.52 | -0.29 | 7/23 | 5e-3 | — |
| ext_birkbeck fixed | ↑ | 15,136 | 29.78 | 29.78 | -0.01 | 171/172 | 1 | — |
| ext_birkbeck in top 3 | ↑ | 15,136 | 54.22 | 52.42 | -1.80 | 177/450 | 2e-28 | — |
| ext_holbrook fixed | ↑ | 450 | 38.89 | 36.44 | -2.44 | 6/17 | 0.035 | — |
| ext_wikipedia fixed | ↑ | 1,100 | 74.73 | 79.00 | +4.27 | 62/15 | 6e-8 | — |
| GUARD false corrections, ECPS correct | ↓ | 9,522 | 0.70 | 0.55 | -0.16 | 6/21 | 6e-3 | — |
| GUARD unknown names changed | ↓ | 292 | 59.93 | 59.25 | -0.68 | 3/5 | 0.73 | — |
| GUARD rare dictionary words changed | ↓ | 1,457 | 12.15 | 14.48 | +2.33 | 40/6 | 3e-7 | FAIL |
| GUARD next word in top 3 | ↑ | 1,083 | 17.27 | 17.27 | +0.00 | 0/0 | 1 | — |
| Keystroke savings | ↑ | 1,083 | 48.29 | 47.97 | -0.32 | | | |

Exact scoring repairs most of the first table's false-correction regression (0.70% → 0.55%; `5f2df22` had 0.38%), leaves fewer misspellings uncorrected and fixes more Wikipedia misspellings. It also changes more rare dictionary words, a guardrail failure, and ranks Birkbeck targets lower.

### Models on the `428e985` decoder

Held split, percentages. The last column is chat-final against generic-final, with the paired McNemar p.

| Metric | | n | n-gram | Installed | Generic | Chat | Chat − generic (p) |
| --- | :---: | ---: | ---: | ---: | ---: | ---: | ---: |
| ECPS real misspellings fixed | ↑ | 9,622 | 89.33 | 86.89 | 86.45 | 85.61 | -0.84 (5e-4) |
| ECPS target in top 3 | ↑ | 9,622 | 94.75 | 94.00 | 93.92 | 93.50 | -0.42 (0.024) |
| Synthetic typos fixed | ↑ | 5,606 | 88.67 | 91.76 | 91.44 | 90.97 | -0.46 (0.084) |
| Synthetic target in top 3 | ↑ | 5,606 | 93.52 | 96.27 | 96.31 | 95.83 | -0.48 (0.018) |
| Synthetic first letter wrong fixed | ↑ | 977 | 75.13 | 88.43 | 87.82 | 87.92 | +0.10 (1) |
| syn two_errors fixed | ↑ | 514 | 60.70 | 73.15 | 71.40 | 71.01 | -0.39 (0.87) |
| ext_aspell fixed | ↑ | 237 | 54.43 | 46.84 | 47.26 | 43.04 | -4.22 (0.021) |
| ext_birkbeck fixed | ↑ | 15,136 | 40.20 | 29.78 | 29.28 | 27.27 | -2.02 (6e-33) |
| ext_holbrook fixed | ↑ | 450 | 45.33 | 36.44 | 34.89 | 34.89 | +0.00 (1) |
| ext_wikipedia fixed | ↑ | 1,100 | 79.18 | 79.00 | 77.64 | 72.64 | -5.00 (5e-11) |
| GUARD false corrections, ECPS correct | ↓ | 9,522 | 0.45 | 0.55 | 0.59 | 0.74 | +0.15 (0.038) FAIL |
| GUARD unknown names changed | ↓ | 292 | 75.00 | 59.25 | 56.16 | 56.51 | +0.34 (1) |
| GUARD rare dictionary words changed | ↓ | 1,457 | 39.12 | 14.48 | 13.93 | 11.39 | -2.54 (1e-11) |
| GUARD real-word errors fixed | ↑ | 708 | 44.21 | 48.16 | 48.73 | 50.28 | +1.55 (0.27) |
| GUARD next word in top 3 | ↑ | 1,083 | 17.54 | 17.27 | 20.31 | 19.30 | -1.02 (0.32) |
| Keystroke savings | ↑ | 1,083 | 45.23 | 47.97 | 48.93 | 47.97 | -0.96 |

- Against the n-gram, all three NSS models fix more synthetic typos (+2.3 to +3.1 pp), first-letter errors (+12.7 to +13.3 pp), two-error typos and real-word errors, and change far fewer rare valid words (11–14% against 39%) and unknown names (56–59% against 75%), each p < 0.02. They fix fewer real misspellings (−2.4 to −3.7 pp) and fewer Birkbeck, Holbrook and Aspell misspellings (p < 0.02). Only generic-final predicts the next word better than the n-gram (p = 0.011).
- Neither generic model dominates the other. The installed step-8000 model fixes slightly more misspellings (ECPS +0.44 pp, p = 0.012; Birkbeck +0.50 pp; Wikipedia +1.36 pp); generic-final predicts the next word better (+3.04 pp, p = 7e-5) and changes fewer unknown names and rare words.
- The chat model is worse than generic-final on real misspellings, the external lists and correct words changed (a guardrail regression), and better only on rare valid words changed.
- ECPS contexts are informal single sentences ("lol", "made my day."), the closest the benchmark comes to messaging, and the chat model is worse there too. The MacKenzie phrases are short written sentences. The external lists, the hard words and most keep sets have no context, so the model's sentence-start distribution decides them, which is where the chat model loses most (Wikipedia −5.00 pp). The benchmark has no dialogue turns and no conversational next-word rows.

The same joint search without the correction rules (raw mode, `KB_RAW=1 KB_NSS_FLOOR=1`; p against the raw n-gram):

| Metric | | n | n-gram | Generic (p) | Chat (p) |
| --- | :---: | ---: | ---: | ---: | ---: |
| ECPS real misspellings fixed | ↑ | 9,622 | 75.24 | 79.84 (2e-35) | 78.85 (2e-22) |
| Synthetic typos fixed | ↑ | 5,606 | 87.01 | 91.17 (6e-26) | 90.35 (9e-17) |
| ext_birkbeck fixed | ↑ | 15,136 | 23.49 | 20.57 (7e-65) | 18.89 (2e-134) |
| ext_wikipedia fixed | ↑ | 1,100 | 59.27 | 59.91 (0.55) | 52.00 (9e-15) |
| GUARD false corrections, ECPS correct | ↓ | 9,522 | 1.23 | 0.82 (6e-5) | 0.95 (6e-3) |
| GUARD unknown names changed | ↓ | 292 | 47.95 | 53.08 (0.02) | 53.08 (0.028) |
| GUARD rare dictionary words changed | ↓ | 1,457 | 13.18 | 12.83 (0.6) | 10.64 (2e-6) |
| GUARD next word in top 3 | ↑ | 1,083 | 17.17 | 20.31 (4e-3) | 19.30 (0.04) |

Under the same search the NSS language models fix 3.6–4.6 pp more real misspellings than the n-gram and still trail it on Birkbeck by 2.9–4.6 pp, against 10.4–12.9 pp in production: most of the production gap on severe misspellings comes from the n-gram tier's candidate generation, which the composed search does not have ([CONFORMANCE.md](CONFORMANCE.md)).

### The language models on shared held-out sets

As exported (int8), `tools/nss/compare_models.py`: word perplexity under the decoder's distribution, and next-word top 3 on in-vocabulary targets.

| Held-out set | Generic perplexity | Chat perplexity | Generic top 3 | Chat top 3 |
| --- | ---: | ---: | ---: | ---: |
| SODA dialogues (data-v2 test) | 80.07 | **23.34** | 35.38% | **51.99%** |
| Tatoeba (data-v2 test) | **80.57** | 103.52 | **38.06%** | 35.59% |
| Tatoeba (data test) | **62.56** | 84.73 | **40.70%** | 37.55% |
| WikiText-103 test | **166.97** | 248.70 | **33.65%** | 30.87% |
| MASC held-out | **318.99** | 380.15 | **26.42%** | 25.47% |

On MASC's 63,863 lexicon-word targets the production n-gram's perplexity is 750.0, generic-final's 451.3 and chat-final's 537.4 (spoken register: 324.0, 199.4, 212.5). On SODA the generic model predicts `<unk>` 4.03% of the time and the chat model 1.34%; the observed rate is 0.79%.

### Conclusion

- **Latency:** next-word prediction is 33× faster than on `d77aa92` (50.1 → 1.5 ms). Typed words are 16% and keystrokes 12% faster at the median, with 20 MiB less peak RSS. The typed-word and keystroke gain comes from exact scoring's dense lookahead: `ArcLookahead` alone is 26–34% slower than `d77aa92`. The NSS is still about 4× slower than `5f2df22` and 13–15× slower than the n-gram per typed word.
- **Exact scoring:** fixes most of the false-correction regression and adds a rare-word guardrail failure.
- **Chat retrain:** a much better dialogue model (SODA perplexity 80 → 23) and a worse written-English one. On this benchmark it is no better than generic-final, ECPS's informal contexts included, though it is the fastest NSS model. A dialogue-register typing set would test it where it should help.
- `INTERNAL_NSS_ENABLED` remains `NO`.

## Validation

- Native Release: **10/10 passed**, including original n-gram goldens, graph semantics, threshold/fallback behavior, dynamic expansion and trained-model reference checks.
- AddressSanitizer + UndefinedBehaviorSanitizer: **10/10 passed**.
- Internal NSS iOS Simulator Release build: **passed**, arm64 and x86_64.
- Swift/iOS integration: **1 actual Swift Testing test passed**, `KeyboardTests/wordNeuralSearchSpaceTierDecodesInTheSharedEngine()`. It checks the native bridge using a tiny model fixture, not trained-model accuracy. Earlier filters selected zero tests; those runs are not counted.
- No physical-device performance, complete application workflow, Android delivery, or Gboard quality parity claim.
- `428e985` (measured as the working tree), 1 November 2026: `native/tests/run.sh` (AddressSanitizer + UndefinedBehaviorSanitizer) **passed**, including `RawDecoderTests` (the n-gram graph matches `LanguageModel` on 786,177 scores; exact NSS scores, lookahead bounds and `best()` match the model). Log: [validation/followup-2026-11-01/native-sanitizers.log](validation/followup-2026-11-01/native-sanitizers.log).
- `chat-final.nsslm`: `NeuralLanguageModelTests` matches its 220 reference scores. `NeuralFstTests` passes its per-word edge and lookahead checks, then stops at its assumption that "you" keeps an arc after "can you": the chat model gives it e^-15.02, just below the threshold. The test needs another word before the chat model could replace `keyboard/nss-english.nsslm`.

## Reproduce and inspect

```sh
python3 tools/nss/compare_paper.py --out /tmp/nss-paired
python3 tools/nss/latency_paper.py --out /tmp/nss-latency
```

The first command builds the checkpoint and current source and replays all three local corpora; the corpora must already exist. The second builds `5f2df22` and `d77aa92` with `d77aa92`'s harness plus fixed-prefix replay, and the current tree with its own, then replays every arm twice. Run it without competing benchmark/build processes. User-owned background work was left running for the quality measurements.

The follow-up's quality runs use a benchmark built from the current tree (`428e985`), `d77aa92`'s decoder from `latency_paper.py`, and the same three corpora:

```sh
cd tools/evaluation/autocorrect
python3 evaluate.py build --bin nss-cur
KB_NSS=$PWD/../../../keyboard/nss-english.nsslm python3 evaluate.py run cur-nss-english --bin nss-cur
KB_NSS=$PWD/../../../keyboard/nss-english.nsslm python3 evaluate.py run head-nss-english --bin nss-latency-paper
KB_NSS=$PWD/../../nss/artifacts/generic-final.nsslm python3 evaluate.py run cur-nss-generic --bin nss-cur
KB_NSS=$PWD/../../nss/artifacts/chat-final.nsslm python3 evaluate.py run cur-nss-chat --bin nss-cur
python3 evaluate.py run cur-ngram --bin nss-cur
KB_RAW=1 KB_NSS_FLOOR=1 KB_NSS=$PWD/../../nss/artifacts/generic-final.nsslm python3 evaluate.py run cur-raw-generic --bin nss-cur
KB_RAW=1 KB_NSS_FLOOR=1 KB_NSS=$PWD/../../nss/artifacts/chat-final.nsslm python3 evaluate.py run cur-raw-chat --bin nss-cur
KB_RAW=1 python3 evaluate.py run cur-raw-ngram --bin nss-cur
python3 score_runs.py head-nss-english cur-nss-english
python3 score_runs.py cur-ngram cur-nss-english cur-nss-generic cur-nss-chat
python3 score_runs.py cur-raw-ngram cur-raw-generic cur-raw-chat
cd ../../nss
python compare_models.py /tmp/models.json generic=runs/cifg-lstm-96x670/best.pt chat=runs/cifg-lstm-96x670-chat/best.pt
```

`score_runs.py` applies `evaluate.py`'s metrics, held split and McNemar test side by side (`evaluate.py score` also prints CoreV4's stored results, which this machine lacks). `compare_models.py` needs the `ml` environment and both `data/` and `data-v2/`.

- [comparison.json](comparison.json): complete score table, paired gains/losses/p-values, corpus/model hashes, raw quality-run timing and memory.
- [results/manifest.json](results/manifest.json): hashes of all six complete raw JSONL files, stored alongside as gzip archives.
- [validation/provenance.json](validation/provenance.json): implementation/source identity.
- [validation/](validation/): native, sanitizer, simulator, build logs and latency replay inputs/outputs.
- [validation/latency-2026-11-01/](validation/latency-2026-11-01/): the sequential latency replay: sample, per-run outputs (gzip), `latency.json` with quantiles, model hashes and compiler.
- [validation/followup-2026-11-01/](validation/followup-2026-11-01/): the follow-up's paired score tables (`score-*.json`; `score_runs.py` prints the same tables as text), `models.json` (held-out language-model results), the working tree's sanitizer log and `provenance.json` (source, model and result hashes).

The existing untracked `tools/nss/data-v2/` corpus and active training run were left untouched. The original work was checkpointed before implementation; the additional shared trie helper repair fixed an existing Release compilation failure in commit `521144b`.
