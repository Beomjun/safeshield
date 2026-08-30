#!/bin/sh
# shellcheck shell=sh
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT HUP INT TERM

SS_IDENTITY_DIR="$TMP_DIR/identity"
SS_IDENTITY_FILE="$SS_IDENTITY_DIR/identity.env"
export SS_IDENTITY_DIR SS_IDENTITY_FILE

# shellcheck disable=SC1091
. "$ROOT/files/usr/lib/safeshield/identity.sh"

fail() {
	printf 'FAIL: %s\n' "$1" >&2
	exit 1
}

[ "$(ss_identity_normalize_mac 'MAC=AA:BB:CC:DD:EE:FF')" = 'aa:bb:cc:dd:ee:ff' ] || fail 'MAC normalization failed'
ss_identity_valid_mac 'aa:bb:cc:dd:ee:ff' || fail 'valid MAC was rejected'
for mac in '' '00:00:00:00:00:00' 'ff:ff:ff:ff:ff:ff' 'aa:bb:cc:dd:ee'; do
	if ss_identity_valid_mac "$mac"; then
		fail "invalid MAC accepted: $mac"
	fi
done

[ "$(ss_identity_hex_to_mac 'AABBCCDDEEFF')" = 'aa:bb:cc:dd:ee:ff' ] || fail 'hex-to-MAC conversion failed'
[ "$(ss_identity_profile_code 'iptime,ax3000sm')" = 'iptime_ax3000sm' ] || fail 'ipTIME AX3000SM profile mapping changed'
[ "$(ss_identity_profile_code 'glinet,gl-mt300n-v2')" = 'gl_mt300n_v2' ] || fail 'GL-MT300N-V2 profile mapping changed'
[ "$(ss_identity_profile_code 'xiaomi,mi-router-ax3000t')" = 'xiaomi_mi_router_ax3000t' ] || fail 'Xiaomi AX3000T profile mapping changed'
[ "$(ss_identity_profile_code 'smartsafehub,router')" = 'smartsafehub' ] || fail 'SmartSafeHub profile mapping changed'

ss_identity_board_name() {
	printf '%s' 'iptime,ax3000sm'
}

ss_identity_try_mtd_factory_mac() {
	printf '%s' 'aa:bb:cc:dd:ee:ff|mtd:Factory:0x4:mac'
}

ss_identity_detect_primary_mac() {
	return 1
}

ss_identity_compute_physical 'ipTIME AX3000SM' 'aarch64' || fail 'factory MAC identity computation failed'
[ "$SS_IDENTITY_PROVIDER" = 'factory_mac' ] || fail 'factory identity provider changed'
[ "$SS_IDENTITY_SOURCE" = 'mtd:Factory:0x4:mac' ] || fail 'factory identity source changed'
[ "$SS_IDENTITY_STRENGTH" = 'hardware_soft' ] || fail 'factory identity strength changed'
[ "$SS_IDENTITY_PROFILE" = 'iptime_ax3000sm' ] || fail 'factory identity profile changed'
ss_identity_valid_sha256 "$SS_IDENTITY_VALUE_SHA256" || fail 'identity value hash is invalid'
ss_identity_valid_sha256 "$SS_PHYSICAL_FINGERPRINT" || fail 'physical fingerprint is invalid'

SS_INSTALLATION_ID='11111111-2222-3333-4444-555555555555'
SS_INSTALLATION_SECRET='0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
SS_IDENTITY_CREATED_AT='1788090000'
SS_IDENTITY_UPDATED_AT='1788090001'
ss_identity_write_env || fail 'identity file write failed'
[ -s "$SS_IDENTITY_FILE" ] || fail 'identity file was not created'
identity_mode="$(LC_ALL=C ls -ld "$SS_IDENTITY_FILE" | awk '{ print substr($1, 2, 9) }')"
[ "$identity_mode" = 'rw-------' ] || fail 'identity file permissions must be 600'

expected_fingerprint="$SS_PHYSICAL_FINGERPRINT"
SS_PHYSICAL_FINGERPRINT=''
SS_IDENTITY_PROVIDER=''
SS_IDENTITY_SOURCE=''
SS_IDENTITY_STRENGTH=''
SS_IDENTITY_PROFILE=''
SS_INSTALLATION_ID=''
ss_identity_load || fail 'identity file load failed'
[ "$SS_PHYSICAL_FINGERPRINT" = "$expected_fingerprint" ] || fail 'loaded fingerprint changed'
[ "$SS_IDENTITY_PROVIDER" = 'factory_mac' ] || fail 'loaded provider changed'
[ "$SS_INSTALLATION_ID" = '11111111-2222-3333-4444-555555555555' ] || fail 'loaded installation ID changed'

SYNCED=0
STATUS_SYNCED=0
ss_identity_sync_uci() {
	SYNCED=1
}
ss_identity_status_set() {
	STATUS_SYNCED=1
}
ss_identity_create() {
	fail 'existing valid identity must not be recreated'
}
ss_identity_ensure 'ipTIME AX3000SM' 'aarch64' || fail 'identity ensure failed for existing identity'
[ "$SYNCED" = '1' ] || fail 'existing identity was not synchronized to UCI'
[ "$STATUS_SYNCED" = '1' ] || fail 'existing identity was not synchronized to status'

printf '%s\n' 'identity tests: ok'
