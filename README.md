# SafeShield

[![Lint](https://github.com/Beomjun/safeshield/actions/workflows/lint-shell.yml/badge.svg)](https://github.com/Beomjun/safeshield/actions/workflows/lint-shell.yml)
![OpenWrt](https://img.shields.io/badge/OpenWrt-Compatible-blue)
![License](https://img.shields.io/github/license/Beomjun/safeshield?label=License)

A lightweight DNS-based ad blocker for OpenWrt, designed with a powerful, easy-to-use Web UI. Blocks ads and phishing sites, fully compatible with dnsmasq.

## Features

- DNS-based blocking of ads, tracking, and phishing domains
- Fully compatible with **dnsmasq**
- Lightweight design suitable for **low-resource OpenWrt devices**
- Easy management through the **LuCI Web UI**
- Automatic blocklist download and refresh
- Support for **custom allowlist and blocklist**
- Modular shell-based architecture for easy customization and maintenance

## How it works

SafeShield downloads domain blocklists from configured sources,
normalizes and validates the entries, and generates a blocklist
compatible with **dnsmasq**.

The blocklist is automatically refreshed and applied to dnsmasq,
providing DNS-level protection against ads, trackers, and phishing domains.

## System Requirements

SafeShield requires the following environment:

- **OpenWrt 24.10 or later**
- **dnsmasq** (default DNS server in OpenWrt)
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
echo "src/gz smartsafehub https://beomjun.github.io/openwrt-packages/stable/packages/<architecture>/smartsafehub" >> /etc/opkg/customfeeds.conf
```

Example (for `x86_64`):

```sh
echo "src/gz smartsafehub https://beomjun.github.io/openwrt-packages/stable/packages/x86_64/smartsafehub" >> /etc/opkg/customfeeds.conf
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

## Contributors

<a href="https://github.com/Beomjun/safeshield/graphs/contributors">
    <img src="https://contrib.rocks/image?repo=Beomjun/safeshield" alt="Contributors">
</a>

## Support

If you encounter issues or have feature requests, please open an issue on GitHub:

https://github.com/Beomjun/safeshield/issues

Bug reports and pull requests are welcome.

## License

SafeShield is under the [GNU Public License version 3](https://www.gnu.org/licenses/gpl-3.0.html)
