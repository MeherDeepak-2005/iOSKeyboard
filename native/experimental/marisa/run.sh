#!/bin/sh
set -eu
experiment_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$experiment_dir/../../.." && pwd)
result_dir=${1:-$experiment_dir/results}
mkdir -p "$result_dir"
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/kb-marisa-experiment.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT HUP INT TERM
if [ "${2:-}" = "--sanitize" ]; then
  cmake -S "$experiment_dir" -B "$work_dir/build" -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    '-DCMAKE_CXX_FLAGS=-fsanitize=address,undefined -fno-omit-frame-pointer' > "$result_dir/sanitizer-build.log"
else
  cmake -S "$experiment_dir" -B "$work_dir/build" -DCMAKE_BUILD_TYPE=Release > "$result_dir/build.log"
fi
cmake --build "$work_dir/build" -j 4 >> "$result_dir/build.log" 2>&1
runner="$work_dir/build/marisa-experiment"
corpus="$repo_root/keyboard/langdata.bin"
index="$work_dir/vocabulary.marisa"
"$runner" "$corpus" "$index" build > "$result_dir/storage.json"
if [ "${2:-}" = "--sanitize" ]; then
  "$runner" "$corpus" "$index" test > "$result_dir/sanitizer-parity.json"
  exit 0
fi
"$runner" "$corpus" "$index" test > "$result_dir/parity.json"
for trial in 1 2 3; do
  "$runner" "$corpus" "$index" bench > "$result_dir/timing-$trial.json"
  for backend in packed marisa; do
    "$runner" "$corpus" "$index" "memory-$backend" > "$result_dir/memory-$backend-$trial.json"
  done
done
python3 - "$result_dir" "$corpus" <<'PY'
import hashlib, json, pathlib, platform, statistics, sys
out = pathlib.Path(sys.argv[1])
timings = [json.loads(p.read_text()) for p in sorted(out.glob('timing-*.json'))]
summary = {
    'host': platform.platform(),
    'corpus_sha256': hashlib.sha256(pathlib.Path(sys.argv[2]).read_bytes()).hexdigest(),
    'timing_trials': len(timings),
    'median_of_trials': {key: statistics.median(t[key] for t in timings)
                         for key in timings[0] if key != 'checksum'},
    'peak_rss_bytes': {},
}
for backend in ('packed', 'marisa'):
    values = []
    for p in sorted(out.glob(f'memory-{backend}-*.json')):
        values.append(json.loads(p.read_text())['peak_rss_bytes'])
    summary['peak_rss_bytes'][backend] = values
(out / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
PY
