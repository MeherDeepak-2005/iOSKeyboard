# Production Readiness and Gboard Gap Audit

**Audit date:** 2026-07-19  
**Decision:** **BLOCK PRODUCTION RELEASE**

This document is intentionally limited to defects, failure modes, production risks,
and the gap to publicly documented Gboard systems. It does not catalog features that
already work.

## Audit Limits

- This is a static source, asset, data-pipeline, and project-configuration audit.
- An unsigned `Release` build completed for a generic iOS device. Compilation does
  not validate extension-host behavior, touch latency, model latency, memory pressure,
  battery use, accuracy, accessibility, App Review compliance, or device compatibility.
- No simulator or physical-device profiling was performed for this report.
- Gboard comparisons use only published Google research and official product material.
  They do not claim that every paper describes every current Gboard binary or platform.
- Statements marked **proven** follow directly from source or bundled artifacts.
  Statements marked **unmeasured risk** require physical-device or representative-user
  evidence before release.

## Severity

| Level | Meaning |
|---|---|
| **P0** | Release blocker: security, privacy, legal, data-loss, accessibility, or core typing correctness risk. |
| **P1** | Major user failure: wrong text, lag, inconsistent decoding, unusable layout, or repeated trust loss. |
| **P2** | Material quality or efficiency defect that prevents a credible Gboard comparison. |
| **P3** | Product debt that makes the app feel incomplete, confusing, or expensive to maintain. |

## Executive Failure Summary

The project is not close to a defensible Gboard comparison. The largest gap is not one
model weight or one visual theme. It is the absence of a unified, measured production
system. Tap suggestions, boundary autocorrect, severe-typo recovery, previous-word
rewriting, and Glide use different candidate pools, score transforms, model tiers, and
timing. The user can therefore receive different answers from the same evidence merely
because a 60 ms timer, a lock, a Core ML load, or a background pass finished at a
different moment.

The product also has release blockers unrelated to language quality: a plaintext API
credential, no in-app privacy policy, no privacy manifest, persistent sensitive
clipboard storage without retention controls, public logging of typed text, an app icon
catalog with no images, no third-party license inventory, inaccessible custom key views,
and a reset operation that does not reliably reset the running model.

Gboard's published work describes a context-aware FST search space, neural language
information integrated into decoding, spatial models calibrated with representative
real-user behavior, federated language-model training with differential privacy, and
online deployment experiments. This project has a hand-built trie/DTW pipeline, a
pretraining-stage neural model used only after a crude candidate cap, 67 captured Glide
records, and synthetic typo tests generated from the same assumptions as the decoder.
There is no evidence that it beats the existing company keyboard, much less Gboard.

## P0 Release Blockers

### 1. Shipped API Credential

**What's wrong:** A KLIPY API key is embedded as plaintext in the extension's
`Info.plist`. An app bundle is not a secret store; anyone can extract the key from an
IPA. The client also places it in the request URL path.

**User failure:** Abuse of the credential can exhaust quota, disable GIF search, expose
users to service outages, or create billing and moderation incidents unrelated to their
actions.

**Production failure:** The key must be considered compromised as soon as a build is
distributed. There is no server-side token exchange, attestation, key rotation path, or
abuse isolation per app release.

**Evidence:** [demo_keyboard/Info.plist:5](demo_keyboard/Info.plist#L5),
[KBKlipy.swift:50](keyboard/Shared/KBKlipy.swift#L50).

### 2. Privacy and App Review Compliance Is Not Implemented

**What's wrong:** The repository contains no `PrivacyInfo.xcprivacy`, no in-app privacy
policy link, no data-retention explanation, no consent/withdrawal flow, and no user-facing
inventory of data written to the App Group or sent to KLIPY. The keyboard requests Full
Access unconditionally.

**User failure:** A keyboard handles highly sensitive text. Asking for Full Access while
offering no precise disclosure creates immediate abandonment and makes every clipboard,
network, and personalization feature look unsafe.

**Production failure:** Apple requires keyboard extensions to remain functional without
Full Access, limits collection of keyboard activity, and requires an accessible privacy
policy with collection, use, retention, deletion, and third-party handling disclosures.
The repository cannot produce a complete app privacy report for its own behavior.

**Evidence:** [demo_keyboard/Info.plist:15](demo_keyboard/Info.plist#L15),
[ContentView.swift:51](keyboard/App/ContentView.swift#L51). See Apple's
[App Review Guidelines 4.4.1 and 5.1.1](https://developer.apple.com/app-store/review/guidelines/),
[privacy manifest documentation](https://developer.apple.com/documentation/bundleresources/privacy-manifest-files),
and [open-access keyboard guidance](https://developer.apple.com/documentation/uikit/configuring-open-access-for-a-custom-keyboard).

### 3. Clipboard History Can Persist Sensitive Text Indefinitely

**What's wrong:** Up to 50 unpinned and 10 pinned entries, each up to 10,000 characters,
are stored as plaintext JSON in the shared container. There is no expiry, sensitive-data
detection, data-protection policy, per-item lifetime, clear-all control, or automatic
suppression for OTPs, passwords, payment data, addresses, and health text.

**User failure:** Opening the clipboard panel can retain information the user expected to
be ephemeral. Anyone with device access, a backup, or another process entitled to the App
Group can encounter stale secrets.

**Production failure:** A keyboard cannot claim data minimization while retaining broad
clipboard contents indefinitely. The capture code marks a pasteboard change as consumed
before confirming it successfully read and saved a valid string, so a failed read also
silently loses the item.

**Evidence:** [KBClipboard.swift:17](keyboard/Shared/KBClipboard.swift#L17),
[KBClipboard.swift:32](keyboard/Shared/KBClipboard.swift#L32),
[KeyboardViewController.swift:243](demo_keyboard/KeyboardViewController.swift#L243).

### 4. Typed Text Can Be Written to Public Logs

**What's wrong:** Verbose diagnostics logs contexts, typed words, suggestions, Glide
candidates, and autocorrect decisions with `privacy: .public`. Debug builds default
verbose logging to enabled. A persisted preference can also outlive the workflow that
enabled it.

**User failure:** Private messages, names, medical terms, work information, and fragments
near the cursor can appear in Console logs or diagnostic exports.

**Production failure:** A keyboard cannot treat user text as public telemetry. Debug-only
UI does not make the shared logging implementation safe, and there is no redaction,
sampling, expiry, consent record, or build-time assertion that release logging is inert.

**Evidence:** [KBDiagnostics.swift:46](keyboard/Shared/KBDiagnostics.swift#L46),
[KBDiagnostics.swift:70](keyboard/Shared/KBDiagnostics.swift#L70),
[KBDiagnostics.swift:88](keyboard/Shared/KBDiagnostics.swift#L88).

### 5. "Reset Learned Words" Does Not Reliably Reset the Active Keyboard

**What's wrong:** The companion app deletes `kb_model.json`, but the process-wide
`KeyboardEngine.shared` keeps the loaded `UserModel` in memory. A pending coalesced save
can recreate the deleted file. The reset also does not clear static-word boosts,
session-kept words, pending corrections, recent controller corrections, clipboard data,
diagnostics, statistics, emoji recents, or the KLIPY customer identifier.

**User failure:** Words the user explicitly asked to forget can continue influencing
suggestions and can reappear after deletion. This is a false privacy control.

**Production failure:** Deletion has no cross-process protocol, acknowledgement,
generation number, or atomic "reset all personalization" transaction.

**Evidence:** [ContentView.swift:147](keyboard/App/ContentView.swift#L147),
[Keyboardengine.swift:161](keyboard/Engine/Keyboardengine.swift#L161),
[Keyboardengine.swift:145](keyboard/Engine/Keyboardengine.swift#L145).

### 6. Core Keys Are Not Accessible Controls

**What's wrong:** Letter keys are plain `UIView` instances with interaction disabled.
The parent performs custom hit testing but does not expose each virtual key as a
`UIAccessibilityElement`, accessibility action, label, trait, or frame. The source has
no VoiceOver implementation for the typing deck.

**User failure:** VoiceOver, Switch Control, Voice Control, and other assistive input
users cannot reliably discover or activate the keyboard. Several secondary controls are
also only 28-34 pt.

**Production failure:** This is not a cosmetic accessibility gap; the primary product
surface is unavailable. Apple's default iOS control size is 44x44 pt, and custom elements
must provide accessibility semantics.

**Evidence:** [KeyButton.swift:5](keyboard/Views/KeyButton.swift#L5),
[KeyButton.swift:43](keyboard/Views/KeyButton.swift#L43),
[SuggestionBar.swift:20](keyboard/Views/SuggestionBar.swift#L20),
[ClipboardPanel.swift:113](keyboard/Views/ClipboardPanel.swift#L113). See Apple's
[UIKit accessibility guidance](https://developer.apple.com/documentation/uikit/accessibility-for-uikit)
and [HIG accessibility guidance](https://developer.apple.com/design/human-interface-guidelines/accessibility).

### 7. The Main Thread Still Performs Fuzzy Search and Can Wait on a Shared Lock

**What's wrong:** When the 60 ms background pass has not published a matching pending
decision, pressing a boundary performs `lexicon.corrections` synchronously in
`autocorrection`. That method holds one `NSLock` across both the dynamic trie and the
entire 60,101-word mmap trie DP. Background suggestions use the same locked method.

**User failure:** Space, punctuation, or Return can pause behind a background fuzzy
search. Fast users experience delayed boundaries, dropped rollovers, or text appearing
in bursts.

**Production failure:** The old "never block main on the keystroke path" invariant is no
longer true. A comment estimating approximately 1 ms is not a bound, and lock contention
turns it into an unbounded wait relative to the UI frame budget.

**Evidence:** [Keyboardengine.swift:224](keyboard/Engine/Keyboardengine.swift#L224),
[Keyboardengine.swift:242](keyboard/Engine/Keyboardengine.swift#L242),
[Lexicon.swift:140](keyboard/Engine/Lexicon.swift#L140).

### 8. The Neural Model Is a Pretraining Artifact, Not a Validated Keyboard Model

**What's wrong:** The bundled 10.6M-parameter model is explicitly marked `pretrain`; it
is not the completed Qwen distillation, messaging fine-tune, or QAT checkpoint. Export
parity proves conversion fidelity, not language quality. The repository itself states
that on-device latency and final autocorrect accuracy are unproven.

**User failure:** Enabling the model can reorder a correct candidate into a wrong one,
change behavior after lazy loading, disappear under memory pressure, or add delay without
demonstrated benefit.

**Production failure:** There is no release-quality typo benchmark, calibration set,
false-correction evaluation, subgroup analysis, or physical-device model gate.

**Evidence:** [tools/lm/README.md:17](tools/lm/README.md#L17),
[tools/lm/README.md:46](tools/lm/README.md#L46),
[coreml_export_manifest.json](tools/lm/coreml_export_manifest.json).

### 9. Distribution Rights and Attributions Cannot Be Proven

**What's wrong:** The repository has no `LICENSE`, `NOTICE`, attribution manifest, source
version lock, or redistribution record for FrequencyWords/OpenSubtitles-derived data,
SMS and dialogue corpora, Leipzig data, safety lists, the supplied model checkpoint, or
the tokenizer.

**User failure:** Users can lose the product or updates after a legal complaint or store
removal; language data may also be impossible to reproduce or audit.

**Production failure:** A production binary cannot ship third-party corpora and weights
on the assumption that source URLs imply redistribution rights. The dictionary download
uses a mutable branch URL without a checksum.

**Evidence:** [build_language_data.py:38](tools/build_language_data.py#L38),
[build_language_data.py:57](tools/build_language_data.py#L57),
[tools/lm/README.md:10](tools/lm/README.md#L10). No license or notice file exists in
the audited repository.

### 10. Release Assets Are Incomplete

**What's wrong:** `AppIcon.appiconset` contains three metadata entries but no filenames
and no image files. There is no localization catalog. Product identifiers still use
`swiftuimasterclass`, and the extension product remains `demo_keyboard`-derived.

**User failure:** The app presents as unfinished or generic, and all non-English system
users receive hardcoded English UI despite the product advertising future language
support.

**Production failure:** Missing icons and placeholder/incomplete metadata are App Store
completeness failures. Test targets require iOS 18.6 while the product claims iOS 17,
so the oldest supported OS is not covered by the configured tests.

**Evidence:** [AppIcon Contents.json](keyboard/Assets.xcassets/AppIcon.appiconset/Contents.json),
[project.pbxproj:617](keyboard.xcodeproj/project.pbxproj#L617),
[project.pbxproj:699](keyboard.xcodeproj/project.pbxproj#L699).

### 11. Apple Emoji Artwork Is Rasterized Into a Persistent Atlas

**What's wrong:** The companion app renders system emoji glyphs into a raw RGBA file and
the extension maps that file as an image atlas. This creates a persistent copy of Apple
Color Emoji artwork rather than merely inserting Unicode text.

**User failure:** The emoji panel can disappear or be removed late in review if the asset
strategy is rejected, and visual output can become stale after an OS artwork change.

**Production failure:** Apple's review guidelines state that third-party keyboards may
not include Apple emoji. Whether on-device rasterization is accepted must be resolved
with App Review/legal before release; it cannot be assumed safe. The atlas can also be
tens of megabytes at 3x scale.

**Evidence:** [Emoji.swift:159](keyboard/Views/Emoji.swift#L159),
[Emoji.swift:265](keyboard/Views/Emoji.swift#L265),
[ContentView.swift:117](keyboard/App/ContentView.swift#L117). See
[App Review Guideline 5.2.5](https://developer.apple.com/app-store/review/guidelines/).

## Companion App UX Failures

### Information Architecture and Onboarding

| What's wrong | User-end failure | Production/Gboard gap | Evidence |
|---|---|---|---|
| The first item is a 78 pt achievements banner, ahead of keyboard activation, privacy, and health. | New users are asked to care about a league before the keyboard is enabled or trusted. | Activation and recovery are the product funnel; gamification is unrelated to first value and consumes the strongest hierarchy. | [ContentView.swift:51](keyboard/App/ContentView.swift#L51) |
| Setup state is a sticky `hasUsedKeyboard` Boolean set after one host connection. | If the keyboard is later disabled, removed, or loses Full Access, onboarding stays hidden. | iOS does not expose a reliable enabled-state API, so a permanent Boolean cannot represent current health. | [KBSettings.swift:262](keyboard/Shared/KBSettings.swift#L262), [KeyboardViewController.swift:204](demo_keyboard/KeyboardViewController.swift#L204) |
| Full Access state is only the last value observed by the extension. | The app can display stale access state and wrong guidance until the keyboard is opened again. | There is no timestamp, "unknown" state, or explicit refresh handshake. | [KBSettings.swift:268](keyboard/Shared/KBSettings.swift#L268) |
| There is no persistent Setup, Troubleshooting, Privacy, Data, Support, or About destination. | Returning users cannot recover from the common "keyboard missing," "haptics missing," "Full Access off," or fallback-to-system-keyboard failures. | A production keyboard needs an operational support path because extension failures are often silent to users. | [ContentView.swift:51](keyboard/App/ContentView.swift#L51) |
| Tenglish and Telugu are visible but disabled as "Coming soon." | The main settings surface advertises unavailable functionality and feels unfinished. | Placeholder features are an App Review completeness risk and offer no competitive language value. | [KBSettings.swift:5](keyboard/Shared/KBSettings.swift#L5), [ContentView.swift:179](keyboard/App/ContentView.swift#L179) |
| Setting changes have no "applies next time," restart, or live-state feedback. | Users change a theme/model setting, return to the keyboard, and may see old process-cached state. | App Group values do not automatically rebuild an already-running extension. | [KBSettings.swift:207](keyboard/Shared/KBSettings.swift#L207), [KeyboardViewController.swift:101](demo_keyboard/KeyboardViewController.swift#L101) |

### Appearance and Theme Studio

| What's wrong | User-end failure | Production/Gboard gap | Evidence |
|---|---|---|---|
| Theme Studio combines preset selection, five editable roles, a gradient stop picker, hue grid, shades, a color picker, photos, and a manual dark toggle in one long form. | The page has high decision cost and no clear "choose a theme" versus "advanced editor" path. | A production theme flow needs safe presets first and progressive disclosure; this exposes implementation roles directly. | [ThemeStudioView.swift:29](keyboard/App/ThemeStudioView.swift#L29) |
| Every edit saves immediately; there is no Apply, Cancel, Undo, Reset, draft, or before/after state. | Accidental taps permanently alter the live keyboard, and users cannot recover a prior design. | Production customization needs transactional state and reversible edits. | [ThemeStudioView.swift:202](keyboard/App/ThemeStudioView.swift#L202), [ThemeStudioView.swift:225](keyboard/App/ThemeStudioView.swift#L225) |
| The preset carousel flattens `KBPalette.all`, discarding the declared color groups. | Users cannot scan by light/dark suitability or color family despite the data model claiming categories. | The requested palette segregation is not represented in the actual page. | [ThemeStudioView.swift:121](keyboard/App/ThemeStudioView.swift#L121), [KBSettings.swift:127](keyboard/Shared/KBSettings.swift#L127) |
| Custom themes have one manual `dark` Boolean, not paired light/dark variants. | A theme can be readable in one system appearance and unusable after automatic appearance changes. | Mature keyboard themes adapt roles and contrast per appearance, not by one user-authored flag. | [KBSettings.swift:195](keyboard/Shared/KBSettings.swift#L195), [ThemeStudioView.swift:90](keyboard/App/ThemeStudioView.swift#L90) |
| The preview is a simplified SwiftUI imitation, not the actual keyboard component. | Users approve a design that changes geometry, suggestion-strip behavior, globe/emoji controls, typography, transparency, and image crop when used for real. | A production editor needs the same rendering contract as the extension across device sizes and appearances. | [ThemeStudioView.swift:321](keyboard/App/ThemeStudioView.swift#L321) |
| Arbitrary colors are accepted without contrast validation or repair. | Text, icons, selection shading, and action labels can become unreadable. | The luminance helper uses weighted encoded sRGB values without linearization and is not a WCAG/APCA contrast test. | [KeyboardTheme.swift:77](keyboard/Views/KeyboardTheme.swift#L77), [ThemeStudioView.swift:218](keyboard/App/ThemeStudioView.swift#L218) |
| Photo themes have no crop, focal-point, blur, exposure, scrim, or per-orientation controls. | Faces and meaningful content are cropped unpredictably; key legends disappear over high-frequency imagery. | One 980 px downscale cannot serve portrait, landscape, and iPad keyboard bounds consistently. | [ThemeStudioView.swift:273](keyboard/App/ThemeStudioView.swift#L273), [Keyboard.swift:167](keyboard/Views/Keyboard.swift#L167) |

### Fonts

**What's wrong:** The code retains `KBFont`, custom-family names, and a persisted font
preference, but the settings UI no longer exposes it and every stock/custom
`KeyboardTheme` forces `.system`. More importantly, an iOS keyboard extension inserts
Unicode text through `textDocumentProxy`; it cannot force the host app's text font.

**User failure:** A "font" feature would only change key legends, not sent text, so users
would experience it as deceptive. The remaining dormant code suggests a capability the
platform does not provide.

**Production/Gboard gap:** This should not be presented as text styling. Rich stylized
Unicode substitutions are not fonts, harm search/accessibility, and fail across scripts.
There is no safe permanent-font workaround controlled by a system keyboard.

**Evidence:** [KBSettings.swift:36](keyboard/Shared/KBSettings.swift#L36),
[KBSettings.swift:253](keyboard/Shared/KBSettings.swift#L253),
[KeyboardTheme.swift:20](keyboard/Views/KeyboardTheme.swift#L20).

### Achievements and Statistics

| What's wrong | User-end failure | Production/Gboard gap | Evidence |
|---|---|---|---|
| Stats count a committed word before the user has accepted or corrected it. Undo and later correction do not reliably decrement totals. | Leagues, streaks, tap/glide ratios, and trophies are based on guesses rather than trusted actions. | Gamification built on inaccurate instrumentation destroys trust instead of retention. | [KeyboardViewController.swift:394](demo_keyboard/KeyboardViewController.swift#L394), [KBStats.swift:161](keyboard/Shared/KBStats.swift#L161) |
| `flush()` loads, decodes, mutates, encodes, and writes App Group data on the main thread every ten words. | Every tenth boundary can hitch, especially with slow shared-container I/O. | Nonessential gamification work competes with the latency-critical keyboard path. | [KBStats.swift:156](keyboard/Shared/KBStats.swift#L156) |
| Day formatting uses one static formatter while streak calculations accept another calendar. | Time-zone or locale changes can split counts and streaks across inconsistent day keys. | Production analytics requires one explicit calendar/time-zone policy and migration. | [KBStats.swift:105](keyboard/Shared/KBStats.swift#L105), [KBStats.swift:120](keyboard/Shared/KBStats.swift#L120) |
| Trophy requirement text exists in `KBTrophy.detail` but is never shown in the trophy grid. | Locked trophies do not explain how to earn them. Four columns also compress long names. | The page creates opaque goals from unreliable counts and consumes product hierarchy without improving typing. | [KBStats.swift:80](keyboard/Shared/KBStats.swift#L80), [AchievementsView.swift:200](keyboard/App/AchievementsView.swift#L200) |

## Keyboard UI and Interaction Failures

### Layout Geometry and Muscle Memory

| What's wrong | User-end failure | Production/Gboard gap | Evidence |
|---|---|---|---|
| One fixed layout uses 45 pt rows, 6 pt key gaps, 8 pt row gaps, and four rows on every iPhone/iPad size and orientation. | Keys stretch horizontally on iPad and landscape while staying short vertically; familiar target locations and thumb travel change by host. | There are no phone landscape, iPad, compact, split, one-handed, or accessibility layouts. | [Keyboard.swift:122](keyboard/Views/Keyboard.swift#L122), [Keyboard.swift:551](keyboard/Views/Keyboard.swift#L551) |
| The visual A row is centered by half a key pitch, but the spatial model encodes 0.25 pitch. The visual Z row begins after a 1.5-pitch shift key, but the model encodes 0.75 pitch. | The decoder scores the wrong intended touch locations. Users are penalized even when they hit the visible key centers. | Gboard's published spatial work adapts key-center offsets and covariance from representative real behavior; this project starts from internally inconsistent geometry. | [Keyboard.swift:551](keyboard/Views/Keyboard.swift#L551), [SpatialModel.swift:10](keyboard/Engine/SpatialModel.swift#L10), [Gboard spatial personalization](https://research.google/pubs/spatial-model-personalization-in-gboard/) |
| Tap hit testing chooses the nearest key across every row, then applies stale prefix priors near edges and gaps. | A vertical gap tap can resolve to an unexpected row; an old prefix can pull the target toward the wrong letter after the user has already typed on. | Target resizing is driven by static trie subtree frequency, not current contextual decoding confidence. | [Keyboard.swift:955](keyboard/Views/Keyboard.swift#L955), [Lexicon.swift:166](keyboard/Engine/Lexicon.swift#L166) |
| Glide maps points through a nearest-key-relative coordinate transform. Because visual and model row offsets differ, the mapping is piecewise and can jump at nearest-key boundaries. | A smooth physical stroke becomes a discontinuous model path, especially between rows. | The shape decoder is trained/tuned in a coordinate system that does not faithfully represent the UI. | [GlidePath.swift:105](keyboard/Engine/GlidePath.swift#L105), [SpatialModel.swift:35](keyboard/Engine/SpatialModel.swift#L35) |
| Browsing emoji or media adds 96 pt to keyboard height. | Host content jumps when panels open and closes; short fields can be obscured. | A keyboard extension should keep stable geometry unless a validated workflow requires expansion. | [Keyboard.swift:147](keyboard/Views/Keyboard.swift#L147) |

### Visual System, Transparency, and Color

| What's wrong | User-end failure | Production/Gboard gap | Evidence |
|---|---|---|---|
| The stock deck and controller are fully clear; there is no owned material or deterministic fallback surface. | Appearance depends on the host/system backing layer and can become black, muddy, overly transparent, or low contrast. | `clear` is not blur or glass. A custom extension cannot assume every host composites the same material behind it. | [KeyboardTheme.swift:26](keyboard/Views/KeyboardTheme.swift#L26), [KeyboardViewController.swift:85](demo_keyboard/KeyboardViewController.swift#L85) |
| The design does not react to Reduce Transparency, Increase Contrast, Differentiate Without Color, or Bold Text. | Users who explicitly request stronger legibility can receive the least legible version. | System appearance support is reduced to light/dark only. | [KeyboardTheme.swift:20](keyboard/Views/KeyboardTheme.swift#L20) |
| `accentSoft` is documented as a lighter tint of the action accent but is actually neutral translucent white in stock themes. | Shift/delete do not visually belong to the action palette, contradicting the intended shade system. | The HSL/role relationship requested by the design is absent from runtime color derivation. | [KeyboardTheme.swift:9](keyboard/Views/KeyboardTheme.swift#L9), [KeyboardTheme.swift:37](keyboard/Views/KeyboardTheme.swift#L37) |
| The action key is a full diagonal gradient while all other roles are flat. | It visually dominates every host field, even when Return is a secondary action. | There is no tonal-role system that derives action, soft action, special, pressed, and selected states from one perceptual palette. | [KeyButton.swift:53](keyboard/Views/KeyButton.swift#L53) |
| Primary suggestion shading is fixed white alpha. | The highlight can wash out light themes and look like a disabled patch in dark/photo themes. | Selection contrast is not computed from the actual surface beneath it. | [SuggestionBar.swift:26](keyboard/Views/SuggestionBar.swift#L26) |
| Popups are generic rounded rectangles without a key-anchored tail and are constrained to extension bounds. | Press feedback looks detached from the key and can clip near edges. | The feedback does not preserve the visual relationship between finger, key, and enlarged glyph. | [Keyboard.swift:582](keyboard/Views/Keyboard.swift#L582) |

### Touch Semantics, Feedback, and Controls

| What's wrong | User-end failure | Production/Gboard gap | Evidence |
|---|---|---|---|
| Normal keys commit on lift, not touch-down. Rollover tries to commit held touches when another touch begins, but both `touches` and `pendingCommit` are sets with no order guarantee. | Fast overlapping taps can insert later than expected or in nondeterministic order. | The code comment promises press order without storing a press sequence. | [Keyboard.swift:722](keyboard/Views/Keyboard.swift#L722), [Keyboard.swift:759](keyboard/Views/Keyboard.swift#L759) |
| Once one touch is classified as Glide, other fingers are ignored. | A second thumb press during or near a swipe disappears. | Multitouch is advertised in code but disabled during a common interaction state. | [Keyboard.swift:759](keyboard/Views/Keyboard.swift#L759) |
| Shift cycles Off -> On -> Caps Lock -> Off on consecutive single taps. | A user trying to toggle shift twice can accidentally lock caps; this conflicts with the learned double-tap caps-lock convention. | Familiar platform behavior is replaced with a hidden state machine. | [Keyboard.swift:1041](keyboard/Views/Keyboard.swift#L1041) |
| The globe only calls `advanceToNextInputMode`; it does not use `handleInputModeList(from:with:)` for long-press selection. | Users cannot open the system keyboard picker from the custom key and must cycle blindly. | Apple explicitly recommends wiring all touch events to `handleInputModeList`. | [KeyboardViewController.swift:116](demo_keyboard/KeyboardViewController.swift#L116), [Apple custom keyboard guidance](https://developer.apple.com/documentation/uikit/creating-a-custom-keyboard) |
| The keyboard can show both a custom globe/emoji control and system controls below the extension depending on device behavior. | Duplicate or shifting mode controls waste the bottom row and confuse switching. | Apple warns against duplicating system-provided Emoji/Globe controls. | [Keyboard.swift:1034](keyboard/Views/Keyboard.swift#L1034), [Apple virtual keyboard HIG](https://developer.apple.com/design/human-interface-guidelines/virtual-keyboards) |
| Haptics are one generic light impact triggered at touch begin, with no verification that feedback was possible. The setting can read On while users feel nothing. | Users report a broken setting; there is no sound-click alternative or per-action distinction. | There is no runtime capability/status feedback, system-setting adaptation, or device acceptance test. | [Keyboard.swift:69](keyboard/Views/Keyboard.swift#L69), [Keyboard.swift:769](keyboard/Views/Keyboard.swift#L769), [ContentView.swift:77](keyboard/App/ContentView.swift#L77) |
| Updating the host return-key title rebuilds every key view. | Entering a field can cause avoidable allocations, layout churn, and touch-state invalidation. | Only the action key's label/state should change. | [Keyboard.swift:237](keyboard/Views/Keyboard.swift#L237), [KeyboardViewController.swift:306](demo_keyboard/KeyboardViewController.swift#L306) |
| The action key maps the label but not `enablesReturnKeyAutomatically` or an enabled/disabled state. | "Search," "Send," or "Next" can look actionable when the host intends it disabled. | Context customization is partial styling, not complete host-trait behavior. | [KeyboardViewController.swift:306](demo_keyboard/KeyboardViewController.swift#L306) |
| Number and symbol pages are fixed generic layouts. | Email, URL, decimal, phone, and locale-specific fields do not get the expected punctuation or decimal separator. | The code hides suggestions for field types but does not provide specialized key layouts for them. | [Keyboard.swift:1055](keyboard/Views/Keyboard.swift#L1055), [KeyboardViewController.swift:276](demo_keyboard/KeyboardViewController.swift#L276) |
| There are no long-press accents, alternate punctuation, cursor control, text editing mode, or locale-specific variants. | Names and non-English words are slower or impossible to type naturally. | The UI exposes a basic QWERTY grid while Gboard's product surface covers mature editing and multilingual workflows. | [Keyboard.swift:1019](keyboard/Views/Keyboard.swift#L1019) |

### Suggestion Strip UX

| What's wrong | User-end failure | Production/Gboard gap | Evidence |
|---|---|---|---|
| The strip is only 34 pt high and loses 34 pt to a clipboard button. | Three long candidates are cramped; the controls are below the default 44 pt iOS target. | Dense output is prioritized over readability and accessibility. | [Keyboard.swift:125](keyboard/Views/Keyboard.swift#L125), [SuggestionBar.swift:20](keyboard/Views/SuggestionBar.swift#L20) |
| The middle highlight is based on prefix/length heuristics, not calibrated correction confidence. Equal-length unrelated words can be highlighted. | The UI implies "pressing space will choose this" when the boundary decoder may choose another word or no correction. | Visual confidence is disconnected from the actual commit decision. | [SuggestionBar.swift:157](keyboard/Views/SuggestionBar.swift#L157) |
| An exact emoji match forcibly replaces the third-ranked word. | Correction top-3 recall is reduced precisely when a user needs alternatives. | Emoji and language candidates compete without a learned utility model or separate affordance. | [Keyboardengine.swift:986](keyboard/Engine/Keyboardengine.swift#L986) |
| Glide preview disables all three buttons and shows only a winner. | Users cannot inspect or choose alternatives until after insertion. | Live feedback is a single unstable guess rather than an actionable decode state. | [SuggestionBar.swift:87](keyboard/Views/SuggestionBar.swift#L87) |
| Suggestion visibility is resolved once per controller lifetime and not reset in `viewWillAppear`. | Reusing the extension across host fields can leave the strip visible or hidden for the wrong field type. | Avoiding flicker was traded for stale field state. | [KeyboardViewController.swift:170](demo_keyboard/KeyboardViewController.swift#L170), [KeyboardViewController.swift:290](demo_keyboard/KeyboardViewController.swift#L290) |

## Text Engine Correctness Failures

### Suggestions and Autocorrect Are Different Decoders

**What's wrong:** The suggestion bar and the boundary autocorrect do not rank the same
candidate set under the same score. Suggestions mix prefix completions with a filtered
subset of corrections, suppress non-prefix injected candidates when any completion
exists, use compressed frequency, and may replace slot three with emoji. Boundary
autocorrect considers all corrections, uses raw frequency, has different gates, and can
use either fast n-gram or full neural scoring.

**User failure:** The middle suggestion can say "suggestion" while Space commits
"season," or a delayed pass can later change the pending correction to "should." The
behavior depends on timing rather than intent.

**Production failure:** There is no immutable decode result shared by UI and commit.
Correctness cannot be reasoned about or tested as one contract.

**Evidence:** [Keyboardengine.swift:915](keyboard/Engine/Keyboardengine.swift#L915),
[Keyboardengine.swift:961](keyboard/Engine/Keyboardengine.swift#L961),
[Keyboardengine.swift:983](keyboard/Engine/Keyboardengine.swift#L983),
[Keyboardengine.swift:1042](keyboard/Engine/Keyboardengine.swift#L1042).

### Pending Corrections Are Underspecified and Timing-Dependent

**What's wrong:** `PendingCorrection` stores only lowercase word and optional correction.
It omits context, taps, document revision, cursor/field identity, generation, candidate
set, scorer tier, and model residency. The background pass first publishes a fast
n-gram answer, then overwrites it with a full answer after context injection and neural
ranking.

**User failure:** Typing the same word in a different sentence or field can consume a
decision computed from old context. Pressing Space before versus after the neural pass
can commit a different word.

**Production failure:** Word equality is not sufficient cache identity. The early/late
upgrade explicitly makes behavior nondeterministic at human typing speeds.

**Evidence:** [Keyboardengine.swift:126](keyboard/Engine/Keyboardengine.swift#L126),
[Keyboardengine.swift:931](keyboard/Engine/Keyboardengine.swift#L931),
[Keyboardengine.swift:991](keyboard/Engine/Keyboardengine.swift#L991).

### Fixed Debounce Adds Latency and Does Not Guarantee Coalescing

**What's wrong:** Every suggestion request waits 60 ms before engine work begins. The
serial engine can then perform fuzzy search, context-injection beam search, a broad
search, and Core ML scoring. Generation checks can skip queued work but cannot interrupt
an active Core ML prediction.

**User failure:** Fast typing shows stale or blank suggestions. A boundary arrives before
the pending decision and falls into synchronous main-thread search. Slow typing may see
the bar reorder after a visible delay.

**Production failure:** A fixed timer is not a latency budget. No scheduler accounts for
current queue depth, model residency, device speed, thermal state, or time remaining
before likely boundary input.

**Evidence:** [KeyboardViewController.swift:846](demo_keyboard/KeyboardViewController.swift#L846),
[Keyboardengine.swift:810](keyboard/Engine/Keyboardengine.swift#L810),
[Keyboardengine.swift:938](keyboard/Engine/Keyboardengine.swift#L938).

### The Keystroke Path Is Not "Insert Only"

**What's wrong:** A normal character performs proxy timestamping, correction/glide
acceptance bookkeeping, erase tracking, tap-buffer mutation, `documentContextBeforeInput`
reads, double-space logic, auto-shift analysis, and suggestion scheduling. A boundary
adds synchronous correction, multiple proxy deletions/inserts, learning, stats, and
previous-word rescoring setup.

**User failure:** The amount of work varies sharply by character. Space and punctuation
feel heavier than letters, and host proxy latency is multiplied by repeated reads and
deletes.

**Production failure:** There are no signposts around each owned stage and no p50/p95/p99
device measurements. Claims of sub-millisecond behavior are unsupported.

**Evidence:** [KeyboardViewController.swift:361](demo_keyboard/KeyboardViewController.swift#L361),
[KeyboardViewController.swift:394](demo_keyboard/KeyboardViewController.swift#L394),
[KeyboardViewController.swift:641](demo_keyboard/KeyboardViewController.swift#L641).

### Previous-Word Rescue Rewrites Committed Text Asynchronously

**What's wrong:** After a word boundary, an asynchronous neural pass may delete and
reinsert `previous current ` behind the cursor. Candidate pre-gating keeps only up to
three neighbors that are globally more frequent than the existing word.

**User failure:** Text the user already saw and accepted can change later. Cursor,
selection, host transformations, marked text, undo stacks, and collaborative editors can
interact badly with repeated `deleteBackward` calls.

**Production failure:** The pre-gate excludes rarer but context-correct alternatives, so
the feature is both intrusive and incomplete. Tail-string equality is not a document
transaction or revision lock.

**Evidence:** [KeyboardViewController.swift:447](demo_keyboard/KeyboardViewController.swift#L447),
[Keyboardengine.swift:753](keyboard/Engine/Keyboardengine.swift#L753),
[Keyboardengine.swift:777](keyboard/Engine/Keyboardengine.swift#L777).

### Candidate Generation Creates a Hard Accuracy Ceiling

| What's wrong | User-end failure | Production/Gboard gap | Evidence |
|---|---|---|---|
| Fuzzy search has length-based cost budgets and a large first-letter penalty for words of five or more characters. | Severe deviations and valid first-letter slips never reach scoring. | A rescorer cannot recover a candidate that the trie pruned. | [Trie.swift:30](keyboard/Engine/Trie.swift#L30), [eval_harness.py:36](tools/lm/eval_harness.py#L36) |
| Candidate lists are pre-ranked by channel plus frequency and capped at 16 before neural scoring. | A contextually obvious word at rank 17 is permanently invisible to the neural model. | Gboard's published Neural Search Space injects neural LM information into the FST search space rather than only rescoring a small heuristic shortlist. | [Keyboardengine.swift:1073](keyboard/Engine/Keyboardengine.swift#L1073), [Neural Search Space paper](https://aclanthology.org/2024.emnlp-industry.93/) |
| Broad correction runs only when the normal correction list is empty. | One wrong nearby word prevents a distant true word from being considered. | Search breadth is controlled by the presence of any candidate, not confidence or oracle recall. | [Keyboardengine.swift:946](keyboard/Engine/Keyboardengine.swift#L946) |
| Context injection predicts only eight neural and twenty n-gram words, then applies length/end-point heuristics. | Severe typos are recoverable only when the intended word is already among a tiny next-word list. | This is a rescue patch, not integrated search over channel, lexicon, and language model. | [Keyboardengine.swift:872](keyboard/Engine/Keyboardengine.swift#L872) |

## Language Data and Personalization Failures

### N-gram Probability Model

**What's wrong:** The scorer is hand-set stupid backoff: maximum-order observed count,
then `0.4 * bigram`, then `0.16 * unigram`, with small personal boosts. It has no
discounting, interpolation, continuation probability, Kneser-Ney smoothing, calibration,
or domain-conditioned mixture.

**User failure:** Sparse contexts abruptly discard longer context and fall back to global
subtitle frequency. Common but wrong words dominate; uncommon context-correct words
vanish.

**Production/Gboard gap:** Gboard's published decoder represents context in a language
FST and its newer work dynamically incorporates neural LM output into that search space.
This project uses a few constants with no real typo calibration.

**Evidence:** [NgramScorer.swift:49](keyboard/Engine/NgramScorer.swift#L49),
[NgramScorer.swift:80](keyboard/Engine/NgramScorer.swift#L80),
[Gboard FST overview](https://research.google/blog/the-machine-intelligence-behind-gboard/).

### The Language Data Builder Creates False Context

**What's wrong:** Corpus tokens are filtered to in-vocabulary IDs first, and bigrams and
trigrams are then counted across the surviving sequence. Every OOV token is silently
deleted, creating false adjacency between words that were not neighbors. The "sentence
starter" becomes the first in-vocabulary token, not the actual first token.

**User failure:** The keyboard learns transitions that never occurred and gives incorrect
next-word priors around slang, names, URLs, code-switching, and every missing word.

**Production failure:** The bug contaminates every bundled n-gram table. Increasing the
corpus size amplifies rather than fixes it.

**Evidence:** [build_language_data.py:121](tools/build_language_data.py#L121),
[build_language_data.py:135](tools/build_language_data.py#L135).

### N-gram Tables Are Aggressively Truncated

**What's wrong:** Only 32 bigram successors and 16 trigram successors are retained per
context, and trigrams with count below three are dropped. The denominator remains the
pre-truncation total, but all omitted continuations collapse to backoff.

**User failure:** Legitimate long-tail continuations cannot appear as predictions even
when they occurred in training.

**Production/Gboard gap:** The table is optimized for size before a measured recall and
false-positive budget exists. There is no locale/domain allocation strategy.

**Evidence:** [build_language_data.py:59](tools/build_language_data.py#L59),
[build_language_data.py:247](tools/build_language_data.py#L247).

### Vocabulary Coverage Is Not Production English

**What's wrong:** The shipped v4 data has 60,101 words derived primarily from 2018
OpenSubtitles frequency data. Audit checks found `should've`, `could've`, `prolly`,
`rizz`, `yeet`, `delulu`, `lowkey`, `highkey`, `ngl`, `idk`, `imo`, and `lmao` absent.
Some informal words are present, so coverage is inconsistent rather than intentionally
specified.

**User failure:** Missing words cannot be generated by static typo correction or Glide,
and are treated as OOV until repeated personal use. Users discover gaps one word at a
time through wrong corrections.

**Production/Gboard gap:** There is no continuously versioned, locale-aware lexicon;
named-entity/trending pipeline; morphology; code-switching model; or coverage dashboard.

**Evidence:** [build_language_data.py:38](tools/build_language_data.py#L38),
[build_language_data.py:57](tools/build_language_data.py#L57), bundled
`keyboard/langdata.bin` audit.

### Contractions Are Patched, Not Modeled

| What's wrong | User-end failure | Production/Gboard gap | Evidence |
|---|---|---|---|
| At most 300 corpus contractions with count >=100 are merged. | Common valid forms outside that cap, including `should've` and `could've`, cannot be generated or glided. | A closed harvest threshold is not English morphology. | [build_language_data.py:65](tools/build_language_data.py#L65), [build_language_data.py:295](tools/build_language_data.py#L295) |
| `isContractionForm` accepts any known base plus any standard clitic. | Invalid strings such as `dog've`, `we'm`, or `the're` can be protected from correction. | Validation is suffix shape, not grammatical compatibility. | [Lexicon.swift:72](keyboard/Engine/Lexicon.swift#L72) |
| Synthetic restoration covers only small hand-authored base sets. | Every unlisted valid contraction remains broken, while future exceptions require code changes. | The approach cannot scale to dialect, slang, or multiple languages. | [Lexicon.swift:102](keyboard/Engine/Lexicon.swift#L102) |

### User Model Reinforces Mistakes and Is Not Transactional

| What's wrong | User-end failure | Production/Gboard gap | Evidence |
|---|---|---|---|
| Every committed word is learned immediately; lack of an undo is treated as acceptance. | Mistakes, accidental suggestions, and ignored bad Glide outputs gain unigram/bigram/trigram weight. | Passive continuation is weak feedback, not a reliable label. | [KeyboardViewController.swift:394](demo_keyboard/KeyboardViewController.swift#L394), [UserModel.swift:121](keyboard/Engine/UserModel.swift#L121) |
| `demote` decrements only the unigram. | A corrected mistake remains reinforced in its bigram and trigram contexts. | The feedback operation is internally inconsistent. | [UserModel.swift:134](keyboard/Engine/UserModel.swift#L134) |
| Unknown words are adopted after repeated use, regardless of whether repetition is a systematic typo. | The keyboard can permanently learn the exact misspelling it should correct. | There is no correction-pair model, confidence weighting, decay by error evidence, or protected typo list. | [Lexicon.swift:209](keyboard/Engine/Lexicon.swift#L209) |
| `save()` JSON-encodes the whole model on the engine queue caller and writes non-atomically with swallowed errors. | Suggestions can be delayed; a kill or write failure silently loses or corrupts personalization. | The comment says encoding is off the critical queue, but only disk write is dispatched. | [UserModel.swift:164](keyboard/Engine/UserModel.swift#L164) |
| App and extension share files/defaults without a versioned cross-process protocol. | Concurrent reset/save/read operations can overwrite newer state or revive deleted data. | There is no file coordination, schema migration log, atomic generation, or corruption recovery. | [UserModel.swift:108](keyboard/Engine/UserModel.swift#L108), [KBSettings.swift:207](keyboard/Shared/KBSettings.swift#L207) |
| Personalization consists mainly of count boosts. | It cannot learn an individual's touch offsets, key covariance, correction pairs, register, recency, or per-app context. | Gboard has published real-user spatial personalization and federated LM training; this model is a small local counter table. | [UserModel.swift:5](keyboard/Engine/UserModel.swift#L5), [Gboard spatial personalization](https://research.google/pubs/spatial-model-personalization-in-gboard/), [Gboard federated LM paper](https://research.google/pubs/federated-learning-of-gboard-language-models-with-differential-privacy/) |

### Profanity and Safety Filtering

**What's wrong:** A bundled exact list plus substring roots suppresses words globally
with no user setting, age mode, context, locale policy, or distinction between "do not
predict," "do not autocorrect into," and "user explicitly typed." The builder merges
mutable public lists without a reviewed policy or license manifest.

**User failure:** Users discussing identity, abuse, medicine, sexual health, moderation,
or ordinary names can be censored or receive unrelated alternatives. Missing resources
silently change behavior because `safety` is optional.

**Production/Gboard gap:** Safety is a policy product requiring language/community review,
appeals, locale testing, and explicit behavior. A hardcoded substring list cannot provide
that.

**Evidence:** [Lexicon.swift:33](keyboard/Engine/Lexicon.swift#L33),
[Lexicon.swift:38](keyboard/Engine/Lexicon.swift#L38),
[build_safety_lexicon.py:1](tools/build_safety_lexicon.py#L1).

## Neural Runtime Failures

### Model Quality and Score Definition

| What's wrong | User-end failure | Production/Gboard gap | Evidence |
|---|---|---|---|
| The source checkpoint is pretraining-stage. | The model may know broad token statistics but not keyboard correction utility or messaging error patterns. | Perplexity is not false-correction rate, top-1 correction accuracy, or user acceptance. | [tools/lm/README.md:17](tools/lm/README.md#L17) |
| Candidate score sums piece log-probabilities without an end-of-word boundary term or length normalization. | Shorter/easier-tokenized candidates can receive systematic advantage. | Next-word beam search does add a boundary mass, so two neural paths define "word probability" differently. | [NeuralScorer.swift:255](keyboard/Engine/NeuralScorer.swift#L255), [NeuralScorer.swift:416](keyboard/Engine/NeuralScorer.swift#L416), [model.py:325](tools/lm/model.py#L325) |
| Context is capped at 32 subword tokens, not eight reliable words. | Long or fragmented context is silently truncated, and effective history varies by tokenizer segmentation. | "Long-context neural" claims are overstated for messages with names, slang, or byte pieces. | [NeuralScorer.swift:139](keyboard/Engine/NeuralScorer.swift#L139), [NeuralScorer.swift:266](keyboard/Engine/NeuralScorer.swift#L266) |
| The score blend uses fixed 0.7 neural / 0.3 n-gram weights. | Model calibration shifts by context, candidate length, and residency, but the blend does not. | There is no learned calibration, confidence model, or task-level weight fitting. | [NeuralScorer.swift:599](keyboard/Engine/NeuralScorer.swift#L599) |

### Runtime Latency and Allocation

| What's wrong | User-end failure | Production/Gboard gap | Evidence |
|---|---|---|---|
| The Core ML graph has fixed batch 16; one candidate still executes padded work for 16 rows. | Short candidate lists pay near-full model dispatch cost. | Export shape is optimized for package conversion, not measured request distribution. | [NeuralScorer.swift:139](keyboard/Engine/NeuralScorer.swift#L139), [tools/lm/README.md:63](tools/lm/README.md#L63) |
| Every call allocates and zeros several `MLMultiArray` objects. Fragmented candidates can trigger additional forwards. | Typing creates allocation churn, memory spikes, and latency variance. | There is no input-buffer pool, reusable feature provider, or request arena. | [NeuralScorer.swift:278](keyboard/Engine/NeuralScorer.swift#L278), [NeuralScorer.swift:291](keyboard/Engine/NeuralScorer.swift#L291) |
| Next-word prediction recomputes the complete sequence for up to four beam steps. It then computes CPU log-softmax over all 6,000 logits per row. | Empty-word suggestions can be the slowest UI state and delay subsequent typing work. | There is no KV cache or incremental recurrent state. | [NeuralScorer.swift:408](keyboard/Engine/NeuralScorer.swift#L408), [NeuralScorer.swift:478](keyboard/Engine/NeuralScorer.swift#L478) |
| Cancellation is checked around work but cannot interrupt an active `MLModel.prediction`. | Obsolete requests still occupy compute while the user types or starts Glide. | Generation counters suppress delivery, not resource use. | [Keyboardengine.swift:979](keyboard/Engine/Keyboardengine.swift#L979), [NeuralScorer.swift:318](keyboard/Engine/NeuralScorer.swift#L318) |
| Compute units are hardcoded to CPU + Neural Engine while a comment says CPU-only may win. | Some supported devices may take a slower or more energy-expensive path. | There is no per-device benchmark matrix or adaptive compute-unit policy. | [NeuralScorer.swift:223](keyboard/Engine/NeuralScorer.swift#L223) |

### Memory and Behavioral Instability

| What's wrong | User-end failure | Production/Gboard gap | Evidence |
|---|---|---|---|
| Model loading is lazy, so early requests use n-gram/unigram and later requests silently switch to neural. | The keyboard changes its correction personality mid-session. | Readiness is not surfaced or frozen per decode session. | [NeuralScorer.swift:200](keyboard/Engine/NeuralScorer.swift#L200), [BlendedScorer.swift:612](keyboard/Engine/NeuralScorer.swift#L612) |
| Memory pressure drops the model; later requests may reload it. | The same input can rank differently before and after pressure, with load spikes recurring during use. | Graceful degradation changes semantics, not just speed. | [NeuralScorer.swift:177](keyboard/Engine/NeuralScorer.swift#L177), [NeuralScorer.swift:184](keyboard/Engine/NeuralScorer.swift#L184) |
| A static 35 MB headroom threshold is not based on a supported-device release matrix; failed measurement explicitly fails open. | Devices closest to the extension limit are allowed to load when headroom cannot be measured. | There is no conservative fallback for unknown memory state. | [NeuralScorer.swift:142](keyboard/Engine/NeuralScorer.swift#L142), [NeuralScorer.swift:209](keyboard/Engine/NeuralScorer.swift#L209) |
| The bundle combines a 19 MB language file, 10.88 MB model package, tokenizer, UI objects, user tables, emoji atlas, and animated media decoding. | Feature combinations can trigger extension termination and silent system-keyboard fallback. | No 30-minute oldest-device stress profile proves a safe peak footprint. | [tools/lm/README.md:46](tools/lm/README.md#L46), bundled artifact sizes |
| The graph is not integer end-to-end. It contains quantize/dequantize plus floating layer norm, softmax, indexing, and output operations. | "Completely int8" expectations translate into wrong memory/latency assumptions. | W8A8 eligibility for matrix operations is not equivalent to an all-INT8 runtime. | [tools/lm/README.md:40](tools/lm/README.md#L40), [coreml_export_manifest.json](tools/lm/coreml_export_manifest.json) |

## Glide Failures

### Preview and Final Commit Can Diverge

**What's wrong:** Preview and final call the same high-level decoder, but the preview
cache key requires the exact raw path, timestamps, layout, and context. The latest preview
normally covers a prefix of the final stroke, so release cancels previews and misses the
cache. It reruns decoding on the full path, which can produce a different winner.

**User failure:** The middle word shown under the finger is not the word inserted on lift.
The UI has promised a result that the final decoder never committed to.

**Production failure:** The test only verifies the unrealistic case where preview and
final receive byte-for-byte identical paths. There is no prefix-state continuation,
stable confidence rule, or final-frame preview guarantee.

**Evidence:** [Keyboardengine.swift:471](keyboard/Engine/Keyboardengine.swift#L471),
[Keyboardengine.swift:523](keyboard/Engine/Keyboardengine.swift#L523),
[Keyboardengine.swift:619](keyboard/Engine/Keyboardengine.swift#L619),
[keyboardTests.swift:283](keyboardTests/keyboardTests.swift#L283).

### Glide Latency Is Structurally Repeated Work

**What's wrong:** Live decoding starts at most every 60 ms and is single-flight. On lift,
an exact-cache miss reruns preprocessing, beam search, endpoint augmentation, DTW shape
costs, n-gram scoring, and sorting on another queue before dispatching insertion to main.

**User failure:** Finger lift can produce a visible pause even though a plausible preview
was already displayed.

**Production failure:** The preview does not retain an incremental beam/decoder state that
the final samples can extend. Cancellation avoids some queue competition but discards
useful computation.

**Evidence:** [Keyboard.swift:116](keyboard/Views/Keyboard.swift#L116),
[KeyboardViewController.swift:742](demo_keyboard/KeyboardViewController.swift#L742),
[Keyboardengine.swift:641](keyboard/Engine/Keyboardengine.swift#L641).

### Glide Accuracy Evidence Is Circular and Too Small

| What's wrong | User-end failure | Production/Gboard gap | Evidence |
|---|---|---|---|
| The production beam width is documented at about 86.7% synthetic top-1 and 89.4% recall. | Roughly one in ten intended words can be absent before context ranking in the project's own optimistic harness. | This is not competitive release evidence. | [GlidePath.swift:231](keyboard/Engine/GlidePath.swift#L231) |
| The harness synthesizes paths for 300 mostly high-frequency words using the same key grid and noise assumptions as the decoder. | Reported accuracy does not represent real thumbs, devices, screen sizes, motor patterns, or long-tail vocabulary. | Gboard publications use representative real typing behavior and online experiments. | [glide_eval/main.swift:94](tools/glide_eval/main.swift#L94), [glide_eval/main.swift:117](tools/glide_eval/main.swift#L117) |
| Only 67 Glide captures are present. Calibration treats the decoder's committed winner as trusted ground truth. | Wrong commits teach the calibration that the wrong word was intended. | There is no corrected-intent labeling or statistically useful user/device sample. | [glide_capture.jsonl](tools/glide_capture.jsonl), [calibrate.py:8](tools/glide_eval/calibrate.py#L8), [calibrate.py:63](tools/glide_eval/calibrate.py#L63) |
| Typing on is treated as Glide acceptance. | Users who ignore or fail to notice a wrong word reinforce it. | Absence of correction is not equivalent to a positive label. | [KeyboardViewController.swift:72](demo_keyboard/KeyboardViewController.swift#L72), [Keyboardengine.swift:735](keyboard/Engine/Keyboardengine.swift#L735) |
| Final Glide ranking uses only the n-gram prior; neural context is deferred to later previous-word rewriting. | Context-sensitive words are committed with weaker evidence, then may mutate after insertion. | The language model is outside the actual Glide search/commit decision. | [Keyboardengine.swift:548](keyboard/Engine/Keyboardengine.swift#L548), [Keyboardengine.swift:655](keyboard/Engine/Keyboardengine.swift#L655) |
| Dynamic learned/contact/OOV words are not part of the static mmap Glide trie. | Names, slang, and missing contractions cannot be glided even after the user teaches them. | Personalization does not expand Glide's search space. | [Keyboardengine.swift:574](keyboard/Engine/Keyboardengine.swift#L574), [Lexicon.swift:7](keyboard/Engine/Lexicon.swift#L7) |

### Glide Decoder Efficiency and Visual Feedback

| What's wrong | User-end failure | Production/Gboard gap | Evidence |
|---|---|---|---|
| Every beam child copies an array of letter points, and each depth sorts hypothesis arrays. DTW is computed for every emitted word. | Long or ambiguous strokes create allocation and CPU spikes. | The implementation is a prototype search structure, not a compact incremental decoder. | [GlidePath.swift:276](keyboard/Engine/GlidePath.swift#L276), [GlidePath.swift:309](keyboard/Engine/GlidePath.swift#L309) |
| Direction scoring is compiled but disabled because only synthetic tuning exists. | Spatially similar shapes remain difficult to distinguish. | A potentially useful channel cannot ship without real data. | [GlidePath.swift:217](keyboard/Engine/GlidePath.swift#L217) |
| The trail is an unsmoothed raw polyline with a fixed 7.5 pt tail and 18 pt circular head. | Low touch-sample rates create angular segments; the head/tail ratio does not adapt to key size, velocity, or accessibility. | Visual feedback is decorative rather than a confidence/trajectory aid. | [Keyboard.swift:176](keyboard/Views/Keyboard.swift#L176), [Keyboard.swift:932](keyboard/Views/Keyboard.swift#L932) |

## Emoji, Clipboard, and Media Failures

### Emoji

| What's wrong | User-end failure | Production/Gboard gap | Evidence |
|---|---|---|---|
| Search performs two full map scans, repeated string decoding/normalization, and a full sort on each query update. | Emoji search can hitch while the user types, especially before atlas warmup. | No prefix index, locale index, fuzzy lookup, or frequency-ranked retrieval exists. | [Emoji.swift:110](keyboard/Views/Emoji.swift#L110) |
| Search destroys and recreates up to 60 buttons per update. | Results flicker and allocate heavily; accessibility focus cannot remain stable. | Reusable collection cells are not used for the search result strip. | [Emoji.swift:843](keyboard/Views/Emoji.swift#L843) |
| There are no skin-tone variants, long-press variants, locale-aware names, typo-tolerant search, or learned ranking. | Users cannot reach expected emoji forms efficiently. | The feature is a static Unicode catalog, not a production emoji input system. | [Emoji.swift:1](keyboard/Views/Emoji.swift#L1) |
| Atlas creation must run in the companion app; until then the extension uses live glyph rendering. | Emoji memory and visual behavior differ depending on whether the app was opened and atlas generation completed. | A keyboard feature should not silently depend on a prior app-side cache job. | [ContentView.swift:117](keyboard/App/ContentView.swift#L117), [Emoji.swift:255](keyboard/Views/Emoji.swift#L255) |

### Clipboard

| What's wrong | User-end failure | Production/Gboard gap | Evidence |
|---|---|---|---|
| Every mutation loads, decodes, re-encodes, and atomically rewrites the complete JSON file synchronously. | Opening/deleting/pinning can pause the keyboard UI. | There is no serial store actor, index, incremental update, or corruption recovery. | [KBClipboard.swift:32](keyboard/Shared/KBClipboard.swift#L32), [KBClipboard.swift:38](keyboard/Shared/KBClipboard.swift#L38) |
| The empty state says "tap Paste," but the suggestion bar shows only a clipboard icon. | Instructions do not match the interface. | Copy text is implementation narration rather than a clear state/action. | [ClipboardPanel.swift:63](keyboard/Views/ClipboardPanel.swift#L63), [SuggestionBar.swift:33](keyboard/Views/SuggestionBar.swift#L33) |
| Delete accessories are 28 pt. | They are difficult to hit and below the default iOS target. | Primary destructive actions are not accessibility-sized. | [ClipboardPanel.swift:113](keyboard/Views/ClipboardPanel.swift#L113) |
| There is no search, global clear, expiry, sensitive-item warning, or per-item retention setting. | Large histories become unmanageable and risky. | The feature lacks the controls required by its privacy surface. | [KBClipboard.swift:43](keyboard/Shared/KBClipboard.swift#L43) |

### GIFs and Stickers

| What's wrong | User-end failure | Production/Gboard gap | Evidence |
|---|---|---|---|
| API fetch ignores HTTP status, response MIME type, and transport error details; any `Data` is passed to JSON parsing. | Outages, auth errors, rate limits, and captive portals all collapse into an unexplained empty state. | No typed error model, retry, backoff, auth recovery, or observability exists. | [KBKlipy.swift:48](keyboard/Shared/KBKlipy.swift#L48) |
| Media downloads have no response-size or content validation before moving files into cache. | A malicious or malformed response can consume disk/memory or fail decode repeatedly. | Remote content is trusted by URL and extension only. | [KBMediaCache.swift:42](keyboard/Shared/KBMediaCache.swift#L42) |
| Requests are not coalesced or truly cancelled when cells are reused. | Scrolling can continue downloading and decoding media no longer visible. | Generation checks discard results but do not cancel network/CPU work. | [MediaPanel.swift:392](keyboard/Views/MediaPanel.swift#L392), [MediaPanel.swift:408](keyboard/Views/MediaPanel.swift#L408) |
| Every page append calls `reloadData()`. | Pagination rebuilds visible state and causes avoidable layout churn. | Incremental inserts and stable identifiers are absent. | [MediaPanel.swift:159](keyboard/Views/MediaPanel.swift#L159) |
| Every visible animated cell is ticked by one display link and up to two decodes run concurrently. | A media panel can consume substantial CPU, battery, and extension memory while typing is one tap away. | There is no measured energy/memory budget or automatic animation suspension under pressure. | [MediaPanel.swift:130](keyboard/Views/MediaPanel.swift#L130), [MediaPanel.swift:364](keyboard/Views/MediaPanel.swift#L364) |
| Selecting media only copies it and tells the user to paste manually. | "Insert" is a two-step host-dependent workflow that often fails in apps that reject GIF paste. | The experience cannot match integrated first-party media insertion, and this limitation is not set before browsing. | [MediaPanel.swift:192](keyboard/Views/MediaPanel.swift#L192) |
| There is no offline metadata cache, safe-search policy, moderation/reporting flow, age handling, or provider failover. | Users can see stale, objectionable, empty, or unavailable content with no recovery. | A public media product requires policy and operations, not only an API grid. | [MediaPanel.swift:145](keyboard/Views/MediaPanel.swift#L145) |

## Reliability, Storage, and Code-Structure Failures

### Unused Core Data Can Crash the Companion App

**What's wrong:** The app initializes an unused Core Data stack and injects its context
into the root view. Store load failures call `fatalError`.

**User failure:** Disk, migration, protection, or corruption errors can terminate a
settings app that does not need Core Data at all.

**Production failure:** An unrelated template dependency creates a crash surface and
startup cost with no product value.

**Evidence:** [keyboardApp.swift:11](keyboard/App/keyboardApp.swift#L11),
[Persistence.swift:34](keyboard/App/Persistence.swift#L34).

### Errors Are Silently Swallowed

**What's wrong:** User model, clipboard, settings, theme photo, emoji atlas, media cache,
and diagnostics contain broad `try?` paths. Corruption, permission, disk-full, schema,
and network failures frequently become empty defaults.

**User failure:** Personalization, themes, clips, media, or diagnostics disappear without
an explanation or recovery option.

**Production failure:** There is no structured error taxonomy, user-safe recovery,
production telemetry, or corruption quarantine. Silent fallback hides release defects.

**Evidence:** [UserModel.swift:150](keyboard/Engine/UserModel.swift#L150),
[KBClipboard.swift:32](keyboard/Shared/KBClipboard.swift#L32),
[Emoji.swift:281](keyboard/Views/Emoji.swift#L281),
[KBMediaCache.swift:45](keyboard/Shared/KBMediaCache.swift#L45).

### App Group State Has No Ownership Protocol

**What's wrong:** App and extension independently read/write `UserDefaults` blobs and
files. There are no schema versions for most values, no writer identity, no compare-and-
swap generation, no migration transaction, and no notification/acknowledgement channel.

**User failure:** Changes appear late, are overwritten, or produce mixed old/new state.

**Production failure:** The observed CFPreferences warnings are symptoms of an
under-specified shared-state architecture, even if using the singleton suite removes
some repeated attachment work.

**Evidence:** [KBSettings.swift:207](keyboard/Shared/KBSettings.swift#L207),
[UserModel.swift:108](keyboard/Engine/UserModel.swift#L108),
[KBStats.swift:94](keyboard/Shared/KBStats.swift#L94).

### Comments Substitute for Measurements

**What's wrong:** Source comments claim approximate neural, trie, memory, and Glide costs,
but the repository has no production benchmark target, signposted latency suite, MetricKit
pipeline, memory regression gate, or checked-in device matrix.

**User failure:** Optimizations can regress unnoticed until users report lag or iOS kills
the extension.

**Production failure:** Performance claims cannot be reproduced, compared across commits,
or enforced in CI.

**Evidence:** [Keyboardengine.swift:224](keyboard/Engine/Keyboardengine.swift#L224),
[GlidePath.swift:231](keyboard/Engine/GlidePath.swift#L231),
[NeuralScorer.swift:142](keyboard/Engine/NeuralScorer.swift#L142).

## Test and Evaluation Failures

### Typo Evaluation Is Synthetic and Circular

**What's wrong:** The harness generates typos from the same keyboard geometry and channel
cost assumptions used by the decoder. It deliberately avoids corrupting the first letter.
Its source sentences are Leipzig text, not a consented real mobile typo corpus. The
default baseline constants in the script also no longer fully represent every runtime
path.

**User failure:** Offline numbers overestimate real-world candidate recall and hide the
exact severe deviations and first-letter errors users make.

**Production/Gboard gap:** There is no real `(touches, typed, intended, left context,
accepted/reverted)` dataset, no company-keyboard baseline, no locale/register slices, and
no confidence intervals.

**Evidence:** [eval_harness.py:1](tools/lm/eval_harness.py#L1),
[eval_harness.py:237](tools/lm/eval_harness.py#L237),
[eval_harness.py:273](tools/lm/eval_harness.py#L273).

### Unit and UI Coverage Misses Core Failure Modes

| What's wrong | User-end failure | Production/Gboard gap | Evidence |
|---|---|---|---|
| Unit tests emphasize emoji parsing/renders, contractions, stats math, and an exact Glide cache hit. | Core races and stale decisions can regress while tests remain green. | There are no controller-host tests for rapid typing, pending context, selection movement, marked text, secure fields, or multi-touch ordering. | [keyboardTests.swift:6](keyboardTests/keyboardTests.swift#L6) |
| Render tests write PNGs but do not compare against approved baselines or assert geometry/contrast. | Visual regressions depend on manual inspection and are easy to miss. | No automated multi-device screenshot matrix exists. | [keyboardTests.swift:391](keyboardTests/keyboardTests.swift#L391), [keyboardTests.swift:468](keyboardTests/keyboardTests.swift#L468) |
| UI tests launch only the companion app; the template `testExample` has no assertions. | The system-wide extension workflow is never exercised end to end. | No test enables/switches keyboard, types into representative hosts, or verifies text output. | [keyboardUITests.swift:25](keyboardUITests/keyboardUITests.swift#L25) |
| Only app launch performance is measured. | Keyboard extension startup, tap latency, suggestions, Glide, memory, and model loading have no regression gate. | App launch is not the performance-critical product path. | [keyboardUITests.swift:63](keyboardUITests/keyboardUITests.swift#L63) |
| Test deployment is iOS 18.6 while product deployment is iOS 17.0. | iOS 17-specific crashes, APIs, rendering, and model behavior can ship untested. | The oldest supported environment is the most important memory/performance gate. | [project.pbxproj:475](keyboard.xcodeproj/project.pbxproj#L475), [project.pbxproj:617](keyboard.xcodeproj/project.pbxproj#L617) |

### Missing Production Matrices

There is no checked-in evidence for any of the following:

- Tap-handler p50/p95/p99 latency on the oldest supported iPhone.
- Boundary/autocorrect p50/p95/p99, including lock contention.
- Glide preview age, preview/final agreement, and lift-to-insert p50/p95/p99.
- Peak and sustained extension footprint with neural + emoji + media + photo theme.
- Jetsam survival during 30-minute typing and panel-switch stress.
- Thermal and battery impact of repeated Core ML and animated media.
- Accuracy and false-correction rate on real touch/typo data.
- Accuracy slices for word length, OOV, names, contractions, slang, code-switching,
  disability/accessibility input, screen size, orientation, and typing speed.
- VoiceOver, Switch Control, Voice Control, Dynamic Type, Reduce Transparency,
  Increase Contrast, and Bold Text acceptance.
- Host matrix covering Messages, Notes, Mail, Safari, App Store search, Spotlight,
  UIKit, SwiftUI, WKWebView, secure fields, enterprise/managed apps, and third-party
  editors.
- Offline, rate-limit, malformed-media, disk-full, corrupt-model, and App Group failure
  behavior.

## Why It Does Not Approach Gboard

| Capability | This project | Publicly documented Gboard level | Why the project loses |
|---|---|---|---|
| Decode architecture | Separate trie correction, prefix completion, neural rescore, context injection, previous-word rescue, and Glide DTW paths. | A context-aware language FST search space; published Neural Search Space dynamically integrates NN-LM output into the FST. | Separate paths create candidate loss and timing-dependent winners; integrated search lets language evidence affect which paths survive. |
| Spatial model | Static Gaussian-style costs with visual/model row-offset mismatch; no learned per-user touch centers. | Published real-user personalization learns key-center offsets and optionally covariance, validated on representative users. | The project mis-models its own layout before personalization begins. |
| Language model | Truncated hand-smoothed bi/trigrams plus a pretraining-stage 10.6M rescorer after a 16-candidate cap. | Published deployed Gboard LMs trained with federated learning and differential privacy; newer work integrates NN-LM context into search. | The project has weaker training evidence, shorter effective context, candidate pruning before neural evidence, and no deployment validation. |
| Training data | Subtitle/news/dialogue mix, mutable sources, no license manifest, no real correction labels. | Published Gboard work uses large-scale on-device/federated learning and reports deployed models. | Public text does not teach actual touch errors, accept/reject behavior, personal offsets, or current messaging register. |
| Evaluation | Synthetic channel noise and synthetic Glide paths built from the decoder's own assumptions; 67 Glide captures. | Published Gboard work reports representative real-user studies and online experiments. | Circular offline tests cannot predict user error or prove an improvement over a production baseline. |
| Severe deviations | Small next-word injection list and broad search only when close search is empty. | Neural language information can participate in constructing the runtime search space. | A nearby wrong word can block the true distant candidate before the model sees it. |
| Glide | Hand-built beam + DTW, static trie, n-gram-only final ranking, repeated final decode. | Public Gboard work treats raw touch sequences with robust spatial models and integrated decoder infrastructure. | Candidate recall, preview consistency, latency, personalization, and real-data evidence are all below release standard. |
| Multilingual/transliteration | English only; Tenglish/Telugu are inert labels and model tags. | Published Gboard WFST transliteration shipped across 22 languages in 2017; official product material reports broad multilingual support. | There is no Telugu layout, transliteration decoder, script lexicon, language detection, code-switching, or evaluation. |
| Personalization/privacy | Local count tables, plaintext shared files, no deletion transaction, no formal privacy guarantee. | Published Gboard LM work reports federated learning with differential privacy guarantees and secure aggregation for some models. | The project has neither population learning nor a defensible privacy lifecycle. |
| Product maturity | Incomplete onboarding, inaccessible keys, stale settings state, missing app icon/localization/privacy UI, fragile media. | Gboard is a globally deployed product with mature input, language, and operational surfaces. | The project has not passed the minimum release gates needed before feature comparison is meaningful. |

Primary comparison sources:

- [Neural Search Space in Gboard Decoder, EMNLP 2024](https://aclanthology.org/2024.emnlp-industry.93/)
- [The Machine Intelligence Behind Gboard](https://research.google/blog/the-machine-intelligence-behind-gboard/)
- [Spatial Model Personalization in Gboard](https://research.google/pubs/spatial-model-personalization-in-gboard/)
- [Federated Learning of Gboard Language Models with Differential Privacy](https://research.google/pubs/federated-learning-of-gboard-language-models-with-differential-privacy/)
- [Transliterated Mobile Keyboard Input via Weighted FSTs](https://research.google/pubs/transliterated-mobile-keyboard-input-via-weighted-finite-state-transducers/)

## Remediation Plan and Release Gates

The phases below are ordered by dependency. Later phases cannot compensate for failures
in earlier ones.

### Phase 0: Stop-Ship Security, Privacy, Legal, and Completeness

1. Revoke the embedded KLIPY key; remove every client secret from all targets and git
   history; introduce a constrained backend/token strategy or remove network media.
2. Define the exact Full Access product boundary. Basic typing, correction, language
   data, themes, and switching must remain usable without it. Ask only when a user enters
   a feature that requires it.
3. Add a reviewed privacy policy in-app and in App Store metadata. Document local typed
   history, clipboard, App Group files, diagnostics, stable provider ID, media queries,
   retention, deletion, and third parties.
4. Add an accurate privacy manifest and generate/review the archive privacy report.
5. Replace public text logging with non-content metrics. Make content capture a separate
   debug-only build capability that cannot compile into production.
6. Redesign clipboard retention: opt-in history, short default expiry, sensitive-pattern
   suppression, clear-all, per-item expiry, protected storage, and explicit deletion.
7. Implement a versioned cross-process reset transaction that clears all personal data,
   invalidates the in-memory engine, cancels pending writes, and acknowledges completion.
8. Produce a dependency/data/model license and attribution inventory with pinned hashes
   and reproducible source versions. Remove any artifact without proven shipping rights.
9. Resolve Apple emoji artwork rights. Remove persistent rasterization unless written
   approval/legal analysis establishes it is permitted.
10. Add final app icons, production identifiers, support/privacy links, version metadata,
    and remove all placeholder language claims from the release build.
11. Remove unused Core Data or replace `fatalError` with a recoverable, necessary store.

**Exit gate:** No secrets in the archive; complete privacy report and policy; one verified
"Delete all personal data" test across running app/extension processes; complete license
inventory; valid app icons/metadata; legal sign-off for emoji/media assets.

### Phase 1: One Decode Contract and a Nonblocking Input Path

1. Define one immutable `DecodeSnapshot` containing field/session ID, document revision,
   current word, canonical context, touch samples, candidate list, score components,
   model tier, confidence, and generation.
2. Make suggestion display and boundary commit consume the same snapshot and same score.
   Do not let raw/compressed frequency, emoji replacement, or model residency alter the
   primary correction contract.
3. Remove all fuzzy search, JSON work, stats I/O, and contended locks from main. If a
   snapshot is not ready at a boundary, insert the boundary immediately and apply only a
   previously validated decision; never synchronously search 60k words.
4. Replace fixed 60 ms debounce with deadline-aware coalescing and separate priority
   queues for tap decode, next-word prediction, Glide preview, model load, learning, and
   nonessential telemetry.
5. Invalidate results on context, cursor, field, host, model-tier, layout, and generation
   changes. Word equality alone must never validate a cache hit.
6. Remove asynchronous previous-word rewriting until it has a document-safe transaction
   contract and a measured false-change rate.
7. Instrument owned stages with signposts and automated latency regression tests.

**Exit gates:**

- App-owned tap handling before the proxy call: p99 <= 1 ms on the oldest supported
  physical device.
- No main-thread `NSLock` wait, trie walk, Core ML call, JSON encode/decode, file I/O, or
  stats flush in a 30-minute trace.
- Suggestion primary and boundary correction agree for the same snapshot in 100% of
  deterministic replay cases.
- No stale result applies after cursor, field, context, or generation changes.
- Suggestion update after the last key: p95 <= 75 ms and p99 <= 120 ms on the oldest
  supported device, with no backlog growth during 10 characters/second input.

### Phase 2: Fix Layout, Interaction, and Accessibility Before Retuning Models

1. Use one geometry source for visual frames, tap spatial coordinates, dynamic targets,
   popups, tests, and Glide. Eliminate duplicated row-offset constants.
2. Build explicit compact-phone, large-phone, landscape, and iPad layouts. Validate key
   centers against an approved reference and measured user error, not screenshots alone.
3. Store touch-begin sequence numbers so rollover commits are deterministic. Decide and
   test a single tap/glide arbitration contract for multiple fingers.
4. Restore conventional Shift and Caps Lock behavior, long-press input-mode picker,
   field-specific number/symbol layouts, return-key enabled state, and long-press accents.
5. Replace clear-only background assumptions with owned semantic surfaces and deterministic
   light/dark/high-contrast/reduced-transparency fallbacks. Derive action, soft-action,
   special, selected, and pressed roles from a contrast-checked color system.
6. Expose every virtual key and panel action as a correctly framed accessibility element.
   Meet 44 pt default targets or provide equivalent expanded semantic hit regions.
7. Add Dynamic Type where appropriate, VoiceOver order/announcements, Switch Control,
   Voice Control labels, Reduce Motion, Reduce Transparency, and Increase Contrast.

**Exit gates:** Zero key-center divergence between renderer and decoder; deterministic
multi-touch replay; 100% primary controls reachable and labeled with VoiceOver; no
contrast failure in every approved theme/appearance; no overlap or clipped text across
the supported device/orientation matrix.

### Phase 3: Build Real Data and Evaluation Infrastructure

1. Create a consented, privacy-reviewed dataset of real touch points, typed text, intended
   text, context, suggestion shown, correction committed, undo/replacement outcome,
   device/layout, and latency. Do not treat "typed on" as ground truth.
2. Split by user before train/validation/test to prevent personal leakage. Maintain hard
   sets for severe typos, first-letter errors, contractions, names, slang, code-switching,
   accessibility input, and long-tail words.
3. Replay the exact same cases through this engine and the current company production
   keyboard. Report top-1/top-3 recall, false-correction rate, keystroke savings, word
   modified ratio, acceptance/undo rate, latency, and memory with confidence intervals.
4. Repair n-gram counting so OOV boundaries are preserved. Train and evaluate proper
   discounted/interpolated models before selecting table caps.
5. Establish a licensed, versioned lexicon pipeline with contractions/morphology, current
   conversational vocabulary, names, and explicit locale/register coverage reports.
6. Turn every reported user failure into a permanent replay test.

**Exit gate:** A frozen blind test set and reproducible report demonstrating statistically
significant improvement over the company baseline without increasing false corrections,
latency, or memory beyond agreed budgets. Synthetic results cannot satisfy this gate.

### Phase 4: Rebuild Neural Integration Around Measured Utility

1. Do not ship the pretraining checkpoint as a quality feature. Complete task-specific
   distillation/fine-tuning and quantization-aware training on licensed messaging and real
   correction data.
2. Fit score normalization, word-boundary probability, candidate length handling, blend
   weights, and confidence thresholds on the blind correction task, not perplexity.
3. Increase candidate oracle recall before increasing model size. Evaluate neural
   integration during search or a structured FST-like candidate expansion instead of
   only rescoring a frequency-capped list.
4. Export shapes matching real request sizes or prove fixed-batch 16 is faster on every
   supported device. Pool all Core ML inputs and benchmark compute-unit choices.
5. Freeze a decoder tier for each word/session so lazy load or memory pressure cannot
   change a pending decision.
6. Define a measured memory policy with conservative unknown-headroom behavior and no
   automatic reload thrash.

**Exit gates:** Physical-device p50/p95/p99 latency and energy matrix; peak extension
footprint below 70% of the measured kill threshold on the oldest supported device;
zero jetsam terminations in stress; neural model improves blind top-1 and false-correction
metrics enough to justify its memory on every enabled device tier.

### Phase 5: Replace Glide Prototype Evidence With Production Evidence

1. Share one incremental decoder state between preview and final release. Extend the last
   preview with final samples instead of restarting from the raw path.
2. Define a display policy that withholds or marks low-confidence preview instead of
   promising an unstable winner.
3. Train/tune spatial, direction, dwell, endpoint, and language weights on corrected real
   gestures across users, devices, handedness, speed, and key layouts.
4. Include personalized and supplementary words in the Glide search space with bounded
   memory and explicit safety policy.
5. Replace array-copy/sort-heavy hypotheses with compact parent-linked state, bounded
   selection, reusable buffers, and measured cancellation.
6. Smooth the visible trail and scale head/tail by key geometry and motion while respecting
   Reduce Motion.

**Exit gates:** Final displayed preview equals inserted word in >=99% of cases where the
finger did not materially move after that preview; lift-to-insert p95 <=50 ms and p99
<=80 ms on the oldest device; real-user top-1/top-3 and rejection rates beat the company
baseline; no accepted-label training from unverified "typed on" behavior.

### Phase 6: Reduce Product Surface Until It Is Operable

1. Make setup/health/privacy the home hierarchy. Move achievements below core operations
   or remove them until stats are trustworthy.
2. Separate safe theme presets from an advanced transactional editor. Use the real
   keyboard renderer for previews and paired light/dark variants.
3. Remove dormant font promises and code unless explicitly framed as key-legend styling.
4. Hide Tenglish/Telugu from production until layouts, transliteration, lexicons, safety,
   accessibility, and evaluation are complete.
5. Do not ship clipboard or media until their privacy, moderation, error, memory, and
   accessibility gates pass independently.
6. Add localization, support, diagnostics that contain no text content, and actionable
   recovery for every expected extension failure.

**Exit gate:** Every visible row performs a complete production function; no "Coming
soon," API-key setup hint, debug explanation, stale status, or dead control remains.

### Phase 7: Controlled Beta and Release Decision

1. Run internal dogfood, then consented staged beta by device/OS/layout cohort.
2. Monitor only non-content metrics: extension launch failures, jetsam, latency
   distributions, suggestion age, undo rate, correction acceptance, Glide rejection,
   model residency, media failures, and reset completion.
3. Define rollback switches for neural scoring, Glide, media, clipboard, and new language
   data that do not change core typing semantics mid-word.
4. Compare each release candidate against both the company keyboard and the previous
   build on the frozen blind set and device matrix.

**Final release gate:** No P0/P1 open defect; App Review/privacy/legal sign-off; oldest-OS
and oldest-device pass; accessibility acceptance; zero secret or personal text telemetry;
measured accuracy improvement over the company baseline; stable p99 latency and memory;
and a rollback-tested staged rollout. Until all gates pass, a claim of production safety
or Gboard-level quality is unsupported.

---

## Implementation Status and Solution Architecture (2026-07-19)

The findings above describe the pre-remediation snapshot and intentionally remain as an
audit record; some referenced files have since been removed. The following architecture
is now implemented in the working tree.

| Problem class | Implemented solution | Why this is materially different |
|---|---|---|
| Timing-dependent suggestions and corrections | A versioned, immutable `DecodeRequest`/`DecodeSnapshot` contract carries field, document, word-session, generation, and layout revisions. The controller accepts only an exact match, and a boundary consumes that same published decision. | Suggestions and autocorrect can no longer be answers to different text snapshots or a delayed pass from an earlier word. Missing work preserves typed text instead of blocking input. |
| Keystroke and Glide latency | Host insertion happens before bookkeeping; tap decode, Glide preview, and Glide final use isolated queues with cooperative cancellation. Trie reads operate outside mutable-model locks, and Glide uses parent-linked hypotheses, bounded selection, and reusable buffers. | The input path has no model wait or synchronous fuzzy search. Stale speculative work loses authority and exits instead of creating a queue backlog. |
| Preview/final Glide disagreement | Preview and final use one candidate/ranking tier, an exact final-path cache can become commit authority, and every outcome has an opaque ID. | Releasing on the path already shown inserts the shown word; there is no delayed second semantic model that silently changes the winner. |
| Self-reinforcing personalization | Personal boosts require evidence; novel adoption requires confirmation or context diversity; learning has a bounded recent-event ledger; replacement and undo reverse the exact contextual event. Automatic Glide winners are never labels. | A repeated typo or unverified automatic choice cannot become durable truth merely because the user continued typing. Adaptation is evidence-gated and reversible. |
| Weak language data | `langdata.bin` now ships a deterministic, memory-mapped 60,449-word vocabulary with 233,748 bigrams, 376,779 trigrams, 138,138 trie nodes, contractions, current conversational vocabulary, and OOV-safe boundary counting. Scoring uses continuous Witten-Bell interpolation. | The context prior exists on first launch, does not materialize large Swift dictionaries, and backs off continuously instead of dropping abruptly to a frequency heuristic. |
| Unqualified neural model | The Core ML runtime, tokenizer, model package, stale export manifest, and setting were removed from both targets. Offline scripts are explicitly research-only and have promotion gates for rights, blind task gain, oracle recall, graph shapes, physical-device performance, and archive inspection. | Model size and perplexity are no longer treated as evidence of autocorrect quality. The shipping decoder has one stable semantic tier and no hidden memory-dependent personality change. |
| Layout drift and field mismatch | Renderer, hit testing, spatial taps, popups, and Glide share layout profiles. Compact, standard, landscape, and pad geometry plus email, URL, numeric, and decimal key surfaces are explicit. Long-press accents and spacebar cursor control are included. | Visual key centers and decoder geometry stay aligned, while host field semantics change the key surface rather than forcing one QWERTY layout everywhere. |
| Inconsistent themes and accessibility | Themes compile semantic HSL roles for keys, special controls, soft actions, and primary action in paired light/dark variants. Contrast is repaired against linearized sRGB luminance; Increase Contrast, Reduce Transparency, Reduce Motion, VoiceOver labels, 44-point controls, and haptic settings are handled. | Accent colors no longer recolor the app shell or directly become unreadable key fills. Accessibility state changes produce deterministic surfaces rather than accidental blur behavior. |
| Oversized and unsafe product surface | Fonts, unfinished languages, achievements, clipboard, GIF/media, and design-lab surfaces were removed. The host app focuses on setup, health, privacy/reset, haptics, and transactional paired-theme editing. | Every visible row now corresponds to an operable feature; dormant privacy, moderation, network, secret, and memory risks are absent from the release bundle. |
| Silent operational failure | Reset is epoch-based across app and extension, reports fixed non-content failure codes, validates persistence snapshots, quarantines corruption, and never falls back to an unshared personal-data path. Aggregate histograms record host insert, tap decode, Glide preview/final, and lift-to-insert latency alongside footprint and storage health. | Reset ownership is explicit and stale extension writes cannot resurrect prior data. Health data can diagnose latency and storage without recording words, paths, or identifiers. |
| Unprovable quality claims | `tools/evaluation/replay_report.py` validates paired JSONL events, rejects duplicate cases and cross-split users, reports correction/suggestion/oracle metrics and tail latency, computes user-cluster bootstrap intervals, exact paired McNemar significance, and category slices. | A prolific test user cannot inflate confidence, and the company baseline is compared on the exact same events. Synthetic regression tests remain useful but cannot masquerade as a production benchmark. |
| Artifact and privacy drift | `ARTIFACTS.json`, third-party notices, target-specific privacy manifests, deterministic hashes, release-only logging guards, and archive-content checks define the shipped data boundary. | Build output can be checked against reviewed provenance instead of trusting source-folder intent or Xcode target membership by inspection. |

### Remaining Release Gates

These are deliberately not marked complete by implementation work:

1. Collect a consented, privacy-reviewed, user-separated blind test set and replay the
   company production keyboard on the same events.
2. Establish accuracy, false-correction, suggestion, Glide, and latency budgets; require
   confidence intervals that beat the baseline rather than accepting point estimates.
3. Run p50/p95/p99, energy, thermal, sustained footprint, memory-warning, and jetsam tests
   on the oldest supported physical devices using the exact signed Release archive.
4. Complete VoiceOver, Switch Control, Voice Control, Dynamic Type, handedness, device,
   orientation, and host-app compatibility acceptance with real users.
5. Replace placeholder bundle/App Group identifiers and support/privacy metadata, then
   complete signing, App Review, privacy, corpus-license, and legal approval.
6. Stage rollout with a previous-build comparison and tested rollback. Do not market the
   keyboard as safer than production or comparable to Gboard until these gates pass.
