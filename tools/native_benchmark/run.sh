#!/bin/sh
set -eu
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/kb-native-bench.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT HUP INT TERM
for source_name in PackedLexicon SpatialModel IncrementalSearch CandidateGeneration; do
  xcrun clang++ -std=c++20 -O3 -c "$repo_root/native/DecoderCore/src/$source_name.cpp" -o "$work_dir/$source_name.o"
done
xcrun clang++ -std=c++20 -O3 -DKB_REFERENCE_DECODER_YES=1 -fobjc-arc -c "$repo_root/native/iOS/KBDecoderBridge.mm" -o "$work_dir/bridge.o"
swiftc -O -D KB_BENCHMARK_CLI -D KB_REFERENCE_DECODER_YES -Xcc -DKB_REFERENCE_DECODER_YES=1 -module-cache-path "$work_dir/modules" \
  -import-objc-header "$repo_root/native/iOS/Keyboard-Bridging-Header.h" \
  "$repo_root/keyboard/Engine/SpatialModel.swift" "$repo_root/keyboard/Engine/Trie.swift" \
  "$repo_root/keyboard/Engine/LangData.swift" "$repo_root/keyboard/Engine/NativeDecoderParity.swift" \
  "$repo_root/tools/glide_eval/PlatformShim.swift" "$repo_root/keyboardTests/NativePerformanceBenchmark.swift" \
  "$repo_root/tools/native_benchmark/main.swift" "$work_dir/"*.o -lc++ -framework Foundation -o "$work_dir/benchmark"
if [ "${1:-}" = "--build-only" ]; then exit 0; fi
result_dir="${1:-$repo_root/tools/evaluation/results/native-performance}"
mkdir -p "$result_dir"
if [ "${2:-}" = "--memory-only" ]; then
  : # Retain previously measured timing reports; rerun isolated RSS processes.
elif [ "${2:-}" = "--mapped" ]; then
  "$work_dir/benchmark" "$repo_root/keyboard/langdata.bin" --mapped "$result_dir/macos-kernels.json"
  "$work_dir/benchmark" "$repo_root/keyboard/langdata.bin" --initialization "$result_dir/macos-initialization.json"
else
  "$work_dir/benchmark" "$repo_root/keyboard/langdata.bin" "$result_dir/macos-kernels.json"
fi
for trial in 1 2 3 4 5; do
  for backend in swift native native_mapped; do
    /usr/bin/time -l "$work_dir/benchmark" "$repo_root/keyboard/langdata.bin" --memory "$backend" \
      > "$result_dir/memory-$backend-$trial.json" 2> "$result_dir/memory-$backend-$trial.txt"
  done
done
