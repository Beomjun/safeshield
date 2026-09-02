#!/bin/sh
# shellcheck shell=sh

ss_case_tooling() (
	set -eu
	[ -f "$SS_SPEC_ROOT/.pre-commit-config.yaml" ]
	[ -f "$SS_SPEC_ROOT/.shellspec" ]
	[ -f "$SS_SPEC_ROOT/spec/spec_helper.sh" ]
	[ -f "$SS_SPEC_ROOT/spec/core_spec.sh" ]
	[ -f "$SS_SPEC_ROOT/spec/blocklist_spec.sh" ]
	[ -f "$SS_SPEC_ROOT/spec/runtime_spec.sh" ]
	[ -f "$SS_SPEC_ROOT/spec/statistics_spec.sh" ]
	[ -f "$SS_SPEC_ROOT/spec/ucode_spec.sh" ]
	[ -f "$SS_SPEC_ROOT/spec/tooling_spec.sh" ]
	[ -f "$SS_SPEC_ROOT/scripts/lint.sh" ]
	[ -f "$SS_SPEC_ROOT/.github/workflows/lint-shell.yml" ]
	ss_spec_assert_file_contains "$SS_SPEC_ROOT/.pre-commit-config.yaml" 'entry: sh scripts/lint.sh'
	ss_spec_assert_file_contains "$SS_SPEC_ROOT/.pre-commit-config.yaml" 'always_run: true'
	ss_spec_assert_file_contains "$SS_SPEC_ROOT/.github/workflows/lint-shell.yml" 'sh scripts/lint.sh'
	ss_spec_assert_file_contains "$SS_SPEC_ROOT/.github/workflows/lint-shell.yml" 'SHELLSPEC_VERSION: 0.28.1'
	ss_spec_assert_file_contains "$SS_SPEC_ROOT/.github/workflows/lint-shell.yml" 'run: REQUIRE_UCODE=1 shellspec'
	[ ! -e "$SS_SPEC_ROOT/tests/run.sh" ]
	ss_spec_assert_file_contains "$SS_SPEC_ROOT/scripts/lint.sh" 'spec/*_spec.sh)'
	ss_spec_assert_file_contains "$SS_SPEC_ROOT/scripts/lint.sh" 'shfmt -d -ci'
	ss_spec_assert_file_contains "$SS_SPEC_ROOT/scripts/lint.sh" 'shellcheck -x -S warning'
	ss_spec_assert_file_contains "$SS_SPEC_ROOT/scripts/lint.sh" 'sh -n "$file"'
	[ ! -e "$SS_SPEC_ROOT/spec/legacy_tests_spec.sh" ]
)
