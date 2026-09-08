# shellcheck shell=ash

# Paths are defined by core.sh before these helpers are called.
# shellcheck disable=SC2154

SS_STATISTICS_POLL_COMMAND="${SS_STATISTICS_POLL_COMMAND:-/usr/libexec/safeshield-stats-poll}"

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

ss_statistics_effective_snapshot_interval() {
	local configured="${1:-60}"

	if [ "$configured" = "60" ] && [ "$(ss_statistics_profile_code)" = "gl_mt300n_v2" ]; then
		printf '%s\n' '300'
		return 0
	fi
	printf '%s\n' "$configured"
}

ss_statistics_persistence_enabled() {
	case "$(ss_statistics_profile_code)" in
		gl_mt300n_v2)
			return 1
			;;
		*)
			return 0
			;;
	esac
}

ss_statistics_cleanup_legacy_dnsmasq_logging() {
	if [ -f "${SS_STATISTICS_DNSMASQ_CONF}" ]; then
		rm -f "${SS_STATISTICS_DNSMASQ_CONF}" || return 1
		printf '%s\n' '1'
	else
		printf '%s\n' '0'
	fi
}

# Kept as an internal compatibility wrapper for the init script. Statistics no
# longer enables dnsmasq query logging; this only removes a pre-0.3.20-r2 file.
ss_statistics_configure_dnsmasq() {
	ss_statistics_cleanup_legacy_dnsmasq_logging
}

ss_statistics_source_available() {
	[ -x "$SS_STATISTICS_POLL_COMMAND" ] || return 1
	"$SS_STATISTICS_POLL_COMMAND" >/dev/null 2>&1
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
	local legacy_dnsmasq_changed=0

	if [ "${ss_enabled}" != "1" ] || [ "${ss_statistics_enabled}" != "1" ]; then
		procd_kill "${PKG_NAME}" statistics >/dev/null 2>&1 || true

		legacy_dnsmasq_changed="$(ss_statistics_cleanup_legacy_dnsmasq_logging)" || {
			log_error "Failed to remove legacy dnsmasq statistics logging"
			return 1
		}

		if [ "$legacy_dnsmasq_changed" = "1" ]; then
			dnsmasq_restart || {
				log_error "Failed to restart dnsmasq after removing legacy statistics logging"
				return 1
			}
		fi

		return 0
	fi

	ss_require_supported_dnsmasq || {
		log_error "Failed dnsmasq compatibility check while enabling statistics"
		return 1
	}

	legacy_dnsmasq_changed="$(ss_statistics_cleanup_legacy_dnsmasq_logging)" || {
		log_error "Failed to remove legacy dnsmasq statistics logging"
		return 1
	}

	if [ "$legacy_dnsmasq_changed" = "1" ]; then
		dnsmasq_restart || {
			log_error "Failed to restart dnsmasq after removing legacy statistics logging"
			return 1
		}
	fi

	ss_statistics_source_available || {
		log_error "dnsmasq SmartSafeHub statistics UBus source is unavailable"
		return 1
	}

	procd_open_service "${PKG_NAME}"
	ss_statistics_add_procd_instance
	procd_close_service add
}
