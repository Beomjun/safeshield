#!/bin/sh
# shellcheck shell=sh
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"

sh "$ROOT/tests/test_dnsmasq_version.sh"
sh "$ROOT/tests/test_blocklist_format.sh"
sh "$ROOT/tests/test_statistics.sh"
sh "$ROOT/tests/test_statistics_collector.sh"
sh "$ROOT/tests/test_lint_integration.sh"
