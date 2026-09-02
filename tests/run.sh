#!/bin/sh
# shellcheck shell=sh
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"

command -v shellspec >/dev/null 2>&1 || {
	echo "error: ShellSpec 0.28.1 or later is required" >&2
	echo "install: curl -fsSL https://git.io/shellspec | sh -s 0.28.1 --yes" >&2
	exit 127
}

cd "$ROOT"
exec shellspec "$@"
