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

function prune_buckets(now,    cutoff, bucket) {
	cutoff = hour_start(now) - ((retention_hours - 1) * 3600)
	for (bucket in queries) {
		if ((bucket + 0) < cutoff) {
			delete queries[bucket]
			delete blocked[bucket]
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

function remove_device(key) {
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
		device_seen[selected] = 1
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

function load_state(    line, fields, count, bucket, key, mac, ip, hostname) {
	while ((getline line < state_file) > 0) {
		count = split(line, fields, "\t")
		if (count >= 5 && fields[1] == "meta") {
			started_at = numeric(fields[2], 0)
			updated_at = numeric(fields[3], 0)
			total_queries = numeric(fields[4], 0)
			total_blocked = numeric(fields[5], 0)
			if (count >= 6) {
				devices_truncated = numeric(fields[6], 0) ? 1 : 0
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
				device_queries[key] += numeric(fields[6], 0)
				device_blocked[key] += numeric(fields[7], 0)
			}
		}
	}
	close(state_file)
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

function migrate_ip_device(ip_key, mac_key, ip, hostname,    old_queries, old_blocked, selected) {
	if (!(ip_key in device_seen) || ip_key == mac_key) {
		return register_device(mac_key, mac_key, ip, hostname)
	}

	old_queries = device_queries[ip_key] + 0
	old_blocked = device_blocked[ip_key] + 0
	remove_device(ip_key)

	selected = register_device(mac_key, mac_key, ip, hostname)
	if (selected != "") {
		device_queries[selected] += old_queries
		device_blocked[selected] += old_blocked
	}
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

function record_device(ip, query_delta, blocked_delta, now,    key) {
	key = device_key_for_ip(ip, now)
	if (key == "") {
		return
	}

	if (query_delta > 0) {
		device_queries[key] += query_delta
	}
	if (blocked_delta > 0) {
		device_blocked[key] += blocked_delta
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

function save_state(now,    tmp, bucket, cutoff, key) {
	prune_buckets(now)
	updated_at = now
	tmp = state_file ".tmp"

	printf "meta\t%d\t%d\t%d\t%d\t%d\n", started_at, updated_at, total_queries, total_blocked, devices_truncated > tmp
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
	close(tmp)

	if (!replace_file(tmp, state_file)) {
		return 0
	}

	return 1
}

function save_json(now,    tmp, current_hour, first_hour, cutoff, bucket, comma, key, identified) {
	tmp = json_file ".tmp"
	current_hour = hour_start(now)
	cutoff = current_hour - ((retention_hours - 1) * 3600)
	first_hour = hour_start(started_at)
	if (first_hour < cutoff) {
		first_hour = cutoff
	}

	printf "{\"schema\":{\"name\":\"safeshield.statistics\",\"version\":1}," > tmp
	printf "\"volatile\":true,\"started_at\":%d,\"updated_at\":%d,", started_at, now >> tmp
	printf "\"retention_hours\":%d,", retention_hours >> tmp
	printf "\"device_limit\":%d,\"devices_truncated\":%s,", max_devices, devices_truncated ? "true" : "false" >> tmp
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
		printf "%s{\"id\":\"%s\",\"mac\":\"%s\",\"ip\":\"%s\",\"hostname\":\"%s\",\"identified\":%s,\"queries\":%d,\"blocked\":%d}", \
			comma, \
			json_escape(key), \
			json_escape(device_mac[key]), \
			json_escape(device_ip[key]), \
			json_escape(device_hostname[key]), \
			identified, \
			device_queries[key] + 0, \
			device_blocked[key] + 0 >> tmp
		comma = ","
	}
	printf "]}\n" >> tmp
	close(tmp)

	return replace_file(tmp, json_file)
}

function save_snapshot(now) {
	if (!save_state(now)) {
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

	if (query_delta > 0) {
		total_queries += query_delta
		queries[bucket] += query_delta
	}
	if (blocked_delta > 0) {
		total_blocked += blocked_delta
		blocked[bucket] += blocked_delta
	}

	record_device(client_ip, query_delta, blocked_delta, now)

	event_index++
	if ((now - last_snapshot) >= snapshot_interval) {
		save_snapshot(now)
	}
}

BEGIN {
	state_file = (state_file != "") ? state_file : "/tmp/safeshield/statistics/state.tsv"
	json_file = (json_file != "") ? json_file : "/tmp/safeshield/statistics/statistics.json"
	lease_file = (lease_file != "") ? lease_file : "/tmp/dhcp.leases"
	snapshot_interval = numeric(snapshot_interval, 60)
	retention_hours = numeric(retention_hours, 168)
	lease_refresh_interval = numeric(lease_refresh_interval, 60)
	max_devices = numeric(max_devices, 128)
	fixed_now = numeric(fixed_now, 0)
	fixed_step = numeric(fixed_step, 0)
	event_index = 0
	device_count = 0
	devices_truncated = 0
	last_lease_refresh = 0

	if (snapshot_interval < 1) {
		snapshot_interval = 60
	}
	if (retention_hours < 1) {
		retention_hours = 168
	}
	if (lease_refresh_interval < 1) {
		lease_refresh_interval = 60
	}
	if (max_devices < 1) {
		max_devices = 128
	}

	load_state()
	if (started_at <= 0) {
		started_at = current_time()
	}
	last_snapshot = updated_at
	if (last_snapshot <= 0) {
		last_snapshot = started_at
	}

	refresh_leases(current_time(), 1)
	prune_buckets(current_time())
	save_snapshot(current_time())
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
	save_snapshot(current_time())
}
