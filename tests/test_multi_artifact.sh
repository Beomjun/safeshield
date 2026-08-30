#!/bin/sh
# shellcheck shell=sh
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT HUP INT TERM

SS_TMP_DIR="$TMP_DIR/tmp"
SS_API_PAYLOAD="$SS_TMP_DIR/resolve-request.json"
SS_API_RESPONSE="$SS_TMP_DIR/resolve-response.json"
SS_RESOLVED_SOURCES="$SS_TMP_DIR/resolved-sources.tsv"
SS_ARTIFACT_CACHE_STATE="$SS_TMP_DIR/artifact-sources.state"
SS_MAX_ARTIFACT_SOURCES=16
ss_license_key='test-license'
ss_download_retry=1
ss_download_timeout=10
ss_max_blocklist_file_size_kb=1024

mkdir -p "$SS_TMP_DIR"

ss_should_stop() { return 1; }
ss_status_set() { :; }
ss_status_add_error() { :; }
log_info() { :; }
log_error() { :; }
log_ok() { :; }
command_exists() { command -v "$1" >/dev/null 2>&1; }

# shellcheck disable=SC1091
. "$ROOT/files/usr/lib/safeshield/blocklist.sh"

fail() {
	printf 'FAIL: %s\n' "$1" >&2
	exit 1
}

ss_write_resolve_payload() {
	printf '{}\n' >"$1"
}

ss_http_post_json() {
	printf '{}\n' >"$3"
}

ss_json_get_file() {
	case "$2" in
		'@.artifact.sources[0].download_url') printf '%s\n' 'https://example.invalid/hagezi.txt' ;;
		'@.artifact.sources[0].action') printf '%s\n' 'block' ;;
		'@.artifact.sources[0].id') printf '%s\n' 'hagezi-pro' ;;
		'@.artifact.sources[0].sha256') printf '%s\n' "$HAGEZI_SHA" ;;
		'@.artifact.sources[1].download_url') printf '%s\n' 'https://example.invalid/smartsafehub-block.txt' ;;
		'@.artifact.sources[1].action') printf '%s\n' 'block' ;;
		'@.artifact.sources[1].id') printf '%s\n' 'smartsafehub-pro' ;;
		'@.artifact.sources[1].sha256') printf '%s\n' "$SMART_BLOCK_SHA" ;;
		'@.artifact.sources[2].download_url') printf '%s\n' 'https://example.invalid/smartsafehub-allow.txt' ;;
		'@.artifact.sources[2].action') printf '%s\n' 'allow' ;;
		'@.artifact.sources[2].id') printf '%s\n' 'smartsafehub-allow' ;;
		'@.artifact.sources[2].sha256') printf '%s\n' "$SMART_ALLOW_SHA" ;;
		'@.artifact.sources[3].download_url') : ;;
		'@.artifact.sources[16].download_url') : ;;
		'@.artifact.sha256') : ;;
		'@.artifact.tier') printf '%s\n' 'pro' ;;
		'@.artifact.version') printf '%s\n' '20260830T120000Z' ;;
		'@.artifact.unique_domains') printf '%s\n' '4' ;;
		'@.artifact.rules') printf '%s\n' '4' ;;
		'@.license.plan') printf '%s\n' 'pro' ;;
		'@.license.status') printf '%s\n' 'active' ;;
		'@.device.profile') printf '%s\n' 'test-profile' ;;
		*) : ;;
	esac
}

cat >"$TMP_DIR/hagezi.txt" <<'DATA'
address=/ads.example/#
address=/shared.example/#
DATA
cat >"$TMP_DIR/smartsafehub-block.txt" <<'DATA'
phishing.example
shared.example
DATA
cat >"$TMP_DIR/smartsafehub-allow.txt" <<'DATA'
shared.example
DATA

HAGEZI_SHA="$(sha256sum "$TMP_DIR/hagezi.txt" | awk '{print $1}')"
SMART_BLOCK_SHA="$(sha256sum "$TMP_DIR/smartsafehub-block.txt" | awk '{print $1}')"
SMART_ALLOW_SHA="$(sha256sum "$TMP_DIR/smartsafehub-allow.txt" | awk '{print $1}')"
export HAGEZI_SHA SMART_BLOCK_SHA SMART_ALLOW_SHA

ss_resolve_artifact || fail 'multi-source artifact resolution failed'

expected_sources="0|block|hagezi-pro|https://example.invalid/hagezi.txt|$HAGEZI_SHA
1|block|smartsafehub-pro|https://example.invalid/smartsafehub-block.txt|$SMART_BLOCK_SHA
2|allow|smartsafehub-allow|https://example.invalid/smartsafehub-allow.txt|$SMART_ALLOW_SHA"
actual_sources="$(cat "$SS_RESOLVED_SOURCES")"
[ "$actual_sources" = "$expected_sources" ] || fail 'resolved artifact sources do not match the API response'

ss_http_get_file() {
	case "$1" in
		'https://example.invalid/hagezi.txt') cp "$TMP_DIR/hagezi.txt" "$2" ;;
		'https://example.invalid/smartsafehub-block.txt') cp "$TMP_DIR/smartsafehub-block.txt" "$2" ;;
		'https://example.invalid/smartsafehub-allow.txt') cp "$TMP_DIR/smartsafehub-allow.txt" "$2" ;;
		*) return 1 ;;
	esac
}

ss_download_api_artifacts || fail 'multi-source artifact download failed'
ss_cached_api_sources_available || fail 'downloaded source cache was not recognized'

[ "$(cat "$SS_TMP_DIR/api.0.block.txt")" = 'ads.example
shared.example' ] || fail 'HaGeZi block source normalization failed'
[ "$(cat "$SS_TMP_DIR/api.1.block.txt")" = 'phishing.example
shared.example' ] || fail 'SmartSafeHub block source normalization failed'
[ "$(cat "$SS_TMP_DIR/api.2.allow.txt")" = 'shared.example' ] || fail 'SmartSafeHub allow source normalization failed'

# Verify legacy artifact.download_url remains accepted.
ss_json_get_file() {
	case "$2" in
		'@.artifact.sources[0].download_url') : ;;
		'@.artifact.download_url') printf '%s\n' 'https://example.invalid/legacy.txt' ;;
		'@.artifact.sha256') printf '%s\n' 'legacy-sha' ;;
		*) : ;;
	esac
}

ss_resolve_artifact_sources "$SS_API_RESPONSE" || fail 'legacy single artifact resolution failed'
[ "$(cat "$SS_RESOLVED_SOURCES")" = '0|block|legacy|https://example.invalid/legacy.txt|legacy-sha' ] || fail 'legacy artifact source mapping changed'

printf '%s\n' 'multi artifact tests: ok'
