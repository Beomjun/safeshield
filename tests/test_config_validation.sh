#!/bin/sh
# shellcheck shell=sh
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
PKG_NAME='safeshield-test'
export PKG_NAME

# shellcheck disable=SC1091
. "$ROOT/files/usr/lib/safeshield/utils.sh"

WARNINGS=''
CONFIG_GET_VALUE=''

log_warn() {
	:
}

ss_status_add_warning() {
	WARNINGS="${WARNINGS}${WARNINGS:+ }$1"
}

config_get() {
	eval "$1='${CONFIG_GET_VALUE}'"
}

# shellcheck disable=SC1091
. "$ROOT/files/usr/lib/safeshield/config.sh"

fail() {
	printf 'FAIL: %s\n' "$1" >&2
	exit 1
}

assert_warning() {
	case " $WARNINGS " in
		*" $1 "*) ;;
		*) fail "missing warning code: $1" ;;
	esac
}

CONFIG_GET_VALUE='configured'
[ "$(ss_config_get config enabled default)" = 'configured' ] || fail 'configured UCI value was not returned'
CONFIG_GET_VALUE=''
[ "$(ss_config_get config enabled default)" = 'default' ] || fail 'default UCI value was not returned'

ss_download_timeout='invalid'
ss_download_retry='-1'
ss_max_blocklist_file_size_kb='1.5'
ss_min_valid_line_count=''
ss_pause_timeout='invalid'
ss_boot_start_delay_s='-5'
ss_statistics_snapshot_interval_s='9'
ss_statistics_retention_hours='169'
ss_compress_blocklist='2'
ss_initial_dnsmasq_restart='yes'
ss_dnsmasq_sanity_check='no'
ss_apply_local_overrides='2'
ss_statistics_enabled='off'
WARNINGS=''

ss_validate_config

[ "$ss_download_timeout" = '10' ] || fail 'invalid download_timeout did not use the default'
[ "$ss_download_retry" = '3' ] || fail 'invalid download_retry did not use the default'
[ "$ss_max_blocklist_file_size_kb" = '30000' ] || fail 'invalid max blocklist size did not use the default'
[ "$ss_min_valid_line_count" = '3000' ] || fail 'invalid minimum line count did not use the default'
[ "$ss_pause_timeout" = '20' ] || fail 'invalid pause_timeout did not use the default'
[ "$ss_boot_start_delay_s" = '30' ] || fail 'invalid boot delay did not use the default'
[ "$ss_statistics_snapshot_interval_s" = '60' ] || fail 'out-of-range snapshot interval did not use the default'
[ "$ss_statistics_retention_hours" = '168' ] || fail 'out-of-range retention did not use the default'
[ "$ss_compress_blocklist" = '0' ] || fail 'invalid compress_blocklist did not use the default'
[ "$ss_initial_dnsmasq_restart" = '0' ] || fail 'invalid initial_dnsmasq_restart did not use the default'
[ "$ss_dnsmasq_sanity_check" = '1' ] || fail 'invalid dnsmasq_sanity_check did not use the default'
[ "$ss_apply_local_overrides" = '1' ] || fail 'invalid apply_local_overrides did not use the default'
[ "$ss_statistics_enabled" = '1' ] || fail 'invalid statistics_enabled did not use the default'

for code in \
	invalid_download_timeout \
	invalid_download_retry \
	invalid_max_blocklist_file_size_kb \
	invalid_min_valid_line_count \
	invalid_pause_timeout \
	invalid_boot_start_delay_s \
	invalid_statistics_snapshot_interval_s \
	invalid_statistics_retention_hours \
	invalid_compress_blocklist \
	invalid_initial_dnsmasq_restart \
	invalid_dnsmasq_sanity_check \
	invalid_apply_local_overrides \
	invalid_statistics_enabled; do
	assert_warning "$code"
done

ss_download_timeout='1'
ss_download_retry='0'
ss_max_blocklist_file_size_kb='1'
ss_min_valid_line_count='0'
ss_pause_timeout='0'
ss_boot_start_delay_s='0'
ss_statistics_snapshot_interval_s='10'
ss_statistics_retention_hours='168'
ss_compress_blocklist='1'
ss_initial_dnsmasq_restart='1'
ss_dnsmasq_sanity_check='0'
ss_apply_local_overrides='0'
ss_statistics_enabled='0'
WARNINGS=''

ss_validate_config
[ -z "$WARNINGS" ] || fail 'valid boundary values unexpectedly produced warnings'
[ "$ss_statistics_snapshot_interval_s" = '10' ] || fail 'minimum snapshot interval changed'
[ "$ss_statistics_retention_hours" = '168' ] || fail 'maximum retention changed'

printf '%s\n' 'configuration validation tests: ok'
