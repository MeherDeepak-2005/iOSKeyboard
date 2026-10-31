#!/bin/sh
set -eu

# Word-level neural search space LM (tools/nss). Bundled ONLY for an explicit internal
# build, never for ordinary Debug or Release builds. Pair INTERNAL_NSS_ENABLED=YES with
# the INTERNAL_NSS Swift compile flag (KeyboardEngine.shared), which maps the model at
# startup and selects the shared engine's "nss" tier for English word sessions.
resources="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
if [ "${INTERNAL_NSS_ENABLED:-NO}" != "YES" ]; then
    # An ordinary build may reuse a directory from an earlier internal build.
    rm -f "${resources}/nss-english.nsslm"
    echo "note: NSS word model not enabled (set INTERNAL_NSS_ENABLED=YES to bundle)"
    exit 0
fi

model="${INTERNAL_NSS_MODEL:-}"
if [ -z "$model" ] || [ ! -f "$model" ]; then
    echo "warning: INTERNAL_NSS_MODEL does not name an .nsslm file; see Config/Secrets.xcconfig.example"
    exit 0
fi

mkdir -p "$resources"
ditto "$model" "${resources}/nss-english.nsslm"
echo "note: installed the NSS word model ($(wc -c < "$model" | tr -d ' ') bytes)"
