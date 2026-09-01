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

function refresh_leases(now, force,    line, fields, count, mac, ip, hostname) {
	if (!force && last_lease_refresh > 0 && (now - last_lease_refresh) < lease_refresh_interval) {
		return
	}

	for (ip in lease_mac) {
		delete lease_mac[ip]
		delete lease_hostname[ip]
	}

	while ((getline line < lease_file) > 0) {
		count = split(line, fields, /[[:space:]]+/)
		if (count < 4) {
			continue
		}

		mac = tolower(fields[2])
		ip = fields[3]
		hostname = fields[4]
		if (mac == "" || ip == "") {
			continue
		}

		lease_mac[ip] = mac
		lease_hostname[ip] = (hostname == "*") ? "" : hostname
	}
	close(lease_file)
	last_lease_refresh = now
}

function move_device_hours(from_key, to_key,    composite, parts, bucket, target) {
	if (from_key == to_key) {
		return
	}

	for (composite in device_hour_queries) {
		split(composite, parts, SUBSEP)
		if (parts[1] != from_key) {
			continue
		}

		bucket = parts[2] + 0
		target = device_bucket_key(to_key, bucket)
		device_hour_queries[target] += device_hour_queries[composite] + 0
		device_hour_blocked[target] += device_hour_blocked[composite] + 0
		delete device_hour_queries[composite]
		delete device_hour_blocked[composite]
	}
	device_has_hourly[to_key] = 1
}

function migrate_ip_device(ip_key, mac_key, ip, hostname,    selected) {
	if (!(ip_key in device_seen) || ip_key == mac_key) {
		return register_device(mac_key, mac_key, ip, hostname)
	}

	# Replacing an existing temporary IP identity must not consume an extra
	# device slot. Remove only its metadata first, keep the hourly buckets, then
	# move those buckets after the stable MAC identity has been registered.
	remove_device_metadata(ip_key)
	selected = register_device(mac_key, mac_key, ip, hostname)
	if (selected == "") {
		return ""
	}

	move_device_hours(ip_key, selected)
	return selected
}

function device_key_for_ip(ip, now,    mac, hostname, ip_key) {
	if (ip == "" || ip == "127.0.0.1" || ip == "::1") {
		return ""
	}

	refresh_leases(now, 0)
	ip_key = "ip:" ip

	if (ip in lease_mac) {
		mac = lease_mac[ip]
		hostname = lease_hostname[ip]
		return migrate_ip_device(ip_key, mac, ip, hostname)
	}

	return register_device(ip_key, "", ip, "")
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
	}
	for (composite in device_hour_queries) {
		split(composite, parts, SUBSEP)
		key = parts[1]
		device_queries[key] += device_hour_queries[composite] + 0
		device_blocked[key] += device_hour_blocked[composite] + 0
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
	printf "meta\t%d\t%d\t%d\t%d\t%d\t%d\t2\t%d\t%d\t%d\t%d\n", \
		started_at, updated_at, total_queries, total_blocked, devices_truncated, \
		persistent_updated_at, session_started_at, persistence_healthy, \
		persistent_error_count, persistent_last_error_at > tmp
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

function schedule_next_persistent(now) {
	next_persistent_at = hour_start(now) + persistent_interval
	while (next_persistent_at <= now) {
		next_persistent_at += persistent_interval
	}
}

function maybe_save_persistent(now, force,    previous_updated) {
	if (persistent_state_file == "") {
		return 1
	}
	if (!force && now < next_persistent_at) {
		return 1
	}

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
	schedule_next_persistent(now)
	return 1
}

function save_json(now,    tmp, current_hour, first_hour, cutoff, bucket, comma, key, identified, device_comma, composite, persistence_enabled, persistent, healthy, volatile_state, storage, truncated) {
	tmp = json_file ".tmp"
	current_hour = hour_start(now)
	cutoff = current_hour - ((retention_hours - 1) * 3600)
	first_hour = hour_start(started_at)
	if (first_hour < cutoff) {
		first_hour = cutoff
	}

	persistence_enabled = (persistent_state_file != "") ? "true" : "false"
	persistent = (persistent_state_file != "" && persistence_healthy && persistent_updated_at > 0) ? "true" : "false"
	healthy = (persistent_state_file != "" && persistence_healthy) ? "true" : "false"
	volatile_state = (persistent_state_file != "") ? "false" : "true"
	storage = (persistent_state_file != "") ? "tmpfs+flash" : "tmpfs"
	truncated = devices_truncated ? "true" : "false"

	printf "{\"schema\":{\"name\":\"safeshield.statistics\",\"version\":2}," > tmp
	printf "\"volatile\":%s,\"storage\":\"%s\",\"persistent\":%s,", volatile_state, storage, persistent >> tmp
	printf "\"persistence_enabled\":%s,\"persistence_healthy\":%s,", persistence_enabled, healthy >> tmp
	printf "\"persistent_error_count\":%d,\"persistent_last_error_at\":%d,", persistent_error_count, persistent_last_error_at >> tmp
	printf "\"persistent_updated_at\":%d,\"persistent_checkpoint_interval_s\":%d,", persistent_updated_at, persistent_interval >> tmp
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
		for (bucket = first_hour; bucket <= current_hour; bucket += 3600) {
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

function save_snapshot(now, force_persistent) {
	prune_buckets(now)
	recompute_totals()
	updated_at = now
	maybe_save_persistent(now, force_persistent)

	if (!save_state_file(state_file, now)) {
		return 0
	}
	if (!save_json(now)) {
		return 0
	}
	last_snapshot = now
	return 1
}

function record_event(query_delta, blocked_delta, client_ip,    now, bucket) {
	now = current_time()
	bucket = hour_start(now)
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
		save_snapshot(now, 0)
	}
}

BEGIN {
	state_file = (state_file != "") ? state_file : "/tmp/safeshield/statistics/state.tsv"
	json_file = (json_file != "") ? json_file : "/tmp/safeshield/statistics/statistics.json"
	persistent_state_file = (persistent_state_file != "") ? persistent_state_file : ""
	lease_file = (lease_file != "") ? lease_file : "/tmp/dhcp.leases"
	snapshot_interval = numeric(snapshot_interval, 60)
	retention_hours = numeric(retention_hours, 168)
	lease_refresh_interval = numeric(lease_refresh_interval, 60)
	persistent_interval = numeric(persistent_interval, 3600)
	persistent_retry_interval = numeric(persistent_retry_interval, 300)
	max_devices = numeric(max_devices, 128)
	fixed_now = numeric(fixed_now, 0)
	fixed_step = numeric(fixed_step, 0)
	event_index = 0
	device_count = 0
	devices_truncated = 0
	last_lease_refresh = 0
	loaded_state = 0
	state_schema_version = 1
	persistent_updated_at = 0
	persistence_healthy = (persistent_state_file != "") ? 1 : 0
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
	if (persistent_interval < 60) {
		persistent_interval = 3600
	}
	if (persistent_retry_interval < 60) {
		persistent_retry_interval = 300
	}
	if (max_devices < 1) {
		max_devices = 128
	}

	tmp_state_updated_at = state_file_updated_at(state_file)
	persistent_state_updated_at = state_file_updated_at(persistent_state_file)
	if (persistent_state_updated_at > tmp_state_updated_at) {
		load_state_file(persistent_state_file)
	}
	else if (tmp_state_updated_at >= 0) {
		load_state_file(state_file)
	}
	else if (persistent_state_updated_at >= 0) {
		load_state_file(persistent_state_file)
	}

	if (started_at <= 0) {
		started_at = current_time()
	}
	session_started_at = current_time()
	migrate_legacy_device_totals(current_time())
	refresh_leases(current_time(), 1)
	prune_buckets(current_time())
	recompute_totals()
	last_snapshot = updated_at
	if (last_snapshot <= 0) {
		last_snapshot = session_started_at
	}
	schedule_next_persistent(current_time())
	save_snapshot(current_time(), 0)
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
	save_snapshot(current_time(), 1)
}
