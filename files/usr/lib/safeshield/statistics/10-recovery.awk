# SafeShield statistics: state and journal recovery.
# Loaded together with the other statistics/*.awk modules by safeshield-statsd.

function state_file_updated_at(path,    line, fields, count, meta_seen, meta_updated, expected_queries, expected_blocked, bucket_queries, bucket_blocked) {
	if (path == "") {
		return -1
	}

	meta_seen = 0
	meta_updated = 0
	expected_queries = 0
	expected_blocked = 0
	bucket_queries = 0
	bucket_blocked = 0

	while ((getline line < path) > 0) {
		count = split(line, fields, "\t")
		if (count >= 5 && fields[1] == "meta") {
			meta_seen = 1
			meta_updated = numeric(fields[3], 0)
			expected_queries = numeric(fields[4], 0)
			expected_blocked = numeric(fields[5], 0)
		}
		else if (count >= 4 && fields[1] == "bucket") {
			bucket_queries += numeric(fields[3], 0)
			bucket_blocked += numeric(fields[4], 0)
		}
	}
	close(path)

	if (!meta_seen) {
		return -1
	}
	if (bucket_queries != expected_queries || bucket_blocked != expected_blocked) {
		return -1
	}

	return meta_updated
}

function load_state_file(path,    line, fields, count, bucket, key, mac, ip, hostname, composite) {
	if (path == "") {
		return 0
	}

	while ((getline line < path) > 0) {
		count = split(line, fields, "\t")
		if (count >= 5 && fields[1] == "meta") {
			started_at = numeric(fields[2], 0)
			updated_at = numeric(fields[3], 0)
			total_queries = numeric(fields[4], 0)
			total_blocked = numeric(fields[5], 0)
			if (count >= 6) {
				devices_truncated = numeric(fields[6], 0) ? 1 : 0
			}
			if (count >= 7) {
				persistent_updated_at = numeric(fields[7], 0)
			}
			if (count >= 8) {
				state_schema_version = numeric(fields[8], 1)
			}
			if (count >= 9) {
				loaded_session_started_at = numeric(fields[9], 0)
			}
			if (count >= 10) {
				persistence_healthy = numeric(fields[10], 1) ? 1 : 0
			}
			if (count >= 11) {
				persistent_error_count = numeric(fields[11], 0)
			}
			if (count >= 12) {
				persistent_last_error_at = numeric(fields[12], 0)
			}
			if (count >= 13) {
				persistent_compacted_at = numeric(fields[13], 0)
			}
			if (count >= 14) {
				last_journal_completed_bucket = numeric(fields[14], 0)
			}
			if (count >= 15) {
				generation_id = decode_state_field(fields[15])
			}
			loaded_state = 1
		}
		else if (count >= 8 && fields[1] == "source") {
			source_instance_id = decode_state_field(fields[2])
			source_transport_scope = decode_state_field(fields[3])
			source_client_capacity = numeric(fields[4], 0)
			source_tracked_clients = numeric(fields[5], 0)
			source_untracked_queries = numeric(fields[6], 0)
			source_total_queries = numeric(fields[7], 0)
			source_total_blocked = numeric(fields[8], 0)
			source_available = (count >= 9 && numeric(fields[9], 0)) ? 1 : 0
			source_error_count = (count >= 10) ? numeric(fields[10], 0) : 0
			source_last_error_at = (count >= 11) ? numeric(fields[11], 0) : 0
			source_untracked_blocked = (count >= 12) ? numeric(fields[12], 0) : 0
			source_initialized = (source_instance_id != "") ? 1 : 0
		}
		else if (count >= 4 && fields[1] == "source_client") {
			key = decode_state_field(fields[2])
			if (key != "") {
				source_client_queries[key] = numeric(fields[3], 0)
				source_client_blocked[key] = numeric(fields[4], 0)
			}
		}
		else if (count >= 4 && fields[1] == "bucket") {
			bucket = numeric(fields[2], 0)
			if (bucket > 0) {
				queries[bucket] = numeric(fields[3], 0)
				blocked[bucket] = numeric(fields[4], 0)
			}
		}
		else if (count >= 7 && fields[1] == "device") {
			key = decode_state_field(fields[2])
			mac = decode_state_field(fields[3])
			ip = decode_state_field(fields[4])
			hostname = decode_state_field(fields[5])
			key = register_device(key, mac, ip, hostname)
			if (key != "") {
				legacy_device_queries[key] += numeric(fields[6], 0)
				legacy_device_blocked[key] += numeric(fields[7], 0)
			}
		}
		else if (count >= 5 && fields[1] == "device_bucket") {
			key = decode_state_field(fields[2])
			bucket = numeric(fields[3], 0)
			if (key != "" && bucket > 0) {
				key = register_device(key, "", "", "")
				if (key != "") {
					composite = device_bucket_key(key, bucket)
					device_hour_queries[composite] += numeric(fields[4], 0)
					device_hour_blocked[composite] += numeric(fields[5], 0)
					device_has_hourly[key] = 1
				}
			}
		}
	}
	close(path)
	return loaded_state
}

function journal_file_updated_at(path,    line, fields, count, line_no, current_txn, current_updated, last_commit_line, latest_updated) {
	if (path == "") {
		return -1
	}

	line_no = 0
	current_txn = ""
	current_updated = 0
	last_commit_line = 0
	latest_updated = -1
	while ((getline line < path) > 0) {
		line_no++
		count = split(line, fields, "\t")
		if (count >= 11 && fields[1] == "begin") {
			current_txn = fields[2]
			current_updated = numeric(fields[4], 0)
		}
		else if (count >= 2 && fields[1] == "commit" && current_txn != "" && fields[2] == current_txn) {
			last_commit_line = line_no
			latest_updated = current_updated
			current_txn = ""
			current_updated = 0
		}
	}
	close(path)

	return (last_commit_line > 0) ? latest_updated : -1
}

function load_journal_file(path, min_updated_at,    line, fields, count, line_no, current_txn, current_start, active_end, txn_updated, txn_started, txn_truncated, txn_session_started, txn_completed, txn_healthy, txn_error_count, txn_last_error, txn_generation_id, key, mac, ip, hostname, bucket, composite, committed_end) {
	if (path == "") {
		return 0
	}

	# First pass records only complete transaction ranges. A power loss can leave
	# a partial append at the tail (or before a later retry); those records must
	# never be replayed unless their matching commit marker is present.
	line_no = 0
	current_txn = ""
	current_start = 0
	while ((getline line < path) > 0) {
		line_no++
		count = split(line, fields, "\t")
		if (count >= 11 && fields[1] == "begin") {
			current_txn = fields[2]
			current_start = line_no
		}
		else if (count >= 2 && fields[1] == "commit" && current_txn != "" && fields[2] == current_txn) {
			committed_end[current_start] = line_no
			current_txn = ""
			current_start = 0
		}
	}
	close(path)

	line_no = 0
	current_txn = ""
	active_end = 0
	while ((getline line < path) > 0) {
		line_no++
		count = split(line, fields, "\t")
		if (count >= 11 && fields[1] == "begin") {
			current_txn = fields[2]
			active_end = committed_end[line_no] + 0
			if (active_end <= 0) {
				current_txn = ""
				continue
			}
			txn_updated = numeric(fields[4], 0)
			if (min_updated_at >= 0 && txn_updated <= min_updated_at) {
				current_txn = ""
				active_end = 0
				continue
			}
			txn_started = numeric(fields[5], 0)
			txn_truncated = numeric(fields[6], 0) ? 1 : 0
			txn_session_started = numeric(fields[7], 0)
			txn_completed = numeric(fields[8], 0)
			txn_healthy = numeric(fields[9], 1) ? 1 : 0
			txn_error_count = numeric(fields[10], 0)
			txn_last_error = numeric(fields[11], 0)
			txn_generation_id = (count >= 12) ? decode_state_field(fields[12]) : ""
			continue
		}
		if (current_txn == "" || line_no > active_end) {
			continue
		}
		if (count >= 4 && fields[1] == "bucket") {
			bucket = numeric(fields[2], 0)
			if (bucket > 0) {
				queries[bucket] = numeric(fields[3], 0)
				blocked[bucket] = numeric(fields[4], 0)
			}
			continue
		}
		if (count >= 5 && fields[1] == "device") {
			key = decode_state_field(fields[2])
			mac = decode_state_field(fields[3])
			ip = decode_state_field(fields[4])
			hostname = decode_state_field(fields[5])
			register_device(key, mac, ip, hostname)
			continue
		}
		if (count >= 5 && fields[1] == "device_bucket") {
			key = decode_state_field(fields[2])
			bucket = numeric(fields[3], 0)
			if (key != "" && bucket > 0) {
				key = register_device(key, "", "", "")
				if (key != "") {
					composite = device_bucket_key(key, bucket)
					device_hour_queries[composite] = numeric(fields[4], 0)
					device_hour_blocked[composite] = numeric(fields[5], 0)
					device_has_hourly[key] = 1
				}
			}
			continue
		}
		if (count >= 2 && fields[1] == "delete_device") {
			key = decode_state_field(fields[2])
			if (key != "") {
				journal_replaying = 1
				remove_device(key)
				journal_replaying = 0
			}
			continue
		}
		if (count >= 2 && fields[1] == "commit" && fields[2] == current_txn && line_no == active_end) {
			if (txn_started > 0) {
				started_at = txn_started
			}
			if (txn_generation_id != "") {
				generation_id = txn_generation_id
			}
			devices_truncated = txn_truncated
			if (txn_session_started > 0) {
				loaded_session_started_at = txn_session_started
			}
			if (txn_completed > last_journal_completed_bucket) {
				last_journal_completed_bucket = txn_completed
			}
			persistent_updated_at = txn_updated
			persistence_healthy = txn_healthy
			persistent_error_count = txn_error_count
			persistent_last_error_at = txn_last_error
			updated_at = txn_updated
			loaded_state = 1
			state_schema_version = 4
			current_txn = ""
			active_end = 0
		}
	}
	close(path)
	journal_replaying = 0
	return loaded_state
}

function migrate_legacy_device_totals(now,    key, bucket, composite) {
	if (state_schema_version >= 2) {
		return
	}

	bucket = hour_start((updated_at > 0) ? updated_at : now)
	for (key in device_seen) {
		if (device_has_hourly[key]) {
			continue
		}
		if ((legacy_device_queries[key] + 0) == 0 && (legacy_device_blocked[key] + 0) == 0) {
			continue
		}

		composite = device_bucket_key(key, bucket)
		device_hour_queries[composite] += legacy_device_queries[key] + 0
		device_hour_blocked[composite] += legacy_device_blocked[key] + 0
		device_has_hourly[key] = 1
	}
}
