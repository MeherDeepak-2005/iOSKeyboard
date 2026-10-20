# MARISA vocabulary experiment

This is an opt-in native C++ prototype, separate from shipping iOS/Android targets.
It uses unmodified upstream MARISA 0.3.1 (see vendor/PROVENANCE.md), not the
customized copy in CoreV4. The existing production decoder and mutable personal,
contact and supplementary vocabulary layers are untouched.

Run from the iOSKeyboard repository:

```sh
native/experimental/marisa/run.sh
native/experimental/marisa/run.sh /private/tmp/marisa-sanitizers --sanitize
```

CMake, a C++20 compiler and Python 3 are required. Vendored source makes the run
offline. The runner builds in a temporary directory, generates a temporary index,
checks parity, then saves three Release timing trials and separate-process memory
samples in results/. Sanitizer mode only builds/checks correctness; never compare
its performance with Release. Memory collection uses getrusage, with macOS byte
units and Linux KiB converted to bytes. The file mapper and runner are POSIX tools;
the vocabulary adapter itself is platform-neutral C++.

## Adapter and compatibility

MarisaLexicon exposes the same search signature as PackedLexicon, plus exact word
ID lookup, prefix existence and experimental frequency-ranked completions. It maps
an immutable MARISA dictionary and retains a four-byte corpus-ID mapping per key.
Frequencies and n-grams remain in the existing borrowed PackedLexicon. No n-gram
IDs are rewritten. The caller must retain that corpus and its bytes for the entire
adapter lifetime. Query agents and DP buffers are local to each call.

The offline builder uses MARISA_LABEL_ORDER, preserving label-sorted DFS candidate
order. Loading validates key count, ID permutation and every reverse-mapped word
against the corpus, rejecting stale/mismatched dictionaries. The sidecar has a
versioned magic and little-endian integers. Build artifacts are experimental and
not atomically published; build to a fresh temporary destination as the runner does.

The weighted fuzzy adapter preserves insertion/deletion, spatial substitutions,
touch alignment, OSA transpositions, omitted apostrophe cost, first-letter policy,
depth limit and separate prefix/terminal funding. Cancellation drops partial hits.
MARISA's public API does not expose child cursors. The adapter therefore enumerates
keys in lexical order, shares DP rows across common prefixes and skips DP beneath
pruned prefixes. It still decodes those keys, unlike PackedLexicon's direct subtree
pruning. This is a public-API feasibility baseline, not a claim about the fastest
possible customized MARISA traversal.

Completion ranking enumerates the whole prefix and returns its highest frequency
words. Equal-frequency ties use lexical order, whereas the shipping packed trie
uses heap traversal ties. Completion tie parity is **not** established; this method
is experimental and is not wired into shipping completion or Glide. Search parity
is checked exactly, including order, costs and frequencies.

## Measurements and limits

See RESULTS.md and results/summary.json for the measured decision. Measurements
use the production 114,283-form KBLM v6 corpus. The corpus SHA-256 is in the summary.
Search covers 55 nonempty inputs, including incremental prefixes, apostrophes and
misspellings, with five repetitions after one warm-up sweep (275 samples/backend
per trial). Backends alternate execution order. Radius is 3.6 with no touch/funding
in the timing set; correctness separately covers radii 0, 1.6, 3.6 and 7.2, touches,
funding, severe typos, mismatched maps and vocabulary IDs above 65535.

These are independent full-search kernels on this Mac, not retained-session,
whole-decoder, cold-launch, energy or physical-phone measurements. Pack validation
runs once per process. Reported MARISA opening is **additional** mapping plus full
ID/word validation after opening the packed corpus. It is not an equivalent
replacement-only launch comparison. RSS is whole-process peak across opening and
one query sweep, not isolated index residency. Both processes retain the original
pack including its trie; the MARISA process additionally maps its new index.
Consequently, smaller index bytes do not establish lower shipping RSS.

The packed exact-lookup timing is a benchmark-only C++ reproduction of the existing
packed child binary search. All IDs are checked against the corpus before timing.
It is a representation comparison, not a timing of the Swift call/bridge overhead.
Both exact-lookup measurements sweep the entire vocabulary and return batch times.

A production switch would also require direct compressed-branch traversal (or a
new candidate generator), retained-session integration, completion/Glide ordering
parity, replacement pack layout and device benchmarks. The current full-search
regression is a sufficient reason to stop before that larger migration. The
experiment remains reproducible for evaluating such future work.
