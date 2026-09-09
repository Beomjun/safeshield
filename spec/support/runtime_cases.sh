#!/bin/sh
# shellcheck shell=sh

ss_case_refreshd_wait() (
	set -eu
	TMP="$(ss_spec_tmpdir)"
	WAIT_PID=''
	trap 'if [ -n "$WAIT_PID" ]; then kill "$WAIT_PID" 2>/dev/null || true; wait "$WAIT_PID" 2>/dev/null || true; fi; rm -rf "$TMP"' EXIT HUP INT TERM
	REFRESHD="$SS_SPEC_ROOT/files/usr/libexec/safeshield-refreshd"
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
		[ "$tries" -lt 100 ] || return 1
		sleep 0.02
	done
	SLEEP_PID="$(cat "$SLEEP_PID_FILE")"
	kill -TERM "$WAIT_PID"
	tries=0
	while kill -0 "$WAIT_PID" 2>/dev/null; do
		tries=$((tries + 1))
		[ "$tries" -lt 100 ] || return 1
		sleep 0.02
	done
	wait "$WAIT_PID" 2>/dev/null || true
	WAIT_PID=''
	ss_spec_assert_eq "$(cat "$SLEEP_CALLS")" '30'
	tries=0
	while kill -0 "$SLEEP_PID" 2>/dev/null; do
		tries=$((tries + 1))
		[ "$tries" -lt 100 ] || return 1
		sleep 0.02
	done
)

ss_case_statistics_collector() (
	set -eu
	TMP="$(ss_spec_tmpdir)"
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
. '$SS_SPEC_ROOT/files/usr/lib/safeshield/statistics.sh'
ss_load_config() { return 0; }
ss_dnsmasq_safeshield_block_supported() { return 0; }
command_exists() { command -v "\$1" >/dev/null 2>&1; }
log_info() { :; }
log_warn() { :; }
log_error() { printf '%s\n' "\$*" >&2; }
EOF_CORE
	cat >"$TMP/bin/stats-poll" <<'EOF_POLL'
#!/bin/sh
printf '%s\n' '1' >>"$POLL_COUNT_FILE"
printf '%s\n' 'snapshot	runtime-instance	udp	128	1	0	10	2'
printf '%s\n' 'client	192.168.1.2	10	2'
printf '%s\n' 'commit'
EOF_POLL
	cat >"$TMP/bin/awk" <<'EOF_AWK'
#!/bin/sh
printf '%s\n' "$$" >"$AWK_PID_FILE"
printf '%s\n' "$@" >"$AWK_ARGS_FILE"
while IFS= read -r line; do
	printf '%s\n' "$line" >>"$AWK_INPUT_FILE"
done
EOF_AWK
	cat >"$TMP/bin/ip" <<'EOF_IP'
#!/bin/sh
exit 0
EOF_IP
	chmod 755 "$TMP/bin/stats-poll" "$TMP/bin/awk" "$TMP/bin/ip"
	POLL_COUNT_FILE="$TMP/poll-count"
	AWK_PID_FILE="$TMP/awk.pid"
	AWK_ARGS_FILE="$TMP/awk.args"
	AWK_INPUT_FILE="$TMP/awk.input"
	export POLL_COUNT_FILE AWK_PID_FILE AWK_ARGS_FILE AWK_INPUT_FILE
	PATH="$TMP/bin:$PATH" \
		SS_STATSD_FUNCTIONS_LIB="$TMP/functions.sh" \
		SS_STATSD_CORE_LIB="$TMP/core.sh" \
		SS_STATSD_AWK_DIR="$SS_SPEC_ROOT/files/usr/lib/safeshield/statistics" \
		SS_STATSD_POLL_COMMAND="$TMP/bin/stats-poll" \
		SS_STATSD_GENERATION_ID='runtime-generation' \
		SS_STATSD_PERSISTENT_STATE_FILE="$TMP/flash/statistics-state.tsv" \
		SS_STATSD_PERSISTENT_JOURNAL_FILE="$TMP/flash/statistics-journal.tsv" \
		sh "$SS_SPEC_ROOT/files/usr/libexec/safeshield-statsd" &
	STATSD_PID=$!
	tries=0
	while [ ! -s "$AWK_PID_FILE" ] || ! grep -Fx 'commit' "$AWK_INPUT_FILE" >/dev/null 2>&1; do
		tries=$((tries + 1))
		[ "$tries" -lt 100 ] || return 1
		sleep 0.02
	done
	AWK_PID="$(cat "$AWK_PID_FILE")"
	ss_spec_assert_file_line "$AWK_ARGS_FILE" 'snapshot_interval=300'
	ss_spec_assert_file_line "$AWK_ARGS_FILE" 'identity_cache_ttl=60'
	ss_spec_assert_file_line "$AWK_ARGS_FILE" 'generation_seed=runtime-generation'
	ss_spec_assert_file_line "$AWK_ARGS_FILE" 'ipv6_neigh_command=ip -6 neigh show 2>/dev/null'
	ss_spec_assert_file_line "$AWK_ARGS_FILE" "$SS_SPEC_ROOT/files/usr/lib/safeshield/statistics/20-identity.awk"
	ss_spec_assert_file_line "$AWK_ARGS_FILE" "$SS_SPEC_ROOT/files/usr/lib/safeshield/statistics/90-main.awk"
	ss_spec_assert_file_line "$AWK_ARGS_FILE" 'persistent_state_file='
	ss_spec_assert_file_line "$AWK_ARGS_FILE" 'persistent_journal_file='
	ss_spec_assert_file_line "$AWK_INPUT_FILE" 'snapshot	runtime-instance	udp	128	1	0	10	2'
	ss_spec_assert_file_line "$AWK_INPUT_FILE" 'client	192.168.1.2	10	2'
	ss_spec_assert_eq "$(cat "$POLL_COUNT_FILE")" '1'
	[ ! -e "$TMP/flash" ]
	kill -TERM "$STATSD_PID"
	wait "$STATSD_PID" 2>/dev/null || true
	STATSD_PID=''
	sleep 0.05
	! kill -0 "$AWK_PID" 2>/dev/null
	[ ! -e "$TMP/statistics/collector.lock" ]
	! find "$TMP/statistics" -maxdepth 1 -name 'events.*' | grep . >/dev/null
)

ss_case_statistics_reconcile() (
	set -eu
	TMP="$(ss_spec_tmpdir)"
	trap 'rm -rf "$TMP"' EXIT HUP INT TERM
	SS_DNSMASQ_DIR="$TMP/dnsmasq.d"
	SS_STATISTICS_DNSMASQ_CONF="$SS_DNSMASQ_DIR/safeshield.statistics.conf"
	SS_STATISTICS_POLL_COMMAND="$TMP/stats-poll"
	PKG_NAME='safeshield'
	ss_enabled=1
	ss_statistics_enabled=0
	export SS_DNSMASQ_DIR SS_STATISTICS_DNSMASQ_CONF SS_STATISTICS_POLL_COMMAND PKG_NAME
	export ss_enabled ss_statistics_enabled
	cat >"$SS_STATISTICS_POLL_COMMAND" <<'EOF_POLL'
#!/bin/sh
exit 0
EOF_POLL
	chmod 755 "$SS_STATISTICS_POLL_COMMAND"
	# shellcheck disable=SC1091
	. "$SS_SPEC_ROOT/files/usr/lib/safeshield/statistics.sh"
	CALLS="$TMP/calls"
	record_call() { printf '%s\n' "$*" >>"$CALLS"; }
	log_error() { :; }
	log_warn() { :; }
	ss_status_set() { :; }
	ss_status_add_warning() { :; }
	DNSMASQ_PATCHED=1
	ss_dnsmasq_safeshield_block_supported() { [ "$DNSMASQ_PATCHED" = '1' ]; }
	uci() {
		record_call "uci $*"
		return 0
	}
	ss_require_supported_dnsmasq() {
		record_call require_supported_dnsmasq
		return 0
	}
	dnsmasq_restart() {
		record_call dnsmasq_restart
		return 0
	}
	procd_kill() {
		record_call "procd_kill $*"
		return 0
	}
	procd_open_service() { record_call "procd_open_service $*"; }
	procd_open_instance() { record_call "procd_open_instance $*"; }
	procd_set_param() { record_call "procd_set_param $*"; }
	procd_close_instance() { record_call procd_close_instance; }
	procd_close_service() { record_call "procd_close_service $*"; }
	mkdir -p "$SS_DNSMASQ_DIR"
	cat >"$SS_STATISTICS_DNSMASQ_CONF" <<'CONFIG'
# Legacy SafeShield statistics logging
log-queries=extra
log-async=25
CONFIG
	: >"$CALLS"
	ss_statistics_reconcile_runtime
	[ ! -e "$SS_STATISTICS_DNSMASQ_CONF" ]
	ss_spec_assert_file_line "$CALLS" 'procd_kill safeshield statistics'
	ss_spec_assert_file_line "$CALLS" 'dnsmasq_restart'
	! grep -Fx 'procd_kill safeshield' "$CALLS" >/dev/null

	ss_statistics_enabled=1
	: >"$CALLS"
	ss_statistics_reconcile_runtime
	[ ! -e "$SS_STATISTICS_DNSMASQ_CONF" ]
	ss_spec_assert_file_line "$CALLS" 'require_supported_dnsmasq'
	ss_spec_assert_file_line "$CALLS" 'procd_open_service safeshield'
	ss_spec_assert_file_line "$CALLS" 'procd_open_instance statistics'
	ss_spec_assert_file_line "$CALLS" 'procd_close_service add'
	! grep -Fx 'dnsmasq_restart' "$CALLS" >/dev/null
	! grep -F 'procd_kill safeshield' "$CALLS" >/dev/null

	: >"$CALLS"
	ss_statistics_reconcile_runtime
	! grep -Fx 'dnsmasq_restart' "$CALLS" >/dev/null
	ss_spec_assert_file_line "$CALLS" 'procd_open_instance statistics'

	DNSMASQ_PATCHED=0
	ss_statistics_enabled=1
	: >"$CALLS"
	ss_statistics_reconcile_runtime
	ss_spec_assert_eq "$ss_statistics_enabled" '0'
	ss_spec_assert_file_line "$CALLS" 'uci -q set safeshield.config.statistics_enabled=0'
	ss_spec_assert_file_line "$CALLS" 'uci -q commit safeshield'
	ss_spec_assert_file_line "$CALLS" 'procd_kill safeshield statistics'
	! grep -F 'procd_open_instance statistics' "$CALLS" >/dev/null

	ss_spec_assert_file_contains "$SS_SPEC_ROOT/files/usr/share/rpcd/ucode/safeshield/config.uc" "changed_names[0] == 'statistics_enabled'"
	ss_spec_assert_file_contains "$SS_SPEC_ROOT/files/usr/share/rpcd/ucode/safeshield/config.uc" "run_service_action('reconcile_statistics', 60000)"
)
