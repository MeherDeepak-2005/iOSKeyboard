#!/bin/sh
# Compile the production Glide sources and native comparison seam into a Mac CLI.
set -eu
cd "$(dirname "$0")"
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/kb-glide-eval.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT HUP INT TERM
for source_name in PackedLexicon SpatialModel IncrementalSearch CandidateGeneration; do
  xcrun clang++ -std=c++20 -O2 -c "../../native/DecoderCore/src/$source_name.cpp" -o "$work_dir/$source_name.o"
done
xcrun clang++ -std=c++20 -O2 -fobjc-arc -c ../../native/iOS/KBDecoderBridge.mm -o "$work_dir/bridge.o"
swiftc -O -module-cache-path "$work_dir/modules" \
  -import-objc-header ../../native/iOS/Keyboard-Bridging-Header.h \
  ../../keyboard/Engine/SpatialModel.swift \
  ../../keyboard/Engine/Trie.swift \
  ../../keyboard/Engine/LangData.swift \
  ../../keyboard/Engine/NativeDecoderParity.swift \
  ../../keyboard/Engine/GlidePath.swift \
  PlatformShim.swift main.swift "$work_dir/PackedLexicon.o" "$work_dir/SpatialModel.o" "$work_dir/IncrementalSearch.o" "$work_dir/CandidateGeneration.o" "$work_dir/bridge.o" \
  -lc++ -framework Foundation -o "$work_dir/glide_eval"
if [ "${1:-}" = "--build-only" ]; then exit 0; fi
"$work_dir/glide_eval" "$@"
