#!/bin/sh
# shellcheck shell=sh
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

STATE="$TMP/state.tsv"
JSON="$TMP/statistics.json"
PERSISTENT="$TMP/statistics-state.tsv"
JOURNAL="$TMP/statistics-journal.tsv"
LEASES="$TMP/dhcp.leases"
ARP="$TMP/arp"
LOG="$TMP/dnsmasq.log"

cat >"$LEASES" <<'LEASES'
1788000000 aa:bb:cc:dd:ee:ff 192.168.1.20 iphone *
LEASES
cat >"$ARP" <<'ARP'
IP address       HW type     Flags       HW address            Mask     Device
ARP

# Start from the snapshot format written by 0.3.18-r4. Journal mode must use
# it as a compacted base without rewriting that full flash file every hour.
cat >"$PERSISTENT" <<'STATE'
meta	1787950800	1787950800	1	1	0	1787950800	2	1787950800	1	0	0
bucket	1787950800	1	1
device	aa:bb:cc:dd:ee:ff	aa:bb:cc:dd:ee:ff	192.168.1.20	iphone	1	1
device_bucket	aa:bb:cc:dd:ee:ff	1787950800	1	1
STATE
before_base="$(cksum "$PERSISTENT")"

cat >"$LOG" <<'LOGS'
daemon.info dnsmasq[1]: 12 192.168.1.20/50002 query[A] openwrt.org from 192.168.1.20
LOGS

awk \
	-v state_file="$STATE" \
	-v json_file="$JSON" \
	-v persistent_state_file="$PERSISTENT" \
	-v persistent_journal_file="$JOURNAL" \
	-v persistent_interval=3600 \
	-v persistent_compact_interval=604800 \
	-v snapshot_interval=60 \
	-v retention_hours=168 \
	-v lease_file="$LEASES" \
	-v arp_file="$ARP" \
	-v fixed_now=1787954400 \
	-f "$ROOT/files/usr/lib/safeshield/statistics.awk" \
	<"$LOG"

after_base="$(cksum "$PERSISTENT")"
[ "$before_base" = "$after_base" ] || {
	echo 'hourly journal checkpoint must not rewrite the compacted base snapshot' >&2
	exit 1
}
[ -s "$JOURNAL" ]
grep -F 'begin' "$JOURNAL" >/dev/null
grep -F 'commit' "$JOURNAL" >/dev/null
grep -F "$(printf 'bucket\t1787954400\t1\t0')" "$JOURNAL" >/dev/null
grep -F "$(printf 'device_bucket\taa:bb:cc:dd:ee:ff\t1787954400\t1\t0')" "$JOURNAL" >/dev/null
if grep -F 'openwrt.org' "$JOURNAL" >/dev/null; then
	echo 'raw domains must never be written to the statistics journal' >&2
	exit 1
fi
grep -F '"persistence_mode":"journal"' "$JSON" >/dev/null
grep -F '"persistent_compact_interval_s":604800' "$JSON" >/dev/null
grep -F '"totals":{"queries":2,"blocked":1}' "$JSON" >/dev/null

# Reboot recovery must replay the compacted base and committed journal records.
rm -f "$STATE" "$JSON"
: >"$LOG"
awk \
	-v state_file="$STATE" \
	-v json_file="$JSON" \
	-v persistent_state_file="$PERSISTENT" \
	-v persistent_journal_file="$JOURNAL" \
	-v persistent_interval=3600 \
	-v persistent_compact_interval=604800 \
	-v snapshot_interval=60 \
	-v retention_hours=168 \
	-v lease_file="$LEASES" \
	-v arp_file="$ARP" \
	-v fixed_now=1787958000 \
	-f "$ROOT/files/usr/lib/safeshield/statistics.awk" \
	<"$LOG"
grep -F '"totals":{"queries":2,"blocked":1}' "$JSON" >/dev/null
grep -F '{"bucket_start":1787950800,"queries":1,"blocked":1}' "$JSON" >/dev/null
grep -F '{"bucket_start":1787954400,"queries":1,"blocked":0}' "$JSON" >/dev/null

# A partial append without a matching commit marker must be ignored, even when
# a later collector run appends another complete transaction after it.
cat >>"$JOURNAL" <<'PARTIAL'
begin	interrupted	1	1787961600	1787950800	0	1787961600	1787958000	1	0	0
bucket	1787954400	999	999
PARTIAL
rm -f "$STATE" "$JSON"
: >"$LOG"
awk \
	-v state_file="$STATE" \
	-v json_file="$JSON" \
	-v persistent_state_file="$PERSISTENT" \
	-v persistent_journal_file="$JOURNAL" \
	-v persistent_interval=3600 \
	-v persistent_compact_interval=604800 \
	-v snapshot_interval=60 \
	-v retention_hours=168 \
	-v lease_file="$LEASES" \
	-v arp_file="$ARP" \
	-v fixed_now=1787961600 \
	-f "$ROOT/files/usr/lib/safeshield/statistics.awk" \
	<"$LOG"
grep -F '"totals":{"queries":2,"blocked":1}' "$JSON" >/dev/null
if grep -F '"queries":999' "$JSON" >/dev/null; then
	echo 'an uncommitted journal transaction must never be replayed' >&2
	exit 1
fi

# The previous run appended a valid transaction after the interrupted one. A
# second reboot verifies that the incomplete middle transaction is still
# ignored rather than becoming implicitly committed by a later append.
rm -f "$STATE" "$JSON"
: >"$LOG"
awk \
	-v state_file="$STATE" \
	-v json_file="$JSON" \
	-v persistent_state_file="$PERSISTENT" \
	-v persistent_journal_file="$JOURNAL" \
	-v persistent_interval=3600 \
	-v persistent_compact_interval=604800 \
	-v snapshot_interval=60 \
	-v retention_hours=168 \
	-v lease_file="$LEASES" \
	-v arp_file="$ARP" \
	-v fixed_now=1787965200 \
	-f "$ROOT/files/usr/lib/safeshield/statistics.awk" \
	<"$LOG"
grep -F '"totals":{"queries":2,"blocked":1}' "$JSON" >/dev/null
if grep -F '"queries":999' "$JSON" >/dev/null; then
	echo 'an interrupted journal transaction must stay ignored after later commits' >&2
	exit 1
fi

# Compaction is deliberately infrequent. When due, it rewrites one complete
# retained base snapshot and then discards old journal transactions. Absolute
# journal upserts make an interrupted truncate safe to replay without doubles.
COMPACT_STATE="$TMP/compact-state.tsv"
COMPACT_JSON="$TMP/compact-statistics.json"
COMPACT_BASE="$TMP/compact-base.tsv"
COMPACT_JOURNAL="$TMP/compact-journal.tsv"
COMPACT_LOG="$TMP/compact.log"
cat >"$COMPACT_BASE" <<'STATE'
meta	1787954400	1787954400	1	0	0	1787954400	3	1787954400	1	0	0	1787954400	1787950800
bucket	1787954400	1	0
device	aa:bb:cc:dd:ee:ff	aa:bb:cc:dd:ee:ff	192.168.1.20	iphone	1	0
device_bucket	aa:bb:cc:dd:ee:ff	1787954400	1	0
STATE
cat >"$COMPACT_LOG" <<'LOGS'
daemon.info dnsmasq[1]: 20 192.168.1.20/50020 query[A] one.example from 192.168.1.20
daemon.info dnsmasq[1]: 21 192.168.1.20/50021 query[A] two.example from 192.168.1.20
LOGS

awk \
	-v state_file="$COMPACT_STATE" \
	-v json_file="$COMPACT_JSON" \
	-v persistent_state_file="$COMPACT_BASE" \
	-v persistent_journal_file="$COMPACT_JOURNAL" \
	-v persistent_interval=3600 \
	-v persistent_compact_interval=3600 \
	-v snapshot_interval=1 \
	-v retention_hours=168 \
	-v lease_file="$LEASES" \
	-v arp_file="$ARP" \
	-v fixed_now=1787954400 \
	-v fixed_step=3600 \
	-f "$ROOT/files/usr/lib/safeshield/statistics.awk" \
	<"$COMPACT_LOG"

grep -F "$(printf 'meta\t1787954400\t1787958000\t3\t0')" "$COMPACT_BASE" >/dev/null
grep -F '"totals":{"queries":3,"blocked":0}' "$COMPACT_JSON" >/dev/null
[ -s "$COMPACT_JOURNAL" ]
# The journal was compacted during the second event; END then writes only the
# active 1787958000 hour again, so historical 1787954400 upserts are absent.
if grep -F "$(printf 'bucket\t1787954400')" "$COMPACT_JOURNAL" >/dev/null; then
	echo 'compaction must discard historical journal records already in the base snapshot' >&2
	exit 1
fi
grep -F "$(printf 'bucket\t1787958000\t1\t0')" "$COMPACT_JOURNAL" >/dev/null

# IP -> MAC reconciliation must persist the migrated full retained history, not
# only the current hour. Otherwise the tombstone would delete historical ip:*
# buckets on the next reboot without recreating them under the MAC identity.
MIGRATE_STATE="$TMP/migrate-state.tsv"
MIGRATE_JSON="$TMP/migrate-statistics.json"
MIGRATE_BASE="$TMP/migrate-base.tsv"
MIGRATE_JOURNAL="$TMP/migrate-journal.tsv"
MIGRATE_LEASES="$TMP/migrate-leases"
MIGRATE_EMPTY_LEASES="$TMP/migrate-empty-leases"
cat >"$MIGRATE_BASE" <<'STATE'
meta	1787950800	1787954400	6	2	0	1787954400	2	1787954400	1	0	0
bucket	1787950800	3	1
bucket	1787954400	3	1
device	ip:192.168.1.50	*	192.168.1.50	*	4	1
device	de:ad:be:ef:00:02	de:ad:be:ef:00:02	192.168.1.50	workstation	2	1
device_bucket	ip:192.168.1.50	1787950800	2	1
device_bucket	ip:192.168.1.50	1787954400	2	0
device_bucket	de:ad:be:ef:00:02	1787950800	1	0
device_bucket	de:ad:be:ef:00:02	1787954400	1	1
STATE
cat >"$MIGRATE_LEASES" <<'LEASES'
1788000000 de:ad:be:ef:00:02 192.168.1.50 workstation *
LEASES
: >"$MIGRATE_EMPTY_LEASES"
: >"$LOG"
awk \
	-v state_file="$MIGRATE_STATE" \
	-v json_file="$MIGRATE_JSON" \
	-v persistent_state_file="$MIGRATE_BASE" \
	-v persistent_journal_file="$MIGRATE_JOURNAL" \
	-v persistent_interval=3600 \
	-v persistent_compact_interval=604800 \
	-v snapshot_interval=60 \
	-v retention_hours=168 \
	-v lease_file="$MIGRATE_LEASES" \
	-v arp_file="$ARP" \
	-v fixed_now=1787954400 \
	-f "$ROOT/files/usr/lib/safeshield/statistics.awk" \
	<"$LOG"
grep -F "$(printf 'delete_device\tip:192.168.1.50')" "$MIGRATE_JOURNAL" >/dev/null
grep -F "$(printf 'device_bucket\tde:ad:be:ef:00:02\t1787950800\t3\t1')" "$MIGRATE_JOURNAL" >/dev/null
grep -F "$(printf 'device_bucket\tde:ad:be:ef:00:02\t1787954400\t3\t1')" "$MIGRATE_JOURNAL" >/dev/null

# Reboot without DHCP/ARP help: the journal itself must keep the old IP
# identity deleted and preserve both historical MAC buckets.
rm -f "$MIGRATE_STATE" "$MIGRATE_JSON"
awk \
	-v state_file="$MIGRATE_STATE" \
	-v json_file="$MIGRATE_JSON" \
	-v persistent_state_file="$MIGRATE_BASE" \
	-v persistent_journal_file="$MIGRATE_JOURNAL" \
	-v persistent_interval=3600 \
	-v persistent_compact_interval=604800 \
	-v snapshot_interval=60 \
	-v retention_hours=168 \
	-v lease_file="$MIGRATE_EMPTY_LEASES" \
	-v arp_file="$ARP" \
	-v fixed_now=1787958000 \
	-f "$ROOT/files/usr/lib/safeshield/statistics.awk" \
	<"$LOG"
grep -F '"id":"de:ad:be:ef:00:02"' "$MIGRATE_JSON" >/dev/null
grep -F '{"bucket_start":1787950800,"queries":3,"blocked":1}' "$MIGRATE_JSON" >/dev/null
grep -F '{"bucket_start":1787954400,"queries":3,"blocked":1}' "$MIGRATE_JSON" >/dev/null
if grep -F '"id":"ip:192.168.1.50"' "$MIGRATE_JSON" >/dev/null; then
	echo 'journal replay must not resurrect a migrated temporary IP identity' >&2
	exit 1
fi

# A journal append failure must keep tmpfs statistics available while exposing
# persistence health/error metadata. The next retry is delayed by the existing
# persistence backoff rather than turning the 60-second RAM snapshot into a
# repeated flash-write failure loop.
FAIL_STATE="$TMP/journal-fail-state.tsv"
FAIL_JSON="$TMP/journal-fail-statistics.json"
FAIL_BASE="$TMP/journal-fail-base.tsv"
FAIL_JOURNAL="$TMP/journal-fail.tsv"
FAIL_BIN="$TMP/journal-fail-bin"
mkdir "$FAIL_BIN"
cat >"$FAIL_BIN/cat" <<'CAT'
#!/bin/sh
exit 1
CAT
chmod 755 "$FAIL_BIN/cat"
: >"$LOG"
PATH="$FAIL_BIN:$PATH" awk \
	-v state_file="$FAIL_STATE" \
	-v json_file="$FAIL_JSON" \
	-v persistent_state_file="$FAIL_BASE" \
	-v persistent_journal_file="$FAIL_JOURNAL" \
	-v persistent_interval=3600 \
	-v persistent_retry_interval=300 \
	-v persistent_compact_interval=604800 \
	-v snapshot_interval=60 \
	-v retention_hours=168 \
	-v lease_file="$LEASES" \
	-v arp_file="$ARP" \
	-v fixed_now=1787968800 \
	-f "$ROOT/files/usr/lib/safeshield/statistics.awk" \
	<"$LOG"
grep -F '"persistence_mode":"journal"' "$FAIL_JSON" >/dev/null
grep -F '"persistence_healthy":false' "$FAIL_JSON" >/dev/null
grep -F '"persistent_error_count":1' "$FAIL_JSON" >/dev/null
[ -s "$FAIL_STATE" ]

# Upgrade and rpcd contracts include both persistent files and expose journal
# mode/compaction metadata without leaking filesystem paths through the API.
grep -Fx '/etc/safeshield/statistics-state.tsv' "$ROOT/files/lib/upgrade/keep.d/safeshield" >/dev/null
grep -Fx '/etc/safeshield/statistics-journal.tsv' "$ROOT/files/lib/upgrade/keep.d/safeshield" >/dev/null
grep -F "persistence_mode: sprintf('%s', data.persistence_mode || 'none')" \
	"$ROOT/files/usr/share/rpcd/ucode/safeshield/statistics.uc" >/dev/null
grep -F 'persistent_compact_interval_s: to_int(data.persistent_compact_interval_s, 604800)' \
	"$ROOT/files/usr/share/rpcd/ucode/safeshield/statistics.uc" >/dev/null

printf '%s\n' 'statistics journal tests: ok'
