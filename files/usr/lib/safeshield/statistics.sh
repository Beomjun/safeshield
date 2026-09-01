# shellcheck shell=ash

# Paths are defined by core.sh before these helpers are called.
# shellcheck disable=SC2154

ss_statistics_profile_code() {
	local board=""
	local profile=""

	if command -v ss_identity_board_name >/dev/null 2>&1 && command -v ss_identity_profile_code >/dev/null 2>&1; then
		board="$(ss_identity_board_name 2>/dev/null || true)"
		if [ -n "$board" ]; then
			profile="$(ss_identity_profile_code "$board" 2>/dev/null || true)"
		fi
	fi

	case "$profile" in
		'' | unknown)
			[ -n "${SS_IDENTITY_PROFILE:-}" ] && profile="${SS_IDENTITY_PROFILE}"
			;;
	esac
	[ -n "$profile" ] || profile="unknown"
	printf '%s\n' "$profile"
}

ss_statistics_log_async_lines() {
	case "$(ss_statistics_profile_code)" in
		gl_mt300n_v2)
			printf '%s\n' '50'
			;;
		*)
			printf '%s\n' '25'
			;;
	esac
}

ss_statistics_effective_snapshot_interval() {
	local configured="${1:-60}"

	if [ "$configured" = "60" ] && [ "$(ss_statistics_profile_code)" = "gl_mt300n_v2" ]; then
		printf '%s\n' '300'
		return 0
	fi
	printf '%s\n' "$configured"
}

ss_statistics_configure_dnsmasq() {
	local enabled="${1:-0}"
	local log_async_lines=""
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

	log_async_lines="$(ss_statistics_log_async_lines)"
	{
		printf '%s\n' '# Managed by SafeShield. Do not edit.'
		printf '%s\n' 'log-queries=extra'
		printf 'log-async=%s\n' "$log_async_lines"
	} >"$tmp" || {
		rm -f "$tmp"
		return 1
	}

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
