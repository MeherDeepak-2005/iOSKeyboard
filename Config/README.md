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

`INTERNAL_NEURAL_MODEL_PACKAGE` and `INTERNAL_NEURAL_TOKENIZER_MODEL` are consumed
by Debug builds. Ordinary Release builds do not read, compile, or bundle those
paths. The Xcode build phase compiles the Core ML package and creates the compact
tokenizer artifact without requiring a globally installed `sentencepiece` Python
module.

For optimized physical-device profiling, explicitly opt in with both the build
setting and Swift compilation condition:

```sh
xcodebuild -scheme keyboard -configuration Release -sdk iphoneos \
  -destination 'generic/platform=iOS' INTERNAL_NEURAL_ENABLED=YES \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS=INTERNAL_NEURAL \
  ENABLE_USER_SCRIPT_SANDBOXING=NO build
```

This is an internal artifact, not the shipping configuration. Audit its extension
with `tools/verify_release_artifacts.py --allow-neural`. A normal Release build omits
the model and is still checked against the stricter 14 MB/no-neural gate.
