#!/bin/sh
# shellcheck shell=sh
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

[ -f "$ROOT/.pre-commit-config.yaml" ] || fail 'missing .pre-commit-config.yaml'
[ -f "$ROOT/.shellspec" ] || fail 'missing .shellspec'
[ -f "$ROOT/spec/spec_helper.sh" ] || fail 'missing ShellSpec helper'
[ -f "$ROOT/spec/legacy_tests_spec.sh" ] || fail 'missing ShellSpec legacy suite'
[ -f "$ROOT/scripts/lint.sh" ] || fail 'missing scripts/lint.sh'
[ -f "$ROOT/.github/workflows/lint-shell.yml" ] || fail 'missing lint workflow'

grep -Fq 'entry: sh scripts/lint.sh' "$ROOT/.pre-commit-config.yaml" || fail 'pre-commit does not use scripts/lint.sh'
grep -Fq 'always_run: true' "$ROOT/.pre-commit-config.yaml" || fail 'pre-commit lint is not configured to run for every commit'
grep -Fq 'sh scripts/lint.sh' "$ROOT/.github/workflows/lint-shell.yml" || fail 'CI does not use scripts/lint.sh'
grep -Fq 'SHELLSPEC_VERSION: 0.28.1' "$ROOT/.github/workflows/lint-shell.yml" || fail 'CI does not pin ShellSpec 0.28.1'
grep -Fq 'exec shellspec "$@"' "$ROOT/tests/run.sh" || fail 'tests/run.sh does not delegate to ShellSpec'
grep -Fq 'for test_file in tests/test_*.sh; do' "$ROOT/spec/legacy_tests_spec.sh" || fail 'ShellSpec suite does not auto-discover legacy tests'
grep -Fq "The output should not equal ''" "$ROOT/spec/legacy_tests_spec.sh" || fail 'ShellSpec legacy suite does not validate stdout'
grep -Fq "The error should equal ''" "$ROOT/spec/legacy_tests_spec.sh" || fail 'ShellSpec legacy suite does not validate stderr'
grep -Fq 'spec/*_spec.sh)' "$ROOT/scripts/lint.sh" || fail 'lint script does not exclude ShellSpec DSL files from shfmt'
grep -Fq 'shfmt -d -ci' "$ROOT/scripts/lint.sh" || fail 'lint script does not enforce shfmt -d -ci'
grep -Fq 'shellcheck -x -S warning' "$ROOT/scripts/lint.sh" || fail 'lint script does not run ShellCheck'
grep -Fq 'sh -n "$file"' "$ROOT/scripts/lint.sh" || fail 'lint script does not validate shell syntax'

echo 'lint integration tests: ok'
