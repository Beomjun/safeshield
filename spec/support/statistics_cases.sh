#!/bin/sh
# shellcheck shell=sh

ss_statistics_awk() {
	awk "$@" \
		-f "$SS_SPEC_ROOT/files/usr/lib/safeshield/statistics/00-common.awk" \
		-f "$SS_SPEC_ROOT/files/usr/lib/safeshield/statistics/10-recovery.awk" \
		-f "$SS_SPEC_ROOT/files/usr/lib/safeshield/statistics/20-identity.awk" \
		-f "$SS_SPEC_ROOT/files/usr/lib/safeshield/statistics/30-aggregate.awk" \
		-f "$SS_SPEC_ROOT/files/usr/lib/safeshield/statistics/40-persistence.awk" \
		-f "$SS_SPEC_ROOT/files/usr/lib/safeshield/statistics/50-output.awk" \
		-f "$SS_SPEC_ROOT/files/usr/lib/safeshield/statistics/90-main.awk"
}

ss_case_statistics() (
	set -eu
	TMP="$(ss_spec_tmpdir)"
	trap 'rm -rf "$TMP"' EXIT HUP INT TERM
	SS_DNSMASQ_DIR="$TMP/dnsmasq.d"
	SS_STATISTICS_DNSMASQ_CONF="$SS_DNSMASQ_DIR/safeshield.statistics.conf"
	export SS_DNSMASQ_DIR SS_STATISTICS_DNSMASQ_CONF
	mkdir -p "$SS_DNSMASQ_DIR"
	# shellcheck disable=SC1091
	. "$SS_SPEC_ROOT/files/usr/lib/safeshield/statistics.sh"

	ss_spec_assert_eq "$(ss_statistics_effective_snapshot_interval 60)" '60'
	ss_spec_assert_eq "$(ss_statistics_effective_snapshot_interval 120)" '120'
	ss_statistics_persistence_enabled
	changed="$(ss_statistics_configure_dnsmasq 1)"
	ss_spec_assert_eq "$changed" '1'
	ss_spec_assert_file_line "$SS_STATISTICS_DNSMASQ_CONF" 'log-queries=extra'
	ss_spec_assert_file_line "$SS_STATISTICS_DNSMASQ_CONF" 'log-async=25'
	ss_spec_assert_eq "$(ss_statistics_configure_dnsmasq 1)" '0'
	SS_IDENTITY_PROFILE='gl_mt300n_v2'
	export SS_IDENTITY_PROFILE
	ss_spec_assert_eq "$(ss_statistics_effective_snapshot_interval 60)" '300'
	ss_spec_assert_eq "$(ss_statistics_effective_snapshot_interval 120)" '120'
	! ss_statistics_persistence_enabled
	ss_spec_assert_eq "$(ss_statistics_configure_dnsmasq 1)" '1'
	ss_spec_assert_file_line "$SS_STATISTICS_DNSMASQ_CONF" 'log-async=50'
	ss_spec_assert_eq "$(ss_statistics_configure_dnsmasq 1)" '0'
	SS_IDENTITY_PROFILE=''
	export SS_IDENTITY_PROFILE
	ss_statistics_persistence_enabled
	ss_spec_assert_eq "$(ss_statistics_configure_dnsmasq 0)" '1'
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
	ss_statistics_awk \
		-v state_file="$STATE" \
		-v json_file="$JSON" \
		-v snapshot_interval=60 \
		-v retention_hours=168 \
		-v lease_file="$LEASES" \
		-v fixed_now=1787950800 \
		<"$FIXTURE"
	ss_spec_assert_eq "$(awk -F '\t' '$1 == "meta" { print $4 " " $5 }' "$STATE")" '3 2'
	ss_spec_assert_file_contains "$JSON" '"totals":{"queries":3,"blocked":2}'
	! grep -F 'ads.example' "$STATE" "$JSON" >/dev/null
	ss_spec_assert_file_contains "$JSON" '"id":"aa:bb:cc:dd:ee:ff","mac":"aa:bb:cc:dd:ee:ff","ip":"192.168.1.20","hostname":"iphone","identified":true,"queries":2,"blocked":2'
	ss_spec_assert_file_contains "$JSON" '"id":"ip:192.168.1.10","mac":"","ip":"192.168.1.10","hostname":"","identified":false,"queries":1,"blocked":0'

	cat >"$FIXTURE" <<'LOGS'
Sat Aug 29 07:00:00 2026 daemon.info dnsmasq[1]: 14 192.168.1.30/50004 query[A] openwrt.org from 192.168.1.30
LOGS
	ss_statistics_awk \
		-v state_file="$STATE" \
		-v json_file="$JSON" \
		-v snapshot_interval=60 \
		-v retention_hours=168 \
		-v lease_file="$LEASES" \
		-v fixed_now=1787954400 \
		<"$FIXTURE"
	ss_spec_assert_file_contains "$JSON" '"totals":{"queries":4,"blocked":2}'
	ss_spec_assert_file_contains "$JSON" '"id":"11:22:33:44:55:66","mac":"11:22:33:44:55:66","ip":"192.168.1.30","hostname":"laptop","identified":true,"queries":1,"blocked":0'
	ss_spec_assert_eq "$(grep -c '^bucket' "$STATE")" '2'

	MIGRATE_STATE="$TMP/migrate-state.tsv"
	MIGRATE_JSON="$TMP/migrate-statistics.json"
	MIGRATE_LEASES="$TMP/migrate-dhcp.leases"
	MIGRATE_LOG="$TMP/migrate.log"
	: >"$MIGRATE_LEASES"
	printf '%s\n' 'daemon.info dnsmasq[1]: 21 192.168.1.40/50001 query[A] first.example from 192.168.1.40' >"$MIGRATE_LOG"
	ss_statistics_awk -v state_file="$MIGRATE_STATE" -v json_file="$MIGRATE_JSON" -v lease_file="$MIGRATE_LEASES" -v snapshot_interval=60 -v retention_hours=168 -v fixed_now=1787958000 <"$MIGRATE_LOG"
	printf '%s\n' '1788000000 de:ad:be:ef:00:01 192.168.1.40 tablet *' >"$MIGRATE_LEASES"
	printf '%s\n' 'daemon.info dnsmasq[1]: 22 192.168.1.40/50002 query[A] second.example from 192.168.1.40' >"$MIGRATE_LOG"
	ss_statistics_awk -v state_file="$MIGRATE_STATE" -v json_file="$MIGRATE_JSON" -v lease_file="$MIGRATE_LEASES" -v snapshot_interval=60 -v retention_hours=168 -v fixed_now=1787958061 <"$MIGRATE_LOG"
	ss_spec_assert_file_contains "$MIGRATE_JSON" '"id":"de:ad:be:ef:00:01","mac":"de:ad:be:ef:00:01","ip":"192.168.1.40","hostname":"tablet","identified":true,"queries":2,"blocked":0'
	! grep -F '"id":"ip:192.168.1.40"' "$MIGRATE_JSON" >/dev/null

	ARP_STATE="$TMP/arp-state.tsv"
	ARP_JSON="$TMP/arp-statistics.json"
	ARP_LEASES="$TMP/arp-dhcp.leases"
	ARP_TABLE="$TMP/arp-table"
	ARP_LOG="$TMP/arp.log"
	: >"$ARP_LEASES"
	: >"$ARP_LOG"
	cat >"$ARP_TABLE" <<'ARP'
IP address       HW type     Flags       HW address            Mask     Device
192.168.1.50     0x1         0x2         de:ad:be:ef:00:02     *        br-lan
ARP
	cat >"$ARP_STATE" <<'STATE'
meta	1787950800	1787954400	6	2	0	0	2	1787954400
device	ip:192.168.1.50	*	192.168.1.50	*	4	1
device	de:ad:be:ef:00:02	de:ad:be:ef:00:02	192.168.1.50	workstation	2	1
device_bucket	ip:192.168.1.50	1787950800	2	1
device_bucket	ip:192.168.1.50	1787954400	2	0
device_bucket	de:ad:be:ef:00:02	1787950800	1	0
device_bucket	de:ad:be:ef:00:02	1787954400	1	1
bucket	1787950800	3	1
bucket	1787954400	3	1
STATE
	ss_statistics_awk -v state_file="$ARP_STATE" -v json_file="$ARP_JSON" -v lease_file="$ARP_LEASES" -v arp_file="$ARP_TABLE" -v snapshot_interval=60 -v retention_hours=168 -v fixed_now=1787954400 <"$ARP_LOG"
	ss_spec_assert_file_contains "$ARP_JSON" '"id":"de:ad:be:ef:00:02","mac":"de:ad:be:ef:00:02","ip":"192.168.1.50","hostname":"workstation","identified":true,"queries":6,"blocked":2'
	! grep -F '"id":"ip:192.168.1.50"' "$ARP_JSON" >/dev/null
	! grep -F "$(printf 'device_bucket\tip:192.168.1.50\t')" "$ARP_STATE" >/dev/null

	DIRTY_STATE="$TMP/dirty-state.tsv"
	DIRTY_JSON="$TMP/dirty-statistics.json"
	DIRTY_LOG="$TMP/dirty.log"
	MV_COUNT_FILE="$TMP/mv-count"
	FAKE_BIN="$TMP/fake-bin"
	REAL_MV="$(command -v mv)"
	mkdir -p "$FAKE_BIN"
	cat >"$FAKE_BIN/mv" <<'EOF_MV'
#!/bin/sh
printf '%s\n' '1' >>"$MV_COUNT_FILE"
exec "$REAL_MV" "$@"
EOF_MV
	chmod 755 "$FAKE_BIN/mv"
	: >"$DIRTY_LOG"
	: >"$MV_COUNT_FILE"
	PATH="$FAKE_BIN:$PATH" MV_COUNT_FILE="$MV_COUNT_FILE" REAL_MV="$REAL_MV" \
		ss_statistics_awk \
		-v state_file="$DIRTY_STATE" \
		-v json_file="$DIRTY_JSON" \
		-v snapshot_interval=60 \
		-v retention_hours=168 \
		-v fixed_now=1787954400 \
		<"$DIRTY_LOG"
	ss_spec_assert_eq "$(wc -l <"$MV_COUNT_FILE" | tr -d '[:space:]')" '2'
)

ss_case_statistics_persistence() (
	set -eu
	TMP="$(ss_spec_tmpdir)"
	trap 'rm -rf "$TMP"' EXIT HUP INT TERM
	STATE="$TMP/state.tsv"
	JSON="$TMP/statistics.json"
	PERSISTENT="$TMP/statistics-state.tsv"
	LEASES="$TMP/dhcp.leases"
	LOG="$TMP/dnsmasq.log"
	printf '%s\n' '1788000000 aa:bb:cc:dd:ee:ff 192.168.1.20 iphone *' >"$LEASES"
	cat >"$LOG" <<'LOGS'
daemon.info dnsmasq[1]: 11 192.168.1.20/50001 query[A] ads.example from 192.168.1.20
daemon.info dnsmasq[1]: 11 192.168.1.20/50001 config ads.example is 0.0.0.0
LOGS
	ss_statistics_awk -v state_file="$STATE" -v json_file="$JSON" -v persistent_state_file="$PERSISTENT" -v persistent_interval=3600 -v snapshot_interval=60 -v retention_hours=168 -v lease_file="$LEASES" -v fixed_now=1787950800 <"$LOG"
	ss_spec_assert_nonempty "$PERSISTENT"
	ss_spec_assert_file_contains "$JSON" '"version":2'
	ss_spec_assert_file_contains "$JSON" '"volatile":false'
	ss_spec_assert_file_contains "$JSON" '"storage":"tmpfs+flash"'
	ss_spec_assert_file_contains "$JSON" '"persistent":true'
	ss_spec_assert_file_contains "$JSON" '"totals":{"queries":1,"blocked":1}'
	! grep -F 'ads.example' "$PERSISTENT" >/dev/null

	rm -f "$STATE" "$JSON"
	printf '%s\n' 'daemon.info dnsmasq[1]: 12 192.168.1.20/50002 query[A] openwrt.org from 192.168.1.20' >"$LOG"
	ss_statistics_awk -v state_file="$STATE" -v json_file="$JSON" -v persistent_state_file="$PERSISTENT" -v persistent_interval=3600 -v snapshot_interval=60 -v retention_hours=168 -v lease_file="$LEASES" -v fixed_now=1787954400 <"$LOG"
	ss_spec_assert_file_contains "$JSON" '"totals":{"queries":2,"blocked":1}'
	ss_spec_assert_file_contains "$JSON" '{"bucket_start":1787950800,"queries":1,"blocked":1}'
	ss_spec_assert_file_contains "$JSON" '{"bucket_start":1787954400,"queries":1,"blocked":0}'
	ss_spec_assert_file_contains "$JSON" '"session_started_at":1787954400'

	LEGACY_STATE="$TMP/legacy-state.tsv"
	LEGACY_JSON="$TMP/legacy-statistics.json"
	cat >"$LEGACY_STATE" <<'STATE'
meta	1787950800	1787950800	3	1	0
bucket	1787950800	3	1
device	aa:bb:cc:dd:ee:ff	aa:bb:cc:dd:ee:ff	192.168.1.20	iphone	3	1
STATE
	: >"$LOG"
	ss_statistics_awk -v state_file="$LEGACY_STATE" -v json_file="$LEGACY_JSON" -v snapshot_interval=60 -v retention_hours=168 -v lease_file="$LEASES" -v fixed_now=1787950800 <"$LOG"
	ss_spec_assert_file_contains "$LEGACY_JSON" '"totals":{"queries":3,"blocked":1}'
	ss_spec_assert_file_contains "$LEGACY_JSON" '"queries":3,"blocked":1,"hourly":[{"bucket_start":1787950800,"queries":3,"blocked":1}]'
	ss_spec_assert_file_contains "$LEGACY_STATE" "$(printf 'device_bucket\taa:bb:cc:dd:ee:ff\t1787950800\t3\t1')"

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
	ss_statistics_awk \
		-v state_file="$LATEST_STATE" \
		-v json_file="$LATEST_JSON" \
		-v persistent_state_file="$LATEST_PERSISTENT" \
		-v persistent_interval=3600 \
		-v snapshot_interval=60 \
		-v retention_hours=168 \
		-v lease_file="$LEASES" \
		-v fixed_now=1787958000 \
		<"$LOG"
	ss_spec_assert_file_contains "$LATEST_JSON" '"totals":{"queries":2,"blocked":1}'

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
	ss_statistics_awk \
		-v state_file="$CORRUPT_STATE" \
		-v json_file="$CORRUPT_JSON" \
		-v persistent_state_file="$CORRUPT_PERSISTENT" \
		-v persistent_interval=3600 \
		-v snapshot_interval=60 \
		-v retention_hours=168 \
		-v lease_file="$LEASES" \
		-v fixed_now=1787961600 \
		<"$LOG"
	ss_spec_assert_file_contains "$CORRUPT_JSON" '"totals":{"queries":2,"blocked":1}'

	FAIL_STATE="$TMP/fail-state.tsv"
	FAIL_JSON="$TMP/fail-statistics.json"
	FAIL_TARGET="$TMP/fail-persistent.tsv"
	FAIL_BIN="$TMP/fail-bin"
	REAL_MV="$(command -v mv)"
	mkdir "$FAIL_BIN"
	cat >"$FAIL_BIN/mv" <<EOF_MV
#!/bin/sh
case "\${*}" in
	*fail-persistent.tsv*) exit 1 ;;
esac
exec "$REAL_MV" "\${@}"
EOF_MV
	chmod +x "$FAIL_BIN/mv"
	: >"$LOG"
	PATH="$FAIL_BIN:$PATH" ss_statistics_awk -v state_file="$FAIL_STATE" -v json_file="$FAIL_JSON" -v persistent_state_file="$FAIL_TARGET" -v persistent_interval=3600 -v persistent_retry_interval=300 -v snapshot_interval=60 -v retention_hours=168 -v lease_file="$LEASES" -v fixed_now=1787965200 <"$LOG"
	ss_spec_assert_file_contains "$FAIL_JSON" '"persistence_enabled":true'
	ss_spec_assert_file_contains "$FAIL_JSON" '"persistence_healthy":false'
	ss_spec_assert_file_contains "$FAIL_JSON" '"persistent_error_count":1'
	ss_spec_assert_file_contains "$FAIL_JSON" '"persistent_last_error_at":1787965200'
	ss_spec_assert_nonempty "$FAIL_STATE"

	STATISTICS_UC="$SS_SPEC_ROOT/files/usr/share/rpcd/ucode/safeshield/statistics.uc"
	ss_spec_assert_file_contains "$STATISTICS_UC" 'hourly: sanitize_hourly(item.hourly)'
	ss_spec_assert_eq "$(grep -Fc 'hourly: sanitize_hourly(item.hourly)' "$STATISTICS_UC")" '1'
	ss_spec_assert_file_contains "$STATISTICS_UC" 'persistence_healthy: to_bool(data.persistence_healthy, false)'

	VOLATILE_STATE="$TMP/volatile-state.tsv"
	VOLATILE_JSON="$TMP/volatile-statistics.json"
	cat >"$VOLATILE_STATE" <<'STATE'
meta	1787950800	1787950800	1	0	0	1787950700	3	1787950800	0	2	1787950600	1787950500	1787947200
bucket	1787950800	1	0
STATE
	: >"$LOG"
	ss_statistics_awk -v state_file="$VOLATILE_STATE" -v json_file="$VOLATILE_JSON" -v snapshot_interval=300 -v retention_hours=168 -v lease_file="$LEASES" -v fixed_now=1787954400 <"$LOG"
	for expected in \
		'"persistence_enabled":false' \
		'"persistence_healthy":true' \
		'"persistence_mode":"none"' \
		'"persistent_error_count":0' \
		'"persistent_last_error_at":0' \
		'"persistent_updated_at":0' \
		'"persistent_compacted_at":0' \
		'"snapshot_interval_s":300'; do
		ss_spec_assert_file_contains "$VOLATILE_JSON" "$expected"
	done
)

ss_case_statistics_journal() (
	set -eu
	TMP="$(ss_spec_tmpdir)"
	trap 'rm -rf "$TMP"' EXIT HUP INT TERM
	STATE="$TMP/state.tsv"
	JSON="$TMP/statistics.json"
	PERSISTENT="$TMP/statistics-state.tsv"
	JOURNAL="$TMP/statistics-journal.tsv"
	LEASES="$TMP/dhcp.leases"
	ARP="$TMP/arp"
	LOG="$TMP/dnsmasq.log"
	printf '%s\n' '1788000000 aa:bb:cc:dd:ee:ff 192.168.1.20 iphone *' >"$LEASES"
	printf '%s\n' 'IP address       HW type     Flags       HW address            Mask     Device' >"$ARP"
	cat >"$PERSISTENT" <<'STATE'
meta	1787950800	1787950800	1	1	0	1787950800	2	1787950800	1	0	0
bucket	1787950800	1	1
device	aa:bb:cc:dd:ee:ff	aa:bb:cc:dd:ee:ff	192.168.1.20	iphone	1	1
device_bucket	aa:bb:cc:dd:ee:ff	1787950800	1	1
STATE
	before_base="$(cksum "$PERSISTENT")"
	printf '%s\n' 'daemon.info dnsmasq[1]: 12 192.168.1.20/50002 query[A] openwrt.org from 192.168.1.20' >"$LOG"
	ss_statistics_awk -v state_file="$STATE" -v json_file="$JSON" -v persistent_state_file="$PERSISTENT" -v persistent_journal_file="$JOURNAL" -v persistent_interval=3600 -v persistent_compact_interval=604800 -v snapshot_interval=60 -v retention_hours=168 -v lease_file="$LEASES" -v arp_file="$ARP" -v fixed_now=1787954400 <"$LOG"
	ss_spec_assert_eq "$before_base" "$(cksum "$PERSISTENT")"
	ss_spec_assert_nonempty "$JOURNAL"
	ss_spec_assert_file_contains "$JOURNAL" 'begin'
	ss_spec_assert_file_contains "$JOURNAL" 'commit'
	ss_spec_assert_file_contains "$JOURNAL" "$(printf 'bucket\t1787954400\t1\t0')"
	ss_spec_assert_file_contains "$JOURNAL" "$(printf 'device_bucket\taa:bb:cc:dd:ee:ff\t1787954400\t1\t0')"
	! grep -F 'openwrt.org' "$JOURNAL" >/dev/null
	ss_spec_assert_file_contains "$JSON" '"persistence_mode":"journal"'
	ss_spec_assert_file_contains "$JSON" '"persistent_compact_interval_s":604800'
	ss_spec_assert_file_contains "$JSON" '"totals":{"queries":2,"blocked":1}'

	rm -f "$STATE" "$JSON"
	: >"$LOG"
	ss_statistics_awk -v state_file="$STATE" -v json_file="$JSON" -v persistent_state_file="$PERSISTENT" -v persistent_journal_file="$JOURNAL" -v persistent_interval=3600 -v persistent_compact_interval=604800 -v snapshot_interval=60 -v retention_hours=168 -v lease_file="$LEASES" -v arp_file="$ARP" -v fixed_now=1787958000 <"$LOG"
	ss_spec_assert_file_contains "$JSON" '"totals":{"queries":2,"blocked":1}'
	ss_spec_assert_file_contains "$JSON" '{"bucket_start":1787950800,"queries":1,"blocked":1}'
	ss_spec_assert_file_contains "$JSON" '{"bucket_start":1787954400,"queries":1,"blocked":0}'

	cat >>"$JOURNAL" <<'PARTIAL'
begin	interrupted	1	1787961600	1787950800	0	1787961600	1787958000	1	0	0
bucket	1787954400	999	999
PARTIAL
	rm -f "$STATE" "$JSON"
	ss_statistics_awk -v state_file="$STATE" -v json_file="$JSON" -v persistent_state_file="$PERSISTENT" -v persistent_journal_file="$JOURNAL" -v persistent_interval=3600 -v persistent_compact_interval=604800 -v snapshot_interval=60 -v retention_hours=168 -v lease_file="$LEASES" -v arp_file="$ARP" -v fixed_now=1787961600 <"$LOG"
	ss_spec_assert_file_contains "$JSON" '"totals":{"queries":2,"blocked":1}'
	! grep -F '"queries":999' "$JSON" >/dev/null

	rm -f "$STATE" "$JSON"
	: >"$LOG"
	ss_statistics_awk \
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
		<"$LOG"
	ss_spec_assert_file_contains "$JSON" '"totals":{"queries":2,"blocked":1}'
	! grep -F '"queries":999' "$JSON" >/dev/null

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
	ss_statistics_awk \
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
		<"$COMPACT_LOG"
	ss_spec_assert_file_contains "$COMPACT_BASE" "$(printf 'meta\t1787954400\t1787958000\t3\t0')"
	ss_spec_assert_file_contains "$COMPACT_JSON" '"totals":{"queries":3,"blocked":0}'
	ss_spec_assert_nonempty "$COMPACT_JOURNAL"
	! grep -F "$(printf 'bucket\t1787954400')" "$COMPACT_JOURNAL" >/dev/null
	ss_spec_assert_file_contains "$COMPACT_JOURNAL" "$(printf 'bucket\t1787958000\t1\t0')"

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
	printf '%s\n' '1788000000 de:ad:be:ef:00:02 192.168.1.50 workstation *' >"$MIGRATE_LEASES"
	: >"$MIGRATE_EMPTY_LEASES"
	: >"$LOG"
	ss_statistics_awk -v state_file="$MIGRATE_STATE" -v json_file="$MIGRATE_JSON" -v persistent_state_file="$MIGRATE_BASE" -v persistent_journal_file="$MIGRATE_JOURNAL" -v persistent_interval=3600 -v persistent_compact_interval=604800 -v snapshot_interval=60 -v retention_hours=168 -v lease_file="$MIGRATE_LEASES" -v arp_file="$ARP" -v fixed_now=1787954400 <"$LOG"
	ss_spec_assert_file_contains "$MIGRATE_JOURNAL" "$(printf 'delete_device\tip:192.168.1.50')"
	ss_spec_assert_file_contains "$MIGRATE_JOURNAL" "$(printf 'device_bucket\tde:ad:be:ef:00:02\t1787950800\t3\t1')"
	ss_spec_assert_file_contains "$MIGRATE_JOURNAL" "$(printf 'device_bucket\tde:ad:be:ef:00:02\t1787954400\t3\t1')"
	rm -f "$MIGRATE_STATE" "$MIGRATE_JSON"
	ss_statistics_awk -v state_file="$MIGRATE_STATE" -v json_file="$MIGRATE_JSON" -v persistent_state_file="$MIGRATE_BASE" -v persistent_journal_file="$MIGRATE_JOURNAL" -v persistent_interval=3600 -v persistent_compact_interval=604800 -v snapshot_interval=60 -v retention_hours=168 -v lease_file="$MIGRATE_EMPTY_LEASES" -v arp_file="$ARP" -v fixed_now=1787958000 <"$LOG"
	ss_spec_assert_file_contains "$MIGRATE_JSON" '"id":"de:ad:be:ef:00:02"'
	ss_spec_assert_file_contains "$MIGRATE_JSON" '{"bucket_start":1787950800,"queries":3,"blocked":1}'
	ss_spec_assert_file_contains "$MIGRATE_JSON" '{"bucket_start":1787954400,"queries":3,"blocked":1}'
	! grep -F '"id":"ip:192.168.1.50"' "$MIGRATE_JSON" >/dev/null

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
	PATH="$FAIL_BIN:$PATH" ss_statistics_awk -v state_file="$FAIL_STATE" -v json_file="$FAIL_JSON" -v persistent_state_file="$FAIL_BASE" -v persistent_journal_file="$FAIL_JOURNAL" -v persistent_interval=3600 -v persistent_retry_interval=300 -v persistent_compact_interval=604800 -v snapshot_interval=60 -v retention_hours=168 -v lease_file="$LEASES" -v arp_file="$ARP" -v fixed_now=1787968800 <"$LOG"
	ss_spec_assert_file_contains "$FAIL_JSON" '"persistence_mode":"journal"'
	ss_spec_assert_file_contains "$FAIL_JSON" '"persistence_healthy":false'
	ss_spec_assert_file_contains "$FAIL_JSON" '"persistent_error_count":1'
	ss_spec_assert_nonempty "$FAIL_STATE"
	ss_spec_assert_file_line "$SS_SPEC_ROOT/files/lib/upgrade/keep.d/safeshield" '/etc/safeshield/statistics-state.tsv'
	ss_spec_assert_file_line "$SS_SPEC_ROOT/files/lib/upgrade/keep.d/safeshield" '/etc/safeshield/statistics-journal.tsv'
	ss_spec_assert_file_contains "$SS_SPEC_ROOT/files/usr/share/rpcd/ucode/safeshield/statistics.uc" "persistence_mode: sprintf('%s', data.persistence_mode || 'none')"
	ss_spec_assert_file_contains "$SS_SPEC_ROOT/files/usr/share/rpcd/ucode/safeshield/statistics.uc" 'persistent_compact_interval_s: to_int(data.persistent_compact_interval_s, 604800)'
)

ss_case_statistics_stale_journal() (
	set -eu
	TMP="$(ss_spec_tmpdir)"
	trap 'rm -rf "$TMP"' EXIT HUP INT TERM
	STATE="$TMP/state.tsv"
	JSON="$TMP/statistics.json"
	PERSISTENT="$TMP/statistics-state.tsv"
	JOURNAL="$TMP/statistics-journal.tsv"
	LEASES="$TMP/dhcp.leases"
	ARP="$TMP/arp"
	LOG="$TMP/dnsmasq.log"
	: >"$LEASES"
	printf '%s\n' 'IP address       HW type     Flags       HW address            Mask     Device' >"$ARP"
	: >"$LOG"

	cat >"$PERSISTENT" <<'STATE'
meta	1787950800	1787958000	5	2	0	1787958000	4	1787958000	1	0	0	1787958000	1787954400	generation-base
bucket	1787954400	5	2
STATE
	cat >"$JOURNAL" <<'JOURNAL'
begin	stale-transaction	2	1787954400	1787950800	0	1787954400	1787950800	1	0	0	generation-base
bucket	1787954400	1	0
commit	stale-transaction
JOURNAL

	ss_statistics_awk \
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
		-v generation_seed='generation-new-candidate' \
		-v fixed_now=1787961600 \
		<"$LOG"

	ss_spec_assert_file_contains "$JSON" '"generation_id":"generation-base"'
	ss_spec_assert_file_contains "$JSON" '"totals":{"queries":5,"blocked":2}'
	ss_spec_assert_file_contains "$JSON" '{"bucket_start":1787954400,"queries":5,"blocked":2}'
	! grep -F '{"bucket_start":1787954400,"queries":1,"blocked":0}' "$JSON" >/dev/null
)

ss_case_statistics_internal_queries() (
	set -eu
	TMP="$(ss_spec_tmpdir)"
	trap 'rm -rf "$TMP"' EXIT HUP INT TERM
	STATE="$TMP/state.tsv"
	JSON="$TMP/statistics.json"
	LEASES="$TMP/dhcp.leases"
	ARP="$TMP/arp"
	LOG="$TMP/dnsmasq.log"
	: >"$LEASES"
	printf '%s\n' 'IP address       HW type     Flags       HW address            Mask     Device' >"$ARP"
	cat >"$LOG" <<'LOGS'
daemon.info dnsmasq[1]: 10 127.0.0.1/50000 query[A] health.example from 127.0.0.1
daemon.info dnsmasq[1]: 10 127.0.0.1/50000 config health.example is 0.0.0.0
daemon.info dnsmasq[1]: 11 ::1/50001 query[AAAA] health-v6.example from ::1
daemon.info dnsmasq[1]: 11 ::1/50001 config health-v6.example is ::
daemon.info dnsmasq[1]: 12 192.168.1.20/50002 query[A] ads.example from 192.168.1.20
daemon.info dnsmasq[1]: 12 192.168.1.20/50002 config ads.example is 0.0.0.0
LOGS

	ss_statistics_awk \
		-v state_file="$STATE" \
		-v json_file="$JSON" \
		-v snapshot_interval=60 \
		-v retention_hours=168 \
		-v lease_file="$LEASES" \
		-v arp_file="$ARP" \
		-v generation_seed='generation-internal' \
		-v fixed_now=1787950800 \
		<"$LOG"

	ss_spec_assert_file_contains "$JSON" '"totals":{"queries":1,"blocked":1}'
	ss_spec_assert_file_contains "$JSON" '"id":"ip:192.168.1.20"'
	! grep -F '"id":"ip:127.' "$JSON" >/dev/null
	! grep -F '"id":"ip:::1"' "$JSON" >/dev/null
)

ss_case_statistics_generation() (
	set -eu
	TMP="$(ss_spec_tmpdir)"
	trap 'rm -rf "$TMP"' EXIT HUP INT TERM
	STATE="$TMP/state.tsv"
	JSON="$TMP/statistics.json"
	LEASES="$TMP/dhcp.leases"
	ARP="$TMP/arp"
	LOG="$TMP/dnsmasq.log"
	: >"$LEASES"
	printf '%s\n' 'IP address       HW type     Flags       HW address            Mask     Device' >"$ARP"
	: >"$LOG"

	ss_statistics_awk \
		-v state_file="$STATE" \
		-v json_file="$JSON" \
		-v snapshot_interval=60 \
		-v retention_hours=168 \
		-v lease_file="$LEASES" \
		-v arp_file="$ARP" \
		-v generation_seed='generation-one' \
		-v fixed_now=1787950800 \
		<"$LOG"

	ss_spec_assert_file_contains "$JSON" '"generation_id":"generation-one"'
	ss_spec_assert_file_contains "$JSON" '"started_at":1787950800,"session_started_at":1787950800'
	ss_spec_assert_eq "$(awk -F '\t' '$1 == "meta" { print $8 " " $15 }' "$STATE")" '4 generation-one'

	ss_statistics_awk \
		-v state_file="$STATE" \
		-v json_file="$JSON" \
		-v snapshot_interval=60 \
		-v retention_hours=168 \
		-v lease_file="$LEASES" \
		-v arp_file="$ARP" \
		-v generation_seed='generation-two' \
		-v fixed_now=1787950860 \
		<"$LOG"

	ss_spec_assert_file_contains "$JSON" '"generation_id":"generation-one"'
	ss_spec_assert_file_contains "$JSON" '"started_at":1787950800,"session_started_at":1787950860'
	! grep -F '"generation_id":"generation-two"' "$JSON" >/dev/null

	rm -f "$STATE" "$JSON"
	ss_statistics_awk \
		-v state_file="$STATE" \
		-v json_file="$JSON" \
		-v snapshot_interval=60 \
		-v retention_hours=168 \
		-v lease_file="$LEASES" \
		-v arp_file="$ARP" \
		-v generation_seed='generation-two' \
		-v fixed_now=1787950920 \
		<"$LOG"

	ss_spec_assert_file_contains "$JSON" '"generation_id":"generation-two"'
	ss_spec_assert_file_contains "$JSON" '"started_at":1787950920,"session_started_at":1787950920'
)

ss_case_statistics_ipv6_identity() (
	set -eu
	TMP="$(ss_spec_tmpdir)"
	trap 'rm -rf "$TMP"' EXIT HUP INT TERM
	STATE="$TMP/state.tsv"
	JSON="$TMP/statistics.json"
	LEASES="$TMP/dhcp.leases"
	ARP="$TMP/arp"
	LOG="$TMP/dnsmasq.log"
	: >"$LEASES"
	printf '%s\n' 'IP address       HW type     Flags       HW address            Mask     Device' >"$ARP"
	cat >"$LOG" <<'LOGS'
daemon.info dnsmasq[1]: 20 2001:db8::100/50000 query[AAAA] one.example from 2001:db8::100
daemon.info dnsmasq[1]: 21 2001:db8::200/50001 query[AAAA] two.example from 2001:db8::200
LOGS

	ss_statistics_awk \
		-v state_file="$STATE" \
		-v json_file="$JSON" \
		-v snapshot_interval=60 \
		-v retention_hours=168 \
		-v lease_file="$LEASES" \
		-v arp_file="$ARP" \
		-v generation_seed='generation-ipv6' \
		-v fixed_now=1787950800 \
		<"$LOG"

	ss_spec_assert_file_contains "$JSON" '"totals":{"queries":2,"blocked":0}'
	ss_spec_assert_file_contains "$JSON" '"id":"ip:2001:db8::100","mac":"","ip":"2001:db8::100","hostname":"","identified":false'
	ss_spec_assert_file_contains "$JSON" '"id":"ip:2001:db8::200","mac":"","ip":"2001:db8::200","hostname":"","identified":false'
)

ss_case_statistics_ipv6_neighbor_identity() (
	set -eu
	TMP="$(ss_spec_tmpdir)"
	trap 'rm -rf "$TMP"' EXIT HUP INT TERM
	STATE="$TMP/state.tsv"
	JSON="$TMP/statistics.json"
	LEASES="$TMP/dhcp.leases"
	ARP="$TMP/arp"
	NEIGH="$TMP/ipv6-neigh"
	FIRST_LOG="$TMP/first.log"
	SECOND_LOG="$TMP/second.log"
	: >"$LEASES"
	printf '%s\n' 'IP address       HW type     Flags       HW address            Mask     Device' >"$ARP"
	: >"$NEIGH"
	cat >"$FIRST_LOG" <<'LOGS'
daemon.info dnsmasq[1]: 20 2001:db8::100/50000 query[AAAA] one.example from 2001:db8::100
LOGS

	ss_statistics_awk \
		-v state_file="$STATE" \
		-v json_file="$JSON" \
		-v snapshot_interval=60 \
		-v retention_hours=168 \
		-v lease_file="$LEASES" \
		-v arp_file="$ARP" \
		-v ipv6_neigh_file="$NEIGH" \
		-v generation_seed='generation-ipv6-neigh' \
		-v fixed_now=1787950800 \
		<"$FIRST_LOG"

	ss_spec_assert_file_contains "$JSON" '"id":"ip:2001:db8::100","mac":"","ip":"2001:db8::100","hostname":"","identified":false,"queries":1,"blocked":0'

	cat >"$NEIGH" <<'NEIGHBORS'
2001:db8::100 dev br-lan lladdr aa:bb:cc:dd:ee:ff STALE
2001:db8::200 dev br-lan lladdr aa:bb:cc:dd:ee:ff REACHABLE
2001:db8::300 dev br-lan FAILED
NEIGHBORS
	cat >"$SECOND_LOG" <<'LOGS'
daemon.info dnsmasq[1]: 21 2001:db8::200/50001 query[AAAA] two.example from 2001:db8::200
daemon.info dnsmasq[1]: 22 2001:db8::300/50002 query[AAAA] unresolved.example from 2001:db8::300
LOGS

	ss_statistics_awk \
		-v state_file="$STATE" \
		-v json_file="$JSON" \
		-v snapshot_interval=60 \
		-v retention_hours=168 \
		-v lease_file="$LEASES" \
		-v arp_file="$ARP" \
		-v ipv6_neigh_command="cat $NEIGH" \
		-v generation_seed='unused-new-generation' \
		-v fixed_now=1787950861 \
		<"$SECOND_LOG"

	ss_spec_assert_file_contains "$JSON" '"totals":{"queries":3,"blocked":0}'
	ss_spec_assert_file_contains "$JSON" '"id":"aa:bb:cc:dd:ee:ff","mac":"aa:bb:cc:dd:ee:ff","ip":"2001:db8::200","hostname":"","identified":true,"queries":2,"blocked":0'
	ss_spec_assert_file_contains "$JSON" '"id":"ip:2001:db8::300","mac":"","ip":"2001:db8::300","hostname":"","identified":false,"queries":1,"blocked":0'
	! grep -F '"id":"ip:2001:db8::100"' "$JSON" >/dev/null
	! grep -F '"id":"ip:2001:db8::200"' "$JSON" >/dev/null
	! grep -F "$(printf 'device_bucket\tip:2001:db8::100\t')" "$STATE" >/dev/null
)

ss_case_statistics_modules() (
	set -eu
	STATISTICS_DIR="$SS_SPEC_ROOT/files/usr/lib/safeshield/statistics"
	STATSD="$SS_SPEC_ROOT/files/usr/libexec/safeshield-statsd"
	for module in \
		00-common.awk \
		10-recovery.awk \
		20-identity.awk \
		30-aggregate.awk \
		40-persistence.awk \
		50-output.awk \
		90-main.awk; do
		[ -s "$STATISTICS_DIR/$module" ]
		ss_spec_assert_file_contains "$STATSD" "-f \"\$SS_STATSD_AWK_DIR/$module\""
	done
	[ ! -e "$SS_SPEC_ROOT/files/usr/lib/safeshield/statistics.awk" ]
	ss_spec_assert_file_contains "$SS_SPEC_ROOT/Makefile" '$(INSTALL_DATA) ./files/usr/lib/safeshield/statistics/*.awk $(1)/usr/lib/safeshield/statistics/'
)
