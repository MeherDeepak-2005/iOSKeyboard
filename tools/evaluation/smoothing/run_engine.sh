#!/bin/sh
# Replay frozen requests through production KeyboardEngine in an iOS simulator.
set -eu
repo_root=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
mode=${1:-baseline}
case "$mode" in baseline|validation) ;; *) echo 'Usage: run_engine.sh baseline|validation' >&2; exit 2 ;; esac
config=/tmp/ioskeyboard-correction-calibration-config.json
trap 'rm -f "$config"' EXIT HUP INT TERM
python3 - "$repo_root" "$mode" "$config" <<'PY'
from pathlib import Path
import json,sys
root=Path(sys.argv[1]);mode=sys.argv[2];out=root/'tools/evaluation/results/correction-calibration-2026-10-19'
sys.path.insert(0,str(root/'tools/evaluation/smoothing'))
from calibrate import BASELINE
policy=BASELINE if mode=='baseline' else json.loads((out/'frozen-policy.json').read_text())['policy']
dataset='all.jsonl' if mode=='baseline' else 'validation.jsonl'
output='baseline-engine.jsonl' if mode=='baseline' else 'selected-validation-engine.jsonl'
Path(sys.argv[3]).write_text(json.dumps(dict(dataset=str(out/dataset),output=str(out/output),policy=policy,smoothing='modifiedKneserNey',incrementalEvery=0 if mode=='baseline' else 20)))
PY
output_dir="$repo_root/tools/evaluation/results/correction-calibration-2026-10-19"
if ! xcodebuild -project "$repo_root/keyboard.xcodeproj" -scheme keyboard -configuration Debug \
    -destination "${KB_CALIBRATION_DESTINATION:-platform=iOS Simulator,name=iPhone 17 Pro}" \
    -derivedDataPath /tmp/ioskeyboard-mkn-derived CODE_SIGNING_ALLOWED=NO test \
    '-only-testing:keyboardTests/CorrectionCalibrationTests/replayFrozenCalibrationRequests()' \
    > "$output_dir/$mode-xcode.log" 2>&1; then
    tail -n 50 "$output_dir/$mode-xcode.log" >&2
    exit 1
fi
tail -n 12 "$output_dir/$mode-xcode.log"
