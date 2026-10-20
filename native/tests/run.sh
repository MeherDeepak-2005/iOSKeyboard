#!/bin/sh
set -eu
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/kb-native-tests.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT HUP INT TERM
# ASan/UBSan catch unsafe accesses and arithmetic in malformed/truncated fixtures.
"${CXX:-clang++}" -std=c++20 -Wall -Wextra -Werror -g \
  -fsanitize=address,undefined -fno-omit-frame-pointer \
  "$repo_root/native/DecoderCore/src/"*.cpp \
  "$repo_root/native/tests/PackedLexiconTests.cpp" -o "$work_dir/packed-tests"
"$work_dir/packed-tests" "$repo_root/keyboard/langdata.bin"

"${CXX:-clang++}" -std=c++20 -Wall -Wextra -Werror -g \
  -fsanitize=address,undefined -fno-omit-frame-pointer \
  "$repo_root/native/DecoderCore/src/"*.cpp \
  "$repo_root/native/tests/CandidateGenerationTests.cpp" -o "$work_dir/candidate-tests"
"$work_dir/candidate-tests"

"${CXX:-clang++}" -std=c++20 -Wall -Wextra -Werror -g \
  -fsanitize=address,undefined -fno-omit-frame-pointer \
  "$repo_root/native/DecoderCore/src/"*.cpp \
  "$repo_root/native/tests/NeuralSearchTests.cpp" -o "$work_dir/neural-tests"
"$work_dir/neural-tests"
