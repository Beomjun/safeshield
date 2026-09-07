# SafeShield

[![Lint](https://github.com/Junatum/safeshield/actions/workflows/lint-shell.yml/badge.svg)](https://github.com/Junatum/safeshield/actions/workflows/lint-shell.yml)
![OpenWrt](https://img.shields.io/badge/OpenWrt-Compatible-blue)
![License](https://img.shields.io/github/license/Junatum/safeshield?label=License)

A lightweight DNS-based ad blocker for OpenWrt, designed with a powerful, easy-to-use Web UI. Blocks ads and phishing sites, fully compatible with dnsmasq.

## Features

- DNS-based blocking of ads, tracking, and phishing domains
- Fully compatible with **dnsmasq**
- Lightweight design suitable for **low-resource OpenWrt devices**
- Easy management through the **LuCI Web UI**
- Automatic blocklist download and refresh
- Multiple Hub artifact sources with independent block/allow actions and checksum verification
- Support for **custom allowlist and blocklist**
- Modular shell-based architecture for easy customization and maintenance

## Package versions

The badges below show the versions currently published to each repository channel.

| Package | Stable | Beta |
| --- | --- | --- |
| SafeShield | [![Stable SafeShield](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Frepo.smartsafehub.com%2Fstable%2Fversions.json&query=%24.packages%5B%22safeshield%22%5D&label=&color=brightgreen&cacheSeconds=300)](https://repo.smartsafehub.com/stable/versions.json) | [![Beta SafeShield](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Frepo.smartsafehub.com%2Fbeta%2Fversions.json&query=%24.packages%5B%22safeshield%22%5D&label=&color=orange&cacheSeconds=300)](https://repo.smartsafehub.com/beta/versions.json) |
| LuCI SafeShield | [![Stable LuCI SafeShield](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Frepo.smartsafehub.com%2Fstable%2Fversions.json&query=%24.packages%5B%22luci-app-safeshield%22%5D&label=&color=brightgreen&cacheSeconds=300)](https://repo.smartsafehub.com/stable/versions.json) | [![Beta LuCI SafeShield](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Frepo.smartsafehub.com%2Fbeta%2Fversions.json&query=%24.packages%5B%22luci-app-safeshield%22%5D&label=&color=orange&cacheSeconds=300)](https://repo.smartsafehub.com/beta/versions.json) |

## How it works

SafeShield provides DNS-level protection by automatically applying the
appropriate **dnsmasq**-compatible blocklist for each device.

It helps block ads, trackers, and phishing domains with scheduled updates
and optional local allow/block overrides.

### Hub artifact source contract

SafeShield accepts both the legacy single-artifact response and the preferred
multi-source response from the SmartSafeHub Hub API. Existing deployments can
continue returning `artifact.download_url`.

For multiple independently licensed or managed datasets, the Hub should return
`artifact.sources`:

```json
{
  "artifact": {
    "tier": "pro",
    "version": "20260830T120000Z",
    "sources": [
      {
        "id": "hagezi-pro",
        "action": "block",
        "download_url": "https://example.invalid/hagezi-pro.txt",
        "sha256": "..."
      },
      {
        "id": "smartsafehub-pro",
        "action": "block",
        "download_url": "https://example.invalid/smartsafehub-pro.txt",
        "sha256": "..."
      },
      {
        "id": "smartsafehub-allow",
        "action": "allow",
        "download_url": "https://example.invalid/smartsafehub-allow.txt",
        "sha256": "..."
      }
    ]
  }
}
```

Each source is downloaded, checksum-verified, normalized, and retained as an
independent runtime cache file. SafeShield merges all block and allow sources
only on the router when generating the active dnsmasq configuration. This keeps
the Hub artifacts separate while preserving override precedence as `local allow`
> `local block` > `Hub allow` > `Hub block`.

## System Requirements

SafeShield requires the following environment:

- **OpenWrt 25.12 or later**
- **dnsmasq 2.80 or later** (required for the optimized `address=/domain/#` block rules)
- At least **16 MB free flash storage**
- Internet access for downloading blocklists

## Installation

SafeShield can be installed from the **SmartSafeHub OpenWrt package repository**.

Determine your device architecture:

```sh
opkg print-architecture
```

Add the repository:

```sh
echo "src/gz smartsafehub https://junatum.github.io/openwrt-packages/stable/packages/<architecture>/smartsafehub" >> /etc/opkg/customfeeds.conf
```

Example (for `x86_64`):

```sh
echo "src/gz smartsafehub https://junatum.github.io/openwrt-packages/stable/packages/x86_64/smartsafehub" >> /etc/opkg/customfeeds.conf
```

Update package lists:

```sh
opkg update
```

Install SafeShield:

```sh
opkg install safeshield
```

Install the LuCI web interface (optional):

```sh
opkg install luci-app-safeshield
```

After installation, configure SafeShield via the LuCI interface under **LuCI → Services → SafeShield**.

## Build from source

SafeShield is built as an OpenWrt package. Build it inside an OpenWrt buildroot or SDK that matches your target device and OpenWrt version.

### Build with OpenWrt buildroot

Clone OpenWrt and prepare feeds:

```sh
git clone -b production https://github.com/Junatum/openwrt.git
cd openwrt

./scripts/feeds update -a
./scripts/feeds install -a
```

Add SafeShield under the OpenWrt `package/` directory:

```sh
git clone https://github.com/Junatum/safeshield package/safeshield
```

If you also want to build the LuCI web interface, add
`luci-app-safeshield` as well:

```sh
git clone https://github.com/Junatum/luci-app-safeshield package/luci-app-safeshield
```

Select your target device:

```sh
make menuconfig
```

For example, for MediaTek Filogic devices such as ipTIME AX3000SM:

```text
Target System  ---> MediaTek Ralink ARM
Subtarget      ---> Filogic 8x0
Target Profile ---> your device profile
```

Enable SafeShield as a module:

```sh
cat >> .config <<'EOF'
CONFIG_PACKAGE_safeshield=m
CONFIG_PACKAGE_luci-app-safeshield=m
EOF

make defconfig
```

Build the packages:

```sh
make package/safeshield/clean V=s
make package/safeshield/compile V=s

make package/luci-app-safeshield/clean V=s
make package/luci-app-safeshield/compile V=s
```

Find the generated packages:

```sh
find bin -type f \( \
  -name 'safeshield*.apk' \
  -o -name 'luci-app-safeshield*.apk' \
\) -print
```

Depending on the OpenWrt version and package location, the output can appear
under one of these paths:

```text
bin/targets/<target>/<subtarget>/packages/
bin/packages/<architecture>/<feed-name>/
```

For example, a MediaTek Filogic `apk` build may generate packages under:

```text
bin/targets/mediatek/filogic/packages/
```

### Build with OpenWrt SDK

You can also build SafeShield with the OpenWrt SDK for your target. This is
faster when you only need package artifacts.

```sh
tar xf openwrt-sdk-*.tar.*
cd openwrt-sdk-*

./scripts/feeds update -a
./scripts/feeds install -a

git clone https://github.com/Junatum/safeshield package/safeshield
git clone https://github.com/Junatum/luci-app-safeshield package/luci-app-safeshield

cat >> .config <<'EOF'
CONFIG_PACKAGE_safeshield=m
CONFIG_PACKAGE_luci-app-safeshield=m
EOF

make defconfig

make package/safeshield/compile V=s
make package/luci-app-safeshield/compile V=s
```

### Install local build artifacts

For OpenWrt `apk` based builds, copy the generated artifacts to the
device:

```sh
find bin -type f \( -name 'safeshield-*.apk' -o -name 'luci-app-safeshield-*.apk' \) -print

scp path/to/safeshield-*.apk root@192.168.1.1:/tmp/
scp path/to/luci-app-safeshield-*.apk root@192.168.1.1:/tmp/
```

Install them on the device:

```sh
ssh root@192.168.1.1

apk add --allow-untrusted /tmp/safeshield-*.apk
apk add --allow-untrusted /tmp/luci-app-safeshield-*.apk

/etc/init.d/rpcd restart
/etc/init.d/uhttpd restart
/etc/init.d/safeshield restart
```

Verify the installation:

```sh
ubus call safeshield status
/etc/init.d/safeshield status
logread | grep -i safeshield
```

## Development linting

SafeShield uses the same shell lint entrypoint locally and in GitHub Actions:

```sh
sh scripts/lint.sh
```

The lint script runs `shfmt -d -ci`, ShellCheck, and `sh -n` against tracked shell files. Install `shfmt` and `shellcheck` on the development machine before running it.

To enable the repository pre-commit hook, install `pre-commit` and register the hook once:

```sh
pre-commit install
```

After that, `git commit` runs the shell lint automatically. You can also check the whole repository manually:

```sh
pre-commit run --all-files
```

## Internal rpcd ucode layout

SafeShield keeps the rpcd registration entrypoint intentionally small and loads feature modules from `/usr/share/rpcd/ucode/safeshield/`:

```text
/usr/share/rpcd/ucode/safeshield.uc
/usr/share/rpcd/ucode/safeshield/
├── core.uc
├── runtime.uc
├── status.uc
├── config.uc
├── refresh.uc
├── rules.uc
├── license.uc
└── statistics.uc
```

The entrypoint prepends `/usr/share/rpcd/ucode/safeshield/*.uc` to ucode's `REQUIRE_SEARCH_PATH`, so the private RPC modules stay colocated with the rpcd plugin instead of using the global `/usr/share/ucode` tree.

The public ubus contract remains exposed through the single `safeshield` object; the module split is an internal implementation detail.

## SafeShield ubus API

The `safeshield` package owns the public management API used by LuCI and
SmartSafeHub clients. The API keeps UCI mutations, service lifecycle,
refresh scheduling and local rule files behind one ubus object.

Available methods:

```text
safeshield.status
safeshield.config
safeshield.statistics
safeshield.config_update
safeshield.set_enabled
safeshield.refresh
safeshield.rules_list
safeshield.rule_add
safeshield.rule_delete
safeshield.license_get
safeshield.license_update
```

Read the current public configuration:

```sh
ubus call safeshield config
```

Read lightweight local DNS statistics:

```sh
ubus call safeshield statistics
/etc/init.d/safeshield statistics
```

Statistics are collected from live dnsmasq query logging. Raw queried domains
are never written to the statistics state. Loopback (`127.0.0.0/8` and `::1`)
queries are excluded so SafeShield's own DNS health checks do not inflate user
query or blocked counters. In addition to global hourly query/block counters,
SafeShield keeps per-device totals and per-device hourly buckets locally. DHCP
clients are identified by MAC address using the dnsmasq lease file, with the
current IP and hostname included for the local UI. IPv4 clients can also be
resolved through the kernel ARP table, while IPv6 clients use the kernel NDP
neighbor cache (`ip -6 neigh show`). This lets multiple IPv6 privacy/temporary
addresses from the same LAN client converge on one MAC identity and migrates
any earlier `ip:<address>` hourly buckets when the neighbor entry becomes
available. Clients that still cannot be resolved use a temporary IP-based
identity. Device statistics are capped at 128 identities to bound memory use
on low-end routers.

Each retained statistics dataset has a stable `generation_id`. `started_at` is
the creation time of that retained dataset and is restored together with the
generation when the collector restarts. `session_started_at` is the start time
of the current collector process and therefore changes on every collector
restart. This distinction lets cloud ingestion upsert repeated snapshots from
the same generation without treating a process restart as a new dataset.

The collector implementation is split into focused AWK modules under
`/usr/lib/safeshield/statistics/` for common helpers, recovery, client identity,
aggregation, persistence, output, and the collector lifecycle. `safeshield-statsd`
loads the modules together as one AWK program, preserving the single collector
process used on resource-constrained routers.

Hot statistics live under `/tmp/safeshield/statistics/` and are retained for up
to 168 hourly buckets. Supported profiles additionally persist aggregate state
with a compact base snapshot plus hourly journal, while constrained profiles
may stay tmpfs-only. The collector starts `logread` in follow-only mode, so
existing system log entries are not counted a second time when the service
restarts.

The default statistics settings are:

```text
statistics_enabled=1
statistics_snapshot_interval_s=60
statistics_retention_hours=168
```

When statistics are enabled, SafeShield adds `log-queries=extra` and
`log-async=25` to its managed dnsmasq configuration. The `extra` mode provides
the requestor address needed to attribute block responses to local devices.
Disabling statistics removes those settings and stops the collector. dnsmasq
query messages still pass through the normal in-memory OpenWrt system log while
collection is enabled; SafeShield persists aggregate counters only, never raw
DNS query names.

The blocked counter tracks dnsmasq null-address (`0.0.0.0` / `::`) responses.
On SmartSafeHub images these responses are expected to come from SafeShield.
If another package installs additional null-address dnsmasq rules, those hits
are included in the aggregate blocked count as well.

Update writable configuration values. `enabled` and `license_key` are
intentionally excluded and have dedicated methods:

```sh
ubus call safeshield config_update '{
  "values": {
    "refresh_interval_s": 28800,
    "refresh_on_boot": true,
    "require_wan": true,
    "apply_local_overrides": true,
    "statistics_enabled": true,
    "statistics_snapshot_interval_s": 60,
    "statistics_retention_hours": 168
  }
}'
```

Enable or disable SafeShield. This method commits the desired UCI value and
requests the full SafeShield enable/disable lifecycle. Runtime convergence is
asynchronous under procd, so a successful response reports the accepted target
state instead of returning a potentially stale status snapshot:

```sh
ubus call safeshield set_enabled '{"enabled":true}'
```

A successful response has this shape:

```json
{
  "ok": true,
  "changed": true,
  "accepted": true,
  "target_enabled": true,
  "reconciled": false
}
```

Clients should poll `safeshield.status` until runtime state converges. For an
enable request, wait for `enabled=true`, `active=true` and
`runtime.refreshd_running=true`. For a disable request, wait for
`enabled=false`, `active=false` and `runtime.refreshd_running=false`.

Request an immediate refresh:

```sh
ubus call safeshield refresh
```

List local allow/block overrides:

```sh
ubus call safeshield rules_list
ubus call safeshield rules_list '{"action":"allow"}'
ubus call safeshield rules_list '{"action":"block"}'
```

Add or delete a local rule. Rule changes request an asynchronous refresh by
default so the active dnsmasq blocklist is rebuilt. For bulk edits, pass
`"refresh":false` on intermediate mutations and invoke `safeshield.refresh`
after the last mutation.

```sh
ubus call safeshield rule_add '{
  "action": "block",
  "domain": "example.com"
}'

ubus call safeshield rule_delete '{
  "action": "block",
  "domain": "example.com"
}'
```

### Local rule fast apply

`rule_add` and `rule_delete` keep the public SafeShield API unchanged, but their automatic apply path no longer performs a full Hub artifact refresh. SafeShield retains the normalized Hub domains in `/tmp/safeshield/api.block.txt`, rebuilds only the local allow/block inputs, merges them atomically, restarts dnsmasq, and verifies runtime DNS. The local apply worker shares the normal refresh lock, so a rule edit made during a full refresh waits for that refresh and then reapplies the newest local state. If the cached Hub artifact is missing, SafeShield falls back to one normal full refresh.

Read the raw license key only when an authenticated management client explicitly
requests it. Normal `status`, `config` and `license_update` responses continue to
return only masked license metadata.

```sh
ubus call safeshield license_get
```

Update or clear the license key. Passing an empty string removes the configured
UCI option and immediately requests a SafeShield refresh so the device is resolved
as unlicensed/free again. SafeShield intentionally treats an absent `license_key`
option as the canonical unlicensed state; all runtime readers fall back to an empty
key when the option is not present.

```sh
ubus call safeshield license_update '{"license_key":"YOUR-LICENSE-KEY"}'
ubus call safeshield license_update '{"license_key":""}'
```

The package also installs an rpcd ACL named `safeshield`. Read access covers
`status`, `config` and `rules_list`; sensitive license access and mutating
methods are declared as write access.

## Contributors

<a href="https://github.com/Junatum/safeshield/graphs/contributors">
    <img src="https://contrib.rocks/image?repo=Junatum/safeshield" alt="Contributors">
</a>

## Support

If you encounter issues or have feature requests, please open an issue on GitHub:

https://github.com/Junatum/safeshield/issues

Bug reports and pull requests are welcome.

## Third-party blocklist data

SafeShield may install SmartSafeHub artifacts derived from third-party DNS
blocklists, including [HaGeZi's DNS Blocklists](https://github.com/hagezi/dns-blocklists).
HaGeZi-derived artifacts remain subject to GNU GPL v3.0. See
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) for the upstream project,
license, source inventory, and installed notice location.

## License

SafeShield is under the [GNU Public License version 3](https://www.gnu.org/licenses/gpl-3.0.html)
