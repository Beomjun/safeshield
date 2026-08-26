'use strict';

let core = require('core');
let ubus = require('ubus').connect();

let PKG_NAME = core.PKG_NAME;
let STATUS_FILE = core.STATUS_FILE;
let SERVICE_INIT = core.SERVICE_INIT;
let read_json_file = core.read_json_file;
let to_bool = core.to_bool;
let reload_uci = core.reload_uci;
let cfg = core.cfg;

function service_running(name) {
    let r = ubus.call('service', 'list', { name: name });
    if (!r || !r[name] || !r[name].instances) {
        return false;
    }

    for (let inst_name, inst in r[name].instances) {
        if (inst.running) {
            return true;
        }
    }

    return false;
}

function dnsmasq_running() {
    let r = ubus.call('service', 'list', { name: 'dnsmasq' });
    if (!r || !r.dnsmasq || !r.dnsmasq.instances) {
        return false;
    }

    for (let inst_name, inst in r.dnsmasq.instances) {
        if (inst.running) {
            return true;
        }
    }

    return false;
}

function run_service_action(action, timeout_ms) {
    let rc = system([ SERVICE_INIT, action ], timeout_ms || 60000);

    return {
        ok: rc == 0,
        rc: rc
    };
}

function refresh_running() {
    let state = read_json_file(STATUS_FILE, {});
    let data = state.data || {};

    return data.status == 'running';
}

function start_refresh_async() {
    reload_uci();

    if (!to_bool(cfg('enabled', '0'), false)) {
        return {
            accepted: false,
            reason: 'disabled'
        };
    }

    if (!service_running(PKG_NAME)) {
        return {
            accepted: false,
            reason: 'service_stopped'
        };
    }

    if (refresh_running()) {
        return {
            accepted: false,
            reason: 'already_running'
        };
    }

    let rc = system([
        '/bin/sh',
        '-c',
        '/etc/init.d/safeshield refresh_once </dev/null >/dev/null 2>&1 &'
    ], 5000);

    return {
        accepted: rc == 0,
        reason: (rc == 0) ? '' : 'spawn_failed',
        rc: rc
    };
}

function start_local_apply_async() {
    reload_uci();

    if (!to_bool(cfg('enabled', '0'), false)) {
        return {
            accepted: false,
            reason: 'disabled'
        };
    }

    if (!to_bool(cfg('apply_local_overrides', '1'), true)) {
        return {
            accepted: false,
            reason: 'local_overrides_disabled'
        };
    }

    if (!service_running(PKG_NAME)) {
        return {
            accepted: false,
            reason: 'service_stopped'
        };
    }

    // The shell worker shares the refresh lock with full artifact refreshes.
    // It waits for an in-flight refresh and then merges the newest local rule
    // files against the retained api.block.txt cache. Duplicate workers are
    // harmless because the engine fingerprints the normalized local state.
    let rc = system([
        '/bin/sh',
        '-c',
        '/etc/init.d/safeshield apply_local_rules </dev/null >/dev/null 2>&1 &'
    ], 5000);

    return {
        accepted: rc == 0,
        reason: (rc == 0) ? '' : 'spawn_failed',
        rc: rc
    };
}

return {
    service_running: service_running,
    dnsmasq_running: dnsmasq_running,
    run_service_action: run_service_action,
    refresh_running: refresh_running,
    start_refresh_async: start_refresh_async,
    start_local_apply_async: start_local_apply_async
};
