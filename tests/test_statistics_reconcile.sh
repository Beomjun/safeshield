#!/bin/sh
# shellcheck shell=sh
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

SS_DNSMASQ_DIR="$TMP/dnsmasq.d"
SS_STATISTICS_DNSMASQ_CONF="$SS_DNSMASQ_DIR/safeshield.statistics.conf"
PKG_NAME='safeshield'
ss_enabled=1
ss_statistics_enabled=0
export SS_DNSMASQ_DIR SS_STATISTICS_DNSMASQ_CONF PKG_NAME
export ss_enabled ss_statistics_enabled

# shellcheck disable=SC1090
. "$ROOT/files/usr/lib/safeshield/statistics.sh"

CALLS="$TMP/calls"

record_call() {
	printf '%s\n' "$*" >>"$CALLS"
}

log_error() {
	:
}

ss_require_supported_dnsmasq() {
	record_call require_supported_dnsmasq
	return 0
}

ss_ensure_dnsmasq_confdir() {
	record_call ensure_dnsmasq_confdir
	return 0
}

dnsmasq_restart() {
	record_call dnsmasq_restart
	return 0
}

procd_kill() {
	record_call "procd_kill $*"
	return 0
}

procd_open_service() {
	record_call "procd_open_service $*"
}

procd_open_instance() {
	record_call "procd_open_instance $*"
}

procd_set_param() {
	record_call "procd_set_param $*"
}

procd_close_instance() {
	record_call procd_close_instance
}

procd_close_service() {
	record_call "procd_close_service $*"
}

mkdir -p "$SS_DNSMASQ_DIR"
cat >"$SS_STATISTICS_DNSMASQ_CONF" <<'CONFIG'
# Managed by SafeShield. Do not edit.
log-queries=extra
log-async=25
CONFIG

: >"$CALLS"
ss_statistics_reconcile_runtime
[ ! -e "$SS_STATISTICS_DNSMASQ_CONF" ]
grep -Fx 'procd_kill safeshield statistics' "$CALLS" >/dev/null
grep -Fx 'dnsmasq_restart' "$CALLS" >/dev/null
if grep -Fx 'procd_kill safeshield' "$CALLS" >/dev/null; then
	echo 'statistics reconciliation must not stop the SafeShield refresh instance' >&2
	exit 1
fi

ss_statistics_enabled=1
: >"$CALLS"
ss_statistics_reconcile_runtime
grep -Fx 'log-queries=extra' "$SS_STATISTICS_DNSMASQ_CONF" >/dev/null
grep -Fx 'log-async=25' "$SS_STATISTICS_DNSMASQ_CONF" >/dev/null
grep -Fx 'dnsmasq_restart' "$CALLS" >/dev/null
grep -Fx 'procd_open_service safeshield' "$CALLS" >/dev/null
grep -Fx 'procd_open_instance statistics' "$CALLS" >/dev/null
grep -Fx 'procd_close_service add' "$CALLS" >/dev/null
if grep -F 'procd_kill safeshield' "$CALLS" >/dev/null; then
	echo 'enabling statistics must not stop any SafeShield service instance' >&2
	exit 1
fi

: >"$CALLS"
ss_statistics_reconcile_runtime
if grep -Fx 'dnsmasq_restart' "$CALLS" >/dev/null; then
	echo 'unchanged statistics logging configuration must not restart dnsmasq' >&2
	exit 1
fi
grep -Fx 'procd_open_instance statistics' "$CALLS" >/dev/null

grep -F "changed_names[0] == 'statistics_enabled'" \
	"$ROOT/files/usr/share/rpcd/ucode/safeshield/config.uc" >/dev/null
grep -F "run_service_action('reconcile_statistics', 60000)" \
	"$ROOT/files/usr/share/rpcd/ucode/safeshield/config.uc" >/dev/null

printf '%s\n' 'statistics runtime reconciliation tests: ok'
