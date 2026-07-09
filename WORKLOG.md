# Work log — autocorrect / suggestion improvements

Status key: `[x]` changed · `[~]` in progress · `[ ]` planned

## Batch: correction quality + memory (this session) — ALL BUILDING

Both schemes build clean. Data verified against brute force (scratchpad
check_v3.py, check_batch2.py): trie round-trips vocab, transposition DP == OSA
brute force, emoji map sorted + binary-searchable, tap cost reduces to discrete.

- [x] #11 Damerau transpositions. `Trie.transCost = 0.8` + transposition branch in
  `Trie.search`, `LangData.trieSearch`, and `eval_harness.py` (prevLetter + depth-2
  row threaded). "teh"→"the" now costs 0.8 (one edit), verified == full OSA matrix.
- [x] #12 Real touch coordinates. `KeyTap {dx,dy}`; continuous `KB.subCost(_:typed:tap:)`;
  taps captured in `KeyboardView.touchesBegan`, buffered per word in the controller
  (`wordTaps`), passed to corrections/autocorrection. Engine ignores on length
  mismatch, so any desync is safe. nil taps = exact legacy behavior.
- [x] #13 Key-target resizing. `LangData.trieChildren` → `Lexicon.nextCharPriors` →
  returned from `suggestions`; `KeyboardView.setKeyPriors`; `key(at:)` keeps an
  authoritative inner core (28% inset always wins) and biases only edge/gap taps by
  prior (capped 0.12·pitch²). No neural calls — pure mmap trie reads.
- [x] #14 Split corrections ("alot"→"a lot"). `splitCandidate` + `NgramScorer.pairLogProb`,
  wired into neural and n-gram correction paths. Retroactive previous-word rewrite
  still deferred (needs async proxy surgery).
- [x] #15 Ghost completion styling. `SuggestionBar.setSuggestions(_:typedPrefix:)`
  renders typed prefix solid + completion remainder dimmed (attributed title).
  True in-field ghost text is impossible for iOS keyboard extensions.
- [x] #16 Word→emoji (emoji.bin v2). Builder adds sorted word→emoji section (157 pairs);
  `EmojiStore.emoji(forWord:)` binary-searches it; engine drops the emoji into the
  last suggestion slot on an exact match; controller `handlePick` emoji guard inserts
  it without learning. v1 files still load (map treated as empty).
- [x] #17 Selective font registration. `KBFont.fileToken` + `FontInstaller.
  registerSelectedFont()` (extension loads only the chosen font's file). App still
  registers all for the Fonts preview. ODR is app-only, unavailable to extensions.
- [ ] #18 KV-cache + int8 quantization. Plan only — needs coremltools (ABSENT on this
  machine), export pipeline rerun, MLState (iOS 18+), and output-parity checks.
  Execute in a dedicated pass. See plan in the final report.
