#!/bin/sh
set -eu

# GRU streaming search-prior model (roadmap Plan 3 / NN-LM in the trie). Bundled ONLY for
# an explicit internal profiling build, never for ordinary Debug or Release builds. Pair it
# with the INTERNAL_GRU Swift compile flag (KeyboardEngine.shared) so the extension both
# bundles the model AND wires GRULanguagePrior into contextSearchPrior. Mirrors
# install_internal_coreml.sh; the two are independent switches.
if [ "${INTERNAL_GRU_ENABLED:-NO}" != "YES" ]; then
    echo "note: GRU search prior not enabled (set INTERNAL_GRU_ENABLED=YES to bundle)"
    exit 0
fi

model_package="${INTERNAL_GRU_MODEL_PACKAGE:-}"
tokenizer_model="${INTERNAL_GRU_TOKENIZER_MODEL:-}"
if [ -z "$model_package" ] || [ -z "$tokenizer_model" ]; then
    echo "note: GRU model paths are not configured (see Config/Secrets.xcconfig.example)"
    exit 0
fi
if [ ! -d "$model_package" ] || [ ! -f "$tokenizer_model" ]; then
    echo "warning: GRU model paths are invalid; see Config/Secrets.xcconfig.example"
    exit 0
fi

score_package="${INTERNAL_GRU_SCORE_PACKAGE:-}"
resources="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
compiled_output="${resources}/gru.mlmodelc"
score_output="${resources}/gru_score.mlmodelc"
tokenizer_output="${resources}/gru_tokenizer.bin"
temporary="${TARGET_TEMP_DIR}/internal-gru-coreml"
stamp="${TARGET_TEMP_DIR}/internal-gru.sha256"

# Skip recompilation when neither model package, the tokenizer, nor the optional score package changed.
fingerprint=$(
    find "$model_package" -type f -print0 | sort -z | xargs -0 shasum -a 256
    shasum -a 256 "$tokenizer_model"
    if [ -n "$score_package" ] && [ -d "$score_package" ]; then
        find "$score_package" -type f -print0 | sort -z | xargs -0 shasum -a 256
    fi
)
fingerprint=$(printf '%s' "$fingerprint" | shasum -a 256 | awk '{print $1}')
score_current=true
if [ -n "$score_package" ] && [ ! -d "$score_output" ]; then score_current=false; fi
if [ -d "$compiled_output" ] && [ -f "$tokenizer_output" ] && [ "$score_current" = true ] \
        && [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$fingerprint" ]; then
    echo "note: internal GRU search prior is current"
    exit 0
fi

rm -rf "$temporary" "$compiled_output"
rm -f "$tokenizer_output"
mkdir -p "$temporary" "$resources"
xcrun coremlcompiler compile "$model_package" "$temporary"

set -- "$temporary"/*.mlmodelc
if [ "$#" -ne 1 ] || [ ! -d "$1" ]; then
    echo "error: Core ML compiler did not emit exactly one model"
    exit 1
fi
ditto "$1" "$compiled_output"
python3 "${SRCROOT}/tools/lm/export_coreml.py" \
    --part tokenizer \
    --sentencepiece "$tokenizer_model" \
    --tokenizer-output "$tokenizer_output"

# Optional batched scorer — bundle only when configured; GRULanguagePrior falls back to the
# single-step path when gru_score.mlmodelc is absent, so this never blocks the search prior.
rm -rf "$score_output"
if [ -n "$score_package" ] && [ -d "$score_package" ]; then
    score_temporary="${TARGET_TEMP_DIR}/internal-gru-score"
    rm -rf "$score_temporary"
    mkdir -p "$score_temporary"
    xcrun coremlcompiler compile "$score_package" "$score_temporary"
    set -- "$score_temporary"/*.mlmodelc
    if [ "$#" -eq 1 ] && [ -d "$1" ]; then
        ditto "$1" "$score_output"
        echo "note: installed internal GRU batched scorer"
    else
        echo "warning: GRU score compiler did not emit exactly one model"
    fi
fi

printf '%s' "$fingerprint" > "$stamp"
echo "note: installed internal GRU search prior and tokenizer"
