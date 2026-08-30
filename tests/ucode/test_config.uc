'use strict';

let core = require('core');
let runtime = require('runtime');
let config = require('config');

let built = config.build();
assert(built.schema.name == 'safeshield.config', 'config schema name is preserved');
assert(built.values.enabled == false, 'disabled state is normalized to boolean');
assert(built.values.download_retry == 3, 'integer options are normalized');
assert(built.license.configured == true, 'configured license is reported');
assert(built.license.key_masked == 'abcd...wxyz', 'license key is masked');
assert(built.device.memory_mb == 256, 'device memory is normalized to integer');

let invalid_type = config.update({ args: { values: { debug: 'true' } } });
assert(invalid_type.ok == false && invalid_type.error.code == 'invalid_type', 'boolean options reject strings');

let out_of_range = config.update({ args: { values: { download_retry: 101 } } });
assert(out_of_range.ok == false && out_of_range.error.code == 'out_of_range', 'integer options enforce ranges');

let unknown = config.update({ args: { values: { unknown_option: true } } });
assert(unknown.ok == false && unknown.error.code == 'unknown_option', 'unknown options are rejected');

let dedicated = config.update({ args: { values: { enabled: true } } });
assert(dedicated.ok == false && dedicated.error.code == 'dedicated_method_required', 'enabled requires dedicated method');

runtime.state.last_action = '';
let statistics = config.update({ args: { values: { statistics_enabled: false } } });
assert(statistics.ok == true, 'statistics update succeeds');
assert(statistics.reconciled == true && statistics.restarted == false, 'statistics-only update reconciles without restart');
assert(runtime.state.last_action == 'reconcile_statistics', 'statistics update requests reconciliation');
assert(core.values.statistics_enabled == '0', 'statistics update commits UCI value');

runtime.state.last_action = '';
runtime.state.refresh_count = 0;
let debug = config.update({ args: { values: { debug: true } } });
assert(debug.ok == true && debug.restarted == true, 'regular config update restarts service');
assert(runtime.state.last_action == 'restart', 'regular config update requests restart');
assert(runtime.state.refresh_count == 1, 'regular config update requests refresh');
assert(core.values.debug == '1', 'regular config update commits UCI value');

let missing_enabled = config.set_enabled({ args: {} });
assert(missing_enabled.ok == false && missing_enabled.error.code == 'missing_argument', 'set_enabled requires enabled argument');

let invalid_enabled = config.set_enabled({ args: { enabled: 1 } });
assert(invalid_enabled.ok == false && invalid_enabled.error.code == 'invalid_type', 'set_enabled requires boolean');

let enabled = config.set_enabled({ args: { enabled: true } });
assert(enabled.ok == true && enabled.changed == true, 'set_enabled updates changed state');
assert(core.values.enabled == '1', 'set_enabled commits enabled state');

print('ucode config tests: ok\n');
