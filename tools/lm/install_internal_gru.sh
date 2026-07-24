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

resources="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
compiled_output="${resources}/gru.mlmodelc"
tokenizer_output="${resources}/gru_tokenizer.bin"
temporary="${TARGET_TEMP_DIR}/internal-gru-coreml"
stamp="${TARGET_TEMP_DIR}/internal-gru.sha256"

# Skip recompilation when neither the model package nor the tokenizer changed.
fingerprint=$(
    find "$model_package" -type f -print0 \
        | sort -z \
        | xargs -0 shasum -a 256
    shasum -a 256 "$tokenizer_model"
)
fingerprint=$(printf '%s' "$fingerprint" | shasum -a 256 | awk '{print $1}')
if [ -d "$compiled_output" ] && [ -f "$tokenizer_output" ] \
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
printf '%s' "$fingerprint" > "$stamp"
echo "note: installed internal GRU search prior and tokenizer"
