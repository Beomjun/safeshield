#!/bin/sh
# shellcheck shell=sh
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
sh "$ROOT/tests/test_utils.sh"
sh "$ROOT/tests/test_config_validation.sh"
sh "$ROOT/tests/test_dnsmasq_version.sh"
sh "$ROOT/tests/test_status_state.sh"
sh "$ROOT/tests/test_identity.sh"
sh "$ROOT/tests/test_rpcd_contract.sh"
sh "$ROOT/tests/test_resolve_payload.sh"
sh "$ROOT/tests/test_ucode.sh"
sh "$ROOT/tests/test_status_version.sh"
sh "$ROOT/tests/test_refreshd_wait.sh"
sh "$ROOT/tests/test_blocklist_format.sh"
sh "$ROOT/tests/test_multi_artifact.sh"
sh "$ROOT/tests/test_statistics.sh"
sh "$ROOT/tests/test_statistics_collector.sh"
sh "$ROOT/tests/test_statistics_persistence.sh"
sh "$ROOT/tests/test_statistics_journal.sh"
sh "$ROOT/tests/test_statistics_reconcile.sh"
sh "$ROOT/tests/test_lint_integration.sh"

echo "Done"
