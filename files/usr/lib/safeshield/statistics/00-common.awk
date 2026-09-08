# SafeShield statistics: common counter and device helpers.
# Loaded together with the other statistics/*.awk modules by safeshield-statsd.

# SafeShield dnsmasq statistics collector.
# Production input is a low-frequency snapshot stream generated from dnsmasq
# cumulative UBus counters. Legacy log fixtures remain accepted for regression
# coverage. Raw queried domains are never persisted.

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
