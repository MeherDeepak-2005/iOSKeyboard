# Native primary backend verification

The vocabulary pipeline was executed. The resulting `keyboard/langdata.bin`
contains **61,082 forms**, occupies **9,455,641 bytes**, and is byte-identical to
the dictionary in the final device-target iOS build. Its SHA-256 is
`ddbb25cb14d90bfb3e0097980aab68b8423f9e768b9bdfb8fbdbd55f163298d2`.
The earlier expansion comparison is preserved in `../english-vocabulary/`.

| Gate | Result | Evidence |
|---|---|---|
| Release simulator tests, independent Swift/native comparisons | 104 passed, zero failures | `simulator-test-results.json` |
| Severe typo `coeevitjkn → correction` | 155/155 correct commits across five contexts; correction ranked first | `coeevitjkn-native-primary.json` |
| Portable C++ ASan/UBSan | Passed formats 2–5, malformed/truncated packs, ownership, spatial/DP, boosted seeds, corpus search/cancellation and score assertions | `native-tests.log` |
| Portable CMake/CTest | 1/1 passed with actual expanded corpus | `cmake-tests.log` |
| Dictionary pipeline tests | 12/12 passed | `vocabulary-tests.log` |
| macOS Glide and paired native benchmark harnesses | Compile-only passed | Harness scripts; no new timing comparison claimed |
| Android JNI adapter | Host Clang C++20 syntax check with warnings as errors passed | `verification.json` |
| Unsigned device-target extension | 13,794,230 / 14,000,000 bytes | `device-release-bundle-audit.json` |
| Locally ad-hoc signed extension, strict codesign verification | 13,818,780 / 14,000,000 bytes | `adhoc-device-bundle-audit.json` |

Normal Release excludes large Swift reference search bodies and audit-only bridge
materializers. Debug/test builds explicitly enable them. Both iOS application and
extension Release targets use Swift `-Osize`; the C++ optimization settings, word
frequencies, thresholds and dictionary bytes were preserved. This reduces code
size; its effect on runtime speed has not been measured on a physical device.
The final test run used these size settings with `ENABLE_TESTABILITY=YES`, retaining
the independent reference implementation for comparisons within `1e-9`.

The native backend is now the default for packed static full search, retained
English search and batched language-score mathematics. See the exact remaining
ownership inventory in [the architecture document](../../ANDROID_IOS_ARCHITECTURE.md).
Final policy/ranking, mutable adopted words, Glide and neural migration remain work
for subsequent parity stages. Telugu and transliteration remain in Swift.

Android SDK/NDK, Java, Kotlin and Gradle are unavailable on this machine. The
Kotlin library, JNI adapter, CMake integration and shared dictionary staging are
prepared, but an Android build, ABI/link check and device test are pending. The
JNI syntax check used official OpenJDK 17 JNI headers temporarily; those headers
are not part of the application or checked-in sources.

The severe-typo timings were collected during a concurrent simulator test suite,
including initialization and other tests. They establish regression quality,
not a paired performance improvement. Physical iPhone/Android latency and RAM
remain unmeasured. Trained neural artifacts are unavailable; the trained neural
comparison remains pending. Deterministic model fixtures only verify plumbing.

The signed size check uses a local ad-hoc signature, not App Store distribution
provisioning. Recheck the distribution-signed archive before release. No app was
deployed or published during this work.
