'use strict';

let fs = require('fs');
let ubus = require('ubus').connect();
let uci = require('uci').cursor();

const PKG_NAME = 'safeshield';
const STATUS_FILE = `/dev/shm/${PKG_NAME}.status.json`;
const BLOCKLIST_FILE = '/tmp/dnsmasq.d/safeshield.blocklist';
const LOCAL_ALLOWLIST_FILE = '/etc/safeshield/allowlist';
const LOCAL_BLOCKLIST_FILE = '/etc/safeshield/blocklist';
const SCHEMA_NAME = 'safeshield.status';
const SCHEMA_VERSION = 1;
const CONFIG_SCHEMA_NAME = 'safeshield.config';
const CONFIG_SCHEMA_VERSION = 1;
const RULES_SCHEMA_NAME = 'safeshield.rules';
const RULES_SCHEMA_VERSION = 1;
const SERVICE_INIT = '/etc/init.d/safeshield';
const RULES_DIR = '/etc/safeshield';

const CONFIG_SPEC = {
    verbosity: { kind: 'int', def: 2, min: 0, max: 7 },
    apply_local_overrides: { kind: 'bool', def: true },
    max_blocklist_file_size_kb: { kind: 'int', def: 30000, min: 1, max: 2147483647 },
    min_valid_line_count: { kind: 'int', def: 3000, min: 0, max: 2147483647 },
    compress_blocklist: { kind: 'bool', def: false },
    initial_dnsmasq_restart: { kind: 'bool', def: false },
    dnsmasq_sanity_check: { kind: 'bool', def: true },
    download_timeout: { kind: 'int', def: 10, min: 1, max: 86400 },
    download_retry: { kind: 'int', def: 3, min: 1, max: 100 },
    pause_timeout: { kind: 'int', def: 20, min: 1, max: 86400 },
    boot_start_delay_s: { kind: 'int', def: 30, min: 0, max: 86400 },
    refresh_on_boot: { kind: 'bool', def: true },
    refresh_interval_s: { kind: 'int', def: 21600, min: 1, max: 2147483647 },
    require_wan: { kind: 'bool', def: true },
    debug: { kind: 'bool', def: false }
};

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

function reload_uci() {
    return !!uci.load(PKG_NAME);
}

function cfg(name, def) {
    let v = uci.get(PKG_NAME, 'config', name);
    return (v == null) ? def : v;
}

function identity_cfg(name, def) {
    let v = uci.get(PKG_NAME, 'identity', name);
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

function build_api_source(data, enabled) {
    let api_resolve_ok = to_optional_bool(data.health_api_resolve);
    let artifact_download_ok = to_optional_bool(data.health_artifact_download);
    let last_result = data.last_result || '';

    if (!enabled) {
        last_result = 'disabled';
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
        enabled: enabled,
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
    reload_uci();

    let state = read_json_file(STATUS_FILE, {});
    let data = state.data || {};

    let enabled = to_bool(cfg('enabled', '0'), false);
    let refresh_on_boot = to_bool(cfg('refresh_on_boot', '1'), true);
    let require_wan = to_bool(cfg('require_wan', '1'), true);
    let refresh_interval_s = to_int(cfg('refresh_interval_s', '21600'), 21600);
    let boot_start_delay_s = to_int(cfg('boot_start_delay_s', '30'), 30);

    let license_key = cfg('license_key', '');
    let license_configured = !!license_key;
    let apply_local_overrides = to_bool(cfg('apply_local_overrides', '1'), true);

    let cfg_physical_fingerprint = identity_cfg('physical_fingerprint', '');
    let cfg_fingerprint_version = identity_cfg('fingerprint_version', '1');
    let cfg_identity_provider = identity_cfg('identity_provider', '');
    let cfg_identity_source = identity_cfg('identity_source', '');
    let cfg_identity_strength = identity_cfg('identity_strength', '');
    let cfg_identity_profile = identity_cfg('identity_profile', '');
    let cfg_installation_id = identity_cfg('installation_id', '');
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
    let physical_fingerprint = data.physical_fingerprint || cfg_physical_fingerprint || '';
    let fingerprint_version = to_int(data.fingerprint_version || cfg_fingerprint_version || 1, 1);
    let identity_provider = data.identity_provider || cfg_identity_provider || '';
    let identity_source = data.identity_source || cfg_identity_source || '';
    let identity_strength = data.identity_strength || cfg_identity_strength || '';
    let identity_profile = data.identity_profile || cfg_identity_profile || '';
    let installation_id = data.installation_id || cfg_installation_id || '';
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

    let hub_source = build_api_source(data, enabled);
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
        license: {
            configured: license_configured,
            key_masked: mask_secret(license_key),
            plan: license_plan,
            status: license_status
        },

        device: {
            physical_fingerprint: physical_fingerprint,
            fingerprint_version: fingerprint_version,
            identity_provider: identity_provider,
            identity_source: identity_source,
            identity_strength: identity_strength,
            identity_profile: identity_profile,
            installation_id: installation_id,
            profile: device_profile,
            configured: {
                physical_fingerprint: cfg_physical_fingerprint,
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
            allowlist_path: LOCAL_ALLOWLIST_FILE,
            blocklist_path: LOCAL_BLOCKLIST_FILE
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

function api_error(code, message, field) {
    let error = {
        code: code,
        message: message
    };

    if (field) {
        error.field = field;
    }

    return {
        ok: false,
        error: error
    };
}

function uci_commit_option(name, value) {
    if (!uci.set(PKG_NAME, 'config', name, sprintf('%s', value))) {
        return false;
    }

    if (!uci.commit(PKG_NAME)) {
        uci.revert(PKG_NAME);
        return false;
    }

    reload_uci();
    return true;
}

function bool_uci(v) {
    return v ? '1' : '0';
}

function config_public_value(name, spec) {
    let raw = cfg(name, null);

    if (spec.kind == 'bool') {
        return to_bool(raw, spec.def);
    }

    return to_int(raw, spec.def);
}

function build_config() {
    reload_uci();

    let values = {};

    for (let name, spec in CONFIG_SPEC) {
        values[name] = config_public_value(name, spec);
    }

    values.enabled = to_bool(cfg('enabled', '0'), false);

    return {
        schema: {
            name: CONFIG_SCHEMA_NAME,
            version: CONFIG_SCHEMA_VERSION
        },
        values: values,
        license: {
            configured: !!cfg('license_key', ''),
            key_masked: mask_secret(cfg('license_key', ''))
        },
        device: {
            vendor: cfg('device_vendor', ''),
            model: cfg('device_model', ''),
            arch: cfg('device_arch', ''),
            memory_mb: to_int(cfg('device_memory_mb', ''), 0)
        }
    };
}

function validate_config_value(name, value) {
    let spec = CONFIG_SPEC[name];

    if (!spec) {
        if (name == 'enabled') {
            return api_error('dedicated_method_required', 'Use set_enabled to change enabled state', name);
        }

        if (name == 'license_key') {
            return api_error('dedicated_method_required', 'Use license_update to change the license key', name);
        }

        return api_error('unknown_option', 'Unsupported SafeShield configuration option', name);
    }

    if (spec.kind == 'bool') {
        if (type(value) != 'bool') {
            return api_error('invalid_type', 'Expected a boolean value', name);
        }

        return {
            ok: true,
            uci: bool_uci(value),
            value: value
        };
    }

    if (spec.kind == 'int') {
        if (type(value) != 'int') {
            return api_error('invalid_type', 'Expected an integer value', name);
        }

        if (value < spec.min || value > spec.max) {
            return api_error(
                'out_of_range',
                sprintf('Value must be between %d and %d', spec.min, spec.max),
                name
            );
        }

        return {
            ok: true,
            uci: sprintf('%d', value),
            value: value
        };
    }

    return api_error('invalid_spec', 'Invalid internal configuration specification', name);
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

function normalize_rule_domain(value) {
    if (type(value) != 'string') {
        return '';
    }

    let domain = lc(trim(value));

    if (!domain || substr(domain, 0, 1) == '#' || substr(domain, 0, 1) == '!') {
        return '';
    }

    domain = replace(domain, /^0\.0\.0\.0[ \t]+/, '');
    domain = replace(domain, /^127\.0\.0\.1[ \t]+/, '');
    domain = replace(domain, /^local=\//, '');
    domain = replace(domain, /^address=\//, '');
    domain = replace(domain, /\/0\.0\.0\.0$/, '');
    domain = replace(domain, /\/::$/, '');
    domain = replace(domain, /\/$/, '');
    domain = replace(domain, /^\//, '');

    if (!match(domain, /^[a-z0-9._-]+$/) || length(domain) > 253 || index(domain, '..') >= 0) {
        return '';
    }

    for (let label in split(domain, '.')) {
        if (!label || length(label) > 63 || substr(label, 0, 1) == '-' || substr(label, -1) == '-') {
            return '';
        }
    }

    return domain;
}

function rule_path(action) {
    if (action == 'allow') {
        return LOCAL_ALLOWLIST_FILE;
    }

    if (action == 'block') {
        return LOCAL_BLOCKLIST_FILE;
    }

    return null;
}

function read_rule_entries(path) {
    let content = fs.readfile(path) || '';
    let entries = [];
    let seen = {};

    for (let line in split(content, /\n/)) {
        let domain = normalize_rule_domain(line);

        if (!domain || seen[domain]) {
            continue;
        }

        seen[domain] = true;
        push(entries, domain);
    }

    sort(entries);
    return entries;
}

function write_rule_file_atomic(path, content) {
    if (!fs.stat(RULES_DIR) && !fs.mkdir(RULES_DIR)) {
        return false;
    }

    let tmp = sprintf('%s.tmp.%d', path, time());

    if (fs.writefile(tmp, content) == null) {
        fs.unlink(tmp);
        return false;
    }

    if (!fs.chmod(tmp, 0o644)) {
        fs.unlink(tmp);
        return false;
    }

    if (!fs.rename(tmp, path)) {
        fs.unlink(tmp);
        return false;
    }

    return true;
}

function rule_file_contains(path, domain) {
    for (let existing in read_rule_entries(path)) {
        if (existing == domain) {
            return true;
        }
    }

    return false;
}

function add_rule_to_file(path, domain) {
    let content = fs.readfile(path) || '';

    if (rule_file_contains(path, domain)) {
        return {
            ok: true,
            changed: false
        };
    }

    if (content && substr(content, -1) != '\n') {
        content += '\n';
    }

    content += domain + '\n';

    return {
        ok: write_rule_file_atomic(path, content),
        changed: true
    };
}

function delete_rule_from_file(path, domain) {
    let content = fs.readfile(path) || '';
    let lines = split(content, /\n/);
    let kept = [];
    let changed = false;

    for (let line in lines) {
        if (normalize_rule_domain(line) == domain) {
            changed = true;
            continue;
        }

        push(kept, line);
    }

    if (!changed) {
        return {
            ok: true,
            changed: false
        };
    }

    let next = join('\n', kept);

    return {
        ok: write_rule_file_atomic(path, next),
        changed: true
    };
}

function build_rules(action) {
    let allow = read_rule_entries(LOCAL_ALLOWLIST_FILE);
    let block = read_rule_entries(LOCAL_BLOCKLIST_FILE);

    if (action == 'allow') {
        block = [];
    }
    else if (action == 'block') {
        allow = [];
    }

    return {
        schema: {
            name: RULES_SCHEMA_NAME,
            version: RULES_SCHEMA_VERSION
        },
        allow: allow,
        block: block,
        counts: {
            allow: length(allow),
            block: length(block)
        }
    };
}

function validate_rule_request(args) {
    let action = args.action || '';
    let domain = normalize_rule_domain(args.domain);

    if (!rule_path(action)) {
        return api_error('invalid_action', 'action must be either allow or block', 'action');
    }

    if (!domain) {
        return api_error('invalid_domain', 'domain must be a plain valid domain name', 'domain');
    }

    return {
        ok: true,
        action: action,
        domain: domain,
        path: rule_path(action)
    };
}

function apply_rule_refresh(args) {
    reload_uci();

    let should_refresh = (args.refresh == null) ? true : args.refresh;

    if (!should_refresh) {
        return {
            requested: false,
            accepted: false,
            reason: 'not_requested'
        };
    }

    if (!to_bool(cfg('apply_local_overrides', '1'), true)) {
        return {
            requested: false,
            accepted: false,
            reason: 'local_overrides_disabled'
        };
    }

    let r = start_refresh_async();

    return {
        requested: true,
        accepted: r.accepted,
        reason: r.reason || ''
    };
}

function config_update_call(request) {
    reload_uci();

    let values = request.args.values || {};
    let changes = {};
    let changed_names = [];

    if (type(values) != 'object') {
        return api_error('invalid_type', 'values must be an object', 'values');
    }

    for (let name, value in values) {
        let checked = validate_config_value(name, value);

        if (!checked.ok) {
            return checked;
        }

        let current = cfg(name, null);
        if (sprintf('%s', current) != checked.uci) {
            changes[name] = checked.uci;
            push(changed_names, name);
        }
    }

    if (length(changed_names) == 0) {
        return {
            ok: true,
            changed: [],
            restarted: false,
            config: build_config()
        };
    }

    for (let name, value in changes) {
        if (!uci.set(PKG_NAME, 'config', name, value)) {
            uci.revert(PKG_NAME);
            return api_error('uci_set_failed', 'Failed to update SafeShield configuration', name);
        }
    }

    if (!uci.commit(PKG_NAME)) {
        uci.revert(PKG_NAME);
        return api_error('uci_commit_failed', 'Failed to commit SafeShield configuration');
    }

    reload_uci();

    let restarted = run_service_action('restart', 60000);
    if (!restarted.ok) {
        return {
            ok: false,
            committed: true,
            changed: changed_names,
            restarted: false,
            service_rc: restarted.rc,
            error: {
                code: 'service_restart_failed',
                message: 'Configuration was committed but SafeShield failed to restart'
            },
            config: build_config()
        };
    }

    let refresh = start_refresh_async();

    return {
        ok: true,
        changed: changed_names,
        restarted: true,
        refresh: {
            requested: true,
            accepted: refresh.accepted,
            reason: refresh.reason || ''
        },
        config: build_config()
    };
}

function set_enabled_call(request) {
    reload_uci();

    if (request.args.enabled == null) {
        return api_error('missing_argument', 'enabled is required', 'enabled');
    }

    if (type(request.args.enabled) != 'bool') {
        return api_error('invalid_type', 'enabled must be a boolean', 'enabled');
    }

    let enabled = request.args.enabled;
    let current = to_bool(cfg('enabled', '0'), false);
    let changed = enabled != current;

    if (changed && !uci_commit_option('enabled', bool_uci(enabled))) {
        return api_error('uci_commit_failed', 'Failed to update enabled state');
    }

    let restarted = run_service_action('restart', 60000);
    if (!restarted.ok) {
        return {
            ok: false,
            committed: changed,
            changed: changed,
            enabled: enabled,
            service_rc: restarted.rc,
            error: {
                code: 'service_restart_failed',
                message: 'Enabled state is configured but SafeShield failed to reconcile its runtime lifecycle'
            },
            status: build_status()
        };
    }

    return {
        ok: true,
        changed: changed,
        reconciled: true,
        enabled: enabled,
        status: build_status()
    };
}

function refresh_call() {
    let r = start_refresh_async();

    if (!r.accepted) {
        return {
            ok: r.reason == 'already_running',
            accepted: false,
            reason: r.reason,
            status: build_status()
        };
    }

    return {
        ok: true,
        accepted: true,
        status: build_status()
    };
}

function rules_list_call(request) {
    let action = request.args.action || '';

    if (action && !rule_path(action)) {
        return api_error('invalid_action', 'action must be allow, block or omitted', 'action');
    }

    let result = build_rules(action);
    result.ok = true;
    return result;
}

function rule_add_call(request) {
    let checked = validate_rule_request(request.args);

    if (!checked.ok) {
        return checked;
    }

    let result = add_rule_to_file(checked.path, checked.domain);

    if (!result.ok) {
        return api_error('rule_write_failed', 'Failed to update the local rule file');
    }

    let refresh = result.changed
        ? apply_rule_refresh(request.args)
        : { requested: false, accepted: false, reason: 'unchanged' };

    return {
        ok: true,
        action: checked.action,
        domain: checked.domain,
        added: result.changed,
        refresh: refresh,
        rules: build_rules(checked.action)
    };
}

function rule_delete_call(request) {
    let checked = validate_rule_request(request.args);

    if (!checked.ok) {
        return checked;
    }

    let result = delete_rule_from_file(checked.path, checked.domain);

    if (!result.ok) {
        return api_error('rule_write_failed', 'Failed to update the local rule file');
    }

    let refresh = result.changed
        ? apply_rule_refresh(request.args)
        : { requested: false, accepted: false, reason: 'unchanged' };

    return {
        ok: true,
        action: checked.action,
        domain: checked.domain,
        deleted: result.changed,
        refresh: refresh,
        rules: build_rules(checked.action)
    };
}

function license_update_call(request) {
    reload_uci();

    if (request.args.license_key == null) {
        return api_error('missing_argument', 'license_key is required; use an empty string to clear it', 'license_key');
    }

    let key = trim(request.args.license_key);

    if (length(key) > 512 || match(key, /[\r\n]/)) {
        return api_error('invalid_license_key', 'license_key must be at most 512 characters and contain no line breaks', 'license_key');
    }

    let current = cfg('license_key', '');

    if (current == key) {
        return {
            ok: true,
            changed: false,
            license: {
                configured: !!key,
                key_masked: mask_secret(key)
            },
            refresh: {
                requested: false,
                accepted: false,
                reason: 'unchanged'
            }
        };
    }

    if (!uci_commit_option('license_key', key)) {
        return api_error('uci_commit_failed', 'Failed to update the SafeShield license key');
    }

    let refresh = start_refresh_async();

    return {
        ok: true,
        changed: true,
        license: {
            configured: !!key,
            key_masked: mask_secret(key)
        },
        refresh: {
            requested: true,
            accepted: refresh.accepted,
            reason: refresh.reason || ''
        }
    };
}

return {
    safeshield: {
        status: {
            call: function () {
                return build_status();
            }
        },

        config: {
            call: function () {
                return build_config();
            }
        },

        config_update: {
            args: {
                values: {}
            },
            call: config_update_call
        },

        set_enabled: {
            args: {
                enabled: true
            },
            call: set_enabled_call
        },

        refresh: {
            call: refresh_call
        },

        rules_list: {
            args: {
                action: ''
            },
            call: rules_list_call
        },

        rule_add: {
            args: {
                action: '',
                domain: '',
                refresh: true
            },
            call: rule_add_call
        },

        rule_delete: {
            args: {
                action: '',
                domain: '',
                refresh: true
            },
            call: rule_delete_call
        },

        license_update: {
            args: {
                license_key: ''
            },
            call: license_update_call
        }
    }
};
