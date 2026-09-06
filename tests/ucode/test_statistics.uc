'use strict';

let statistics = require('statistics');

let result = statistics.build();
assert(result.schema.name == 'safeshield.statistics', 'statistics schema is preserved');
assert(result.enabled == true && result.available == true, 'statistics availability is reported');
assert(result.collector_running == true, 'statistics collector state is reported');
assert(result.snapshot_interval_s == 30 && result.effective_snapshot_interval_s == 30 && result.retention_hours == 24, 'statistics config values are normalized');
assert(result.generation_id == 'generation-test', 'statistics generation is preserved');
assert(result.started_at == 100 && result.updated_at == 200, 'statistics timestamps are normalized');
assert(result.totals.queries == 120 && result.totals.blocked == 12, 'statistics totals are normalized');
assert(length(result.hourly) == 2, 'invalid hourly entries are discarded');
assert(result.hourly[0].queries == 20 && result.hourly[1].blocked == 3, 'hourly values are normalized');
assert(result.device_limit == 128 && result.devices_truncated == true, 'device metadata is normalized');
assert(length(result.devices) == 1, 'invalid devices and empty ids are discarded');
assert(result.devices[0].identified == true, 'device identified flag is normalized');
assert(result.devices[0].queries == 50 && result.devices[0].blocked == 5, 'device counters are normalized');

print('ucode statistics tests: ok\n');
