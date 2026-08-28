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
