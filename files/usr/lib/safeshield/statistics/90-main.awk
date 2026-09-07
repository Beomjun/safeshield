# SafeShield statistics: collector lifecycle and dnsmasq event dispatch.
# Loaded together with the other statistics/*.awk modules by safeshield-statsd.

function record_event(query_delta, blocked_delta, client_ip,    now, bucket) {
	if (is_internal_statistics_client(client_ip)) {
		return
	}

	now = current_time()
	bucket = hour_start(now)
	snapshot_dirty = 1
	queries[bucket] += 0
	blocked[bucket] += 0

	if (query_delta > 0) {
		queries[bucket] += query_delta
	}
	if (blocked_delta > 0) {
		blocked[bucket] += blocked_delta
	}

	record_device(client_ip, query_delta, blocked_delta, now)

	event_index++
	if ((now - last_snapshot) >= snapshot_interval) {
		save_snapshot(now, 0, 0)
	}
}

BEGIN {
	state_file = (state_file != "") ? state_file : "/tmp/safeshield/statistics/state.tsv"
	json_file = (json_file != "") ? json_file : "/tmp/safeshield/statistics/statistics.json"
	persistent_state_file = (persistent_state_file != "") ? persistent_state_file : ""
	persistent_journal_file = (persistent_journal_file != "") ? persistent_journal_file : ""
	lease_file = (lease_file != "") ? lease_file : "/tmp/dhcp.leases"
	arp_file = (arp_file != "") ? arp_file : "/proc/net/arp"
	ipv6_neigh_file = (ipv6_neigh_file != "") ? ipv6_neigh_file : ""
	ipv6_neigh_command = (ipv6_neigh_command != "") ? ipv6_neigh_command : ""
	snapshot_interval = numeric(snapshot_interval, 60)
	retention_hours = numeric(retention_hours, 168)
	lease_refresh_interval = numeric(lease_refresh_interval, 60)
	identity_cache_ttl = numeric(identity_cache_ttl, 60)
	persistent_interval = numeric(persistent_interval, 3600)
	persistent_retry_interval = numeric(persistent_retry_interval, 300)
	persistent_compact_interval = numeric(persistent_compact_interval, 604800)
	max_devices = numeric(max_devices, 128)
	fixed_now = numeric(fixed_now, 0)
	fixed_step = numeric(fixed_step, 0)
	generation_seed = normalize_state_field(generation_seed)
	if (generation_seed == "*") {
		generation_seed = ""
	}
	event_index = 0
	snapshot_dirty = 0
	device_count = 0
	devices_truncated = 0
	last_lease_refresh = 0
	loaded_state = 0
	state_schema_version = 1
	persistent_updated_at = 0
	persistent_compacted_at = 0
	last_journal_completed_bucket = 0
	journal_txn_seq = 0
	journal_replaying = 0
	persistence_healthy = (persistent_state_file != "" || persistent_journal_file != "") ? 1 : 0
	persistent_error_count = 0
	persistent_last_error_at = 0

	if (snapshot_interval < 1) {
		snapshot_interval = 60
	}
	if (retention_hours < 1) {
		retention_hours = 168
	}
	if (lease_refresh_interval < 1) {
		lease_refresh_interval = 60
	}
	if (identity_cache_ttl < 1) {
		identity_cache_ttl = 60
	}
	if (identity_cache_ttl > lease_refresh_interval) {
		identity_cache_ttl = lease_refresh_interval
	}
	if (persistent_interval < 60) {
		persistent_interval = 3600
	}
	if (persistent_retry_interval < 60) {
		persistent_retry_interval = 300
	}
	if (persistent_compact_interval < 3600) {
		persistent_compact_interval = 604800
	}
	if (max_devices < 1) {
		max_devices = 128
	}

	tmp_state_updated_at = state_file_updated_at(state_file)
	persistent_state_updated_at = state_file_updated_at(persistent_state_file)
	persistent_journal_updated_at = journal_file_updated_at(persistent_journal_file)
	persistent_combined_updated_at = persistent_state_updated_at
	if (persistent_journal_updated_at > persistent_combined_updated_at) {
		persistent_combined_updated_at = persistent_journal_updated_at
	}

	if (persistent_combined_updated_at > tmp_state_updated_at) {
		if (persistent_state_updated_at >= 0) {
			load_state_file(persistent_state_file)
		}
		if (persistent_journal_updated_at >= 0) {
			load_journal_file(persistent_journal_file, persistent_state_updated_at)
		}
	}
	else if (tmp_state_updated_at >= 0) {
		load_state_file(state_file)
	}
	else if (persistent_combined_updated_at >= 0) {
		if (persistent_state_updated_at >= 0) {
			load_state_file(persistent_state_file)
		}
		if (persistent_journal_updated_at >= 0) {
			load_journal_file(persistent_journal_file, persistent_state_updated_at)
		}
	}

	if (persistent_state_file == "" && persistent_journal_file == "") {
		persistent_updated_at = 0
		persistent_compacted_at = 0
		last_journal_completed_bucket = 0
		persistence_healthy = 1
		persistent_error_count = 0
		persistent_last_error_at = 0
	}
	# started_at identifies the lifetime of the currently retained statistics
	# dataset. It survives collector restarts whenever state can be restored.
	if (started_at <= 0) {
		started_at = current_time()
	}
	# generation_id is the stable identity for that dataset. The stats daemon
	# supplies a fresh candidate on every process start, but restored state wins.
	if (generation_id == "") {
		generation_id = (generation_seed != "") ? generation_seed : sprintf("legacy-%d", started_at)
	}
	# session_started_at is process-scoped and intentionally changes every time
	# the collector starts, even when generation_id and started_at are restored.
	session_started_at = current_time()
	migrate_legacy_device_totals(current_time())
	refresh_leases(current_time(), 1)
	last_snapshot = updated_at
	if (last_snapshot <= 0) {
		last_snapshot = session_started_at
	}
	if (persistent_state_file != "" || persistent_journal_file != "") {
		if (last_journal_completed_bucket <= 0 && persistent_updated_at > 0) {
			last_journal_completed_bucket = hour_start(persistent_updated_at) - 3600
		}
		if (persistent_compacted_at <= 0) {
			persistent_compacted_at = (persistent_updated_at > 0) ? persistent_updated_at : current_time()
		}
		schedule_next_persistent(current_time())
		schedule_next_compaction(current_time())
	}
	else {
		next_persistent_at = 0
		next_compact_at = 0
	}
	save_snapshot(current_time(), 0, 1)
}

/dnsmasq\[[0-9]+\]:/ {
	if ($0 ~ / query\[[^]]+\] .* from /) {
		record_event(1, 0, extract_query_client($0))
		next
	}

	if ($0 ~ / config .* is (0\.0\.0\.0|::)([[:space:]]|$)/) {
		record_event(0, 1, extract_extra_client($0))
		next
	}
}

END {
	save_snapshot(current_time(), 1, 0)
}
