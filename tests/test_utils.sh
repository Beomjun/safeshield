#!/bin/sh
# shellcheck shell=sh
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
PKG_NAME='safeshield-test'
export PKG_NAME

# shellcheck disable=SC1091
. "$ROOT/files/usr/lib/safeshield/utils.sh"

fail() {
	printf 'FAIL: %s\n' "$1" >&2
	exit 1
}

str_contains 'alpha beta' 'beta' || fail 'str_contains missed an existing substring'
if str_contains 'alpha beta' 'gamma'; then
	fail 'str_contains matched a missing substring'
fi

str_contains_word 'alpha beta gamma' 'beta' || fail 'str_contains_word missed an existing word'
if str_contains_word 'alphabet beta' 'alpha'; then
	fail 'str_contains_word matched a partial word'
fi

[ "$(str_first_word 'alpha beta')" = 'alpha' ] || fail 'str_first_word returned the wrong value'
[ "$(str_to_lower 'AbC123')" = 'abc123' ] || fail 'str_to_lower failed'
[ "$(str_to_upper 'AbC123')" = 'ABC123' ] || fail 'str_to_upper failed'
[ "$(str_replace 'alpha-beta-alpha' 'alpha' 'x')" = 'x-beta-x' ] || fail 'str_replace failed'

command_exists sh || fail 'command_exists did not find sh'
if command_exists safeshield-command-that-does-not-exist; then
	fail 'command_exists matched a missing command'
fi

[ "$(ss_mask_secret '')" = '' ] || fail 'empty secret must remain empty'
[ "$(ss_mask_secret '12345678')" = '********' ] || fail 'short secret masking changed'
[ "$(ss_mask_secret 'abcd1234wxyz')" = 'abcd****wxyz' ] || fail 'long secret masking changed'

is_valid_integer 0 || fail 'zero must be a valid integer'
is_valid_integer 42 || fail 'positive integer must be valid'
for value in '' -1 1.5 12x; do
	if is_valid_integer "$value"; then
		fail "invalid integer accepted: $value"
	fi
done

is_greater 2.91 2.90 || fail 'version comparison did not detect a greater version'
if is_greater 2.90 2.90; then
	fail 'equal versions must not compare as greater'
fi
is_greater_equal 2.90 2.90 || fail 'equal versions must compare as greater-or-equal'
is_greater_equal 2.91 2.90 || fail 'newer version must compare as greater-or-equal'
if is_greater_equal 2.79 2.80; then
	fail 'older version must not compare as greater-or-equal'
fi

printf '%s\n' 'utility tests: ok'
