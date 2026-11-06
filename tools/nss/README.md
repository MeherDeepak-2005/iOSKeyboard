# Published NSS graph implementation

The active `nss` tier now uses `NeuralFst` and `NeuralFstSearch`, following the
published UpdateLM/ExtendLM algorithms and thresholds. See
[`docs/nss-paper/CONFORMANCE.md`](../../docs/nss-paper/CONFORMANCE.md) for the hard
constraints, explicit local choices, unavailable Gboard components, and comparison.
The previous `NeuralSearchSpace` scorer remains as an export/reference test utility;
it no longer drives decoding. The historical description below describes the
checkpoint implementation, **not the active graph decoder**.

The internal model at `keyboard/nss-english.nsslm` is a four-gate, untied LSTM with
6,372,332 parameters, initialized by a function-preserving expansion of the frozen
CIFG step-8000 model. This is not additional training and is not Google's model.
The original export and reference scores are preserved in `artifacts/`.
`configs/paper-lstm-96x670.json` is the corresponding configuration for future training.
Both models retain the same 30k vocabulary and locally trained language behavior.

To reconstruct the expanded export:

```sh
python3 tools/nss/expand_reference_model.py \
  tools/nss/artifacts/baseline-step8000.nsslm keyboard/nss-english.nsslm
```

## Raw decoding: the language models without rules

`EngineOptions::raw` (`KB_RAW=1` in the autocorrect harness) measures what the language
models do on their own. Both tiers run the same joint search (`NeuralFstSearch`) and
differ only in the language graph:

- `nss`: `NeuralFst`, the paper's neural search space.
- `ngram`: `NgramFst`, the production Witten–Bell n-gram as a backoff graph (the
  paper's control arm). It reproduces `LanguageModel` scores to float precision
  (`native/tests/RawDecoderTests.cpp`). Its word states expand under the same rule as
  ExtendLM, so the search is identical.

`NeuralFst` scores words exactly (`EngineOptions::nssExact`, on by default, both modes):
every vocabulary word gets its own model probability, also below the e^-15 arc
threshold, which then only decides which words open a state of their own; a lexicon
word outside the vocabulary gets P(`<unk>`|ctx) × share × u(w) / U, where u = pack
frequency + 1, U sums u over the lexicon words outside the vocabulary, and share is
the model's `unknownLexiconShare`. The published graph (Fig. 3) gives below-threshold
vocabulary words and every other word P(`<unk>`|ctx) times their share of the whole
lexicon instead; `nssExact = false` (`KB_NSS_PAPER=1`) restores it.

Switched off in raw mode: the channel's spelling rules (doubled letters, vowel and
c/k/s/z confusions, cheap apostrophe skips; first-letter penalties were never in the
joint search), the correction gate and its margins, the i-forms rule, minimum
correction length, the split margin, candidate funding, context injection, broad
recovery, the completion cap, residual safety demotions and personal history. Kept:
key geometry with uniform insertion (1.6), deletion (1.1) and transposition (0.65)
costs, the missing-space and c/v/b/n/m-for-space channel, blocked-word exclusion, the
user's keep list (a correction the user undid is not made again), and the channel weight (4). The best complete word is committed when its score beats the
typed text's: a lexicon word by its graph score, any other string by the n-gram's
context-free unknown-word mass for both tiers. The production paths are unchanged.

```sh
cd tools/evaluation/autocorrect
KB_RAW=1 python3 evaluate.py run raw-ngram
KB_RAW=1 KB_NSS=../../nss/artifacts/generic-final.nsslm python3 evaluate.py run raw-nss
KB_RAW=1 KB_NSS_PAPER=1 KB_NSS=../../nss/artifacts/generic-final.nsslm python3 evaluate.py run raw-nss-paper
python3 evaluate.py score raw-nss --vs raw-ngram
python3 context_report.py raw-ngram raw-nss
```

## The NSS tier's product rules

Outside raw mode, the `nss` tier applies product rules on top of the joint search
(`EngineSession::decodeNeural`): the n-gram tier's recovered candidates and blocked-typo
rule, kept opening quotes, the "id" rule, names protected by P(`<unk>`) in context and by
capitalization, candidates rescored with a quarter of the n-gram and a frequency prior, and
taps scored against the key they landed on (`touchSubstitutionCost`).
Each is a tunable in `native/DecoderCore/include/Engine.hpp`; a `--tuning` benchmark build
reads `KB_<tunable>` overrides. Results and rejected alternatives:
[COMPARISON.md](../../docs/nss-paper/COMPARISON.md#nss-tier-with-product-rules-1-november-2026).

## Historical checkpoint implementation

# Neural search space (NSS) word language model

The NSS decoder (Gboard, Zhang et al., "Neural Search Space in Gboard Decoder", 2024)
replaces the n-gram language model inside the search with a neural LM over a fixed
word vocabulary. This directory trains that model and exports it for the shared C++
engine (`native/DecoderCore/include/NeuralLanguageModel.hpp`), which runs it on iOS and
Android without Core ML.

| | Gboard NSS | This model |
|---|---|---|
| Model | one-layer LSTM/CIFG | one-layer CIFG-LSTM, 670 cells, projection to 96 |
| Vocabulary | top 30k words (federated counting) of a 170k lexicon | top 30k of the 114k lexicon (`tools/data/nss`, `build_nss_vocab.py`) |
| Embedding | 96 | 96, tied input/output (3.36M parameters; untied: 6.2M) |
| Out-of-vocabulary | epsilon arc with P(`<unk>`) into the unigram lexicon | P(`<unk>`\|ctx) x share x u(w) / oovMass (below) |
| Search space | arcs above e^-15 after each committed word (1k-5k words) | `nssArcThreshold` -15, best 1,024: next words, context injection (top 24), broad-recovery funding above e^-12 |
| Multi-word | ExtendLM, threshold e^-12, top 1 | `NeuralSearchSpace::sequence` for split candidates ("of the") |
| Size | not reported | int8 rows + fp32 scales: 3.9 MB, memory-mapped |

## The `<unk>` probability

Training text maps every word outside the 30k vocabulary to `<unk>`, so the model
learns P(`<unk>`|context): the chance that the next word is any word it does not know.
A lexicon word w outside the vocabulary is scored as Gboard does, through that mass:

    log P(w | ctx) = log P(<unk> | ctx) + log share + log u(w) - log oovMass

- u(w) is the production n-gram's unigram mass: pack frequency + 1, or 0.5 for a word
  without a pack entry (the n-gram scorer's unknown-word mass).
- oovMass sums u over the emittable `[a-z']` pack words outside the vocabulary
  (82,311 words, 1% of the unigram mass), so the fallback is a proper distribution.
- share is the fraction of `<unk>` training tokens that are lexicon words (0.317 for
  the default mixture). The other 68% is text the lexicon cannot emit (names, foreign
  words), which the keyboard leaves as typed.

The decoder's distribution excludes `<pad>`, `<bos>` and `<eos>` and renormalizes:
a user typing letters is writing a word, not ending the sentence.

## Context and the rolling ring buffer

Training sequences are single sentences (`<bos> w1 .. wn <eos>`), split exactly as
`KeyboardViewController.contextWords` reads the left context: letters and
apostrophes form words; digits, hyphens and punctuation separate them; `.`, `!`, `?`
and newlines end the sentence. `<bos>` clears the recurrent state, so packed training
streams and the runtime agree.

The runtime never re-reads the context. `ContextRing` (C++, mirrored by
`nss/ring.py`) keeps the model state after each committed word of the sentence in a
ring buffer (64 slots; the oldest is overwritten), plus the state after `<bos>`. Each
request's context is matched against the ring and only new words are stepped:

| Event | Model steps |
|---|---|
| Another keystroke in the same word | 0 (the cached distribution is reused) |
| A committed word | 1 |
| Backspace into the previous word | 0 |
| The host's 8-word window slides by a word | 1 (the state keeps the whole sentence) |
| A different sentence or field | at most the context length |

One step plus the output layer is about 3.3M multiply-adds. The C++ kernel dequantizes
int8 rows with explicit NEON (the shipping `-Os` build does not auto-vectorize it); on
an M2 at `-Os`: 44 µs per LSTM step, 0.36 ms for the 30k-word output layer and
log-softmax, 0.43 ms per committed word, 0.3 µs for a keystroke inside a word (the
cached distribution). Physical-iPhone timings are still to be measured.

## Architectures

All models implement `nss.models.StreamingLM` (`forward(tokens, state)` equals `step`
threaded token by token; `tests/test_models.py` checks it for every architecture):

| Config | Model | Runtime kernel |
|---|---|---|
| `cifg-lstm-96x670.json` | CIFG-LSTM, the NSS reference | C++ |
| `cifg-lstm-96x670-untied.json` | same, separate output embedding | C++ |
| `lstm-96x670.json` | four-gate LSTM with projection | C++ |
| `gru-96x512.json` | GRU, projected output | C++ |
| `transformer-sw32.json` | sliding-window transformer; state = rolling key/value buffer | Python only |
| `ssm-128x256.json` | gated diagonal linear recurrence (selective SSM) | Python only |

## Commands

Use the `ml` conda environment (PyTorch with MPS); corpus building needs `pyarrow`
(the base environment has it).

```sh
cd tools/nss
python3 -m nss.build_corpus                         # data/: Tatoeba, WikiText-103, MASC held-out
python -m nss.train --config configs/cifg-lstm-96x670.json
python -m nss.evaluate runs/cifg-lstm-96x670/best.pt --out runs/cifg-lstm-96x670/eval.json
python -m nss.export runs/cifg-lstm-96x670/best.pt --out ../../keyboard/nss-english.nsslm
python -m nss.fixtures                              # tiny models for the C++ tests
python -m unittest discover -s tests
```

`build_corpus` splits every source by a hash of its document key (0.5% valid, 0.5%
test) and drops duplicate sentences. Tatoeba's stock characters (Tom in 23% of its
sentences, Mary in 8%) become `<unk>` nine times in ten, the token any other name is.
Add a messaging corpus with `--chat file.txt` (one message per line) and a `chat`
weight in the config.

Training uses the exact full softmax (chunked so the 30k logits never materialize at
once): sampled softmax would bias the rare-class probabilities the `<unk>` fallback
depends on. Validation runs on a CPU copy of the model.

`export` writes the `.nsslm` file (int8 rows with fp32 scales, fp32 biases, the
vocabulary), `<out>.manifest.json` (hashes of the vocabulary, lexicon and checkpoint,
architecture, quantization error, `<unk>` policy) and `<out>.goldens.json`, reference
scores from the dequantized model that `native/tests/NeuralLanguageModelTests.cpp`
must reproduce. The vocabulary and the output layer are a pair: the runtime records the
vocabulary SHA-256 and the exporter refuses a checkpoint trained on another list.

## Evaluation and the app

`nss.evaluate` reports perplexity, `<unk>` calibration and next-word accuracy on the
held-out sets, fp32 and as exported, and compares the model with the production
Witten-Bell n-gram on MASC held-out (documents disjoint from the n-gram's counts).
Task-level results come from the autocorrect harness:

```sh
cd tools/evaluation/autocorrect
python3 evaluate.py build
KB_NSS=../../../keyboard/nss-english.nsslm python3 evaluate.py run nss
python3 evaluate.py score nss --vs <n-gram run>
```

On iOS the model ships in every build (`Config/README.md`): `NSS_ENABLED` bundles
`keyboard/nss-english.nsslm` (currently `artifacts/generic-final.nsslm`) and English
word sessions take the `nss` tier from the first word; `NSS_ENABLED=NO` builds n-gram-only. In the checkpoint implementation, Glide still scored with the n-gram. The new graph tier also supplies neural lookahead and word scores to Glide. The promotion gates in
`tools/lm/README.md` (data rights, blind user-separated evaluation, device latency and
memory) apply before it ships.
