# SafeShield statistics: IPv4/IPv6 client identity resolution.
# Loaded together with the other statistics/*.awk modules by safeshield-statsd.

function add_ipv6_neighbor(line,    fields, count, i, ip, mac) {
	count = split(line, fields, /[[:space:]]+/)
	if (count < 5) {
		return
	}

	ip = fields[1]
	mac = ""
	for (i = 2; i < count; i++) {
		if (fields[i] == "lladdr") {
			mac = normalize_mac(fields[i + 1])
			break
		}
	}

	if (ip == "" || mac == "") {
		return
	}

	# Keep DHCP data authoritative when it already knows this exact address,
	# because DHCP can also provide the hostname exposed by the local API.
	if (!(ip in lease_mac)) {
		lease_mac[ip] = mac
		lease_hostname[ip] = ""
	}
}

function refresh_ipv6_neighbors(    line) {
	if (ipv6_neigh_file != "") {
		while ((getline line < ipv6_neigh_file) > 0) {
			add_ipv6_neighbor(line)
		}
		close(ipv6_neigh_file)
		return
	}

	if (ipv6_neigh_command == "") {
		return
	}

	# `ip -6 neigh show` resolves IPv6 privacy/temporary addresses back to a
	# link-layer address without storing the queried IPv6 address as identity.
	# Missing/FAILED neighbor entries simply keep the existing ip:<address>
	# fallback until the kernel neighbor table learns a MAC address.
	while ((ipv6_neigh_command | getline line) > 0) {
		add_ipv6_neighbor(line)
	}
	close(ipv6_neigh_command)
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

	# IPv6 does not have an ARP table. Merge the kernel NDP neighbor cache so
	# multiple privacy addresses from the same LAN client converge on one MAC
	# identity just like DHCP/ARP-backed IPv4 clients.
	refresh_ipv6_neighbors()

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
