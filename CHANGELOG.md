# Changelog

## [0.3.16-r3] - 2026-08-30

### Added

- Add host-side ucode unit tests for core helpers and rpcd config, license, refresh, rules, statistics, and status behavior.
- Compile-check all production rpcd ucode modules before running ucode unit tests.
- Run ucode tests in GitHub Actions using the ucode revision shipped by the OpenWrt 25.12 package feed.

## [0.3.16-r2] - 2026-08-30

### Added

- Add host-side regression tests for shared utility helpers, configuration validation, identity persistence/profile mapping, status state transitions, and the rpcd/ACL public contract.

### Changed

- Run the new regression tests from the existing `tests/run.sh` entrypoint.

## [0.3.16-r1] - 2026-08-30

### Added

- Support multiple Hub artifact sources through `artifact.sources[]` while preserving the legacy single `artifact.download_url` response.
- Support independent `block` and `allow` actions for remote artifact sources so separately distributed datasets can be combined only at router runtime.
- Download and SHA-256 verify each remote source independently and cache normalized source files for local-rule reapply operations.
- Expose resolved block/allow source counts through the SafeShield status API.

### Changed

- Keep downloaded Hub sources separate in tmpfs and merge them only when generating the active dnsmasq blocklist.
- Define override precedence as local allow > local block > Hub allow > Hub block when multiple source actions overlap.

## [0.3.15-r2] - 2026-08-30

### Changed

- Add an installed third-party data notice for HaGeZi-derived DNS blocklist artifacts.
- Install a GPL-3.0 license copy alongside the notice so the applicable terms are available on-device.

## [0.3.15-r1] - 2026-08-30

- Bump version for release.

## [0.3.14-r8] - 2026-08-30

### Fixed

- Reconcile statistics enable/disable changes without restarting the SafeShield refresh daemon.
- Add or remove only the statistics procd instance while keeping the refresh scheduler running.
- Restart dnsmasq only when the managed statistics logging configuration changes.
- Avoid transient `stage: stopped` states caused by full SafeShield restarts from statistics-only configuration updates.

## [0.3.14-r7] - 2026-08-29

### Fixed

- Initialize all per-device AWK array elements when a device record is created.
- Avoid sparse associative-array values reaching serialization helpers, preventing gawk double-free crashes on affected versions.
- Add regression coverage for complete state serialization of unidentified IP-based devices.

## [0.3.14-r6] - 2026-08-29

### Changed

- Add a shared shell lint entrypoint for shfmt, ShellCheck, and shell syntax validation.
- Run the same shell lint script from local pre-commit hooks and GitHub Actions.
- Fail local commits early when shell formatting does not satisfy `shfmt -d -ci`.

## [0.3.14-r5] - 2026-08-29

### Fixed

- Align statistics tests with the repository shfmt formatting rules.

## [0.3.14-r4] - 2026-08-29

- Add per-device DNS query and block counters to local SafeShield statistics.
- Use `log-queries=extra` so dnsmasq block responses can be attributed to the requesting client.
- Resolve DHCP clients from the configured dnsmasq lease file and use MAC addresses as stable local device identities.
- Fall back to temporary IP identities for clients without a DHCP lease and migrate them when a lease becomes available.
- Cap retained device identities at 128 while keeping raw queried domains out of statistics state.

## [0.3.14-r3] - 2026-08-29

- Fix `shfmt -ci` formatting for the statistics collector regression test environment assignments.

## [0.3.14-r2] - 2026-08-29

- Fix orphaned `logread` / `awk` statistics collector processes after procd restarts or service termination.
- Track collector child PIDs explicitly and terminate them on HUP, INT, TERM, and normal exit.
- Use a per-instance FIFO instead of an unmanaged shell pipeline so the parent process owns the full collector lifecycle.
- Add a tmpfs collector lock to prevent concurrent statistics writers and recover stale locks after crashes.
- Add regression coverage that verifies collector children and runtime files are cleaned up after termination.

## [0.3.14-r1] - 2026-08-29

- Add lightweight local DNS statistics collection using dnsmasq query logs.
- Keep statistics in tmpfs only to avoid persistent flash writes.
- Add hourly query/block counters with configurable snapshots and up to 168 hours of retention.
- Add the `safeshield.statistics` ubus RPC endpoint for local dashboards.
- Enable asynchronous dnsmasq query logging only while statistics collection is enabled.

## [0.3.13-r1] - 2026-08-28

- Bump version for release.

## [0.3.12-r2] - 2026-08-28

- Fix ShellCheck warnings in the dnsmasq compatibility helper and regression test scripts.
- Encapsulate the dnsmasq compatibility failure code behind a helper instead of exposing a cross-file global variable.
- Use an explicit empty `CDPATH` assignment in test path resolution and remove an unused test variable.

## [0.3.12-r1] - 2026-08-28

- Require dnsmasq 2.80 or later before SafeShield starts, refreshes, or reapplies local rules.
- Expose the detected and minimum dnsmasq versions through runtime status and health checks.
- Accept optimized Hub artifacts using `address=/domain/#` and emit the same single-line dual-stack rule in the active dnsmasq blocklist.
- Keep blocklist verification compatible with both the optimized `/#` rule and legacy `0.0.0.0` / `::` rules.

## [0.3.11-r35] - 2026-08-27

- Declare `coreutils-cksum` as a runtime dependency because SafeShield uses `cksum` to fingerprint normalized local allow/block rules.
- Ensure the existing identity hash fallback also has a guaranteed `cksum` implementation on minimal OpenWrt images such as GL-MT300N-V2.
- Fix false dnsmasq restart/runtime failures on OpenWrt targets where `pgrep -x dnsmasq` does not match the running dnsmasq process.
- Use the base-system `pidof` applet for dnsmasq process detection, while retaining the existing DNS query readiness check.
- Declare direct runtime dependencies for the `uci` CLI and `jsonfilter` used by SafeShield shell helpers.
- Use BusyBox-aware fallback dependencies for `sha256sum`, `awk`, `grep`, and `sed` so minimal OpenWrt images install GNU implementations only when the corresponding BusyBox applet is disabled.
- Remove the invalid `cksum` fallback from identity SHA-256 generation; CRC output is not a SHA-256 digest and cannot satisfy the identity format.
- Fail closed when artifact SHA-256 verification cannot run instead of silently accepting an unverified artifact.

## [0.3.10-r34] - 2026-08-26

- Refactor the 1,300+ line rpcd ucode implementation into focused modules under `/usr/share/rpcd/ucode/safeshield/`.
- Keep all SafeShield rpcd ucode sources together under the rpcd plugin tree instead of installing private modules under `/usr/share/ucode`.
- Keep `/usr/share/rpcd/ucode/safeshield.uc` as a small ubus registration entrypoint while preserving existing RPC names, arguments, and response schemas.
- Separate shared UCI/helpers, runtime lifecycle, status, configuration, local rules, refresh, and license logic to reduce coupling.
- Treat an absent `license_key` UCI option as the canonical unlicensed state and clear it explicitly with `uci.delete()` instead of relying on the ucode UCI empty-string deletion side effect.
- Add `safeshield.license_get` for explicit authenticated retrieval of the configured raw license key while keeping normal status/config responses masked.
- Keep license removal on `safeshield.license_update` with an empty key and document the refresh/unlicensed transition.

## [0.3.9-r29] - 2026-08-19

- Apply local allow/block rule mutations from the retained normalized Hub artifact instead of re-resolving and re-downloading the full artifact.
- Serialize local rule application with the full refresh lock and wait for an in-flight refresh before merging the newest local files.
- Fingerprint normalized local rules so rapid duplicate apply workers collapse without repeated dnsmasq restarts.
- Fall back to a full refresh only when the cached Hub artifact is unavailable.
- Expose `last_local_apply` and `last_local_apply_failure` timestamps while keeping the normal Hub refresh schedule unchanged.
