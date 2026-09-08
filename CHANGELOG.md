# Changelog

## [0.3.19-r4] - 2026-09-08

### Fixed

- Detect HTTP 426 responses from Hub artifact resolve and download requests and stop retrying immediately with `safeshield_upgrade_required`.
- Preserve the currently active blocklist without an unnecessary dnsmasq restore/restart when the Hub requires a newer SafeShield version.
- Keep the installed runtime version string in OpenWrt `0.3.19-rN` form so Hub minimum-version validation receives the same revision that the package reports.

## [0.3.19-r3] - 2026-09-07

### Added

- Resolve IPv6 DNS clients through the kernel NDP neighbor cache so privacy/temporary IPv6 addresses from the same link-layer client converge on one MAC-based statistics identity.
- Add regression coverage for IPv6 temporary-identity migration, shared-MAC neighbor merging, failed neighbor fallback, and the modular statistics runtime contract.

### Changed

- Split the monolithic statistics AWK collector into focused common, recovery, identity, aggregation, persistence, output, and lifecycle modules loaded together by `safeshield-statsd`.
- Keep unresolved IPv6 clients on the existing `ip:<address>` fallback until a valid neighbor `lladdr` becomes available, then migrate retained hourly buckets to the MAC identity.

## [0.3.19-r2] - 2026-09-06

### Added

- Add a persistent `generation_id` to statistics state, journal records, JSON output, and the public statistics RPC so one retained dataset can be identified across collector restarts.
- Document the distinction between dataset-scoped `started_at` and process-scoped `session_started_at`.
- Add regression coverage for stale journal recovery, internal loopback DNS queries, statistics generation/session identity, and temporary IPv6 device identities.

### Fixed

- Ignore committed journal transactions that are not newer than the loaded persistent base snapshot, preventing stale retained journal data from rolling statistics backward after interrupted compaction.
- Exclude loopback DNS traffic from both global and per-device statistics so SafeShield's own localhost health checks do not inflate query or blocked counters.

## [0.3.19-r1] - 2026-09-02

- Bump version for release.

## [0.3.18-r13] - 2026-09-02

### Changed

- Remove the `tests/run.sh` compatibility wrapper now that the shell regression suite is fully native ShellSpec.
- Run ShellSpec directly in GitHub Actions with `REQUIRE_UCODE=1 shellspec`, leaving a single test entry point for local and CI execution.
- Extend the tooling contract to require direct ShellSpec CI execution and prevent the legacy `tests/run.sh` wrapper from being reintroduced.

## [0.3.18-r12] - 2026-09-02

### Changed

- Replace the legacy ShellSpec adapter with native ShellSpec suites for the existing SafeShield shell regression coverage.
- Organize the converted suite into core, blocklist, runtime, statistics, ucode, and tooling specs so failures are reported by feature-oriented ShellSpec examples.
- Move reusable shell fixtures and integration scenarios under `spec/support/`, where they remain covered by the normal shfmt, ShellCheck, and `sh -n` lint pipeline.
- Keep `tests/run.sh` as the compatibility entry point while ShellSpec directly discovers only native `spec/*_spec.sh` files.
- Preserve the existing ucode test programs under `tests/ucode/` and invoke them from the native ShellSpec ucode example.

## [0.3.18-r11] - 2026-09-02

### Changed

- Adopt ShellSpec 0.28.1 as the shell test runner and use its `spec/*_spec.sh` discovery instead of maintaining a manual test list in `tests/run.sh`.
- Run the existing POSIX shell regression scripts as individual ShellSpec examples so their established assertions and OpenWrt-specific mocks remain intact during the migration.
- Pin ShellSpec 0.28.1 in GitHub Actions and keep the compatibility `tests/run.sh` entry point for local and CI usage.
- Exclude ShellSpec DSL spec files from general `shfmt` formatting while continuing to lint normal shell helpers and production scripts.
- Treat legacy test stdout as an expected success message and require empty stderr so ShellSpec does not emit unverified-output warnings.

## [0.3.18-r10] - 2026-09-02

### Fixed

- Clear stale Statistics persistence health, error and checkpoint metadata when persistent storage is disabled.
- Keep persistence health non-erroring in volatile mode and avoid scheduling persistent checkpoint or compaction work when no persistent paths are configured.
- Record the collector's effective snapshot interval in runtime statistics and expose it separately from the configured UCI interval so GL-MT300N-V2 reports its 300-second runtime interval.

## [0.3.18-r9] - 2026-09-02

### Changed
- Run Statistics on GL-MT300N-V2 in volatile tmpfs-only mode by disabling the persistent snapshot and journal paths while keeping runtime state and `statistics.json` snapshots available.
- Avoid creating or touching Statistics flash-persistence directories on GL-MT300N-V2; other device profiles continue using the existing journal-based persistence path unchanged.

### Fixed
- Prevent periodic Statistics persistence and journal I/O from contributing to latency spikes on resource-constrained GL-MT300N-V2 routers.

## [0.3.18-r8] - 2026-09-01

### Changed
- Merge already sorted normalized Hub artifact shards with `sort -m -u` instead of concatenating and fully sorting them again during blocklist refresh.
- Reuse the existing statistics totals pass to track each device's first and last retained hourly bucket, then serialize only that active range in `statistics.json`.

## [0.3.18-r7] - 2026-09-01

### Changed
- Filter the live statistics log stream in `logread` so only dnsmasq messages enter the FIFO and AWK collector.
- Replace refreshd's one-second polling sleep loop with a single interruptible sleep child that is cancelled immediately on TERM or INT.
- Stop blocklist test-domain sampling as soon as the requested limit is reached and skip redundant blocklist rule scans for domains already sampled from the installed blocklist.

## [0.3.18-r6] - 2026-09-01

### Changed
- Increase the dnsmasq asynchronous statistics log queue from 25 to 50 lines on GL-MT300N-V2 while keeping the existing 25-line queue on other device profiles.
- Use a 300-second hot statistics snapshot interval on GL-MT300N-V2 when the configured interval is the standard 60-second default, while preserving non-default configured intervals.
- Cache resolved DNS client IP-to-device identities for up to 60 seconds, bounded by the DHCP/ARP lease refresh interval.
- Skip redundant tmpfs state and JSON serialization when no statistics state changed, while still forcing pending persistent journal data to flush on graceful collector shutdown and serializing persistence health changes when a flush updates them.

### Fixed
- Reduce per-query AWK identity processing and periodic snapshot CPU bursts that can cause DNS latency on resource-constrained routers such as GL-MT300N-V2.

## [0.3.18-r5] - 2026-09-01

### Added

- Add journal-based persistence for SafeShield statistics to reduce flash write amplification on low-end devices.
- Persist completed hourly global and per-device statistics by appending compact journal transactions instead of rewriting the full retained statistics state every hour.
- Add transactional `begin`/`commit` markers so incomplete journal writes caused by power loss are ignored during recovery.
- Add periodic journal compaction that merges retained journal data into the persistent base snapshot.
- Preserve statistics journal data across sysupgrade.
- Expose journal persistence mode and compaction metadata through the statistics API.

### Changed

- Keep the 60-second statistics snapshot in tmpfs while limiting routine flash writes to hourly journal updates.
- Change full persistent state rewrites from hourly checkpoints to periodic compaction, with a default compaction interval of 7 days.
- Restore statistics at startup by loading the persistent base snapshot and replaying committed journal transactions.
- Persist IP-to-MAC device identity reconciliation through journal records without losing cumulative or hourly statistics.
- Use absolute hourly bucket updates in the journal so replay remains idempotent after restarts or interrupted compaction.

### Fixed

- Avoid the periodic full-state flash writes that can cause noticeable latency on resource-constrained devices such as the GL-MT300N-V2.
- Ignore incomplete journal transactions after an unexpected shutdown or power loss.
- Keep in-memory statistics operational when a journal persistence write fails, while reporting persistence health through the statistics API.

## [0.3.18-r4] - 2026-09-01

### Fixed

- Reconcile temporary `ip:<address>` statistics identities with MAC-based device identities once the client MAC address becomes available.
- Merge existing cumulative and hourly query/block counters into the resolved MAC identity without losing historical statistics.
- Remove stale IP-based device records and hourly buckets after a successful identity migration.
- Fall back to `/proc/net/arp` for client MAC resolution when DHCP lease data is unavailable.
- Make device hourly bucket migration safe across different AWK implementations by avoiding in-place associative array mutation during iteration.

## [0.3.18-r3] - 2026-09-01

### Fixed

- Preserve per-device hourly statistics through the public statistics RPC.
- Prefer the newest valid tmpfs or persistent statistics state when the collector restarts.
- Reject persistent statistics state whose stored totals do not match its retained hourly buckets.
- Expose persistent checkpoint health and back off retries after flash write failures.

## [0.3.18-r2] - 2026-09-01

### Added

- Persist retained global and per-device hourly SafeShield statistics across router reboots.
- Expose per-device hourly buckets through the statistics API for accurate local history and future cloud ingestion.

### Changed

- Keep 60-second hot snapshots in tmpfs while checkpointing aggregate statistics to flash at most once per hour and on graceful collector shutdown.
- Restore persistent statistics after reboot, retain up to 168 hourly buckets, and migrate version 1 per-device cumulative counters without dropping totals.
- Keep the persistent statistics checkpoint across sysupgrade.

## [0.3.18-r1] - 2026-09-01

### Added

- Include the installed SafeShield package version in Hub artifact resolve requests for operational diagnostics and compatibility analysis.

## [0.3.17-r1] - 2026-08-30

- Bump version for release.

## [0.3.16-r4] - 2026-08-30

### Fixed

- Fix the shared ucode `trim()` helper so leading and trailing whitespace are both removed in a single call.
- Keep ucode unit-test mocks aligned with the production trimming behavior and add explicit leading/trailing regression cases.

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
