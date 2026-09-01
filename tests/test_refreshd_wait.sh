#!/bin/sh
# shellcheck shell=sh
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
TMP="$(mktemp -d)"
WAIT_PID=''
trap 'if [ -n "$WAIT_PID" ]; then kill "$WAIT_PID" 2>/dev/null || true; wait "$WAIT_PID" 2>/dev/null || true; fi; rm -rf "$TMP"' EXIT HUP INT TERM

REFRESHD="$ROOT/files/usr/libexec/safeshield-refreshd"
HARNESS="$TMP/refreshd-wait.sh"
mkdir -p "$TMP/bin"

awk '
    /^ss_should_terminate=0$/ { print }
    /^ss_sleep_pid=/ { print }
    /^handle_term\(\) \{$/, /^}$/ { print }
    /^sleep_seconds\(\) \{$/, /^}$/ { print }
' "$REFRESHD" >"$HARNESS"

# shellcheck disable=SC1090
. "$HARNESS"

REAL_SLEEP="$(command -v sleep)"
SLEEP_CALLS="$TMP/sleep.calls"
SLEEP_PID_FILE="$TMP/sleep.pid"
cat >"$TMP/bin/sleep" <<'EOF_SLEEP'
#!/bin/sh
printf '%s\n' "$*" >>"$SLEEP_CALLS"
printf '%s\n' "$$" >"$SLEEP_PID_FILE"
exec "$REAL_SLEEP" "$@"
EOF_SLEEP
chmod 755 "$TMP/bin/sleep"
export REAL_SLEEP SLEEP_CALLS SLEEP_PID_FILE

(
	trap 'handle_term' TERM INT
	PATH="$TMP/bin:$PATH"
	export PATH
	sleep_seconds 30
) &
WAIT_PID=$!

tries=0
while [ ! -s "$SLEEP_PID_FILE" ]; do
	tries=$((tries + 1))
	[ "$tries" -lt 100 ] || {
		echo 'refreshd interruptible sleep did not start' >&2
		exit 1
	}
	sleep 0.02
done

SLEEP_PID="$(cat "$SLEEP_PID_FILE")"
kill -TERM "$WAIT_PID"

tries=0
while kill -0 "$WAIT_PID" 2>/dev/null; do
	tries=$((tries + 1))
	[ "$tries" -lt 100 ] || {
		echo 'refreshd interruptible sleep did not stop after TERM' >&2
		exit 1
	}
	sleep 0.02
done
wait "$WAIT_PID" 2>/dev/null || true
WAIT_PID=''

[ "$(cat "$SLEEP_CALLS")" = '30' ] || {
	echo 'refreshd sleep must use one long sleep instead of one-second polling' >&2
	exit 1
}
tries=0
while kill -0 "$SLEEP_PID" 2>/dev/null; do
	tries=$((tries + 1))
	[ "$tries" -lt 100 ] || {
		echo "refreshd sleep child survived termination: $SLEEP_PID" >&2
		exit 1
	}
	sleep 0.02
done

printf '%s\n' 'refreshd wait tests: ok'
