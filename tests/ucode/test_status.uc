'use strict';

let core = require('core');
let status = require('status');

let ready = status.build();
assert(ready.status == 'ready', 'status preserves ready state');
assert(ready.summary.label == 'Ready' && ready.summary.severity == 'info', 'ready summary is generated');
assert(index(ready.summary.message, '42000 rules active') >= 0, 'ready summary includes active rule count');
assert(ready.artifact.source_count == 2, 'status reports artifact source count');
assert(ready.artifact.block_source_count == 1 && ready.artifact.allow_source_count == 1, 'status reports artifact action counts');
assert(ready.sources.items[0].last_result == 'ok', 'healthy API source is reported ok');
assert(ready.blocklist.installed == true && ready.blocklist.file_size_kb == 2048, 'blocklist state is normalized');
assert(ready.license.configured == true && ready.license.key_masked == 'abcd...wxyz', 'license state is masked');
assert(ready.health.overall == 'ok', 'healthy ready state reports overall ok');

core.state.data.status = 'error';
core.state.errors = [ { code: 'artifact_download_failed' } ];
let error = status.build();
assert(error.summary.label == 'Error' && error.summary.severity == 'error', 'error summary is generated');
assert(error.summary.message == 'artifact_download_failed', 'error summary uses first error code');
assert(error.health.overall == 'error', 'error status reports overall error');

core.state.data.status = 'ready';
core.state.errors = [];
core.state.warnings = [ { code: 'dnsmasq_warning' } ];
let warning = status.build();
assert(warning.summary.severity == 'warning', 'warnings elevate informational summary severity');
assert(warning.health.overall == 'warning', 'warnings report overall warning health');

core.config.enabled = '0';
core.state.data = {};
core.state.warnings = [];
let disabled = status.build();
assert(disabled.status == 'disabled', 'disabled config falls back to disabled status');
assert(disabled.summary.label == 'Disabled' && disabled.summary.severity == 'warning', 'disabled summary is generated');
assert(disabled.sources.items[0].last_result == 'disabled', 'disabled API source is reported disabled');

print('ucode status tests: ok\n');
