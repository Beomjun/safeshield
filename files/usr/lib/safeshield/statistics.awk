# SafeShield dnsmasq statistics collector.
# Input is the live logread stream. Only aggregate counters are retained.

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

function load_state(    line, fields, count, bucket) {
	while ((getline line < state_file) > 0) {
		count = split(line, fields, "\t")
		if (count >= 5 && fields[1] == "meta") {
			started_at = numeric(fields[2], 0)
			updated_at = numeric(fields[3], 0)
			total_queries = numeric(fields[4], 0)
			total_blocked = numeric(fields[5], 0)
		}
		else if (count >= 4 && fields[1] == "bucket") {
			bucket = numeric(fields[2], 0)
			if (bucket > 0) {
				queries[bucket] = numeric(fields[3], 0)
				blocked[bucket] = numeric(fields[4], 0)
			}
		}
	}
	close(state_file)
}

function shell_quote(value,    quoted) {
	quoted = value
	gsub(/'/, "'\\''", quoted)
	return "'" quoted "'"
}

function replace_file(tmp, final,    rc) {
	rc = system("mv -f " shell_quote(tmp) " " shell_quote(final))
	return rc == 0
}

function save_state(now,    tmp, bucket, cutoff) {
	prune_buckets(now)
	updated_at = now
	tmp = state_file ".tmp"

	printf "meta\t%d\t%d\t%d\t%d\n", started_at, updated_at, total_queries, total_blocked > tmp
	cutoff = hour_start(now) - ((retention_hours - 1) * 3600)
	for (bucket = cutoff; bucket <= hour_start(now); bucket += 3600) {
		if ((bucket in queries) || (bucket in blocked)) {
			printf "bucket\t%d\t%d\t%d\n", bucket, queries[bucket] + 0, blocked[bucket] + 0 >> tmp
		}
	}
	close(tmp)

	if (!replace_file(tmp, state_file)) {
		return 0
	}

	return 1
}

function save_json(now,    tmp, current_hour, first_hour, cutoff, bucket, comma) {
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
	printf "\"totals\":{\"queries\":%d,\"blocked\":%d},", total_queries, total_blocked >> tmp
	printf "\"hourly\":[" >> tmp

	comma = ""
	for (bucket = first_hour; bucket <= current_hour; bucket += 3600) {
		printf "%s{\"bucket_start\":%d,\"queries\":%d,\"blocked\":%d}", comma, bucket, queries[bucket] + 0, blocked[bucket] + 0 >> tmp
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

function record_event(query_delta, blocked_delta,    now, bucket) {
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

	event_index++
	if ((now - last_snapshot) >= snapshot_interval) {
		save_snapshot(now)
	}
}

BEGIN {
	state_file = (state_file != "") ? state_file : "/tmp/safeshield/statistics/state.tsv"
	json_file = (json_file != "") ? json_file : "/tmp/safeshield/statistics/statistics.json"
	snapshot_interval = numeric(snapshot_interval, 60)
	retention_hours = numeric(retention_hours, 168)
	fixed_now = numeric(fixed_now, 0)
	fixed_step = numeric(fixed_step, 0)
	event_index = 0

	if (snapshot_interval < 1) {
		snapshot_interval = 60
	}
	if (retention_hours < 1) {
		retention_hours = 168
	}

	load_state()
	if (started_at <= 0) {
		started_at = current_time()
	}
	last_snapshot = updated_at
	if (last_snapshot <= 0) {
		last_snapshot = started_at
	}

	prune_buckets(current_time())
	save_snapshot(current_time())
}

/dnsmasq\[[0-9]+\]:/ {
	if ($0 ~ / query\[[^]]+\] .* from /) {
		record_event(1, 0)
		next
	}

	if ($0 ~ / config .* is (0\.0\.0\.0|::)([[:space:]]|$)/) {
		record_event(0, 1)
		next
	}
}

END {
	save_snapshot(current_time())
}
