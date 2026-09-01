#!/bin/sh
# shellcheck shell=sh
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

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

cat >"$SS_TMP_DIR/api.0.block.txt" <<'DATA'
ads.example
tracker.example
ads.example
DATA
cat >"$SS_TMP_DIR/api.1.block.txt" <<'DATA'
phishing.example
tracker.example
DATA
cat >"$SS_TMP_DIR/api.2.allow.txt" <<'DATA'
tracker.example
remote-allow.example
DATA
cat >"$SS_TMP_DIR/local.block.txt" <<'DATA'
remote-allow.example
local-block.example
DATA
cat >"$SS_TMP_DIR/local.allow.txt" <<'DATA'
local-block.example
DATA
ss_merge_lists || fail 'ss_merge_lists failed'

expected='address=/ads.example/#
address=/phishing.example/#
address=/remote-allow.example/#
server=/local-block.example/#
server=/tracker.example/#'
actual="$(cat "$SS_BLOCKLIST_FILE")"
[ "$actual" = "$expected" ] || fail 'active blocklist is not using one /# rule per domain'

count="$(grep -c . "$SS_BLOCKLIST_FILE")"
[ "$count" = '5' ] || fail 'rule count must equal effective block/allow rule count'

check_blocklist_rule_present 'ads.example' || fail 'optimized rule verification failed'
first_domain="$(find_test_domains 1)"
[ "$first_domain" = 'ads.example' ] || fail 'optimized rule sampling failed'

rm -f "$SS_TMP_DIR"/api.*.block.txt "$SS_TMP_DIR"/api.*.allow.txt
cat >"$SS_TMP_DIR/api.0.block.txt" <<'DATA'
example.com
DATA
cat >"$SS_TMP_DIR/api.1.allow.txt" <<'DATA'
good.example.com
DATA
cat >"$SS_TMP_DIR/local.block.txt" <<'DATA'
blocked.good.example.com
DATA
cat >"$SS_TMP_DIR/local.allow.txt" <<'DATA'
allowed.blocked.good.example.com
DATA

ss_merge_lists || fail 'source precedence merge failed'
expected='address=/blocked.good.example.com/#
address=/example.com/#
server=/allowed.blocked.good.example.com/#
server=/good.example.com/#'
actual="$(cat "$SS_BLOCKLIST_FILE")"
[ "$actual" = "$expected" ] || fail 'source precedence is not local allow > local block > Hub allow > Hub block'

cat >"$SS_BLOCKLIST_FILE" <<'DATA'
address=/legacy.example/0.0.0.0
address=/legacy.example/::
DATA
check_blocklist_rule_present 'legacy.example' || fail 'legacy rule verification compatibility failed'

cat >"$SS_BLOCKLIST_FILE" <<'DATA'
address=/sample-one.example/#
address=/sample-two.example/#
address=/sample-three.example/#
DATA
sampled="$(find_test_domains 2)"
expected_sample='sample-one.example
sample-two.example'
[ "$sampled" = "$expected_sample" ] || fail 'blocklist sampling did not stop at the requested limit'

RULE_CHECK_COUNT=0
DNS_CHECK_COUNT=0
check_blocklist_rule_present() {
	RULE_CHECK_COUNT=$((RULE_CHECK_COUNT + 1))
	return 1
}
check_domain_blocked() {
	DNS_CHECK_COUNT=$((DNS_CHECK_COUNT + 1))
	return 0
}
check_blocklist_applied_multi_with_stats 2 2 || fail 'sampled blocklist runtime verification failed'
[ "$RULE_CHECK_COUNT" -eq 0 ] || fail 'sampled domains were redundantly rescanned in the blocklist file'
[ "$DNS_CHECK_COUNT" -eq 2 ] || fail 'sampled domains were not checked through dnsmasq runtime resolution'

printf '%s\n' 'blocklist format tests: ok'
