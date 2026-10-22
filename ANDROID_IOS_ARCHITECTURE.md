# Shared decoder core and platform boundaries

The generated English pack is **`keyboard/langdata.bin`: 61,082 forms, 9,455,641
bytes**, SHA-256 `ddbb25cb14d90bfb3e0097980aab68b8423f9e768b9bdfb8fbdbd55f163298d2`.
The vocabulary scripts were executed and that pack is bundled in iOS. Android
stages the same pack into generated assets; there is no separately maintained
Android dictionary.

## Languages and modules

| Layer | Language | Files | Responsibility |
|---|---|---|---|
| Neutral core | C++20 | `native/DecoderCore/` | Checked packed vocabulary, ASCII English tap candidate generation, mutable tries, packed completions, terminal/prefix funding, spatial costs, immutable boosted seed preparation, retained DP, batched language-score mathematics |
| iOS adapter | Objective-C++ | `native/iOS/KBDecoderBridge.h/.mm` | Retain immutable NSData mapping, numeric/UTF-8 transport, whole-batch conversion, native error translation |
| iOS application | Swift | `keyboard/`, `demo_keyboard/` | UI, document insertion, resource discovery, scheduling/revisions, settings, personal storage and existing language routing |
| Android adapter | C++ with JNI | `native/android/SharedEngineJni.cpp` | Read-only file mapping, lifetime-safe opaque handles, one serialized engine lane per handle, byte-array input and versioned `EngineWire` output |
| Android application/library façade | Kotlin | `android/decoder/` | Asset extraction, checksum/version lifecycle, worker scheduling boundary, resource closing; future InputMethodService/UI/personal persistence |

Kotlin follows Android's [Kotlin-first guidance](https://developer.android.com/kotlin/first).
CMake/NDK integration follows the [official NDK toolchain](https://developer.android.com/ndk/guides/cmake).
JNI keeps algorithm work and ownership inside native calls, following
[JNI guidance](https://developer.android.com/ndk/guides/jni-tips).
Objective-C++ is an iOS adapter language; it is not compiled into the neutral
library or Android. Swift remains the iOS UI/lifecycle language.

## What is native by default now

`LangData(url:)`, `IncrementalDecodeSession` and `NgramScorer` default to `.cpp`.
The production path uses C++ validation, one shared immutable dictionary mapping,
C++ packed fuzzy traversal for short/broad/context-funded search, native retained
search for eligible five-or-more-byte English words, and native batched Witten–Bell
interpolation/personal score mathematics. This is actual returned evidence, not a
shadow-only experiment.

The retained session consumes native mapped seeds plus an immutable snapshot of the
existing Swift static-word boosts. It allocates no duplicate Swift seed spellings
or Swift DP buffers. Root gating, the 24,000-state cap/fallback, frequency order,
first-letter penalties, costs and scoring constants are preserved. Native seed-set
and session ownership keeps the backing alive after the Swift reader is released.
Personal data is still one platform-owned database; C++ receives snapshots, not a
second mutable personal store.

Prefix traversal and terminal funding remain separate. The native packed walk
returns results in the existing DFS order and pure channel costs. Cancellation
checks run once per 128 visited nodes, as before; only that cooperative cancellation
check calls the iOS façade. There are no platform lookups or model callbacks per
search node/beam comparison.

Debug and test builds retain `.swiftReference` and optional shadow audits. Large
Swift retained-DP and packed fuzzy-search reference bodies are excluded from normal
shipping Release. Xcode automatically sets `KB_REFERENCE_DECODER_YES` when
`ENABLE_TESTABILITY=YES`; normal Release uses the native path. The command-line
native performance harness explicitly enables the reference condition for its
paired measurements. Swift's small language-score reference remains a defensive
fallback; it is not a second production search engine.

## Remaining migration work — not claimed complete

| Process | Current runtime | Planned destination |
|---|---|---|
| Packed lookup/completions used by tap generator | C++ | Implemented; other LangData/Glide callers still have Swift access |
| Glide anchor/index access and selected n-gram count extraction | Swift reading the shared, natively validated map | C++ packed view |
| Mutable/adopted/supplementary trie storage and traversal | C++ by default; Swift reference in tests | Implemented; learning/persistence remains Swift |
| Tap proposal generation, recovery admission, contraction/split proposals | C++ for ASCII typed input; Swift reference/Unicode fallback | [Candidate generation details](docs/decoder-platform/CPP_CANDIDATE_GENERATION.md) |
| Final ranking, correction gates and neural multiword policy | Swift | C++ policy layer after independent parity |
| Context/personal distribution extraction and next-word merging | Swift; score mathematics are C++ | C++ vocabulary/personal/safety views |
| Glide geometry/search/shape ranking | Swift | C++ after policy/Glide parity |
| Neural tokenizer/search math and Core ML execution façade | Existing Swift; no trained artifacts available | C++ math plus iOS Objective-C++ Core ML backend |
| Core ML / Android model backend abstraction | Planned `InferenceBackend.hpp` | Separate platform implementations; network operations stay in their native ML runtime |
| Telugu and transliteration | Swift/iOS | Outside this English migration |

The core is the primary English channel/math backend, **not yet the complete
cross-platform suggestion/correction pipeline**. The Android module exposes static
full search, retained search and batched score mathematics. It is not a complete
Android IME, and it must not be advertised as having final ranking, learning,
Glide or neural quality parity until those stages are migrated.

## Boundary contract

Use direct calls: Swift → Objective-C++ → C++, and Kotlin → JNI → C++. No HTTP,
local server or per-keystroke cross-process API is introduced. Pass UTF-8 text,
numeric touch buffers, immutable personal evidence and owned ranked/channel results.
Touch offsets use the same normalized key-pitch units as iOS `KeyTap`, not pixels.
Keep Double precision for channel/ranking evidence. Framework-specific tensors and
inference lifecycles stay outside `DecoderCore`.

`PlatformContract.hpp` and Kotlin `RequestIdentity` reserve matching field,
document, word-session, generation, layout, vocabulary and personal epochs. The
existing iOS request/snapshot identifiers and stale-result validation are unchanged.
The Android identity record is preparation for the complete pipeline; its current
synchronous channel calls do not publish UI results or carry whole decode requests.
A future Android worker must capture the complete identity before enqueueing and
compare all fields before insertion/publication, resetting native word state when
its session/layout/vocabulary/personal snapshot changes.

Input buffers are consumed synchronously; results own their data. iOS retains the
exact immutable mapping; Android retains its mmap until all in-flight handle calls
and the session are finished. Handles are registry IDs rather than exposed raw
addresses. Kotlin synchronizes each session and implements `Closeable`; call
`close()` on teardown. C++ owners that define special memory-management operations
explicitly provide/delete all five; simple value evidence records use the Rule of Zero.

## Build and verification

Portable library and actual bundled corpus:

```sh
cmake -S native -B /tmp/xploree-core -DCMAKE_BUILD_TYPE=Debug
cmake --build /tmp/xploree-core
ctest --test-dir /tmp/xploree-core --output-on-failure
native/tests/run.sh
```

The sanitizer runner checks malformed/truncated formats, ownership, borrowed views,
spatial costs, seed caps and personalization, search recovery/cancellation and scoring.
The iOS tests compare native full/retained evidence against independent Swift paths
within `1e-9`, including terminal funding, touches, OOV scores and personal boosts.
The expanded dictionary and existing correction/learning/revision regressions are
included. Re-run all five contexts of `coeevitjkn → correction`.

```sh
xcodebuild -project keyboard.xcodeproj -scheme keyboard -configuration Release \
  ENABLE_TESTABILITY=YES -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:keyboardTests/KeyboardTests \
  -only-testing:keyboardTests/NativePackedLexiconTests \
  -only-testing:keyboardTests/NativeSearchParityTests \
  -only-testing:keyboardTests/SevereTypoBenchmark test
```

Check the complete device-target extension with `tools/verify_release_artifacts.py`.
Simulator code can contain both arm64 and x86_64; it is not an iPhone shipping-size
measurement. Check the distribution-signed archive before release. None of these
build checks establish physical iPhone/Android RAM or whole-decoder speed gains.

Android module integration: [Android README](android/README.md).
Current evidence: [platform verification](docs/decoder-platform/VERIFICATION.md).
The dictionary expansion's earlier evidence remains in `docs/english-vocabulary/`.
