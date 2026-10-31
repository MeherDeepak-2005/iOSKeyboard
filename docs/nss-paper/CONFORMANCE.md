# NSS reproduction constraints and scope

Reference: Zhang et al., *Neural Search Space in Gboard Decoder*, EMNLP Industry
2024, pp. 1245–1254, https://aclanthology.org/2024.emnlp-industry.93/.
The downloaded publication is committed as `2024.emnlp-industry.93.pdf`.
SHA-256: `d9bc6c070f2459add9ba8ca21e2d7fe1207f9dafb07f4366cc7031b53ad9b83c`.

This branch reproduces the published **NSS language-graph mechanism**, integrated
with this project's lexicon and touch/edit adapters. It is not Google's source,
trained weights, private corpus, or complete Gboard spatial/bi-key decoder. Those
are not provided by this paper. No claim of bit-for-bit Gboard behavior or Gboard
quality parity is made.

## Hard constraints

| Published mechanism | Implementation |
| --- | --- |
| Algorithms 1/3, UpdateLM at a word boundary | `NeuralFst::update`; reset graph arenas to states 0 and 1, then populate neural arcs from committed context. Identical contexts reuse the same root distribution. |
| Figure 2, full unigram fallback state | Shared `NeuralLexicon`: unigram self-loops for emittable dictionary words; state 1. |
| Figure 3, start epsilon weighted by UNK | Expanded states have epsilon weight `log P(UNK|context)` into state 1. Each neural word arc leads to its own state, initially with zero-weight epsilon fallback. |
| Figure 4, multiple paths compete | Both neural and unigram paths survive composition. Viterbi selection uses the best path; fallback also remains available for in-vocabulary words. |
| No OOV-share renormalization from the previous implementation | Graph fallback uses UNK times full-lexicon unigram probability. The previous `share/oovMass` and literal-UNK shift are absent from the active decoder. |
| Algorithm 2, LM and spatial evidence during pruning | `NeuralFstSearch` lazily composes the edit/touch channel, lexicon trie and G. Every beam token includes completed LM score plus admissible prefix LM lookahead before pruning. No pre-LM 32-row shortlist, top-24 neural injection, or bounded funding heuristic. |
| Algorithms 2/4, ExtendLM while typing | Word-terminal hypotheses nominate graph states; the model steps through the hypothesized word and adds continuation arcs at that state. Multiword search continues recursively. |
| §4.4.1 initial arc threshold | `log P >= -15`, with **no 1,024 arc cap**. |
| §4.4.1 extension arc threshold | `log P >= -12`. |
| §4.4.2 / Appendix A.4 dynamic pruning | At most one previously unexpanded eligible state per input frame; its joint path log score must exceed -12. |
| §4.4.3 frequently modified FST | One contiguous mutable arc arena, state-to-range indexing, reset/truncation with retained vector capacity, separate immutable unigram storage. |
| Appendix A.3 gesture support | Neural graph lookahead enters the existing gesture trie beam; final word scores use the same graph. No ExtendLM for gesture input. |

## Explicit local choices where the paper is incomplete

- `C o L` is supplied by the project's English edit/touch channel and packed trie.
  It is an implicit weighted transducer, not a copy of Gboard's unpublished
  bi-key transducer. Insertions, deletions, substitutions, adjacent transpositions,
  missing spaces, and c/v/b/n/m space substitutions are supported. The legacy
  word-length/first-letter recovery gates are not part of this composed search.
- General beam width 512 and relative beam 16 natural-log units are local resource
  settings: the paper does not publish the full decoding beam configuration.
  These are distinct from its **fixed** top-one dynamic-expansion rule.
- The existing spatial scaling, literal protection/commitment policy,
  personalization, and gesture shape model are local product components.
  Replicating NSS does not establish that these match Gboard.
- The lexicon has 114,283 entries rather than Gboard's reported 170k. Neural
  vocabulary remains 30k plus four special tokens. This adapter handles ASCII
  English/apostrophe dictionary words; other input is preserved literally.
- The word distribution masks PAD/BOS/EOS, as the pre-existing runtime does.
  The paper does not specify these special-token conventions.
- A bounded recurrent-state cache retains sentence context across the host's
  sliding eight-word window. Field/epoch changes reset it; edits rebuild the
  current word graph. The paper does not prescribe this cache implementation.
- Final completion traversal stops using an admissible score bound once no
  remaining path can enter the 24 displayed/evidence candidates. Full terminal
  paths remain available to the correction policy.

## Model and reproducibility

The old working tree is preserved at `5f2df22065d4ac3aba3b6d76ff61c1ebc9e5fddc`
on branch `codex/nss-paper-replica`. Generated corpora and active training runs
were left untouched and excluded from that checkpoint.

The frozen old model is `tools/nss/artifacts/baseline-step8000.nsslm`, SHA-256
`814966e17fb56dc8ecad73758f01cd94195e665885373ec4a92f4321e7556638`.
The lexicon SHA-256 is
`9db0760697014aecdf540d1828cd523156bcf87a2ed04f2afaa724ac24cd8ea6`.

The internal model `keyboard/nss-english.nsslm` is a four-gate, untied, one-layer
LSTM with embedding 96, 670 cells, projection 96 and **6,372,332 parameters**
(rounds to the paper's 6.4M). Projection width and tying details are explicit local
choices because the paper does not give every tensor shape.

It is initialized from the frozen trained CIFG by setting input-gate logits to
negative forget-gate logits and copying the embedding into a separate output
matrix. This preserves the trained function to floating-point precision; it is
**not retraining**, not a new data-quality improvement, and not recovery of Google's
weights. The architecture allows independent gates and embeddings;
`configs/paper-lstm-96x670.json` configures a fresh training run. The expanded
quantized artifact is for inference, not a new floating-point training checkpoint. The public corpus still differs
from Gboard's federated training corpus; this cannot be fixed by decoder code.

`expand_reference_model.py` preserves quantized rows and records source/output
hashes. The expanded export matches the frozen export's 220 independent reference
scores within the original tolerance. Full-model graph tests verify all retained
arcs and extension scores against direct recurrent inference, including contexts
with more than 1,024 arcs. The frozen model emits 13,575 initial arcs in the tested
`can you` context, versus the paper's typical 1k–5k; its thresholds remain unchanged.

## Validation and interpretation

- CMake tests cover graph semantics, direct/fallback competition, thresholding,
  lookahead bounds, dynamic expansion, cancellation, and field identity reset.
- Existing n-gram native goldens are unchanged.
- Sanitizer runs check the native integration; simulator tests check the Swift bridge.
- Desktop correction/latency results, simulator integration, and physical-device
  behavior are separate evidence. Desktop memory is not an iOS-extension budget.
- Whole-word request timing includes replay of every input frame for a fresh word;
  per-keystroke timing measures retained-prefix updates. Both must be reported.
- The existing held-out split is target-word-disjoint, not user-disjoint, and has
  already been used in earlier project work. It is not a new blind production test.

See `COMPARISON.md` and machine-readable result artifacts for measured outcomes.
