#!/bin/sh
# shellcheck shell=sh
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT HUP INT TERM

RUNNING_STATUS_FILE="$TMP_DIR/status.json"
SS_DNSMASQ_DIR="$TMP_DIR/dnsmasq.d"
SS_BLOCKLIST_FILE="$SS_DNSMASQ_DIR/safeshield.blocklist"
SS_PREV_BLOCKLIST_GZ="$TMP_DIR/previous.gz"
export RUNNING_STATUS_FILE SS_DNSMASQ_DIR SS_BLOCKLIST_FILE SS_PREV_BLOCKLIST_GZ

# shellcheck disable=SC1091
. "$ROOT/files/usr/lib/safeshield/status.sh"

fail() {
	printf 'FAIL: %s\n' "$1" >&2
	exit 1
}

CALLS="$TMP_DIR/calls"
: >"$CALLS"

record() {
	printf '%s\t%s\t%s\n' "$1" "${2:-}" "${3:-}" >>"$CALLS"
}

ss_status_set() {
	record set "$1" "$2"
}

ss_status_add_error() {
	record error "$1"
}

ss_status_apply() {
	record apply "$1" "${2:-}"
	return 0
}

ss_now() {
	printf '%s' '1000'
}

is_valid_integer() {
	case "$1" in
		'' | *[!0-9]*) return 1 ;;
	esac
	[ "$1" -ge 0 ] 2>/dev/null
}

ss_status_mark_failure 'artifact_download_failed'
grep -F "$(printf 'set\tstatus\terror')" "$CALLS" >/dev/null || fail 'failure status was not recorded'
grep -F "$(printf 'set\tlast_failure\t1000')" "$CALLS" >/dev/null || fail 'failure timestamp was not recorded'
grep -F "$(printf 'set\tlast_result\terror')" "$CALLS" >/dev/null || fail 'failure result was not recorded'
grep -F "$(printf 'set\tlast_error_code\tartifact_download_failed')" "$CALLS" >/dev/null || fail 'failure error code was not recorded'
grep -F "$(printf 'error\tartifact_download_failed')" "$CALLS" >/dev/null || fail 'failure error list was not updated'

: >"$CALLS"
ss_status_mark_success 300
grep -F "$(printf 'apply\tclear_messages')" "$CALLS" >/dev/null || fail 'success did not clear previous messages'
grep -F "$(printf 'set\tstatus\tready')" "$CALLS" >/dev/null || fail 'success status was not set to ready'
grep -F "$(printf 'set\tstage\tdone')" "$CALLS" >/dev/null || fail 'success stage was not set to done'
grep -F "$(printf 'set\tlast_success\t1000')" "$CALLS" >/dev/null || fail 'success timestamp was not recorded'
grep -F "$(printf 'set\tnext_refresh_at\t1300')" "$CALLS" >/dev/null || fail 'next refresh timestamp was not calculated'

: >"$CALLS"
ss_status_mark_success invalid
if grep -F "$(printf 'set\tnext_refresh_at')" "$CALLS" >/dev/null; then
	fail 'invalid refresh interval must not produce next_refresh_at'
fi

: >"$CALLS"
ss_status_reset_health_fields
for key in health_dnsmasq_binary health_dns_runtime health_artifact_download dnsmasq_min_version; do
	grep -F "$(printf 'set\t%s\t' "$key")" "$CALLS" >/dev/null || fail "health reset missed $key"
done

: >"$CALLS"
ss_status_reset_blocklist_fields
for key in blocklist_installed blocklist_file_size_kb blocklist_verification_ok blocklist_backup_available; do
	grep -F "$(printf 'set\t%s\t' "$key")" "$CALLS" >/dev/null || fail "blocklist reset missed $key"
done

: >"$CALLS"
ss_status_reset_artifact_fields
for key in license_plan artifact_tier artifact_source_count artifact_allow_source_count; do
	grep -F "$(printf 'set\t%s\t' "$key")" "$CALLS" >/dev/null || fail "artifact reset missed $key"
done

JSONFILTER_STATUS='running'
jsonfilter() {
	[ -n "$JSONFILTER_STATUS" ] && printf '%s\n' "$JSONFILTER_STATUS"
}

is_active safeshield || fail 'running status must be active'
JSONFILTER_STATUS='idle'
if is_active safeshield; then
	fail 'idle status must not be active'
fi
JSONFILTER_STATUS='statusStopped'
if is_active safeshield; then
	fail 'statusStopped must not be active'
fi
JSONFILTER_STATUS=''
if is_active safeshield; then
	fail 'missing status must not be active'
fi

mkdir -p "$SS_DNSMASQ_DIR"
printf '%s\n' 'address=/ads.example/#' >"$TMP_DIR/new.blocklist"
ss_sync_path() {
	:
}
ss_install_blocklist_atomic "$TMP_DIR/new.blocklist" "$SS_BLOCKLIST_FILE" || fail 'atomic blocklist install failed'
[ "$(cat "$SS_BLOCKLIST_FILE")" = 'address=/ads.example/#' ] || fail 'atomic blocklist install changed content'

command_exists() {
	command -v "$1" >/dev/null 2>&1
}
ss_export_existing_blocklist || fail 'existing blocklist backup failed'
[ -s "$SS_PREV_BLOCKLIST_GZ" ] || fail 'blocklist backup was not created'
rm -f "$SS_BLOCKLIST_FILE"
ss_restore_previous_blocklist || fail 'previous blocklist restore failed'
[ "$(cat "$SS_BLOCKLIST_FILE")" = 'address=/ads.example/#' ] || fail 'restored blocklist changed content'

printf '%s\n' 'status state tests: ok'
