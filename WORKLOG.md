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
- [ ] #18 KV-cache + int8 quantization. coremltools 9.0 IS in the `ml` conda env
  (/Users/meher/anaconda3/envs/ml); quantization already coded in export_coreml.py.
  KV-cache still needs model surgery + MLState (iOS 18+) + parity checks. Deferred.

## Memory
- [x] Fix: `Lexicon.boosts` was unbounded in KEY count (one entry per distinct dict
  word ever typed). Capped at 3000, halve-and-drop. KB-scale, not the reported 12MB.
- Note: 15→27MB typing growth is mmap page fault-in of langdata.bin (18.7MB), by
  design — clean/evictable file pages, faulted lazily as more of the trie/blob is
  touched. RSS (Xcode gauge) climbs to working set + plateaus; phys_footprint
  (jetsam metric, diagnostics screen) largely excludes clean mapped pages. Old heap
  trie was ~all-resident at launch (58MB flat); this is the tradeoff for 15MB start.


Transpositions (Damerau–Levenshtein). Swapped adjacent letters — "teh", "hte", "adn" — are the single most common typo class, and your DP charges them two full edits. Adding a swap operation at ~0.8 cost (one extra DP row of memory) would be the highest-value correction change available. This is the concrete gap behind your instinct.
Real touch coordinates. You score P(typed key | intended key); Gboard scores P(touch point | intended key) from the actual (x, y). KeyboardView owns the raw touches, so the plumbing exists — pass the offset-within-key through onInsert and the channel model gains sub-key precision, plus per-user drift calibration (most people systematically hit low-right).
LM-driven key target resizing. Gboard invisibly grows the tap targets of letters the language model expects next. You have key(at:) nearest-key resolution already — bias its distance metric by next-character probability and mistaps drop before autocorrect ever sees them.
Multi-word correction. You only correct the trailing word. Stock iOS revises the previous word after seeing the next one ("of coarse" → "of course"), and handles splits/joins ("alot" → "a lot"). Your precomputed-decision architecture extends to this: precompute a two-word revision alongside pending.
Glide typing. The trie + spatial Gaussian is most of the machinery; what's missing is path decoding (beam search over the swipe trajectory against trie paths). Big feature, big differentiator, genuinely feasible with what you have.
Inline ghost-text prediction. Grey completion text after the cursor (SwiftKey/Gboard style) — your beam-search word prediction already produces the content; it's mostly UI plus a commit-on-space gesture.
KV-cache + quantization for the neural model. Context changes by one token per keystroke, but you re-encode from scratch every pass. Exporting the model with a key-value cache makes scoring incremental (big latency win), and int8 quantization roughly halves the resident model's memory — headroom for older devices to host it.
Personalization frecency. SwiftKey decays stale habits; your counts only grow (until pruning halves them). Time-weighted decay would keep the personal model tracking who you are now — and it composes with the session-scoped keeps you just asked for.
Word→emoji suggestions. "pizza" offering 🍕 on the bar is a tiny word-to-emoji table away, and it's one of SwiftKey's most-loved features — you now even have the binary-resource pattern to ship it in.
Simultaneous bilingual typing. SwiftKey's killer feature: no language switching, it just detects. Your <en>/<te>/<xlit> register tags in the LM are exactly the right foundation — the Tenglish plan is already pointed at this; the differentiator is making it seamless rather than a mode.

## Extension file registry (PBXFileSystemSynchronizedBuildFileExceptionSet 837F018D)
The app target auto-includes all keyboard/**/*.swift (synchronized group, recursive).
The demo_keyboard EXTENSION does not — every SHARED source file must be listed in its
membershipExceptions in project.pbxproj, BY PATH RELATIVE TO keyboard/. Any entry with
`/` or `+` must be quoted. App-only files (App/*) must NOT be listed.

Folder layout under keyboard/:
- App/    ContentView, keyboardApp, Persistence            (app only — NOT in extension)
- Engine/ SpatialModel, Trie, LangData, LanguageScorer, UserModel, NgramScorer,
          Lexicon, Keyboardengine, NeuralScorer            (extension: "Engine/<f>.swift")
- Views/  Keyboard, KeyButton, SuggestionBar, KeyboardTheme, Emoji  (extension: "Views/<f>.swift")
- Shared/ KBSettings, KBDiagnostics, KBSafetyLexicon, FontInstaller, UIColor+Hex
                                                           (extension: "Shared/<f>.swift")
- (root)  emoji.bin, langdata.bin, rescorer.mlpackage, safety.kbguard, tokenizer.bin
          — resources stay at root, referenced by bare name in BOTH exception sets.

When adding a shared file: create it under the right folder, then add "Folder/File.swift"
(quoted) to 837F018D. When moving a file: update its path there. Both schemes must build.

## KV-cache + quantization (#18-24) progress
- [x] #19 int8 quantized export SHIPPED + verified. Per-channel is load-bearing:
  per-tensor int8 wrecks the TIED embedding/head (last-pos top-1 agreement 0%,
  cos 0.78); per-channel → cos 1.0000, top-1 0.97, top-5 1.00, 4.6MB. Fixed in
  export_coreml.py (granularity="per_channel") + os._exit(0) to dodge coremltools'
  mutex teardown abort. rescorer.mlpackage now REAL → neural path activates on
  capable devices (gated: minAvailableMBToLoad 90MB, drops under pressure).
- [x] #20 stateful TinyLM (model.py Block.forward_cached + TinyLM.forward_cached +
  empty_cache). Verified: step-by-step AND prefill+step KV decoding == full forward
  to 2e-7, top-1 100% (/tmp/kvtest.py).
- [ ] #21-24 BLOCKED on an iOS 18 device for meaningful verification. #21 (StateType
  export) is fragile in this coremltools env; #22-23 (Swift MLState backend) build but
  cannot be runtime-verified without iOS 18 HW; #24 needs a device. #20 is the ready
  foundation to resume from. Deferred per modest-ROI-at-4L/256d tradeoff (see roadmap).
