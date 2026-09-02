#!/bin/sh
# shellcheck shell=sh
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

STATE="$TMP/state.tsv"
JSON="$TMP/statistics.json"
PERSISTENT="$TMP/statistics-state.tsv"
LEASES="$TMP/dhcp.leases"
LOG="$TMP/dnsmasq.log"

cat >"$LEASES" <<'LEASES'
1788000000 aa:bb:cc:dd:ee:ff 192.168.1.20 iphone *
LEASES

cat >"$LOG" <<'LOGS'
daemon.info dnsmasq[1]: 11 192.168.1.20/50001 query[A] ads.example from 192.168.1.20
daemon.info dnsmasq[1]: 11 192.168.1.20/50001 config ads.example is 0.0.0.0
LOGS

awk \
	-v state_file="$STATE" \
	-v json_file="$JSON" \
	-v persistent_state_file="$PERSISTENT" \
	-v persistent_interval=3600 \
	-v snapshot_interval=60 \
	-v retention_hours=168 \
	-v lease_file="$LEASES" \
	-v fixed_now=1787950800 \
	-f "$ROOT/files/usr/lib/safeshield/statistics.awk" \
	<"$LOG"

[ -s "$PERSISTENT" ]
grep -F '"version":2' "$JSON" >/dev/null
grep -F '"volatile":false' "$JSON" >/dev/null
grep -F '"storage":"tmpfs+flash"' "$JSON" >/dev/null
grep -F '"persistent":true' "$JSON" >/dev/null
grep -F '"totals":{"queries":1,"blocked":1}' "$JSON" >/dev/null
grep -F '"hourly":[{"bucket_start":1787950800,"queries":1,"blocked":1}]' "$JSON" >/dev/null
grep -F '"id":"aa:bb:cc:dd:ee:ff"' "$JSON" >/dev/null
grep -F '"hourly":[{"bucket_start":1787950800,"queries":1,"blocked":1}]' "$JSON" >/dev/null
expected_device_bucket="$(printf 'device_bucket\taa:bb:cc:dd:ee:ff\t1787950800\t1\t1')"
grep -F "$expected_device_bucket" "$PERSISTENT" >/dev/null
if grep -F 'ads.example' "$PERSISTENT" >/dev/null; then
	echo 'raw domains must not be written to persistent statistics state' >&2
	exit 1
fi

# Simulate a reboot: tmpfs state disappears while the flash checkpoint remains.
rm -f "$STATE" "$JSON"
cat >"$LOG" <<'LOGS'
daemon.info dnsmasq[1]: 12 192.168.1.20/50002 query[A] openwrt.org from 192.168.1.20
LOGS

awk \
	-v state_file="$STATE" \
	-v json_file="$JSON" \
	-v persistent_state_file="$PERSISTENT" \
	-v persistent_interval=3600 \
	-v snapshot_interval=60 \
	-v retention_hours=168 \
	-v lease_file="$LEASES" \
	-v fixed_now=1787954400 \
	-f "$ROOT/files/usr/lib/safeshield/statistics.awk" \
	<"$LOG"

grep -F '"totals":{"queries":2,"blocked":1}' "$JSON" >/dev/null
grep -F '{"bucket_start":1787950800,"queries":1,"blocked":1}' "$JSON" >/dev/null
grep -F '{"bucket_start":1787954400,"queries":1,"blocked":0}' "$JSON" >/dev/null
grep -F '"session_started_at":1787954400' "$JSON" >/dev/null
grep -F '"id":"aa:bb:cc:dd:ee:ff"' "$JSON" >/dev/null
grep -F '{"bucket_start":1787950800,"queries":1,"blocked":1}' "$JSON" >/dev/null
grep -F '{"bucket_start":1787954400,"queries":1,"blocked":0}' "$JSON" >/dev/null

# A v1 state without device hourly buckets is upgraded without dropping the
# existing per-device totals. They are assigned to the last known hour once.
LEGACY_STATE="$TMP/legacy-state.tsv"
LEGACY_JSON="$TMP/legacy-statistics.json"
cat >"$LEGACY_STATE" <<'STATE'
meta	1787950800	1787950800	3	1	0
bucket	1787950800	3	1
device	aa:bb:cc:dd:ee:ff	aa:bb:cc:dd:ee:ff	192.168.1.20	iphone	3	1
STATE
: >"$LOG"
awk \
	-v state_file="$LEGACY_STATE" \
	-v json_file="$LEGACY_JSON" \
	-v snapshot_interval=60 \
	-v retention_hours=168 \
	-v lease_file="$LEASES" \
	-v fixed_now=1787950800 \
	-f "$ROOT/files/usr/lib/safeshield/statistics.awk" \
	<"$LOG"

grep -F '"totals":{"queries":3,"blocked":1}' "$LEGACY_JSON" >/dev/null
grep -F '"queries":3,"blocked":1,"hourly":[{"bucket_start":1787950800,"queries":3,"blocked":1}]' "$LEGACY_JSON" >/dev/null
legacy_device_bucket="$(printf 'device_bucket\taa:bb:cc:dd:ee:ff\t1787950800\t3\t1')"
grep -F "$legacy_device_bucket" "$LEGACY_STATE" >/dev/null

# When both hot tmpfs state and flash state exist, the newest valid snapshot
# wins. This protects collector respawns after a flash checkpoint that completed
# before the corresponding tmpfs snapshot was replaced.
LATEST_STATE="$TMP/latest-state.tsv"
LATEST_JSON="$TMP/latest-statistics.json"
LATEST_PERSISTENT="$TMP/latest-persistent.tsv"
cat >"$LATEST_STATE" <<'STATE'
meta	1787950800	1787950800	1	0	0	0	2	1787950800
bucket	1787950800	1	0
STATE
cat >"$LATEST_PERSISTENT" <<'STATE'
meta	1787950800	1787954400	2	1	0	1787954400	2	1787954400
bucket	1787950800	1	0
bucket	1787954400	1	1
STATE
: >"$LOG"
awk \
	-v state_file="$LATEST_STATE" \
	-v json_file="$LATEST_JSON" \
	-v persistent_state_file="$LATEST_PERSISTENT" \
	-v persistent_interval=3600 \
	-v snapshot_interval=60 \
	-v retention_hours=168 \
	-v lease_file="$LEASES" \
	-v fixed_now=1787958000 \
	-f "$ROOT/files/usr/lib/safeshield/statistics.awk" \
	<"$LOG"
grep -F '"totals":{"queries":2,"blocked":1}' "$LATEST_JSON" >/dev/null

# A newer but corrupted persistent state must not replace a valid tmpfs state.
CORRUPT_STATE="$TMP/corrupt-state.tsv"
CORRUPT_JSON="$TMP/corrupt-statistics.json"
CORRUPT_PERSISTENT="$TMP/corrupt-persistent.tsv"
cat >"$CORRUPT_STATE" <<'STATE'
meta	1787950800	1787954400	2	1	0	0	2	1787954400
bucket	1787950800	1	0
bucket	1787954400	1	1
STATE
cat >"$CORRUPT_PERSISTENT" <<'STATE'
meta	1787950800	1787958000	999	999	0	1787958000	2	1787958000
bucket	1787958000	1	1
STATE
: >"$LOG"
awk \
	-v state_file="$CORRUPT_STATE" \
	-v json_file="$CORRUPT_JSON" \
	-v persistent_state_file="$CORRUPT_PERSISTENT" \
	-v persistent_interval=3600 \
	-v snapshot_interval=60 \
	-v retention_hours=168 \
	-v lease_file="$LEASES" \
	-v fixed_now=1787961600 \
	-f "$ROOT/files/usr/lib/safeshield/statistics.awk" \
	<"$LOG"
grep -F '"totals":{"queries":2,"blocked":1}' "$CORRUPT_JSON" >/dev/null

# Persistent write failures must not break hot tmpfs statistics. They are
# surfaced in statistics.json and retried with backoff rather than every
# snapshot interval.
FAIL_STATE="$TMP/fail-state.tsv"
FAIL_JSON="$TMP/fail-statistics.json"
FAIL_TARGET="$TMP/fail-persistent.tsv"
FAIL_BIN="$TMP/fail-bin"
REAL_MV="$(command -v mv)"
mkdir "$FAIL_BIN"
cat >"$FAIL_BIN/mv" <<EOF
#!/bin/sh
case "\${*}" in
	*fail-persistent.tsv*) exit 1 ;;
esac
exec "$REAL_MV" "\${@}"
EOF
chmod +x "$FAIL_BIN/mv"
: >"$LOG"
PATH="$FAIL_BIN:$PATH" awk \
	-v state_file="$FAIL_STATE" \
	-v json_file="$FAIL_JSON" \
	-v persistent_state_file="$FAIL_TARGET" \
	-v persistent_interval=3600 \
	-v persistent_retry_interval=300 \
	-v snapshot_interval=60 \
	-v retention_hours=168 \
	-v lease_file="$LEASES" \
	-v fixed_now=1787965200 \
	-f "$ROOT/files/usr/lib/safeshield/statistics.awk" \
	<"$LOG"
grep -F '"persistence_enabled":true' "$FAIL_JSON" >/dev/null
grep -F '"persistence_healthy":false' "$FAIL_JSON" >/dev/null
grep -F '"persistent_error_count":1' "$FAIL_JSON" >/dev/null
grep -F '"persistent_last_error_at":1787965200' "$FAIL_JSON" >/dev/null
[ -s "$FAIL_STATE" ]

# The rpcd sanitizer must expose device hourly buckets at the device level and
# must not recursively attach hourly arrays to hourly bucket objects.
grep -F 'hourly: sanitize_hourly(item.hourly)' \
	"$ROOT/files/usr/share/rpcd/ucode/safeshield/statistics.uc" >/dev/null
[ "$(grep -Fc 'hourly: sanitize_hourly(item.hourly)' \
	"$ROOT/files/usr/share/rpcd/ucode/safeshield/statistics.uc")" -eq 1 ]
grep -F 'persistence_healthy: to_bool(data.persistence_healthy, false)' \
	"$ROOT/files/usr/share/rpcd/ucode/safeshield/statistics.uc" >/dev/null

# Volatile mode must discard stale persistence metadata restored from an older
# tmpfs state and must report the effective collector snapshot interval.
VOLATILE_STATE="$TMP/volatile-state.tsv"
VOLATILE_JSON="$TMP/volatile-statistics.json"
cat >"$VOLATILE_STATE" <<'STATE'
meta	1787950800	1787950800	1	0	0	1787950700	3	1787950800	0	2	1787950600	1787950500	1787947200
bucket	1787950800	1	0
STATE
: >"$LOG"
awk \
	-v state_file="$VOLATILE_STATE" \
	-v json_file="$VOLATILE_JSON" \
	-v snapshot_interval=300 \
	-v retention_hours=168 \
	-v lease_file="$LEASES" \
	-v fixed_now=1787954400 \
	-f "$ROOT/files/usr/lib/safeshield/statistics.awk" \
	<"$LOG"
grep -F '"persistence_enabled":false' "$VOLATILE_JSON" >/dev/null
grep -F '"persistence_healthy":true' "$VOLATILE_JSON" >/dev/null
grep -F '"persistence_mode":"none"' "$VOLATILE_JSON" >/dev/null
grep -F '"persistent_error_count":0' "$VOLATILE_JSON" >/dev/null
grep -F '"persistent_last_error_at":0' "$VOLATILE_JSON" >/dev/null
grep -F '"persistent_updated_at":0' "$VOLATILE_JSON" >/dev/null
grep -F '"persistent_compacted_at":0' "$VOLATILE_JSON" >/dev/null
grep -F '"snapshot_interval_s":300' "$VOLATILE_JSON" >/dev/null

printf '%s\n' 'statistics persistence tests: ok'
