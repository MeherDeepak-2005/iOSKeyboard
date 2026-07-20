#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
output="$repo_root/Config/Klipy.xcconfig"
key="${KLIPY_API_KEY:-}"
filter="${KLIPY_CONTENT_FILTER_APPROVED:-NO}"
enabled="${KLIPY_MEDIA_ENABLED:-YES}"

if [[ -z "$key" ]]; then
	print -u2 "KLIPY_API_KEY is required."
	exit 64
fi
if [[ ! "$key" =~ '^[A-Za-z0-9_-]+$' ]]; then
	print -u2 "KLIPY_API_KEY contains characters rejected by the keyboard client."
	exit 64
fi
if [[ "$filter" != YES ]]; then
	print -u2 "Set KLIPY_CONTENT_FILTER_APPROVED=YES only after Partner Panel review."
	exit 64
fi
if [[ "$enabled" != YES && "$enabled" != NO ]]; then
	print -u2 "KLIPY_MEDIA_ENABLED must be YES or NO."
	exit 64
fi

umask 077
temporary="$(mktemp "$repo_root/Config/.Klipy.xcconfig.XXXXXX")"
trap 'rm -f "$temporary"' EXIT
{
	print -r -- "// Generated locally by tools/configure_klipy.sh. Do not commit."
	print -r -- "KLIPY_API_KEY = $key"
	print -r -- "KLIPY_CONTENT_FILTER_APPROVED = $filter"
	print -r -- "KLIPY_MEDIA_ENABLED = $enabled"
} > "$temporary"
chmod 600 "$temporary"
mv -f "$temporary" "$output"
trap - EXIT
print "Configured KLIPY build settings without printing the key."
