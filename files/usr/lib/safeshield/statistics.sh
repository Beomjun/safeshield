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
log-queries
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
