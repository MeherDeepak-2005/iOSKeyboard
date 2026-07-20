#!/bin/sh
set -eu

# The research scorer is a Debug artifact unless an optimized internal build opts in
# explicitly. Ordinary Release builds leave no model/tokenizer behind even when a
# developer has local paths configured.
if [ "${CONFIGURATION:-}" != "Debug" ] \
        && [ "${INTERNAL_NEURAL_ENABLED:-NO}" != "YES" ]; then
    exit 0
fi

model_package="${INTERNAL_NEURAL_MODEL_PACKAGE:-}"
tokenizer_model="${INTERNAL_NEURAL_TOKENIZER_MODEL:-}"
if [ -z "$model_package" ] || [ -z "$tokenizer_model" ]; then
    echo "note: internal neural scorer is not configured"
    exit 0
fi
if [ ! -d "$model_package" ] || [ ! -f "$tokenizer_model" ]; then
    echo "warning: internal neural scorer paths are invalid; see Config/Secrets.xcconfig.example"
    exit 0
fi

resources="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
compiled_output="${resources}/rescorer.mlmodelc"
tokenizer_output="${resources}/tokenizer.bin"
temporary="${TARGET_TEMP_DIR}/internal-neural-coreml"
stamp="${TARGET_TEMP_DIR}/internal-neural.sha256"

fingerprint=$(
    find "$model_package" -type f -print0 \
        | sort -z \
        | xargs -0 shasum -a 256
    shasum -a 256 "$tokenizer_model"
)
fingerprint=$(printf '%s' "$fingerprint" | shasum -a 256 | awk '{print $1}')
if [ -d "$compiled_output" ] && [ -f "$tokenizer_output" ] \
        && [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$fingerprint" ]; then
    echo "note: internal W8 scorer is current"
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
echo "note: installed internal W8 scorer and tokenizer"
