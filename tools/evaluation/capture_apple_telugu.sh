#!/bin/zsh
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <booted-simulator-udid>" >&2
  exit 64
fi

UDID="$1"
RESULT_ROOT="${APPLE_TELUGU_RESULT_DIR:-${TMPDIR:-/tmp}}"
RESULT="${RESULT_ROOT%/}/apple-telugu-$(date +%Y%m%d-%H%M%S).xcresult"

# XCTest does not reliably inherit arbitrary shell variables when testmanagerd
# launches a UI-test runner. A temporary global preference is visible to that
# process and is removed even if xcodebuild fails.
xcrun simctl spawn "$UDID" defaults write NSGlobalDomain \
  KeyboardCaptureAppleTeluguReference -bool YES
trap 'xcrun simctl spawn "$UDID" defaults delete NSGlobalDomain KeyboardCaptureAppleTeluguReference >/dev/null 2>&1 || true' EXIT

CAPTURE_APPLE_TELUGU=1 xcodebuild \
  -scheme keyboard \
  -sdk iphonesimulator \
  -destination "id=${UDID}" \
  -resultBundlePath "$RESULT" \
  -only-testing:keyboardUITests/keyboardUITests/testCaptureAppleTeluguReference \
  test

echo "$RESULT"
