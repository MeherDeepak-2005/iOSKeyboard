#!/bin/bash
# Engine speed and memory on a connected iPhone (keyboardTests/EnginePerformanceBenchmark.swift):
# engine start, word-start prediction, per-keystroke decode, glide and live-swipe latency, footprint.
#   tools/perf/device_perf.sh DEVICE_ID NAME [Release|Debug] [BUILD_SETTING=value ...]
# Release (default) is the shipping optimisation, made testable for @testable import, with the
# extension's raw NSS flag applied to the test host too (the decoder bridge is compiled into both).
# The phone must stay unlocked. Writes tools/perf/results/NAME.json.
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
device="$1"; name="$2"; config="${3:-Release}"; shift $(( $# < 3 ? $# : 3 ))
out="$repo/tools/perf/results"; mkdir -p "$out"
log="$(mktemp -t device-perf)"
TEST_RUNNER_KB_PERF=1 xcodebuild test -project "$repo/keyboard.xcodeproj" -scheme keyboard \
  -configuration "$config" -destination "platform=iOS,id=$device" -allowProvisioningUpdates \
  -only-testing:keyboardTests/EnginePerformanceBenchmark \
  ENABLE_TESTABILITY=YES 'GCC_PREPROCESSOR_DEFINITIONS=$(inherited) KB_NSS_RAW=1' "$@" >"$log" 2>&1 || true
json="$(grep -o 'KB_PERF {.*}' "$log" | head -1 | cut -c9- || true)"
view="$(grep -o 'KB_PERF_VIEW {.*}' "$log" | head -1 | cut -c14- || true)"
if [ -z "$json" ]; then
  grep -E "error:|✘|Unlock|Lost" "$log" | head -20 >&2 || true
  echo "no KB_PERF result; full log: $log" >&2
  exit 1
fi
python3 -c 'import json, sys
report = json.loads(sys.argv[1])
if sys.argv[2]: report["keyboardView"] = json.loads(sys.argv[2])
print(json.dumps(report, indent=2, sort_keys=True))' "$json" "$view" >"$out/$name.json"
rm -f "$log"
echo "$out/$name.json"
