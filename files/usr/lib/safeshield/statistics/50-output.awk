# SafeShield statistics: JSON snapshots and persistence scheduling.
# Loaded together with the other statistics/*.awk modules by safeshield-statsd.

function save_json(now,    tmp, current_hour, first_hour, cutoff, bucket, comma, key, identified, device_comma, composite, device_first_hour, device_last_hour, persistence_enabled, persistent, healthy, volatile_state, storage, persistence_mode, truncated) {
	tmp = json_file ".tmp"
	current_hour = hour_start(now)
	cutoff = current_hour - ((retention_hours - 1) * 3600)
	first_hour = hour_start(started_at)
	if (first_hour < cutoff) {
		first_hour = cutoff
	}

	persistence_enabled = (persistent_state_file != "" || persistent_journal_file != "") ? "true" : "false"
	persistent = (persistence_enabled == "true" && persistence_healthy && persistent_updated_at > 0) ? "true" : "false"
	healthy = (persistence_enabled == "true") ? (persistence_healthy ? "true" : "false") : "true"
	volatile_state = (persistence_enabled == "true") ? "false" : "true"
	storage = (persistence_enabled == "true") ? "tmpfs+flash" : "tmpfs"
	persistence_mode = (persistent_journal_file != "") ? "journal" : ((persistent_state_file != "") ? "snapshot" : "none")
	truncated = devices_truncated ? "true" : "false"

	printf "{\"schema\":{\"name\":\"safeshield.statistics\",\"version\":2}," > tmp
	printf "\"volatile\":%s,\"storage\":\"%s\",\"persistent\":%s,", volatile_state, storage, persistent >> tmp
	printf "\"persistence_enabled\":%s,\"persistence_healthy\":%s,", persistence_enabled, healthy >> tmp
	printf "\"persistence_mode\":\"%s\",", persistence_mode >> tmp
	printf "\"persistent_error_count\":%d,\"persistent_last_error_at\":%d,", persistent_error_count, persistent_last_error_at >> tmp
	printf "\"persistent_updated_at\":%d,\"persistent_checkpoint_interval_s\":%d,", persistent_updated_at, persistent_interval >> tmp
	printf "\"persistent_compacted_at\":%d,\"persistent_compact_interval_s\":%d,", persistent_compacted_at, persistent_compact_interval >> tmp
	printf "\"snapshot_interval_s\":%d,", snapshot_interval >> tmp
	printf "\"generation_id\":\"%s\",", json_escape(generation_id) >> tmp
	printf "\"source\":{\"backend\":\"dnsmasq_ubus\",\"available\":%s,", source_available ? "true" : "false" >> tmp
	printf "\"instance_id\":\"%s\",\"transport_scope\":\"%s\",", \
		json_escape(source_instance_id), json_escape(source_transport_scope) >> tmp
	printf "\"client_capacity\":%d,\"tracked_clients\":%d,\"untracked_queries\":%d,", \
		source_client_capacity, source_tracked_clients, source_untracked_queries >> tmp
	printf "\"poll_error_count\":%d,\"last_error_at\":%d},", \
		source_error_count, source_last_error_at >> tmp
	printf "\"started_at\":%d,\"session_started_at\":%d,\"updated_at\":%d,", started_at, session_started_at, now >> tmp
	printf "\"retention_hours\":%d,", retention_hours >> tmp
	printf "\"device_limit\":%d,\"devices_truncated\":%s,", max_devices, truncated >> tmp
	printf "\"totals\":{\"queries\":%d,\"blocked\":%d},", total_queries, total_blocked >> tmp
	printf "\"hourly\":[" >> tmp

	comma = ""
	for (bucket = first_hour; bucket <= current_hour; bucket += 3600) {
		printf "%s{\"bucket_start\":%d,\"queries\":%d,\"blocked\":%d}", comma, bucket, queries[bucket] + 0, blocked[bucket] + 0 >> tmp
		comma = ","
	}
	printf "],\"devices\":[" >> tmp

	comma = ""
	for (key in device_seen) {
		identified = (device_mac[key] != "") ? "true" : "false"
		printf "%s{\"id\":\"%s\",\"mac\":\"%s\",\"ip\":\"%s\",\"hostname\":\"%s\",\"identified\":%s,\"queries\":%d,\"blocked\":%d,\"hourly\":[", \
			comma, \
			json_escape(key), \
			json_escape(device_mac[key]), \
			json_escape(device_ip[key]), \
			json_escape(device_hostname[key]), \
			identified, \
			device_queries[key] + 0, \
			device_blocked[key] + 0 >> tmp

		device_comma = ""
		device_first_hour = device_first_bucket[key] + 0
		device_last_hour = device_last_bucket[key] + 0
		if (device_first_hour <= 0 || device_first_hour < first_hour) {
			device_first_hour = first_hour
		}
		if (device_last_hour <= 0 || device_last_hour > current_hour) {
			device_last_hour = current_hour
		}

		for (bucket = device_first_hour; bucket <= device_last_hour; bucket += 3600) {
			composite = device_bucket_key(key, bucket)
			if (!((composite in device_hour_queries) || (composite in device_hour_blocked))) {
				continue
			}
			printf "%s{\"bucket_start\":%d,\"queries\":%d,\"blocked\":%d}", \
				device_comma, bucket, device_hour_queries[composite] + 0, device_hour_blocked[composite] + 0 >> tmp
			device_comma = ","
		}
		printf "]}" >> tmp
		comma = ","
	}
	printf "]}\n" >> tmp
	close(tmp)

	return replace_file(tmp, json_file)
}

function persistence_metadata_signature() {
	return persistent_updated_at SUBSEP persistence_healthy SUBSEP persistent_error_count SUBSEP \
		persistent_last_error_at SUBSEP persistent_compacted_at SUBSEP last_journal_completed_bucket
}

function save_snapshot(now, force_persistent, force_snapshot,    serialize_snapshot, previous_persistence_metadata) {
	serialize_snapshot = snapshot_dirty || force_snapshot
	if (serialize_snapshot) {
		prune_buckets(now)
		recompute_totals()
	}
	if (serialize_snapshot || force_persistent) {
		updated_at = now
	}

	previous_persistence_metadata = persistence_metadata_signature()
	maybe_save_persistent(now, force_persistent)
	if (persistence_metadata_signature() != previous_persistence_metadata) {
		serialize_snapshot = 1
	}

	if (!serialize_snapshot) {
		last_snapshot = now
		return 1
	}
	if (!save_state_file(state_file, now)) {
		return 0
	}
	if (!save_json(now)) {
		return 0
	}
	snapshot_dirty = 0
	last_snapshot = now
	return 1
}
