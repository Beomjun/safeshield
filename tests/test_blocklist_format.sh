#!/bin/sh
# shellcheck shell=sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

PKG_NAME='safeshield'
SS_TMP_DIR="$TMP_DIR/tmp"
SS_DNSMASQ_DIR="$TMP_DIR/dnsmasq.d"
SS_BLOCKLIST_FILE="$SS_DNSMASQ_DIR/safeshield.blocklist"
ss_min_valid_line_count=0
ss_max_blocklist_file_size_kb=1024
ss_dnsmasq_sanity_check=0
ss_valid_line_count=0

mkdir -p "$SS_TMP_DIR" "$SS_DNSMASQ_DIR"

ss_should_stop() { return 1; }
ss_status_set() { :; }
ss_status_add_error() { :; }
log_info() { :; }
log_error() { :; }
log_warn() { :; }
ss_sync_path() { :; }
ss_blocklist_tmp_path() { printf '%s/.safeshield.blocklist.tmp.%s\n' "$SS_DNSMASQ_DIR" "$$"; }
ss_install_blocklist_atomic() { mv -f "$1" "$2"; }

# shellcheck disable=SC1091
. "$ROOT/files/usr/lib/safeshield/blocklist.sh"

fail() {
	printf 'FAIL: %s\n' "$1" >&2
	exit 1
}

normalized="$(printf '%s\n' \
	'address=/ads.example/#' \
	'address=/legacy-v4.example/0.0.0.0' \
	'address=/legacy-v6.example/::' | ss_normalize_domains)"
expected='ads.example
legacy-v4.example
legacy-v6.example'
[ "$normalized" = "$expected" ] || fail 'optimized /# artifact normalization failed'

cat >"$SS_TMP_DIR/api.block.txt" <<'DATA'
ads.example
tracker.example
ads.example
DATA
: >"$SS_TMP_DIR/allowlist.txt"

ss_merge_lists || fail 'ss_merge_lists failed'

expected='address=/ads.example/#
address=/tracker.example/#'
actual="$(cat "$SS_BLOCKLIST_FILE")"
[ "$actual" = "$expected" ] || fail 'active blocklist is not using one /# rule per domain'

count="$(grep -c . "$SS_BLOCKLIST_FILE")"
[ "$count" = '2' ] || fail 'rule count must equal unique blocked domain count'

check_blocklist_rule_present 'ads.example' || fail 'optimized rule verification failed'
first_domain="$(find_test_domains 1)"
[ "$first_domain" = 'ads.example' ] || fail 'optimized rule sampling failed'

cat >"$SS_BLOCKLIST_FILE" <<'DATA'
address=/legacy.example/0.0.0.0
address=/legacy.example/::
DATA
check_blocklist_rule_present 'legacy.example' || fail 'legacy rule verification compatibility failed'

printf '%s\n' 'blocklist format tests: ok'
