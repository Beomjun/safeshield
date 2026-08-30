#!/bin/sh
# shellcheck shell=sh
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
ENTRY="$ROOT/files/usr/share/rpcd/ucode/safeshield.uc"
ACL="$ROOT/files/usr/share/rpcd/acl.d/safeshield.json"
MAKEFILE="$ROOT/Makefile"

fail() {
	printf 'FAIL: %s\n' "$1" >&2
	exit 1
}

[ -f "$ENTRY" ] || fail 'missing rpcd entrypoint'
[ -f "$ACL" ] || fail 'missing rpcd ACL'

grep -Fq "unshift(REQUIRE_SEARCH_PATH, '/usr/share/rpcd/ucode/safeshield/*.uc');" "$ENTRY" || {
	fail 'rpcd entrypoint no longer loads private SafeShield modules'
}

for module in status config refresh rules license statistics; do
	grep -Fq "let $module = require('$module');" "$ENTRY" || fail "rpcd entrypoint is missing $module module"
done

for method in \
	status \
	config \
	statistics \
	config_update \
	set_enabled \
	refresh \
	rules_list \
	rule_add \
	rule_delete \
	license_get \
	license_update; do
	grep -Fq "        $method: {" "$ENTRY" || fail "rpcd method is missing: $method"
	grep -Fq "\"$method\"" "$ACL" || fail "rpcd ACL is missing method: $method"
done

grep -Fq './files/usr/share/rpcd/ucode/safeshield/*.uc' "$MAKEFILE" || fail 'package install no longer includes rpcd modules'
grep -Fq './files/usr/share/rpcd/acl.d/safeshield.json' "$MAKEFILE" || fail 'package install no longer includes the rpcd ACL'

printf '%s\n' 'rpcd contract tests: ok'
