#!/bin/sh
# shellcheck shell=sh
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

SS_DNSMASQ_DIR="$TMP/dnsmasq.d"
SS_STATISTICS_DNSMASQ_CONF="$SS_DNSMASQ_DIR/safeshield.statistics.conf"
export SS_DNSMASQ_DIR SS_STATISTICS_DNSMASQ_CONF

# shellcheck disable=SC1090
. "$ROOT/files/usr/lib/safeshield/statistics.sh"

changed="$(ss_statistics_configure_dnsmasq 1)"
[ "$changed" = "1" ]
grep -Fx 'log-queries=extra' "$SS_STATISTICS_DNSMASQ_CONF" >/dev/null
grep -Fx 'log-async=25' "$SS_STATISTICS_DNSMASQ_CONF" >/dev/null

changed="$(ss_statistics_configure_dnsmasq 1)"
[ "$changed" = "0" ]

changed="$(ss_statistics_configure_dnsmasq 0)"
[ "$changed" = "1" ]
[ ! -e "$SS_STATISTICS_DNSMASQ_CONF" ]

STATE="$TMP/state.tsv"
JSON="$TMP/statistics.json"
FIXTURE="$TMP/dnsmasq.log"
LEASES="$TMP/dhcp.leases"

cat >"$LEASES" <<'LEASES'
1788000000 aa:bb:cc:dd:ee:ff 192.168.1.20 iphone *
1788000000 11:22:33:44:55:66 192.168.1.30 laptop *
LEASES

cat >"$FIXTURE" <<'LOGS'
Sat Aug 29 06:00:00 2026 daemon.info dnsmasq[1]: query[A] example.com from 192.168.1.10
Sat Aug 29 06:00:00 2026 daemon.info dnsmasq[1]: forwarded example.com to 1.1.1.1
Sat Aug 29 06:00:01 2026 daemon.info dnsmasq[1]: 11 192.168.1.20/50001 query[A] ads.example from 192.168.1.20
Sat Aug 29 06:00:01 2026 daemon.info dnsmasq[1]: 11 192.168.1.20/50001 config ads.example is 0.0.0.0
Sat Aug 29 06:00:02 2026 daemon.info dnsmasq[1]: 12 192.168.1.20/50002 query[AAAA] ads.example from 192.168.1.20
Sat Aug 29 06:00:02 2026 daemon.info dnsmasq[1]: 12 192.168.1.20/50002 config ads.example is ::
Sat Aug 29 06:00:03 2026 daemon.info dnsmasq-dhcp[1]: DHCPACK(br-lan) 192.168.1.20 aa:bb:cc:dd:ee:ff client
Sat Aug 29 06:00:04 2026 daemon.info dnsmasq[1]: 13 127.0.0.1/50003 config router.lan is 192.168.1.1
LOGS

awk \
	-v state_file="$STATE" \
	-v json_file="$JSON" \
	-v snapshot_interval=60 \
	-v retention_hours=168 \
	-v lease_file="$LEASES" \
	-v fixed_now=1787950800 \
	-f "$ROOT/files/usr/lib/safeshield/statistics.awk" \
	<"$FIXTURE"

meta_counts="$(awk -F '\t' '$1 == "meta" { print $4 " " $5 }' "$STATE")"
[ "$meta_counts" = "3 2" ]
grep -F '"totals":{"queries":3,"blocked":2}' "$JSON" >/dev/null
if grep -F 'ads.example' "$STATE" "$JSON" >/dev/null; then
	echo 'raw domains must not be persisted in statistics files' >&2
	exit 1
fi
grep -F '"id":"aa:bb:cc:dd:ee:ff","mac":"aa:bb:cc:dd:ee:ff","ip":"192.168.1.20","hostname":"iphone","identified":true,"queries":2,"blocked":2' "$JSON" >/dev/null
grep -F '"id":"ip:192.168.1.10","mac":"","ip":"192.168.1.10","hostname":"","identified":false,"queries":1,"blocked":0' "$JSON" >/dev/null
expected_device_line="$(printf 'device\taa:bb:cc:dd:ee:ff\taa:bb:cc:dd:ee:ff\t192.168.1.20\tiphone\t2\t2')"
grep -F "$expected_device_line" "$STATE" >/dev/null

cat >"$FIXTURE" <<'LOGS'
Sat Aug 29 07:00:00 2026 daemon.info dnsmasq[1]: 14 192.168.1.30/50004 query[A] openwrt.org from 192.168.1.30
LOGS

awk \
	-v state_file="$STATE" \
	-v json_file="$JSON" \
	-v snapshot_interval=60 \
	-v retention_hours=168 \
	-v lease_file="$LEASES" \
	-v fixed_now=1787954400 \
	-f "$ROOT/files/usr/lib/safeshield/statistics.awk" \
	<"$FIXTURE"

grep -F '"totals":{"queries":4,"blocked":2}' "$JSON" >/dev/null
grep -F '"id":"11:22:33:44:55:66","mac":"11:22:33:44:55:66","ip":"192.168.1.30","hostname":"laptop","identified":true,"queries":1,"blocked":0' "$JSON" >/dev/null
bucket_count="$(grep -c '^bucket' "$STATE")"
[ "$bucket_count" -eq 2 ]

# A client first seen without a DHCP lease must migrate to its MAC identity
# once the lease appears, without losing counters or creating a duplicate.
MIGRATE_STATE="$TMP/migrate-state.tsv"
MIGRATE_JSON="$TMP/migrate-statistics.json"
MIGRATE_LEASES="$TMP/migrate-dhcp.leases"
MIGRATE_LOG="$TMP/migrate.log"
: >"$MIGRATE_LEASES"
cat >"$MIGRATE_LOG" <<'LOGS'
daemon.info dnsmasq[1]: 21 192.168.1.40/50001 query[A] first.example from 192.168.1.40
LOGS
awk \
	-v state_file="$MIGRATE_STATE" \
	-v json_file="$MIGRATE_JSON" \
	-v lease_file="$MIGRATE_LEASES" \
	-v snapshot_interval=60 \
	-v retention_hours=168 \
	-v fixed_now=1787958000 \
	-f "$ROOT/files/usr/lib/safeshield/statistics.awk" \
	<"$MIGRATE_LOG"
cat >"$MIGRATE_LEASES" <<'LEASES'
1788000000 de:ad:be:ef:00:01 192.168.1.40 tablet *
LEASES
cat >"$MIGRATE_LOG" <<'LOGS'
daemon.info dnsmasq[1]: 22 192.168.1.40/50002 query[A] second.example from 192.168.1.40
LOGS
awk \
	-v state_file="$MIGRATE_STATE" \
	-v json_file="$MIGRATE_JSON" \
	-v lease_file="$MIGRATE_LEASES" \
	-v snapshot_interval=60 \
	-v retention_hours=168 \
	-v fixed_now=1787958061 \
	-f "$ROOT/files/usr/lib/safeshield/statistics.awk" \
	<"$MIGRATE_LOG"
grep -F '"id":"de:ad:be:ef:00:01","mac":"de:ad:be:ef:00:01","ip":"192.168.1.40","hostname":"tablet","identified":true,"queries":2,"blocked":0' "$MIGRATE_JSON" >/dev/null
if grep -F '"id":"ip:192.168.1.40"' "$MIGRATE_JSON" >/dev/null; then
	echo 'temporary IP identity must migrate to DHCP MAC identity' >&2
	exit 1
fi

printf '%s\n' 'statistics tests: ok'
