# SafeShield dnsmasq statistics collector.
# Input is the live logread stream. Only aggregate counters and local device
# counters are retained. Raw queried domains are never persisted.

function numeric(value, fallback) {
	if (value ~ /^[0-9]+$/) {
		return value + 0
	}
	return fallback
}

function current_time() {
	if (fixed_now > 0) {
		return fixed_now + (event_index * fixed_step)
	}
	return systime()
}

function hour_start(epoch) {
	return int(epoch / 3600) * 3600
}

function device_bucket_key(key, bucket) {
	return key SUBSEP bucket
}

function prune_buckets(now,    cutoff, bucket, composite, parts) {
	cutoff = hour_start(now) - ((retention_hours - 1) * 3600)
	for (bucket in queries) {
		if ((bucket + 0) < cutoff) {
			delete queries[bucket]
			delete blocked[bucket]
		}
	}

	for (composite in device_hour_queries) {
		split(composite, parts, SUBSEP)
		bucket = parts[2] + 0
		if (bucket < cutoff) {
			delete device_hour_queries[composite]
			delete device_hour_blocked[composite]
		}
	}
}

function normalize_state_field(value,    normalized) {
	normalized = value
	gsub(/[\t\r\n]/, "_", normalized)
	return (normalized == "") ? "*" : normalized
}

function decode_state_field(value) {
	return (value == "*") ? "" : value
}

function normalize_mac(value,    parts, count, i, mac) {
	mac = tolower(value)
	count = split(mac, parts, ":")
	if (count != 6 || mac == "00:00:00:00:00:00") {
		return ""
	}
	for (i = 1; i <= count; i++) {
		if (parts[i] !~ /^[0-9a-f][0-9a-f]$/) {
			return ""
		}
	}
	return mac
}

function remove_device_metadata(key) {
	if (!(key in device_seen)) {
		return
	}

	delete device_seen[key]
	delete device_mac[key]
	delete device_ip[key]
	delete device_hostname[key]
	delete device_queries[key]
	delete device_blocked[key]
	device_count--
}

function remove_device(key,    composite, parts) {
	if (!(key in device_seen)) {
		return
	}

	for (composite in device_hour_queries) {
		split(composite, parts, SUBSEP)
		if (parts[1] == key) {
			delete device_hour_queries[composite]
			delete device_hour_blocked[composite]
		}
	}

	remove_device_metadata(key)
}

function register_device(key, mac, ip, hostname,    selected) {
	if (key == "") {
		return ""
	}

	selected = key
	if (!(selected in device_seen) && device_count >= max_devices && selected != "other") {
		devices_truncated = 1
		selected = "other"
		mac = ""
		ip = ""
		hostname = "Other devices"
	}

	if (!(selected in device_seen)) {
		# Initialize every per-device array element together. Besides keeping the
		# device record structurally complete, this avoids passing a missing awk
		# associative-array element to helper functions during serialization.
		device_seen[selected] = 1
		device_mac[selected] = ""
		device_ip[selected] = ""
		device_hostname[selected] = ""
		device_queries[selected] = 0
		device_blocked[selected] = 0
		device_count++
	}

	if (selected != "other") {
		if (mac != "") {
			device_mac[selected] = tolower(mac)
		}
		if (ip != "") {
			device_ip[selected] = ip
		}
		if (hostname != "" && hostname != "*") {
			device_hostname[selected] = hostname
		}
	}
	else {
		device_hostname[selected] = "Other devices"
	}

	return selected
}

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

function clear_identity_cache(    ip) {
	for (ip in identity_key_cache) {
		delete identity_key_cache[ip]
		delete identity_cache_expires[ip]
	}
}

function cache_identity_key(ip, key, now) {
	if (ip == "" || key == "") {
		return key
	}
	identity_key_cache[ip] = key
	identity_cache_expires[ip] = now + identity_cache_ttl
	return key
}

function refresh_leases(now, force,    line, fields, count, mac, ip, hostname) {
	if (!force && last_lease_refresh > 0 && (now - last_lease_refresh) < lease_refresh_interval) {
		return
	}

	clear_identity_cache()
	for (ip in lease_mac) {
		delete lease_mac[ip]
		delete lease_hostname[ip]
	}

	while ((getline line < lease_file) > 0) {
		count = split(line, fields, /[[:space:]]+/)
		if (count < 4) {
			continue
		}

		mac = normalize_mac(fields[2])
		ip = fields[3]
		hostname = fields[4]
		if (mac == "" || ip == "") {
			continue
		}

		lease_mac[ip] = mac
		lease_hostname[ip] = (hostname == "*") ? "" : hostname
	}
	close(lease_file)

	# DHCP leases are not guaranteed to contain every active client. Static-IP
	# clients and lease-file update windows can otherwise recreate an ip:*
	# identity after the device has already been identified by MAC. Use the
	# kernel ARP table as the current IPv4 identity fallback. A DHCP lease stays
	# authoritative when both sources contain the same IP because it also carries
	# the hostname used by the public statistics API.
	while ((getline line < arp_file) > 0) {
		count = split(line, fields, /[[:space:]]+/)
		if (count < 4) {
			continue
		}

		ip = fields[1]
		mac = normalize_mac(fields[4])
		if (ip == "" || mac == "") {
			continue
		}

		if (!(ip in lease_mac)) {
			lease_mac[ip] = mac
			lease_hostname[ip] = ""
		}
	}
	close(arp_file)

	last_lease_refresh = now
	reconcile_ip_devices()
}

function move_device_hours(from_key, to_key,    composite, parts, bucket, target, count, i, move_keys) {
	if (from_key == to_key) {
		return
	}

	# Do not mutate the associative array while iterating over it. Some awk
	# implementations may skip entries when keys are added/deleted during the
	# same for-in traversal, leaving orphan ip:* hourly buckets behind.
	count = 0
	for (composite in device_hour_queries) {
		split(composite, parts, SUBSEP)
		if (parts[1] == from_key) {
			move_keys[++count] = composite
		}
	}

	for (i = 1; i <= count; i++) {
		composite = move_keys[i]
		split(composite, parts, SUBSEP)
		bucket = parts[2] + 0
		target = device_bucket_key(to_key, bucket)
		device_hour_queries[target] += device_hour_queries[composite] + 0
		device_hour_blocked[target] += device_hour_blocked[composite] + 0
		delete device_hour_queries[composite]
		delete device_hour_blocked[composite]
		delete move_keys[i]
	}

	delete device_has_hourly[from_key]
	if (count > 0) {
		device_has_hourly[to_key] = 1
	}
}

function migrate_ip_device(ip_key, mac_key, ip, hostname,    selected) {
	if (!(ip_key in device_seen) || ip_key == mac_key) {
		return register_device(mac_key, mac_key, ip, hostname)
	}

	# Replacing an existing temporary IP identity must not consume an extra
	# device slot. Remove only its metadata first, keep the hourly buckets, then
	# move those buckets after the stable MAC identity has been registered. The
	# journal tombstone prevents an older persisted ip:* identity from reappearing
	# after reboot before DHCP/ARP reconciliation runs again.
	if (!journal_replaying) {
		journal_deleted_device[ip_key] = 1
	}
	remove_device_metadata(ip_key)
	selected = register_device(mac_key, mac_key, ip, hostname)
	if (selected == "") {
		return ""
	}

	move_device_hours(ip_key, selected)
	if (!journal_replaying) {
		journal_full_device[selected] = 1
	}
	return selected
}

function reconcile_ip_devices(    ip, ip_key, mac, hostname) {
	for (ip in lease_mac) {
		ip_key = "ip:" ip
		if (!(ip_key in device_seen)) {
			continue
		}

		mac = lease_mac[ip]
		if (mac == "") {
			continue
		}
		hostname = lease_hostname[ip]
		migrate_ip_device(ip_key, mac, ip, hostname)
	}
}

function is_internal_statistics_client(ip) {
	return (ip == "::1" || ip ~ /^127\./)
}

function device_key_for_ip(ip, now,    cached_key, mac, hostname, ip_key, selected) {
	if (ip == "" || is_internal_statistics_client(ip)) {
		return ""
	}

	if ((ip in identity_key_cache) && (identity_cache_expires[ip] + 0) > now) {
		cached_key = identity_key_cache[ip]
		if (cached_key != "") {
			return cached_key
		}
	}
	delete identity_key_cache[ip]
	delete identity_cache_expires[ip]

	refresh_leases(now, 0)
	ip_key = "ip:" ip

	if (ip in lease_mac) {
		mac = lease_mac[ip]
		hostname = lease_hostname[ip]
		selected = migrate_ip_device(ip_key, mac, ip, hostname)
	}
	else {
		selected = register_device(ip_key, "", ip, "")
	}

	return cache_identity_key(ip, selected, now)
}

function record_device(ip, query_delta, blocked_delta, now,    key, bucket, composite) {
	key = device_key_for_ip(ip, now)
	if (key == "") {
		return
	}

	bucket = hour_start(now)
	composite = device_bucket_key(key, bucket)
	device_hour_queries[composite] += 0
	device_hour_blocked[composite] += 0
	if (query_delta > 0) {
		device_hour_queries[composite] += query_delta
	}
	if (blocked_delta > 0) {
		device_hour_blocked[composite] += blocked_delta
	}
	device_has_hourly[key] = 1
}

function recompute_totals(    bucket, composite, parts, key, stale_count, i) {
	total_queries = 0
	total_blocked = 0
	for (bucket in queries) {
		total_queries += queries[bucket] + 0
		total_blocked += blocked[bucket] + 0
	}

	for (key in device_seen) {
		device_queries[key] = 0
		device_blocked[key] = 0
		delete device_first_bucket[key]
		delete device_last_bucket[key]
	}
	for (composite in device_hour_queries) {
		split(composite, parts, SUBSEP)
		key = parts[1]
		bucket = parts[2] + 0
		device_queries[key] += device_hour_queries[composite] + 0
		device_blocked[key] += device_hour_blocked[composite] + 0
		if (!(key in device_first_bucket) || bucket < (device_first_bucket[key] + 0)) {
			device_first_bucket[key] = bucket
		}
		if (!(key in device_last_bucket) || bucket > (device_last_bucket[key] + 0)) {
			device_last_bucket[key] = bucket
		}
	}

	stale_count = 0
	for (key in device_seen) {
		if ((device_queries[key] + 0) == 0 && (device_blocked[key] + 0) == 0) {
			stale_devices[++stale_count] = key
		}
	}
	for (i = 1; i <= stale_count; i++) {
		remove_device(stale_devices[i])
		delete stale_devices[i]
	}
}

function extract_query_client(line,    client) {
	client = line
	if (client !~ / from /) {
		return ""
	}
	sub(/^.* from /, "", client)
	sub(/[[:space:]].*$/, "", client)
	return client
}

function extract_extra_client(line,    payload, fields, count, client) {
	payload = line
	sub(/^.*dnsmasq\[[0-9]+\]:[[:space:]]*/, "", payload)
	count = split(payload, fields, /[[:space:]]+/)
	if (count < 3 || fields[1] !~ /^[0-9]+$/) {
		return ""
	}

	client = fields[2]
	sub(/\/[0-9]+$/, "", client)
	return client
}

function shell_quote(value,    quoted) {
	quoted = value
	gsub(/'/, "'\\''", quoted)
	return "'" quoted "'"
}

function json_escape(value,    escaped) {
	escaped = value
	gsub(/\\/, "\\\\", escaped)
	gsub(/"/, "\\\"", escaped)
	gsub(/\r/, "\\r", escaped)
	gsub(/\n/, "\\n", escaped)
	gsub(/\t/, "\\t", escaped)
	return escaped
}

function replace_file(tmp, final,    rc) {
	rc = system("mv -f " shell_quote(tmp) " " shell_quote(final))
	return rc == 0
}

function save_state_file(path, now,    tmp, bucket, cutoff, key, composite, parts) {
	if (path == "") {
		return 0
	}

	tmp = path ".tmp"
	printf "meta\t%d\t%d\t%d\t%d\t%d\t%d\t4\t%d\t%d\t%d\t%d\t%d\t%d\t%s\n", \
		started_at, updated_at, total_queries, total_blocked, devices_truncated, \
		persistent_updated_at, session_started_at, persistence_healthy, \
		persistent_error_count, persistent_last_error_at, persistent_compacted_at, \
		last_journal_completed_bucket, normalize_state_field(generation_id) > tmp
	cutoff = hour_start(now) - ((retention_hours - 1) * 3600)
	for (bucket = cutoff; bucket <= hour_start(now); bucket += 3600) {
		if ((bucket in queries) || (bucket in blocked)) {
			printf "bucket\t%d\t%d\t%d\n", bucket, queries[bucket] + 0, blocked[bucket] + 0 >> tmp
		}
	}
	for (key in device_seen) {
		printf "device\t%s\t%s\t%s\t%s\t%d\t%d\n", \
			normalize_state_field(key), \
			normalize_state_field(device_mac[key]), \
			normalize_state_field(device_ip[key]), \
			normalize_state_field(device_hostname[key]), \
			device_queries[key] + 0, \
			device_blocked[key] + 0 >> tmp
	}
	for (composite in device_hour_queries) {
		split(composite, parts, SUBSEP)
		if ((parts[2] + 0) < cutoff) {
			continue
		}
		printf "device_bucket\t%s\t%d\t%d\t%d\n", \
			normalize_state_field(parts[1]), \
			parts[2] + 0, \
			device_hour_queries[composite] + 0, \
			device_hour_blocked[composite] + 0 >> tmp
	}
	close(tmp)

	if (!replace_file(tmp, path)) {
		system("rm -f " shell_quote(tmp))
		return 0
	}
	return 1
}

function append_file(source, target,    rc) {
	rc = system("cat " shell_quote(source) " >> " shell_quote(target))
	return rc == 0
}

function clear_journal_file(path,    rc) {
	if (path == "") {
		return 1
	}
	rc = system(": > " shell_quote(path))
	return rc == 0
}

function schedule_next_persistent(now) {
	next_persistent_at = hour_start(now) + persistent_interval
	while (next_persistent_at <= now) {
		next_persistent_at += persistent_interval
	}
}

function schedule_next_compaction(now) {
	if (persistent_compact_interval <= 0) {
		next_compact_at = 0
		return
	}
	if (persistent_compacted_at <= 0) {
		persistent_compacted_at = now
	}
	next_compact_at = persistent_compacted_at + persistent_compact_interval
	while (next_compact_at <= now) {
		next_compact_at += persistent_compact_interval
	}
}

function journal_has_pending_deletes(    key) {
	for (key in journal_deleted_device) {
		return 1
	}
	return 0
}

function journal_has_pending_full_devices(    key) {
	for (key in journal_full_device) {
		return 1
	}
	return 0
}

function clear_journal_pending(    key) {
	for (key in journal_deleted_device) {
		delete journal_deleted_device[key]
	}
	for (key in journal_full_device) {
		delete journal_full_device[key]
	}
}

function write_journal_transaction(now, first_bucket, last_bucket, completed_through,    tmp, txn_id, bucket, key, composite, wrote_device, device_first, device_last, cutoff) {
	if (persistent_journal_file == "") {
		return 0
	}
	if (first_bucket > last_bucket && !journal_has_pending_deletes() && !journal_has_pending_full_devices()) {
		return 1
	}

	tmp = state_file ".journal.tmp"
	txn_id = sprintf("%d-%d-%d", now, event_index, ++journal_txn_seq)
	printf "begin\t%s\t2\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%s\n", \
		txn_id, now, started_at, devices_truncated, session_started_at, \
		completed_through, persistence_healthy, persistent_error_count, \
		persistent_last_error_at, normalize_state_field(generation_id) > tmp

	for (key in journal_deleted_device) {
		printf "delete_device\t%s\n", normalize_state_field(key) >> tmp
	}

	for (bucket = first_bucket; bucket <= last_bucket; bucket += 3600) {
		if ((bucket in queries) || (bucket in blocked)) {
			printf "bucket\t%d\t%d\t%d\n", bucket, queries[bucket] + 0, blocked[bucket] + 0 >> tmp
		}
	}

	# Journal writes normally cover one completed hour. Iterate at most
	# max_devices for that hour instead of scanning every retained device-hour
	# entry (up to max_devices * retention_hours) on low-end routers. Identity
	# migration is the exception: its target MAC receives the full retained
	# history in the same transaction as the old ip:* tombstone.
	cutoff = hour_start(now) - ((retention_hours - 1) * 3600)
	for (key in device_seen) {
		wrote_device = 0
		device_first = first_bucket
		device_last = last_bucket
		if (key in journal_full_device) {
			device_first = cutoff
			device_last = hour_start(now)
		}
		for (bucket = device_first; bucket <= device_last; bucket += 3600) {
			composite = device_bucket_key(key, bucket)
			if (!((composite in device_hour_queries) || (composite in device_hour_blocked))) {
				continue
			}
			if (!wrote_device) {
				printf "device\t%s\t%s\t%s\t%s\n", \
					normalize_state_field(key), \
					normalize_state_field(device_mac[key]), \
					normalize_state_field(device_ip[key]), \
					normalize_state_field(device_hostname[key]) >> tmp
				wrote_device = 1
			}
			printf "device_bucket\t%s\t%d\t%d\t%d\n", \
				normalize_state_field(key), bucket, \
				device_hour_queries[composite] + 0, \
				device_hour_blocked[composite] + 0 >> tmp
		}
	}
	printf "commit\t%s\n", txn_id >> tmp
	close(tmp)

	if (!append_file(tmp, persistent_journal_file)) {
		system("rm -f " shell_quote(tmp))
		return 0
	}
	system("rm -f " shell_quote(tmp))
	clear_journal_pending()
	return 1
}

function flush_completed_journal(now,    current_bucket, target_bucket, cutoff, first_bucket) {
	current_bucket = hour_start(now)
	target_bucket = current_bucket - 3600
	cutoff = current_bucket - ((retention_hours - 1) * 3600)
	first_bucket = last_journal_completed_bucket + 3600
	if (last_journal_completed_bucket <= 0 || first_bucket < cutoff) {
		first_bucket = cutoff
	}

	if (target_bucket < first_bucket && !journal_has_pending_deletes() && !journal_has_pending_full_devices()) {
		return 1
	}
	if (!write_journal_transaction(now, first_bucket, target_bucket, target_bucket)) {
		return 0
	}
	if (target_bucket >= first_bucket) {
		last_journal_completed_bucket = target_bucket
	}
	return 1
}

function flush_current_journal(now,    current_bucket) {
	current_bucket = hour_start(now)
	return write_journal_transaction(now, current_bucket, current_bucket, last_journal_completed_bucket)
}

function maybe_compact_persistent(now,    previous_compacted) {
	if (persistent_state_file == "" || persistent_journal_file == "" || persistent_compact_interval <= 0) {
		return 1
	}
	if (next_compact_at <= 0 || now < next_compact_at) {
		return 1
	}

	previous_compacted = persistent_compacted_at
	persistent_compacted_at = now
	if (!save_state_file(persistent_state_file, now)) {
		persistent_compacted_at = previous_compacted
		persistent_error_count++
		persistent_last_error_at = now
		next_compact_at = now + ((persistent_retry_interval > 3600) ? persistent_retry_interval : 3600)
		return 0
	}

	# The base snapshot is already complete. If journal truncation is interrupted,
	# startup ignores committed transactions whose updated_at is not newer than
	# the base snapshot, preventing retained absolute upserts from rolling it back.
	if (!clear_journal_file(persistent_journal_file)) {
		persistent_error_count++
		persistent_last_error_at = now
	}
	schedule_next_compaction(now)
	return 1
}

function save_persistent_snapshot(now,    previous_updated) {
	previous_updated = persistent_updated_at
	persistent_updated_at = now
	persistence_healthy = 1
	if (!save_state_file(persistent_state_file, now)) {
		persistent_updated_at = previous_updated
		persistence_healthy = 0
		persistent_error_count++
		persistent_last_error_at = now
		next_persistent_at = now + persistent_retry_interval
		return 0
	}
	persistence_healthy = 1
	return 1
}

function maybe_save_persistent(now, force,    previous_updated, ok) {
	if (persistent_state_file == "" && persistent_journal_file == "") {
		return 1
	}
	if (!force && now < next_persistent_at) {
		return 1
	}

	# Compatibility fallback for callers that do not configure a journal.
	if (persistent_journal_file == "") {
		if (!save_persistent_snapshot(now)) {
			return 0
		}
		schedule_next_persistent(now)
		return 1
	}

	previous_updated = persistent_updated_at
	persistence_healthy = 1
	ok = flush_completed_journal(now)
	if (ok && force) {
		ok = flush_current_journal(now)
	}
	if (!ok) {
		persistent_updated_at = previous_updated
		persistence_healthy = 0
		persistent_error_count++
		persistent_last_error_at = now
		next_persistent_at = now + persistent_retry_interval
		return 0
	}

	persistent_updated_at = now
	persistence_healthy = 1
	if (!force) {
		maybe_compact_persistent(now)
	}
	schedule_next_persistent(now)
	return 1
}

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
