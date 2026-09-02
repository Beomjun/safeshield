#!/bin/sh
# shellcheck shell=sh
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
TMP="$(mktemp -d)"
STATSD_PID=''
trap 'if [ -n "$STATSD_PID" ]; then kill "$STATSD_PID" 2>/dev/null || true; wait "$STATSD_PID" 2>/dev/null || true; fi; rm -rf "$TMP"' EXIT HUP INT TERM

mkdir -p "$TMP/bin" "$TMP/statistics"

cat >"$TMP/functions.sh" <<'EOF_FUNCTIONS'
# test stub
EOF_FUNCTIONS
cat >"$TMP/core.sh" <<EOF_CORE
ss_enabled=1
ss_statistics_enabled=1
ss_statistics_snapshot_interval_s=60
ss_statistics_retention_hours=168
SS_STATISTICS_DIR='$TMP/statistics'
SS_STATISTICS_STATE_FILE='$TMP/statistics/state.tsv'
SS_STATISTICS_JSON_FILE='$TMP/statistics/statistics.json'
SS_IDENTITY_PROFILE='gl_mt300n_v2'
. '$ROOT/files/usr/lib/safeshield/statistics.sh'
ss_load_config() { return 0; }
command_exists() { command -v "\$1" >/dev/null 2>&1; }
log_info() { :; }
log_warn() { :; }
log_error() { printf '%s\n' "\$*" >&2; }
EOF_CORE
cat >"$TMP/bin/logread" <<'EOF_LOGREAD'
#!/bin/sh
printf '%s\n' "$$" >"$LOGREAD_PID_FILE"
printf '%s\n' "$@" >"$LOGREAD_ARGS_FILE"
while :; do
	printf '%s\n' 'daemon.info dnsmasq[1]: query[A] example.com from 192.168.1.2'
done
EOF_LOGREAD

cat >"$TMP/bin/awk" <<'EOF_AWK'
#!/bin/sh
printf '%s\n' "$$" >"$AWK_PID_FILE"
printf '%s\n' "$@" >"$AWK_ARGS_FILE"
while IFS= read -r line; do
	: "$line"
done
EOF_AWK
chmod 755 "$TMP/bin/logread" "$TMP/bin/awk"

LOGREAD_PID_FILE="$TMP/logread.pid"
LOGREAD_ARGS_FILE="$TMP/logread.args"
AWK_PID_FILE="$TMP/awk.pid"
AWK_ARGS_FILE="$TMP/awk.args"
export LOGREAD_PID_FILE LOGREAD_ARGS_FILE AWK_PID_FILE AWK_ARGS_FILE
PATH="$TMP/bin:$PATH" \
	SS_STATSD_FUNCTIONS_LIB="$TMP/functions.sh" \
	SS_STATSD_CORE_LIB="$TMP/core.sh" \
	SS_STATSD_AWK_PROGRAM="$ROOT/files/usr/lib/safeshield/statistics.awk" \
	SS_STATSD_PERSISTENT_STATE_FILE="$TMP/flash/statistics-state.tsv" \
	SS_STATSD_PERSISTENT_JOURNAL_FILE="$TMP/flash/statistics-journal.tsv" \
	sh "$ROOT/files/usr/libexec/safeshield-statsd" &
STATSD_PID=$!

tries=0
while [ ! -s "$LOGREAD_PID_FILE" ] || [ ! -s "$AWK_PID_FILE" ]; do
	tries=$((tries + 1))
	[ "$tries" -lt 100 ] || {
		echo 'statistics collector children did not start' >&2
		exit 1
	}
	sleep 0.02
done
LOGREAD_PID="$(cat "$LOGREAD_PID_FILE")"
AWK_PID="$(cat "$AWK_PID_FILE")"
expected_logread_args='-f
-l
0
-e
dnsmasq'
[ "$(cat "$LOGREAD_ARGS_FILE")" = "$expected_logread_args" ] || {
	echo 'statistics collector did not filter logread to dnsmasq messages' >&2
	exit 1
}
grep -Fx 'snapshot_interval=300' "$AWK_ARGS_FILE" >/dev/null
grep -Fx 'identity_cache_ttl=60' "$AWK_ARGS_FILE" >/dev/null
grep -Fx 'persistent_state_file=' "$AWK_ARGS_FILE" >/dev/null
grep -Fx 'persistent_journal_file=' "$AWK_ARGS_FILE" >/dev/null
[ ! -e "$TMP/flash" ] || {
	echo 'GL-MT300N-V2 collector must not create flash persistence paths' >&2
	exit 1
}

kill -TERM "$STATSD_PID"
wait "$STATSD_PID" 2>/dev/null || true
STATSD_PID=''
sleep 0.05
if kill -0 "$LOGREAD_PID" 2>/dev/null; then
	echo "logread child survived statistics collector termination: $LOGREAD_PID" >&2
	exit 1
fi
if kill -0 "$AWK_PID" 2>/dev/null; then
	echo "awk child survived statistics collector termination: $AWK_PID" >&2
	exit 1
fi
if [ -e "$TMP/statistics/collector.lock" ]; then
	echo 'statistics collector lock was not removed' >&2
	exit 1
fi
if find "$TMP/statistics" -maxdepth 1 -name 'events.*' | grep . >/dev/null; then
	echo 'statistics collector FIFO was not removed' >&2
	exit 1
fi
printf '%s\n' 'statistics collector lifecycle tests: ok'
