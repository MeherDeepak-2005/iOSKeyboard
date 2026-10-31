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

"${CXX:-clang++}" -std=c++20 -Wall -Wextra -Werror -g \
  -fsanitize=address,undefined -fno-omit-frame-pointer \
  "$repo_root/native/DecoderCore/src/"*.cpp \
  "$repo_root/native/tests/EngineTests.cpp" -o "$work_dir/engine-tests"
"$work_dir/engine-tests" "$repo_root/keyboard/langdata.bin" "$repo_root" "$repo_root/tools/evaluation/fixtures/shared-engine"

"${CXX:-clang++}" -std=c++20 -Wall -Wextra -Werror -g \
  -fsanitize=address,undefined -fno-omit-frame-pointer \
  "$repo_root/native/DecoderCore/src/"*.cpp \
  "$repo_root/native/tests/NeuralLanguageModelTests.cpp" -o "$work_dir/nss-tests"
# Tiny random models cover each NSS kernel; the trained model, when exported, too.
for model in "$repo_root/native/tests/fixtures/nss/"*.nsslm "$repo_root/keyboard/nss-english.nsslm"; do
  [ -f "$model" ] || continue
  "$work_dir/nss-tests" "$model" "${model%.nsslm}.goldens.json" "$repo_root/keyboard/langdata.bin"
done

"${CXX:-clang++}" -std=c++20 -Wall -Wextra -Werror -g \
  -fsanitize=address,undefined -fno-omit-frame-pointer \
  "$repo_root/native/DecoderCore/src/"*.cpp \
  "$repo_root/native/tests/NeuralFstTests.cpp" -o "$work_dir/nss-fst-tests"
"$work_dir/nss-fst-tests" "$repo_root/keyboard/nss-english.nsslm" "$repo_root/keyboard/langdata.bin"
