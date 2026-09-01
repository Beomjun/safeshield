'use strict';

let core = require('core');
let runtime = require('runtime');

let PKG_NAME = core.PKG_NAME;
let STATISTICS_SCHEMA_NAME = core.STATISTICS_SCHEMA_NAME;
let STATISTICS_SCHEMA_VERSION = core.STATISTICS_SCHEMA_VERSION;
let STATISTICS_FILE = core.STATISTICS_FILE;
let reload_uci = core.reload_uci;
let cfg = core.cfg;
let read_json_file = core.read_json_file;
let to_bool = core.to_bool;
let to_int = core.to_int;
let service_instance_running = runtime.service_instance_running;
function sanitize_hourly(items) {
    let result = [];

    if (type(items) != 'array') {
        return result;
    }

    for (let item in items) {
        if (type(item) != 'object') {
            continue;
        }

        push(result, {
            bucket_start: to_int(item.bucket_start, 0),
            queries: to_int(item.queries, 0),
            blocked: to_int(item.blocked, 0),
            hourly: sanitize_hourly(item.hourly)
        });
    }

    return result;
}

function sanitize_devices(items) {
    let result = [];
    if (type(items) != 'array') {
        return result;
    }

    for (let item in items) {
        if (type(item) != 'object') {
            continue;
        }

        let id = sprintf('%s', item.id || '');
        if (!id) {
            continue;
        }
        push(result, {
            id: id,
            mac: sprintf('%s', item.mac || ''),
            ip: sprintf('%s', item.ip || ''),
            hostname: sprintf('%s', item.hostname || ''),
            identified: to_bool(item.identified, false),
            queries: to_int(item.queries, 0),
            blocked: to_int(item.blocked, 0)
        });
    }

    return result;
}

function build_statistics() {
    reload_uci();
    let enabled = to_bool(cfg('statistics_enabled', '1'), true);
    let retention_hours = to_int(cfg('statistics_retention_hours', '168'), 168);
    let snapshot_interval_s = to_int(cfg('statistics_snapshot_interval_s', '60'), 60);
    let data = read_json_file(STATISTICS_FILE, {});
    let totals = (type(data.totals) == 'object') ? data.totals : {};
    return {
        schema: {
            name: STATISTICS_SCHEMA_NAME,
            version: STATISTICS_SCHEMA_VERSION
        },
        enabled: enabled,
        available: !!data.schema,
        collector_running: service_instance_running(PKG_NAME, 'statistics'),
        volatile: to_bool(data.volatile, true),
        storage: sprintf('%s', data.storage || 'tmpfs'),
        persistent: to_bool(data.persistent, false),
        persistent_updated_at: to_int(data.persistent_updated_at, 0),
        persistent_checkpoint_interval_s: to_int(data.persistent_checkpoint_interval_s, 3600),
        snapshot_interval_s: snapshot_interval_s,
        retention_hours: retention_hours,
        started_at: to_int(data.started_at, 0),
        session_started_at: to_int(data.session_started_at, 0),
        updated_at: to_int(data.updated_at, 0),
        totals: {
            queries: to_int(totals.queries, 0),
            blocked: to_int(totals.blocked, 0)
        },
        hourly: sanitize_hourly(data.hourly),
        device_limit: to_int(data.device_limit, 128),
        devices_truncated: to_bool(data.devices_truncated, false),
        devices: sanitize_devices(data.devices)
    };
}
return {
    build: build_statistics
};
