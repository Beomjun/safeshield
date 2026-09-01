#!/bin/sh
# shellcheck shell=sh
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

SS_TMP_DIR="$TMP"
export SS_TMP_DIR

# shellcheck disable=SC1090
. "$ROOT/files/usr/lib/safeshield/blocklist.sh"

cat >"$TMP/api.0.block.txt" <<'EOF_BLOCK_0'
alpha.example
shared.example
EOF_BLOCK_0
cat >"$TMP/api.1.block.txt" <<'EOF_BLOCK_1'
beta.example
shared.example
EOF_BLOCK_1

ss_merge_sorted_api_sources block "$TMP/merged-blocks.txt"
expected='alpha.example
beta.example
shared.example'
[ "$(cat "$TMP/merged-blocks.txt")" = "$expected" ] || {
	echo 'sorted API artifact merge produced unexpected output' >&2
	exit 1
}

rm -f "$TMP"/api.*.block.txt
ss_merge_sorted_api_sources block "$TMP/empty-blocks.txt"
[ ! -s "$TMP/empty-blocks.txt" ] || {
	echo 'sorted API artifact merge must preserve empty-input behavior' >&2
	exit 1
}

BLOCKLIST="$ROOT/files/usr/lib/safeshield/blocklist.sh"
STATISTICS="$ROOT/files/usr/lib/safeshield/statistics.awk"

grep -F 'sort -m -u "$@" >"$out"' "$BLOCKLIST" >/dev/null || {
	echo 'API artifact merge is not using sorted merge mode' >&2
	exit 1
}
grep -F 'delete device_first_bucket[key]' "$STATISTICS" >/dev/null || {
	echo 'statistics totals pass does not rebuild per-device bucket bounds' >&2
	exit 1
}
grep -F 'device_first_hour = device_first_bucket[key] + 0' "$STATISTICS" >/dev/null || {
	echo 'statistics JSON does not use the per-device first bucket' >&2
	exit 1
}
grep -F 'for (bucket = device_first_hour; bucket <= device_last_hour; bucket += 3600)' "$STATISTICS" >/dev/null || {
	echo 'statistics JSON is not bounded to each device active range' >&2
	exit 1
}

printf '%s\n' 'performance path tests: ok'
