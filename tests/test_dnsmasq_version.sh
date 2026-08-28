#!/bin/sh
# shellcheck shell=sh
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

PKG_NAME='safeshield'
export PKG_NAME

# shellcheck disable=SC1091
. "$ROOT/files/usr/lib/safeshield/utils.sh"

ss_status_set() { :; }
log_error() { :; }

# shellcheck disable=SC1091
. "$ROOT/files/usr/lib/safeshield/dns.sh"

fail() {
	printf 'FAIL: %s\n' "$1" >&2
	exit 1
}

make_dnsmasq() {
	version="$1"
	cat >"$TMP_DIR/dnsmasq" <<SCRIPT
#!/bin/sh
printf '%s\\n' 'Dnsmasq version ${version} Copyright (c) 2000-2026 Simon Kelley'
SCRIPT
	chmod +x "$TMP_DIR/dnsmasq"
}

PATH="$TMP_DIR:$PATH"
export PATH

make_dnsmasq '2.80'
[ "$(ss_dnsmasq_version)" = '2.80' ] || fail 'failed to parse dnsmasq 2.80'
ss_require_supported_dnsmasq || fail 'dnsmasq 2.80 must be supported'

make_dnsmasq '2.90'
ss_require_supported_dnsmasq || fail 'dnsmasq 2.90 must be supported'

make_dnsmasq '2.80rc1'
[ "$(ss_dnsmasq_version)" = '2.80' ] || fail 'version suffix must be stripped'
ss_require_supported_dnsmasq || fail 'dnsmasq 2.80rc1 must compare as 2.80'

make_dnsmasq '2.79'
if ss_require_supported_dnsmasq; then
	fail 'dnsmasq 2.79 must be rejected'
fi
[ "$(ss_dnsmasq_check_error)" = 'dnsmasq_version_unsupported' ] || fail 'unexpected error for unsupported dnsmasq'

cat >"$TMP_DIR/dnsmasq" <<'SCRIPT'
#!/bin/sh
printf '%s\n' 'unexpected version output'
SCRIPT
chmod +x "$TMP_DIR/dnsmasq"
if ss_require_supported_dnsmasq; then
	fail 'unparseable dnsmasq version must be rejected'
fi
[ "$(ss_dnsmasq_check_error)" = 'dnsmasq_version_unknown' ] || fail 'unexpected error for unknown dnsmasq version'

rm -f "$TMP_DIR/dnsmasq"
ORIGINAL_PATH="$PATH"
PATH="$TMP_DIR"
if ss_require_supported_dnsmasq; then
	fail 'missing dnsmasq binary must be rejected'
fi
PATH="$ORIGINAL_PATH"
[ "$(ss_dnsmasq_check_error)" = 'dnsmasq_binary_not_found' ] || fail 'unexpected error for missing dnsmasq binary'

printf '%s\n' 'dnsmasq version tests: ok'
