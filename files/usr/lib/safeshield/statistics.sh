# shellcheck shell=ash

# Paths are defined by core.sh before these helpers are called.
# shellcheck disable=SC2154

ss_statistics_configure_dnsmasq() {
	local enabled="${1:-0}"
	local tmp="${SS_STATISTICS_DNSMASQ_CONF}.tmp.$$"

	mkdir -p "${SS_DNSMASQ_DIR}" || return 1

	if [ "$enabled" != "1" ]; then
		if [ -f "${SS_STATISTICS_DNSMASQ_CONF}" ]; then
			rm -f "${SS_STATISTICS_DNSMASQ_CONF}" || return 1
			printf '%s\n' '1'
		else
			printf '%s\n' '0'
		fi
		return 0
	fi

	cat >"$tmp" <<'CONFIG'
# Managed by SafeShield. Do not edit.
log-queries=extra
log-async=25
CONFIG

	if [ -f "${SS_STATISTICS_DNSMASQ_CONF}" ] && cmp -s "$tmp" "${SS_STATISTICS_DNSMASQ_CONF}"; then
		rm -f "$tmp"
		printf '%s\n' '0'
		return 0
	fi

	mv -f "$tmp" "${SS_STATISTICS_DNSMASQ_CONF}" || {
		rm -f "$tmp"
		return 1
	}

	printf '%s\n' '1'
}

ss_statistics_add_procd_instance() {
	procd_open_instance statistics
	procd_set_param command /usr/libexec/safeshield-statsd
	procd_set_param respawn 3600 5 5
	procd_set_param stdout 1
	procd_set_param stderr 1
	procd_set_param file /etc/config/safeshield
	procd_set_param data service safeshield-statistics
	procd_close_instance
}

ss_statistics_reconcile_runtime() {
	local statistics_dnsmasq_changed=0

	if [ "${ss_enabled}" != "1" ] || [ "${ss_statistics_enabled}" != "1" ]; then
		procd_kill "${PKG_NAME}" statistics >/dev/null 2>&1 || true

		statistics_dnsmasq_changed="$(ss_statistics_configure_dnsmasq 0)" || {
			log_error "Failed to disable dnsmasq statistics logging"
			return 1
		}

		if [ "$statistics_dnsmasq_changed" = "1" ]; then
			dnsmasq_restart || {
				log_error "Failed to restart dnsmasq after disabling statistics logging"
				return 1
			}
		fi

		return 0
	fi

	ss_require_supported_dnsmasq || {
		log_error "Failed dnsmasq compatibility check while enabling statistics"
		return 1
	}

	ss_ensure_dnsmasq_confdir || {
		log_error "dnsmasq confdir is unavailable while enabling statistics"
		return 1
	}

	statistics_dnsmasq_changed="$(ss_statistics_configure_dnsmasq 1)" || {
		log_error "Failed to enable dnsmasq statistics logging"
		return 1
	}

	if [ "$statistics_dnsmasq_changed" = "1" ]; then
		dnsmasq_restart || {
			log_error "Failed to restart dnsmasq after enabling statistics logging"
			return 1
		}
	fi

	procd_open_service "${PKG_NAME}"
	ss_statistics_add_procd_instance
	procd_close_service add
}
