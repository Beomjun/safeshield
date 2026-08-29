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
grep -Fx 'log-queries' "$SS_STATISTICS_DNSMASQ_CONF" >/dev/null
grep -Fx 'log-async=25' "$SS_STATISTICS_DNSMASQ_CONF" >/dev/null

changed="$(ss_statistics_configure_dnsmasq 1)"
[ "$changed" = "0" ]

changed="$(ss_statistics_configure_dnsmasq 0)"
[ "$changed" = "1" ]
[ ! -e "$SS_STATISTICS_DNSMASQ_CONF" ]

STATE="$TMP/state.tsv"
JSON="$TMP/statistics.json"
FIXTURE="$TMP/dnsmasq.log"

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
if grep -F '192.168.1.20' "$STATE" "$JSON" >/dev/null; then
	echo 'client addresses must not be persisted in statistics files' >&2
	exit 1
fi

cat >"$FIXTURE" <<'LOGS'
Sat Aug 29 07:00:00 2026 daemon.info dnsmasq[1]: 14 192.168.1.30/50004 query[A] openwrt.org from 192.168.1.30
LOGS

awk \
	-v state_file="$STATE" \
	-v json_file="$JSON" \
	-v snapshot_interval=60 \
	-v retention_hours=168 \
	-v fixed_now=1787954400 \
	-f "$ROOT/files/usr/lib/safeshield/statistics.awk" \
	<"$FIXTURE"

grep -F '"totals":{"queries":4,"blocked":2}' "$JSON" >/dev/null
bucket_count="$(grep -c '^bucket' "$STATE")"
[ "$bucket_count" -eq 2 ]

printf '%s\n' 'statistics tests: ok'
