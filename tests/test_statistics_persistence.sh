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

printf '%s\n' 'statistics persistence tests: ok'
