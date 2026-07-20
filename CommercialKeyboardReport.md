# Glyph Commercial Keyboard Report

Date: 2026-07-19  
Decision: **NO-GO for a commercial language-quality claim or broad paid acquisition.**  
Recommended position: privacy-first English/Tenglish/Telugu keyboard for India and the Telugu diaspora.

## Executive Verdict

The codebase has a credible low-latency UIKit keyboard foundation, but it does not yet have the reviewed multilingual data, physical-device evidence, retention, or distribution required to compete with Gboard. A themed English keyboard is not a defensible product. Native Telugu is now an enabled literal-composition Beta, while trained Tenglish transliteration remains the first language-quality wedge; code-switching, autocorrection, and Android scale still require native-speaker and blind quality gates.

Current score after this implementation pass:

| Area | Score | Commercial blocker |
|---|---:|---|
| Runtime structure | 7/10 | Physical memory, energy, and sustained-load gates are not run |
| Demonstrated English quality | 3/10 | Repaired measurements remain synthetic, user-unseparated, and contain no clean-input false-correction slice |
| Glide | 4/10 | No representative path corpus or oldest-device release evidence |
| Neural readiness | 4/10 | Cache math, tier contract, W8/W8A8 export gates exist; no promoted stateful package |
| Tenglish | 3/10 | Separate Telugu-script and Roman modes work, but the context corpus is only a 318-sentence bootstrap and no blind code-switch benchmark exists |
| Native Telugu | 3/10 | Five-row composition and a compact LM exist; the LM is far too small and native review is still missing |
| Commercial backend | 2/10 | StoreKit and server-authoritative client contracts exist; no campaign server, SSV ad integration, merchant postbacks, payout ledger service, KYC, or fraud system |
| Overall backend | 4/10 | Technically promising, not yet commercially proven |

## What Was Implemented

- All targets now require iOS 18.
- `DecodeRequest` identity includes language and a word-session-frozen model tier. Available tiers are `ngram`, `neuralW8`, and `neuralW8A8`; ordinary Release builds instantiate only the n-gram tier. An explicit `INTERNAL_NEURAL` profiling build can load W8 without changing shipping defaults.
- Suggestions and boundary correction still come from one authoritative `DecodeSnapshot`; host insertion still happens before asynchronous decoding.
- The 10.6M student now has tested KV-cache math. The Core ML exporter targets iOS 18, writes W8 and W8A8 comparison packages outside the extension, verifies MIL quantization operations, and refuses non-QAT checkpoints without an explicit research override.
- The Python evaluator now matches the fresh-install Witten-Bell formula, loads either neural checkpoint format with tokenizer-hash verification, batches exact whole-word scores, mirrors the 32-row score cap, and no longer claims synthetic results transfer to an iPhone. It accepts labelled JSONL and emits machine-readable provenance.
- A user-separated softmax ranker trainer now fits spatial, n-gram, neural, frequency, length, typed-word margin, typed-exact, and source features without forced-gold insertion. It emits `promoted: false` unless an untouched test set improves top-1 without worsening false corrections, the paired result is significant, and reviewed physical release gates are explicitly recorded as passed.
- The paired release report now covers oracle recall, top-1/top-3, false/missed correction, WMR, keystroke savings, calibration/Brier score, p50/p95/p99, McNemar significance, and user-cluster confidence intervals.
- Tap personalization now learns bounded row-cluster center offsets and diagonal covariance from accepted literal static words. It persists aggregate sufficient statistics only and is reset with other learning data. This follows the conservative shape of [Google's Gboard spatial-personalization work](https://research.google/pubs/spatial-model-personalization-in-gboard/).
- Tenglish mode uses Roman QWERTY. Reviewed forms may convert at a boundary; unknown compositions remain literal so names and code are not silently transliterated. URL, email, handle, numeric, and secure fields force English, while ordinary search fields retain the selected language. Tenglish Glide is disabled until tap transliteration is validated.
- A deterministic `KBXL v3` builder now stores a 12,000-key weighted transliteration lexicon plus a compact Roman Telugu bi/trigram tail in one mmap artifact. Tenglish-to-Telugu uses Telugu context; Roman Telugu emits only Latin forms and uses its own prior, never the English LM.
- The Telugu corpus pipeline now consumes a strict source manifest with exact hashes, revisions, attribution, license, language/domain tags, source weights, deterministic source caps, and research/release flags. Release verification rejects any runtime source not explicitly release-eligible. The tracked corpus remains only a 318-sentence Tatoeba bootstrap and is not represented as sufficient training data.
- Native Telugu (Beta) is selectable and uses a data-driven consonant, vowel/sign, and Telugu-numeric layout. Aspirates and Latin digits are long-press alternatives; dependent vowels, virama, ZWJ/ZWNJ, NFC composition, complete-cluster deletion, VoiceOver names, and conservative Telugu prefix suggestions are covered without routing Telugu through English autocorrection.
- Glide now retains one session, incremental resampler, candidate pool, and online DTW state. Preview and lift share the same ranked snapshot; top-1 remains in the shaded middle slot with top-2 left and top-3 right, and a one-shot fallback is reserved for invalid incremental state.
- Emoji is local. The companion app rasterizes the system glyphs once into a catalog-hashed atlas; the extension renders grid/search cells from explicit read-only mmap pages rather than CoreText's retained emoji-glyph cache, and drops the mapping on pressure. GIF and Sticker search is explicit-only, Full-Access-gated, query-minimized, cache-bounded, and KLIPY-attributed. Remote media additionally fails closed until the per-key Partner Panel content filter is reviewed and `KLIPY_CONTENT_FILTER_APPROVED=YES` is set. No advertising endpoint or targeting field exists in the extension client.
- Cosmetic leagues, streaks, and achievements are restored as a non-sticky companion-app Progress section. Completed word boundaries are provisional until the immediate undo window closes, and persistence runs on a utility queue; these metrics cannot unlock cash, coupons, ads, or themes.
- Language-data format v5 stores compact sorted context records and a 12-byte trie. Full v4/v5 logical equivalence passed; the current ESDB-validated 60,450-word pack is 9,391,297 bytes versus the old 19,263,737-byte v4 artifact.
- Language-pack health now distinguishes missing resources, invalid schema/header, hash mismatch, and app/extension build mismatch. A preferred Telugu selection survives a session fallback, and the companion app shows the concrete extension failure instead of the generic “In validation” state.
- One suggestion-case policy owns rendering and insertion for typing, taps, autocorrection, and Glide. It preserves literal mixed case, applies lower/initial/all-caps style to corrections, handles English `I` contractions, and commits the exact displayed primary suggestion.
- The generated-suggestion safety policy contains 997 exact reviewed terms, including every one of the 804 recovered policy entries. It records English, Telugu, and Tenglish language IDs plus demote/suppress actions, while deliberate typed text and media-search queries remain uncensored. A reproducible CC-BY-4.0 corpus pass produced a separate review-only queue of 194 Telugu forms and 244 explicit Roman aliases; none ship without per-term native-speaker approval.
- The companion app has Language, integrated Appearance, Haptics, setup/health, privacy controls, a post-setup non-sticky 108-point rewards/theme carousel, StoreKit 2 entitlement handling, and explicit-interest offer settings. Commercial state is app-only, not in the keyboard App Group. Affiliate clicks, rewarded-theme verification, and cashback ledger reads now have server-authoritative interfaces with no keyboard-data parameters; no mock server is presented as production infrastructure.

## Policy Matrix

| Capability | Decision | Reason / implementation boundary |
|---|---|---|
| Ads in keyboard extension | Prohibited | Apple limits display ads to the main app and keyboard extensions may collect activity only to improve keyboard functionality. [App Review Guidelines 2.5.18 and 4.4.1](https://developer.apple.com/app-store/review/guidelines/) |
| Typed-text targeting | Prohibited | Typed text, host-app identity, touch signals, and keyboard usage never enter commercial models or requests. |
| Installed-app monitoring for offers | Prohibited | Apple expressly disallows collecting installed-app information for analytics or marketing. [App Review Guidelines 5.1.2](https://developer.apple.com/app-store/review/guidelines/) |
| StoreKit theme packs / premium | Allowed in companion app | StoreKit 2 provides signed transactions and entitlement APIs. [StoreKit 2](https://developer.apple.com/storekit/) |
| Rewarded-ad themes | Conditionally allowed in companion app | Require explicit opt-in, exact reward disclosure, server-side verification, and non-transferable in-app rewards. Cash, cryptocurrency, and gift cards cannot be ad rewards. [AdMob rewarded policy](https://support.google.com/admob/answer/7313578?hl=en) |
| Personalized coupons | Allowed with consent and minimization | Inputs are limited to explicit interests, saved merchants, offer searches, and confirmed prior offers. |
| Cashback | Separate regulated commerce system | An authenticated click and signed merchant/affiliate conversion postback must drive a server ledger. Keyboard events never establish purchase intent or conversion. |
| AdAttributionKit as purchase proof | Insufficient | It emits privacy-preserving campaign postbacks and conversion values subject to crowd-anonymity limits; it is not a user purchase receipt. [Apple postback documentation](https://developer.apple.com/documentation/adattributionkit/receiving-ad-attributions-and-postbacks) |
| iOS OEM/default-keyboard shortcut | None | iOS controls activation and host substitution. Pursue legitimate Android OEM preload or SDK licensing contracts instead. |

## Neural Checkpoint Record

Machine-readable records: `tools/lm/benchmarks/finetune_internal_eval_2026-07-19.json`, `tools/lm/benchmarks/qwen_repaired_eval_2026-07-19.json`, `tools/lm/benchmarks/internal_w8_artifact_manifest_2026-07-19.json`, `tools/lm/benchmarks/afda5_pairing_status_2026-07-19.json`, and the superseded historical record `tools/lm/benchmarks/qwen_checkpoint_preflight.json`.

| Decoder | Parameters | Messaging PPL | One-edit top-1/top-3 | Two-edit top-1/top-3 |
|---|---:|---:|---:|---:|
| Current n-gram | - | - | 80.4% / 97.6% | 73.2% / 84.8% |
| `finetune.pt`, fixed runtime blend | 10.60M | 53.74 | 84.4% / 99.2% | 78.4% / 85.2% |

Perplexity comes from the recorded English held-out run. Correction columns are fresh 250-case replays using summed whole-word scores, the runtime's fixed 0.7 neural/0.3 n-gram blend, fresh Witten-Bell, and a 32-row cap. They are PyTorch/CPU synthetic diagnostics, not production claims. One-edit CPU p50/p95 was 43.53/81.55 ms on this host; two-edit was 35.27/75.28 ms. The slices contain no already-correct inputs, so false-correction rate is unmeasurable. The two-edit candidate oracle is only 85.6%, proving that reranking alone cannot fix search-space loss.

A sweep on the same synthetic one-edit slice reached 88.4%/98.4% at weight 0.5 with length normalization. That result is test-tuned and is explicitly ineligible for promotion. The tokenizer contains no Telugu-script pieces, so `finetune.pt` must not score Telugu or Tenglish. **Do not bundle this checkpoint.**

An internal Core ML Tools 9 export produced a 10.83 MB W8 package and a 10.88 MB calibrated W8A8 package outside the repository and normal Release target. The graph contains 26 `constexpr_blockwise_shift_scale` INT8 weight-storage ops and 52 activation quantize/dequantize pairs. Independent verification retained 100% candidate top-1 agreement. The W8 scorer is now wired into Debug and explicit optimized `INTERNAL_NEURAL` builds with concrete runtime states, bounded batching, session cancellation, and memory-pressure unload. The optimized W8 extension is 24,154,838 bytes and passes the 25 MB artifact gate. This is packaging evidence only: W8A8 is calibrated PTQ, not the forthcoming QAT checkpoint, and no iPhone ANE, latency, energy, thermal, memory, or blind-quality gate has passed.

No superiority claim against `afda5b4` is permitted. That commit does not track its language-data or model artifacts, and the only discovered unversioned v4 binary is not logically equivalent to the current pack. The blocked comparison and exact missing evidence are recorded in `afda5_pairing_status_2026-07-19.json`.

Required branches:

1. Complete multilingual QAT from the approved fine-tune branch, then verify Core ML parity.
2. Train a 4-6M stateful GRU/LSTM and a 1-2 MB hashed pQRNN challenger.
3. Raise severe-typo oracle recall with NSS-lite candidate expansion before reranking.
4. Blind user-separated comparison of n-gram, W8, QAT W8A8, and recurrent challengers on identical candidates and hardware.

Core ML state is available from iOS 18 and uses registered model buffers plus `StateType`. [Core ML stateful models](https://apple.github.io/coremltools/docs-guides/source/stateful-models.html) W8A8 can use optimized int8-int8 Neural Engine compute on newer A17 Pro/M4-class hardware, but Apple warns that activation quantization can regress CPU/GPU performance; device-specific W8 versus W8A8 selection is mandatory. [Quantization overview](https://apple.github.io/coremltools/docs-guides/source/opt-quantization-overview.html), [performance guidance](https://apple.github.io/coremltools/docs-guides/source/opt-quantization-perf.html)

## Search Architecture

The next ceiling change is NSS-lite, not a larger post-hoc rescorer. The trie/FST must retain candidates using a joint spatial plus neural prefix score so severe candidates are not discarded before neural ranking. Gboard's Neural Search Space dynamically builds its FST from NN-LM output and reported locale-dependent WMR reductions in online experiments, but it also required FST redesign, pruning, and data-structure work. [Neural Search Space in Gboard Decoder](https://aclanthology.org/2024.emnlp-industry.93/)

Implementation sequence:

1. Freeze one model tier per word session and prepare context once.
2. Export an iOS 18 stateful next-token function; verify cache equivalence and MIL state operations.
3. Add a packed prefix-continuation graph with a bounded frontier, deterministic pruning, OOV fallback, and n-gram escape path.
4. Train the supplied linear ranker on real labels; calibrate correction thresholds separately for clean, real-word, and typo cases.
5. Run W8 and W8A8 on the physical matrix. Use W8A8 only on devices where measured latency, energy, and thermal behavior win.
6. Keep GNNs offline for confusion-edge discovery or vocabulary expansion; a runtime GNN duplicates the trie/FST graph at worse memory locality.

## Telugu Launch Plan

Tenglish preserves familiar QWERTY geometry. The current pack has weighted attested variants, bounded phonetic alternatives, Telugu and Roman tries, compact bi/trigram priors, safety metadata, provenance, and hashes. It is still a bootstrap rather than a production decoder: the transliteration search is not yet a compiled weighted FST, the context corpus contains only 318 sentences, and code-switch, name-preservation, and native-speaker benchmarks are absent. Native Telugu Beta provides literal composition, Unicode coverage, NFC normalization, grapheme-safe edits, VoiceOver labels, and conservative completion; autocorrection remains disabled until a balanced Telugu LM passes blind review. Gboard's expansion to hundreds of language varieties required language-specific engineering, operations, and user studies rather than vocabulary files alone. [Gboard internationalization](https://research.google/pubs/writing-across-the-worlds-languages-deep-internationalization-for-gboard-the-google-keyboard/)

The offline pipeline can compile the Aksharantar Telugu training split into a weighted, memory-mappable research lexicon while preserving the archive hash and source-dependent license notice. Aksharantar reports CC-BY for manually collected rows and CC0 for mined/existing rows. Validation and test members are rejected as pack-building input. [Aksharantar dataset and licensing](https://huggingface.co/datasets/ai4bharat/Aksharantar#licensing-information)

Full compiler smoke result: 2,429,539 accepted rows, 23 rejected rows, 150,000 Roman keys, 192,283 Telugu variants, and a 12,115,387-byte binary. The manifest and artifact hashes validated. This output remains under `/tmp` and has `release_status: research`; it was not added to either Xcode target.

Release order:

1. Native Telugu literal Beta and native-speaker layout review
2. Tenglish tap suggestions and explicit conversion, no unknown-name auto-conversion
3. Tenglish boundary conversion after false-transliteration gate
4. English/Tenglish code switching and mode override
5. Tenglish Glide: path -> Roman phonetic candidates -> transliteration FST -> Telugu LM
6. Native Telugu autocorrection and Glide only after native tap quality is stable

## Revenue Model

No valuation follows from checkpoint size. SwiftKey's reported roughly $250M acquisition followed distribution on more than 300M devices, while ClusterDev currently claims 40M+ active users and 100M+ downloads across its products. [SwiftKey report](https://techcrunch.com/2016/02/02/microsoft-is-acquiring-londons-ai-driven-swiftkey-for-250m/), [ClusterDev](https://clusterdev.com/)

Monthly formulas:

- Subscription net = `MAU * paid_conversion * net_monthly_receipt`
- Rewarded-ad net = `MAU * ad_opt_in * views_per_user / 1000 * net_eCPM`
- Affiliate net = `MAU * offer_click_rate * merchant_conversion * AOV * commission * (1 - returns_and_fraud)`
- OEM annual value = signed minimum guarantee + per-device royalty + paid engineering/support

Illustrative base case only, not a forecast: 1.5% paid conversion, INR 110 net monthly receipt, 10% rewarded-ad opt-in, 3 views/month, INR 120 net eCPM, 2% offer click rate, 4% merchant conversion, INR 1,200 AOV, 5% commission, and 10% returns/fraud reserve.

| MAU | Subscription ARR | Rewarded-ad ARR | Affiliate ARR | Total illustrative ARR |
|---:|---:|---:|---:|---:|
| 100k | INR 19.80 lakh | INR 0.43 lakh | INR 0.52 lakh | INR 20.75 lakh |
| 1M | INR 1.98 crore | INR 0.04 crore | INR 0.05 crore | INR 2.07 crore |
| 10M | INR 19.80 crore | INR 0.43 crore | INR 0.52 crore | INR 20.75 crore |

Sensitivity is dominated by retained MAU and paid conversion. Replace every assumption with observed cohort data before fundraising, hiring against revenue, or quoting a valuation. Cashback is excluded because its economics require merchant contracts, payment/KYC costs, working-capital hold periods, fraud loss, tax treatment, and support cost.

## OEM And Distribution

- iOS: App Store distribution only; optimize setup completion, activation, seven-day retention, and keyboard share of typing sessions. There is no legitimate default-keyboard bypass.
- Android: build after Tenglish quality is proven. Support IME lifecycle, low-RAM tiers, model download governance, and OEM-specific QA.
- OEM offer: Telugu/Tenglish decoder SDK, language-pack update tooling, benchmark harness, on-device privacy controls, and integration support. Require a minimum guarantee; avoid unpaid exclusivity and open-ended device customization.
- B2B targets: regional communication apps, fintech support/chat surfaces, education products, creator tools, and language-platform vendors.

## Release Gates

Implementation verification completed in this pass:

- 33 Python unit tests passed across safety preservation and review mining, inference/cache equivalence, tokenizer export, ranker behavior, paired evaluation, language-pack validation, corpus source caps, and Release artifact detection.
- Full v4/v5 comparison found every logical record identical and reduced language data by 52.8%.
- The repaired n-gram harness completed a 20-case smoke run, then a checkpoint-controlled 250-case replay of n-gram, pretrain, and distill with no forced-gold insertion. These remain synthetic diagnostics, not quality claims.
- The iOS app, keyboard extension, and Swift test target compiled with `build-for-testing`; all 73 Swift tests passed on an iPhone 17 simulator, including scalar/grapheme-safe Telugu rollback, non-empty Tenglish prediction fallbacks, the host-generated/extension-mapped emoji-atlas round trip, four-mode output, Telugu composition, severe correction, authoritative suggestion/commit, Glide agreement, and KBXL v1/v2/v3 compatibility paths.
- Apple Telugu was enabled as a system input mode in the simulator and its alphabetic, composition, long-press, and numeric states were captured as screenshot plus accessibility-frame attachments. The observed alphabetic layout has five glyph rows and no shift page; the project reproduces the functional arrangement using project styling rather than Apple artwork.
- A generic iOS Release build completed with code signing disabled. Archive inspection found the reviewed English, Telugu, Tenglish, safety, and emoji resources; no Core ML package, tokenizer, or checkpoint was bundled. The stripped no-neural extension is 13,591,620 bytes and passed the 14 MB artifact gate, leaving 408,380 bytes of headroom. The separately opted-in optimized W8 extension remains an older internal measurement and must be rebuilt before its size is quoted against the new language artifacts.
- No physical-device latency, memory, energy, thermal, accessibility, or sustained-typing gate was run.

| Gate | Threshold | Current status |
|---|---:|---|
| App-owned host insertion p99 | <= 1 ms | Instrumented; physical evidence missing |
| Suggestion p95 | <= 75 ms | Instrumented; release matrix missing |
| Neural stage p95 oldest device | <= 25 ms | No promoted package |
| Glide lift-to-insert p95 | <= 50 ms | Instrumented; representative test missing |
| Queue growth at 10 keys/s | zero | Not sustained-tested |
| Peak footprint | <= 70% measured kill threshold | Telemetry exists; physical kill threshold missing |
| Jetsam / 30-minute typing | zero | Not run |
| Candidate oracle | no regression | Real blind dataset missing |
| Accuracy | significant user-cluster gain | Real blind dataset missing |
| False correction / WMR | no regression | Real blind dataset missing |
| Tenglish | native-speaker pass by slice | Bootstrap only |
| Neural promotion | accuracy win with no latency, memory, energy, or Glide disagreement regression | Not met |

## Staged Go/No-Go

1. **Internal English alpha:** GO only after physical latency/memory gates and repaired baseline replay.
2. **Tenglish closed beta:** NO-GO until trained pack, code-switch set, native-speaker review, and unknown-name false-conversion gate pass.
3. **Paid acquisition:** NO-GO until D7/D30 retention, crash/jetsam rate, activation funnel, and blind quality beat the incumbent baseline.
4. **Rewarded themes:** NO-GO until app-only ad SDK review, consent/disclosure UX, server-side verification, entitlement recovery, and policy review pass.
5. **Cashback:** NO-GO until merchant postbacks, ledger, return hold, fraud review, KYC/tax/legal review, and payout partner are live.
6. **OEM outreach:** Discovery conversations are reasonable after Tenglish beta; commercial claims require measured MAU/retention and a reproducible SDK benchmark.
