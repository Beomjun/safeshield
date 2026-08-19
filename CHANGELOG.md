## [0.3.9-r29] - 2026-08-19

- Apply local allow/block rule mutations from the retained normalized Hub artifact instead of re-resolving and re-downloading the full artifact.
- Serialize local rule application with the full refresh lock and wait for an in-flight refresh before merging the newest local files.
- Fingerprint normalized local rules so rapid duplicate apply workers collapse without repeated dnsmasq restarts.
- Fall back to a full refresh only when the cached Hub artifact is unavailable.
- Expose `last_local_apply` and `last_local_apply_failure` timestamps while keeping the normal Hub refresh schedule unchanged.
