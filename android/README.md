# Android integration preparation

Use Kotlin for the Android façade/UI and the same C++20 `DecoderCore` as iOS.
This repository currently supplies an Android **library integration**, not an
InputMethodService application. Final policy, learning, Glide and neural migration
are still needed for a complete keyboard. See `ANDROID_IOS_ARCHITECTURE.md`.

## Include the prepared library

An Android host project must supply AGP 9+, its compatible Gradle/JDK, Android SDK
(API 36 is the selected compile target), an installed NDK r28+ and CMake 3.22.1.
The module deliberately uses AGP's [built-in Kotlin](https://developer.android.com/build/migrate-to-built-in-kotlin).
If integrating with AGP 8, apply the host's compatible Kotlin Android plugin and
adapt the library DSL rather than changing the neutral core.

In the host `settings.gradle.kts`:

```kotlin
include(":xploreeDecoder")
project(":xploreeDecoder").projectDir = file("/path/to/iOSKeyboard/android/decoder")
```

The host resolves `com.android.library` with its pinned AGP version. In the host's
`gradle.properties`, set `xploree.ndkVersion` to the actual installed r28+ version.
NDK r28+ and AGP 9 support modern [16 KB page-size packaging](https://developer.android.com/guide/practices/page-sizes);
the selected library also uses `c++_shared` for one STL runtime across native adapters.

In the host application dependencies:

```kotlin
implementation(project(":xploreeDecoder"))
```

The library build stages `keyboard/langdata.bin`, its generated SHA-256 and
`keyboard/ThirdPartyNotices.txt` into **build outputs**. No second dictionary copy is
committed, and no source snapshots/corpus sentences are Android runtime resources.
Consumer R8 rules keep JNI names and result constructors stable.

## Use on the IME worker

```kotlin
val decoder = SharedEnglishDictionary.open(context)
try {
    // Pure channel evidence; do not directly turn the first candidate into a commit.
    val full = decoder.search("coeevitjkn", maxCost = 7.2)
    if (decoder.beginWord('c')) {
        decoder.advance("corre")
        decoder.advance("correction")
        val retained = decoder.candidates()
    }
} finally {
    decoder.close()
}
```

The asset helper streams/checksums the pack, installs a content-addressed private
file atomically, and opens a read-only mmap through JNI. Do not modify a mapped file
in place or create a decoder per keystroke. JNI registry ownership protects close
versus in-flight operations; each session has a serialized execution lane. Double
touch offsets are optional, normalized to iOS-compatible key-pitch units.

`beginWord` returning false means unsupported/over-cap seed coverage; use full
search, not a truncated seed set. Invalid retained input preserves the prior state.
Full search accepts optional terminal funding and tap buffers. Batched
`languageScores` accepts immutable corpus/personal evidence; the complete Android
vocabulary/personalization view and final ranking layer remain to migrate.

A future InputMethodService handles Android touch/layout extraction, accessibility,
InputConnection insertion, preferences, personal-data persistence/reset, external
integrations, scheduling and request identity validation. It must reject stale
results using all revision/session/epoch fields, not generation alone. English
ASCII decoding is this module's current scope; do not route other scripts through it.

## Current validation limits

The shared core builds and passes host CMake and sanitizer tests. JNI transport is
syntax-checked with official OpenJDK JNI headers; this is not an Android ABI/runtime
test. This development machine lacks the Android SDK, NDK, Gradle, Java runtime and
Kotlin compiler, so AAR/APK assembly and emulator/physical-device verification are
pending. No Android performance or UI behavior is claimed from host checks.
