'use strict';

let fs = require('fs');
let ubus = require('ubus').connect();
let uci = require('uci').cursor();

const PKG_NAME = 'safeshield';
const STATUS_FILE = `/dev/shm/${PKG_NAME}.status.json`;
const BLOCKLIST_FILE = '/tmp/dnsmasq.d/safeshield.blocklist';
const SCHEMA_NAME = 'safeshield.status';
const SCHEMA_VERSION = 1;
const DEFAULT_API_BASE_URL = 'https://www.smartsafehub.com';
const DEFAULT_API_RESOLVE_PATH = '/api/v1/licenses/resolve';

function trim(s) {
    return replace(s, /^[\r\n\t ]+|[\r\n\t ]+$/, '');
}

function pkg_version() {
    let s = fs.readfile(`/usr/lib/${PKG_NAME}/version`);
    if (!s) {
        return 'unknown';
    }

    return trim(s);
}

const PKG_VERSION = pkg_version();

function read_json_file(path, def) {
    let s = fs.readfile(path);
    if (!s) {
        return def;
    }

    try {
        return json(s);
    }
    catch (e) {
        return def;
    }
}

function file_exists(path) {
    let st = fs.stat(path);
    return !!st;
}

function file_size_kb(path) {
    let st = fs.stat(path);
    if (!st || type(st.size) != 'int') {
        return 0;
    }

    return int((st.size + 1023) / 1024);
}

function to_bool(v, def) {
    if (v == null) {
        return def;
    }

    switch (sprintf('%s', v)) {
        case '1':
        case 'true':
        case 'yes':
        case 'on':
            return true;
        case '0':
        case 'false':
        case 'no':
        case 'off':
            return false;
    }

    return def;
}

function to_optional_bool(v) {
    if (v == null || v == '') {
        return null;
    }

    switch (sprintf('%s', v)) {
        case '1':
        case 'true':
        case 'yes':
        case 'on':
            return true;
        case '0':
        case 'false':
        case 'no':
        case 'off':
            return false;
    }

    return null;
}

function to_int(v, def) {
    if (v == null || v == '') {
        return def;
    }

    let n = int(v);
    return (type(n) == 'int') ? n : def;
}

function cfg(name, def) {
    let v = uci.get(PKG_NAME, 'config', name);
    return (v == null) ? def : v;
}

function mask_secret(v) {
    let s = sprintf('%s', v || '');
    let n = length(s);

    if (n == 0) {
        return '';
    }

    if (n <= 8) {
        return '********';
    }

    return sprintf('%s...%s', substr(s, 0, 4), substr(s, n - 4));
}

function normalize_api_resolve_url(base, path) {
    base = sprintf('%s', base || DEFAULT_API_BASE_URL);
    path = sprintf('%s', path || DEFAULT_API_RESOLVE_PATH);

    base = replace(base, /\/+$/, '');

    if (substr(path, 0, 1) != '/') {
        path = `/${path}`;
    }

    return `${base}${path}`;
}

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

function build_api_source(data, enabled, api_base_url, api_resolve_url, license_key) {
    let api_resolve_ok = to_optional_bool(data.health_api_resolve);
    let artifact_download_ok = to_optional_bool(data.health_artifact_download);
    let last_result = data.last_result || '';

    if (!enabled) {
        last_result = 'disabled';
    }
    else if (!license_key) {
        last_result = 'license_key_missing';
    }
    else if (api_resolve_ok == true && artifact_download_ok == true) {
        last_result = 'ok';
    }
    else if (api_resolve_ok == false) {
        last_result = 'api_resolve_failed';
    }
    else if (artifact_download_ok == false) {
        last_result = 'artifact_download_failed';
    }
    else if (!last_result || last_result == 'idle') {
        last_result = 'configured';
    }

    return {
        section: 'hub_api',
        name: 'SmartSafeHub API Artifact',
        action: 'block',
        enabled: enabled && !!license_key,
        url: api_resolve_url,
        api_base_url: api_base_url,
        last_result: last_result,
        line_count: to_int(data.artifact_unique_domains || data.valid_line_count || 0, 0),
        size_kb: to_int(data.blocklist_file_size_kb || 0, 0),
        artifact_tier: data.artifact_tier || '',
        artifact_version: data.artifact_version || ''
    };
}

function first_error_code(errors) {
    if (type(errors) != 'array' || length(errors) == 0) {
        return '';
    }

    let e = errors[0];
    if (type(e) == 'object' && e.code != null) {
        return sprintf('%s', e.code);
    }

    return sprintf('%s', e);
}

function build_summary(status, stage, valid_line_count, artifact_tier, artifact_version, errors, warnings) {
    let sev = 'info';
    let label = 'Idle';
    let msg = 'SafeShield is idle';

    if (status == 'ready') {
        label = 'Ready';

        if (artifact_tier || artifact_version) {
            msg = sprintf('Hub artifact %s/%s is active, %d rules active', artifact_tier || 'unknown', artifact_version || 'unknown', valid_line_count);
        }
        else {
            msg = sprintf('Hub artifact is active, %d rules active', valid_line_count);
        }
    }
    else if (status == 'running') {
        sev = 'notice';
        label = 'Running';
        msg = stage ? sprintf('Refresh in progress (%s)', stage) : 'Refresh in progress';
    }
    else if (status == 'error') {
        sev = 'error';
        label = 'Error';
        msg = first_error_code(errors) || 'Refresh failed';
    }
    else if (status == 'paused') {
        sev = 'warning';
        label = 'Paused';
        msg = 'SafeShield is paused';
    }
    else if (status == 'disabled') {
        sev = 'warning';
        label = 'Disabled';
        msg = 'SafeShield is disabled';
    }

    if (type(warnings) == 'array' && length(warnings) > 0 && sev == 'info') {
        sev = 'warning';
    }

    return {
        label: label,
        message: msg,
        severity: sev
    };
}

function build_status() {
    let state = read_json_file(STATUS_FILE, {});
    let data = state.data || {};

    let enabled = to_bool(cfg('enabled', '0'), false);
    let refresh_on_boot = to_bool(cfg('refresh_on_boot', '1'), true);
    let require_wan = to_bool(cfg('require_wan', '1'), true);
    let refresh_interval_s = to_int(cfg('refresh_interval_s', '21600'), 21600);
    let boot_start_delay_s = to_int(cfg('boot_start_delay_s', '30'), 30);

    let api_base_url = cfg('api_base_url', DEFAULT_API_BASE_URL);
    let api_resolve_path = cfg('api_resolve_path', DEFAULT_API_RESOLVE_PATH);
    let api_resolve_url = data.api_resolve_url || normalize_api_resolve_url(api_base_url, api_resolve_path);
    let license_key = cfg('license_key', '');
    let license_configured = !!license_key;
    let apply_local_overrides = to_bool(cfg('apply_local_overrides', '1'), true);

    let cfg_device_fingerprint = cfg('device_fingerprint', '');
    let cfg_device_vendor = cfg('device_vendor', '');
    let cfg_device_model = cfg('device_model', '');
    let cfg_device_arch = cfg('device_arch', '');
    let cfg_device_memory_mb = cfg('device_memory_mb', '');

    let status = data.status || (enabled ? 'idle' : 'disabled');
    let stage = data.stage || '';
    let valid_line_count = to_int(data.valid_line_count || 0, 0);
    let warnings = (type(state.warnings) == 'array') ? state.warnings : [];
    let errors = (type(state.errors) == 'array') ? state.errors : [];

    let last_attempt = to_int(data.last_attempt || 0, 0);
    let last_success = to_int(data.last_success || 0, 0);
    let last_failure = to_int(data.last_failure || 0, 0);
    let next_refresh_at = to_int(data.next_refresh_at || 0, 0);
    let last_result = data.last_result || '';
    let last_error_code = data.last_error_code || '';

    let blocklist_file_size_kb = to_int(data.blocklist_file_size_kb || 0, 0);
    let blocklist_installed = to_bool(data.blocklist_installed || '0', false);
    let blocklist_verification_ok = to_bool(data.blocklist_verification_ok || '0', false);
    let blocklist_test_domain = data.blocklist_test_domain || '';
    let blocklist_test_domain_sample_count = to_int(data.blocklist_test_domain_sample_count || 0, 0);
    let blocklist_test_domain_success_count = to_int(data.blocklist_test_domain_success_count || 0, 0);
    let blocklist_test_domains = data.blocklist_test_domains || '';
    let blocklist_backup_available = to_bool(data.blocklist_backup_available || '0', false);

    let artifact_tier = data.artifact_tier || '';
    let artifact_version = data.artifact_version || '';
    let artifact_sha256 = data.artifact_sha256 || '';
    let artifact_unique_domains = to_int(data.artifact_unique_domains || 0, 0);
    let artifact_rules = to_int(data.artifact_rules || 0, 0);
    let artifact_download_url_present = to_bool(data.artifact_download_url_present || '0', false);

    let license_plan = data.license_plan || '';
    let license_status = data.license_status || '';
    let device_fingerprint = data.device_fingerprint || cfg_device_fingerprint || '';
    let device_profile = data.device_profile || '';

    let health_dnsmasq_binary = to_bool(data.health_dnsmasq_binary || '0', false);
    let health_dnsmasq_confdir = to_bool(data.health_dnsmasq_confdir || '0', false);
    let health_dnsmasq_initial_restart = to_optional_bool(data.health_dnsmasq_initial_restart);
    let health_dnsmasq_final_restart = to_bool(data.health_dnsmasq_final_restart || '0', false);
    let health_dns_runtime = to_bool(data.health_dns_runtime || '0', false);
    let health_blocklist_verify = to_bool(data.health_blocklist_verify || '0', false);
    let health_min_valid_line_count = to_bool(data.health_min_valid_line_count || '0', false);
    let health_max_file_size = to_bool(data.health_max_file_size || '0', false);
    let health_api_resolve = to_optional_bool(data.health_api_resolve);
    let health_artifact_download = to_optional_bool(data.health_artifact_download);
    let health_artifact_sha256 = to_optional_bool(data.health_artifact_sha256);

    let hub_source = build_api_source(data, enabled, api_base_url, api_resolve_url, license_key);
    let installed = blocklist_installed || file_exists(BLOCKLIST_FILE);
    let refreshd_running = service_running(PKG_NAME);
    let dns_running = dnsmasq_running();

    let generated_at = time();
    let next_refresh_in_s = 0;

    if (next_refresh_at > generated_at) {
        next_refresh_in_s = next_refresh_at - generated_at;
    }

    return {
        schema: {
            name: SCHEMA_NAME,
            version: SCHEMA_VERSION
        },

        name: PKG_NAME,
        version: PKG_VERSION,

        enabled: enabled,
        active: refreshd_running,
        status: status,
        stage: stage,

        summary: build_summary(status, stage, valid_line_count, artifact_tier, artifact_version, errors, warnings),

        runtime: {
            refreshd_running: refreshd_running,
            dnsmasq_running: dns_running,
            dns_runtime_ok: health_dns_runtime || dns_running,
            config_loaded: true,
            require_wan: require_wan,
            refresh_on_boot: refresh_on_boot,
            last_result: last_result,
            last_error_code: last_error_code
        },

        api: {
            mode: 'hub_artifact',
            base_url: api_base_url,
            resolve_path: api_resolve_path,
            resolve_url: api_resolve_url,
            configured: !!api_base_url && !!api_resolve_path && license_configured,
            license_configured: license_configured,
            license_key_masked: mask_secret(license_key),
            download_url_present: artifact_download_url_present
        },

        license: {
            configured: license_configured,
            key_masked: mask_secret(license_key),
            plan: license_plan,
            status: license_status
        },

        device: {
            fingerprint: device_fingerprint,
            profile: device_profile,
            configured: {
                fingerprint: cfg_device_fingerprint,
                vendor: cfg_device_vendor,
                model: cfg_device_model,
                arch: cfg_device_arch,
                memory_mb: to_int(cfg_device_memory_mb, 0)
            }
        },

        artifact: {
            resolved: !!artifact_tier || !!artifact_version || artifact_download_url_present,
            tier: artifact_tier,
            version: artifact_version,
            sha256: artifact_sha256,
            unique_domains: artifact_unique_domains,
            rules: artifact_rules,
            download_url_present: artifact_download_url_present
        },

        local_overrides: {
            enabled: apply_local_overrides,
            allowlist_path: cfg('local_allowlist_path', '/etc/safeshield/allowlist'),
            blocklist_path: cfg('local_blocklist_path', '/etc/safeshield/blocklist')
        },

        blocklist: {
            installed: installed,
            path: BLOCKLIST_FILE,
            valid_line_count: valid_line_count,
            file_size_kb: blocklist_file_size_kb || file_size_kb(BLOCKLIST_FILE),
            verification_ok: blocklist_verification_ok,
            test_domain: blocklist_test_domain,
            test_domain_sample_count: blocklist_test_domain_sample_count,
            test_domain_success_count: blocklist_test_domain_success_count,
            test_domains: blocklist_test_domains,
            compressed: false,
            previous_backup_available: blocklist_backup_available
        },

        sources: {
            mode: 'hub_api',
            total: 1,
            enabled: hub_source.enabled ? 1 : 0,
            items: [ hub_source ]
        },

        health: {
            overall: (status == 'error') ? 'error' : ((type(warnings) == 'array' && length(warnings) > 0) ? 'warning' : 'ok'),
            checks: {
                api_resolve: health_api_resolve,
                artifact_download: health_artifact_download,
                artifact_sha256: health_artifact_sha256,
                dnsmasq_binary: health_dnsmasq_binary,
                dnsmasq_confdir: health_dnsmasq_confdir,
                dnsmasq_initial_restart: health_dnsmasq_initial_restart,
                dnsmasq_final_restart: health_dnsmasq_final_restart,
                dns_runtime: health_dns_runtime,
                blocklist_verify: health_blocklist_verify,
                min_valid_line_count: health_min_valid_line_count,
                max_file_size: health_max_file_size
            }
        },

        warnings: warnings,
        errors: errors,

        timestamps: {
            generated_at: generated_at,
            last_attempt: last_attempt,
            last_success: last_success,
            last_failure: last_failure,
            next_refresh_at: next_refresh_at,
            refresh_interval_s: refresh_interval_s,
            next_refresh_in_s: next_refresh_in_s,
            boot_start_delay_s: boot_start_delay_s
        }
    };
}

return {
    safeshield: {
        status: {
            call: function () {
                return build_status();
            }
        }
    }
};
