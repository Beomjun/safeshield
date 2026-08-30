#!/bin/sh
# shellcheck shell=sh
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"

fail() {
	printf 'FAIL: %s\n' "$1" >&2
	exit 1
}

make_version="$(sed -n 's/^PKG_VERSION:=//p' "$ROOT/Makefile")"
make_release="$(sed -n 's/^PKG_RELEASE:=//p' "$ROOT/Makefile")"
init_version="$(sed -n "s/^readonly PKG_VERSION='\([^']*\)'/\1/p" "$ROOT/files/etc/init.d/safeshield")"

[ -n "$make_version" ] || fail 'Makefile PKG_VERSION is missing'
[ -n "$make_release" ] || fail 'Makefile PKG_RELEASE is missing'
[ -n "$init_version" ] || fail 'init.d PKG_VERSION is missing'

expected_init_version="${make_version}-r${make_release}"
[ "$init_version" = "$expected_init_version" ] || {
	fail "init.d version ${init_version} does not match package version ${expected_init_version}"
}

grep -Fq "printf '%s\\n' \"\$PKG_VERSION\"" "$ROOT/files/etc/init.d/safeshield" || {
	fail 'init.d version command does not print PKG_VERSION'
}

grep -Fq "echo '\$(PKG_VERSION)-\$(PKG_RELEASE)' > \$(1)/usr/lib/safeshield/version" "$ROOT/Makefile" || {
	fail 'package install does not generate the SafeShield status version file from package metadata'
}

grep -Fq 'fs.readfile(`/usr/lib/${PKG_NAME}/version`)' "$ROOT/files/usr/share/rpcd/ucode/safeshield/core.uc" || {
	fail 'status core does not read the installed SafeShield version file'
}

grep -Fq 'version: PKG_VERSION,' "$ROOT/files/usr/share/rpcd/ucode/safeshield/status.uc" || {
	fail 'ubus status does not expose the package version'
}

printf '%s\n' 'status version tests: ok'
