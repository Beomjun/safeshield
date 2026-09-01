#!/bin/sh
# shellcheck shell=sh
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT HUP INT TERM

fail() {
	printf 'FAIL: %s\n' "$1" >&2
	exit 1
}

# shellcheck disable=SC1091
. "$ROOT/files/usr/lib/safeshield/blocklist.sh"

ss_detect_device_model() {
	printf '%s' 'Test Router'
}

ss_detect_device_vendor() {
	printf '%s' 'TestVendor'
}

ss_detect_device_arch() {
	printf '%s' 'test_arch'
}

ss_detect_device_memory_mb() {
	printf '%s' '128'
}

SS_PHYSICAL_FINGERPRINT='test-fingerprint'
SS_FINGERPRINT_VERSION='1'
SS_IDENTITY_PROVIDER='factory_mac'
SS_IDENTITY_SOURCE='test-source'
SS_IDENTITY_STRENGTH='hardware_soft'
SS_IDENTITY_PROFILE='test-profile'
SS_INSTALLATION_ID='test-installation'

ss_identity_ensure() {
	return 0
}

is_valid_integer() {
	case "$1" in
		'' | *[!0-9]*) return 1 ;;
		*) return 0 ;;
	esac
}

ss_status_set() {
	:
}

ss_license_key='test-license'
SS_VERSION_FILE="$TMP_DIR/version"
export SS_VERSION_FILE

printf '%s\n' '0.3.18-r1' >"$SS_VERSION_FILE"
payload="$TMP_DIR/resolve-request.json"
ss_write_resolve_payload "$payload" || fail 'resolve payload generation failed'

grep -Fq '    "safeshield_version": "0.3.18-r1"' "$payload" || {
	fail 'resolve payload device does not include the installed SafeShield version'
}
if grep -Eq '^  "safeshield_version"' "$payload"; then
	fail 'resolve payload unexpectedly includes a top-level SafeShield version'
fi
grep -Fq '"license_key": "test-license"' "$payload" || {
	fail 'resolve payload license key changed unexpectedly'
}
grep -Fq '"physical_fingerprint": "test-fingerprint"' "$payload" || {
	fail 'resolve payload device identity changed unexpectedly'
}

SS_VERSION_FILE="$TMP_DIR/missing-version"
export SS_VERSION_FILE
fallback_payload="$TMP_DIR/resolve-request-fallback.json"
ss_write_resolve_payload "$fallback_payload" || fail 'fallback resolve payload generation failed'
grep -Fq '    "safeshield_version": "unknown"' "$fallback_payload" || {
	fail 'missing installed version does not fall back to unknown in device metadata'
}
if grep -Eq '^  "safeshield_version"' "$fallback_payload"; then
	fail 'fallback resolve payload unexpectedly includes a top-level SafeShield version'
fi

printf '%s\n' 'resolve payload tests: ok'
