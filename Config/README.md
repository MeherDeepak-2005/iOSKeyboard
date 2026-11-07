# Extension Build Configuration

`Extension.xcconfig` is the tracked base configuration for the keyboard extension.
It fails closed: remote media and internal neural artifacts are disabled unless a
developer supplies the corresponding ignored local configuration.

## KLIPY

1. Set `KLIPY_API_KEY` in the shell and run the configurator from the repository root:
   ```sh
   KLIPY_API_KEY='your_partner_key' \
   KLIPY_CONTENT_FILTER_APPROVED=YES \
   ./tools/configure_klipy.sh
   ```
   This writes an ignored, mode-`0600` `Klipy.xcconfig`; it never prints the key.
2. Set `KLIPY_CONTENT_FILTER_APPROVED = YES` only after the Partner Panel content
   filter and production account have been reviewed.
3. The configurator enables remote GIF and Sticker requests. Delete
   `Config/Klipy.xcconfig` to return to the fail-closed defaults.
4. Clean and rebuild the extension, then inspect the built extension's `Info.plist`
   to confirm all three values expanded.

For a one-off command-line build, Xcode build-setting overrides also work:
```sh
KLIPY_API_KEY='your_partner_key'
xcodebuild -scheme keyboard -configuration Debug -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  KLIPY_API_KEY="$KLIPY_API_KEY" \
  KLIPY_CONTENT_FILTER_APPROVED=YES KLIPY_MEDIA_ENABLED=YES build
unset KLIPY_API_KEY
```
The first `KLIPY_API_KEY` is a shell variable; the second is an Xcode build setting
expanded into the extension's `Info.plist`. It is not a runtime environment variable.

Do not use Xcode Scheme environment variables. A system-hosted keyboard extension
does not inherit them. `Klipy.xcconfig` and `Secrets.xcconfig` are ignored by Git;
the partner key is a public, rotatable mobile client identifier, but it still must
not be committed.

Release verification fails when media is enabled without both a non-empty key and
the approved filter flag. Emoji remains local, and typing performs no KLIPY network
request; GIF and Sticker traffic starts only after an explicit search.

## Internal Neural Model

The decoder's only neural model is the GRU neural search space: it generates
hypotheses inside the trie search and scores them, with no separate rescoring
model. `INTERNAL_GRU_MODEL_PACKAGE`, `INTERNAL_GRU_TOKENIZER_MODEL` and the optional
`INTERNAL_GRU_SCORE_PACKAGE` are read only when `INTERNAL_GRU_ENABLED=YES`; ordinary
Debug and Release builds do not read, compile, or bundle those paths. The Xcode
build phase compiles the Core ML package and creates the compact tokenizer artifact
(`tools/lm/export_tokenizer.py`) without requiring a globally installed
`sentencepiece` Python module.

For optimized physical-device profiling, explicitly opt in with both the build
setting and Swift compilation condition:

```sh
xcodebuild -scheme keyboard -configuration Release -sdk iphoneos \
  -destination 'generic/platform=iOS' INTERNAL_GRU_ENABLED=YES \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS=INTERNAL_GRU \
  ENABLE_USER_SCRIPT_SANDBOXING=NO build
```

The word-level NSS model (`tools/nss`, an `.nsslm` file run by the shared C++ engine,
not Core ML) is the English decoder in every build. `Extension.xcconfig` sets
`NSS_ENABLED = YES`, `NSS_MODEL = keyboard/nss-english.nsslm` and `KB_NSS_RAW=1` (the
official raw configuration), and `KeyboardEngine.shared` maps the model and selects
the `nss` tier from the first word. To build n-gram-only, or to try another export,
override them in `Secrets.xcconfig` or on the command line:

```sh
xcodebuild -scheme keyboard -configuration Release -sdk iphoneos \
  -destination 'generic/platform=iOS' NSS_ENABLED=NO build
```

Audit a shipping extension with `tools/verify_release_artifacts.py --allow-neural`;
without the flag the verifier applies the n-gram-only 14 MB/no-neural gate.

## Debug builds

Debug compiles C, C++ and Objective-C++ with `-Os` (`GCC_OPTIMIZATION_LEVEL = s`, set
once at project level); Swift stays at `-Onone`. At `-O0` the decoder core made a Debug
keyboard 20-25x slower per keystroke than Release on an iPhone 17 (16-20 ms against
0.8 ms, swipe previews ~100 ms against 8 ms), so a Debug install misrepresented the
keyboard. With the C++ optimised, Debug stays within 2x of Release (1.6 ms per keystroke).
Step through decoder C++ in `native/tests`, which builds with `-g` and sanitizers, or
set the level back to 0 locally. `tools/perf/device_perf.sh` measures either build.
