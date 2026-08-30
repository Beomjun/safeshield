#!/bin/sh
# shellcheck shell=sh
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
MODULE_DIR="$ROOT/files/usr/share/rpcd/ucode/safeshield"
ENTRY="$ROOT/files/usr/share/rpcd/ucode/safeshield.uc"
UCODE_BIN="${UCODE:-ucode}"

if ! command -v "$UCODE_BIN" >/dev/null 2>&1; then
	if [ "${REQUIRE_UCODE:-0}" = '1' ]; then
		printf '%s\n' 'FAIL: ucode is required but is not installed' >&2
		exit 1
	fi

	printf '%s\n' 'ucode tests: skipped (ucode is not installed)'
	exit 0
fi

TMPDIR="$(mktemp -d)"
cleanup() {
	rm -rf "$TMPDIR"
}
trap cleanup EXIT HUP INT TERM

compile_ucode() {
	file="$1"
	output="$TMPDIR/$(basename -- "$file").ucb"
	"$UCODE_BIN" -c -o "$output" "$file"
}

compile_ucode "$ENTRY"
for file in "$MODULE_DIR"/*.uc; do
	compile_ucode "$file"
done

run_ucode_test() {
	name="$1"
	mock_dir="$ROOT/tests/ucode/mocks/$name"
	test_file="$ROOT/tests/ucode/test_$name.uc"
	test_tmp="$TMPDIR/$name"
	test_modules="$TMPDIR/modules/$name"

	mkdir -p "$test_tmp" "$test_modules"
	cp "$MODULE_DIR/$name.uc" "$test_modules/$name.uc"
	cp "$mock_dir"/*.uc "$test_modules/"

	"$UCODE_BIN" \
		-L "$test_modules" \
		-D "TEST_TMP=\"$test_tmp\"" \
		"$test_file"
}

for name in core config license refresh rules statistics status; do
	run_ucode_test "$name"
done

printf '%s\n' 'ucode tests: ok'
