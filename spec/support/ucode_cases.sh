#!/bin/sh
# shellcheck shell=sh

ss_case_ucode() (
	set -eu
	MODULE_DIR="$SS_SPEC_ROOT/files/usr/share/rpcd/ucode/safeshield"
	ENTRY="$SS_SPEC_ROOT/files/usr/share/rpcd/ucode/safeshield.uc"
	UCODE_BIN="${UCODE:-ucode}"
	if ! command -v "$UCODE_BIN" >/dev/null 2>&1; then
		[ "${REQUIRE_UCODE:-0}" != '1' ]
		return 0
	fi
	TMPDIR="$(ss_spec_tmpdir)"
	trap 'rm -rf "$TMPDIR"' EXIT HUP INT TERM
	compile_ucode() {
		file="$1"
		output="$TMPDIR/$(basename -- "$file").ucb"
		"$UCODE_BIN" -c -o "$output" "$file" >/dev/null
	}
	compile_ucode "$ENTRY"
	for file in "$MODULE_DIR"/*.uc; do
		compile_ucode "$file"
	done
	run_ucode_test() {
		name="$1"
		mock_dir="$SS_SPEC_ROOT/tests/ucode/mocks/$name"
		test_file="$SS_SPEC_ROOT/tests/ucode/test_$name.uc"
		test_tmp="$TMPDIR/$name"
		test_modules="$TMPDIR/modules/$name"
		mkdir -p "$test_tmp" "$test_modules"
		cp "$MODULE_DIR/$name.uc" "$test_modules/$name.uc"
		cp "$mock_dir"/*.uc "$test_modules/"
		"$UCODE_BIN" -L "$test_modules" -D "TEST_TMP=\"$test_tmp\"" "$test_file" >/dev/null
	}
	for name in core config license refresh rules statistics status; do
		run_ucode_test "$name"
	done
)
