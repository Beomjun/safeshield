#!/bin/sh
# shellcheck shell=sh
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"

"$ROOT/tests/test_dnsmasq_version.sh"
"$ROOT/tests/test_blocklist_format.sh"
