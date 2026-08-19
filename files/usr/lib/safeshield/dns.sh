# shellcheck shell=ash

ss_mkdirs() {
	mkdir -p "${SS_TMP_DIR}" "${SS_DNSMASQ_DIR}"
}

ss_clean_tmp() {
	rm -f \
		"${SS_TMP_DIR}"/*.txt \
		"${SS_TMP_DIR}"/*.raw \
		"${SS_TMP_DIR}"/*.filtered \
		"${SS_TMP_DIR}"/*.json \
		"${SS_RUNTIME_OUT}" \
		2>/dev/null
}

ss_clear_active_blocklist() {
	rm -f "${SS_BLOCKLIST_FILE}"
}

ss_check_dnsmasq_confdir() {
	local confdir

	confdir="$(uci -q get dhcp.@dnsmasq[0].confdir 2>/dev/null)"
	[ "$confdir" = "${SS_DNSMASQ_DIR}" ]
}

check_dnsmasq_binary() {
	command_exists dnsmasq
}

check_dnsmasq_process() {
	pgrep -x dnsmasq >/dev/null 2>&1
}

check_dns_runtime() {
	local domain i

	check_dnsmasq_process || return 1

	for domain in google.com cloudflare.com microsoft.com; do
		for i in 1 2 3 4 5 6 7 8 9 10; do
			ss_should_stop && return 130

			if nslookup "$domain" 127.0.0.1 >"${SS_RUNTIME_OUT}" 2>/dev/null; then
				if ! grep -Eq '^Address: *(0\.0\.0\.0|::)$' "${SS_RUNTIME_OUT}"; then
					rm -f "${SS_RUNTIME_OUT}"
					return 0
				fi
			fi

			ss_should_stop && return 130
			sleep 1
		done
	done

	rm -f "${SS_RUNTIME_OUT}"
	return 1
}

dnsmasq_kill() {
	log_info "Stopping dnsmasq"

	killall -q dnsmasq >/dev/null 2>&1 || true
	sleep 1
	killall -q -KILL dnsmasq >/dev/null 2>&1 || true
}

dnsmasq_restart() {
	local i

	log_info "Restarting dnsmasq"
	/etc/init.d/dnsmasq restart >/dev/null 2>&1 || return 1

	# shellcheck disable=SC2034
	for i in 1 2 3 4 5 6 7 8 9 10 \
		11 12 13 14 15 16 17 18 19 20 \
		21 22 23 24 25 26 27 28 29 30; do
		ss_should_stop && return 130

		if check_dnsmasq_process && nslookup localhost 127.0.0.1 >/dev/null 2>&1; then
			log_ok "dnsmasq restart done"
			return 0
		fi

		sleep 1
	done

	log_error "dnsmasq did not become ready after restart"
	return 1
}
