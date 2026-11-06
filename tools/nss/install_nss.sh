#!/bin/sh
set -eu

# Word-level neural search space LM (tools/nss), bundled in every build unless
# NSS_ENABLED=NO (Config/Extension.xcconfig). KeyboardEngine.shared maps it at startup
# and selects the shared engine's "nss" tier for English word sessions.
resources="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
if [ "${NSS_ENABLED:-YES}" != "YES" ]; then
    # An ordinary build may reuse a directory from an earlier internal build.
    rm -f "${resources}/nss-english.nsslm"
    echo "note: NSS word model not enabled (NSS_ENABLED=NO)"
    exit 0
fi

model="${NSS_MODEL:-}"
if [ -z "$model" ] || [ ! -f "$model" ]; then
    echo "warning: NSS_MODEL does not name an .nsslm file; the keyboard falls back to n-gram"
    exit 0
fi

mkdir -p "$resources"
# cp writes the declared output in place; ditto stages a temp file the script sandbox denies.
cp -f "$model" "${resources}/nss-english.nsslm"
echo "note: installed the NSS word model ($(wc -c < "$model" | tr -d ' ') bytes)"
