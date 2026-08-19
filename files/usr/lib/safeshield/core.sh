# shellcheck shell=ash

# This file defines globals consumed by other sourced scripts.
# shellcheck disable=SC2034

# Variables below are populated by sourced helpers and ss_load_config()
# shellcheck disable=SC2154

# shellcheck disable=SC1091
. "${IPKG_INSTROOT}/usr/share/libubox/jshn.sh"
# shellcheck disable=SC1091
. "${IPKG_INSTROOT}/usr/lib/safeshield/utils.sh"
# shellcheck disable=SC1091
. "${IPKG_INSTROOT}/usr/lib/safeshield/status.sh"
# shellcheck disable=SC1091
. "${IPKG_INSTROOT}/usr/lib/safeshield/log.sh"
# shellcheck disable=SC1091
. "${IPKG_INSTROOT}/usr/lib/safeshield/config.sh"
# shellcheck disable=SC1091
. "${IPKG_INSTROOT}/usr/lib/safeshield/identity.sh"
# shellcheck disable=SC1091
. "${IPKG_INSTROOT}/usr/lib/safeshield/dns.sh"
# shellcheck disable=SC1091
. "${IPKG_INSTROOT}/usr/lib/safeshield/blocklist.sh"

readonly SS_TMP_DIR="/tmp/safeshield"
readonly SS_DNSMASQ_DIR="/tmp/dnsmasq.d"
readonly SS_BLOCKLIST_FILE="${SS_DNSMASQ_DIR}/safeshield.blocklist"
readonly SS_INACTIVE_BLOCKLIST_FILE="${SS_TMP_DIR}/inactive.blocklist"
readonly SS_LOCAL_ALLOWLIST_FILE="/etc/safeshield/allowlist"
readonly SS_LOCAL_BLOCKLIST_FILE="/etc/safeshield/blocklist"
readonly SS_IDENTITY_DIR="/etc/safeshield"
readonly SS_IDENTITY_FILE="${SS_IDENTITY_DIR}/identity.env"
readonly SS_API_PAYLOAD="${SS_TMP_DIR}/resolve-request.json"
readonly SS_API_RESPONSE="${SS_TMP_DIR}/resolve-response.json"
readonly SS_ARTIFACT_RAW="${SS_TMP_DIR}/artifact.blocklist.raw"
readonly SS_ARTIFACT_DOMAINS="${SS_TMP_DIR}/api.block.txt"
readonly SS_PREV_BLOCKLIST_GZ="/tmp/safeshield.prev.blocklist.gz"
readonly SS_RUNTIME_OUT="${SS_TMP_DIR}/runtime.out"
readonly SS_REFRESH_LOCK='/var/lock/safeshield-refresh.lock'
readonly SS_REFRESH_LOCK_FD=307

ss_should_terminate="${ss_should_terminate:-0}"

ss_should_stop() {
	[ "${ss_should_terminate:-0}" -eq 1 ]
}

ss_abort_refresh() {
	log_warn "Termination requested, aborting current refresh"
	ss_status_add_warning "refresh_terminated"
	ss_status_set last_result "terminated"
	ss_refresh_lock_close
	return 130
}

ss_restore_and_restart() {
	ss_restore_previous_blocklist >/dev/null 2>&1 || true
	dnsmasq_restart >/dev/null 2>&1 || true
}

ss_ensure_dnsmasq_confdir() {
	local changed=0

	mkdir -p "${SS_DNSMASQ_DIR}" || {
		log_error "Failed to create dnsmasq confdir: ${SS_DNSMASQ_DIR}"
		return 1
	}

	if ss_check_dnsmasq_confdir; then
		return 0
	fi

	uci -q get dhcp.@dnsmasq[0] >/dev/null || {
		log_error "dnsmasq UCI section not found: dhcp.@dnsmasq[0]"
		return 1
	}

	log_warn "dnsmasq confdir is not set to ${SS_DNSMASQ_DIR}, attempting automatic setup"

	if ! uci show dhcp | grep -Fq ".confdir='${SS_DNSMASQ_DIR}'"; then
		uci add_list dhcp.@dnsmasq[0].confdir="${SS_DNSMASQ_DIR}" || {
			log_error "Failed to add dhcp.@dnsmasq[0].confdir=${SS_DNSMASQ_DIR}"
			return 1
		}
		changed=1
	fi

	if [ "${changed}" -eq 1 ]; then
		uci commit dhcp || {
			log_error "Failed to commit dhcp config"
			return 1
		}

		log_info "Restarting dnsmasq after updating confdir"
		dnsmasq_restart || {
			log_error "Failed to restart dnsmasq after configuring confdir"
			return 1
		}
	fi

	ss_check_dnsmasq_confdir || {
		log_error "dnsmasq confdir verification failed after automatic setup"
		return 1
	}

	return 0
}

ss_sync_blocklist_status() {
	local file_size_kb valid_line_count

	if [ ! -f "${SS_BLOCKLIST_FILE}" ]; then
		ss_status_set blocklist_installed "0"
		ss_status_set blocklist_file_size_kb "0"
		ss_status_set valid_line_count "0"
		ss_status_set blocklist_verification_ok "0"
		ss_status_set health_blocklist_verify ""
		return 0
	fi

	file_size_kb="$(du -k "${SS_BLOCKLIST_FILE}" 2>/dev/null | awk '{print $1}')"
	valid_line_count="$(grep -c . "${SS_BLOCKLIST_FILE}" 2>/dev/null)"

	[ -n "$file_size_kb" ] || file_size_kb="0"
	[ -n "$valid_line_count" ] || valid_line_count="0"

	ss_status_set blocklist_installed "1"
	ss_status_set blocklist_file_size_kb "$file_size_kb"
	ss_status_set valid_line_count "$valid_line_count"
}

ss_stage_active_blocklist() {
	[ -f "${SS_BLOCKLIST_FILE}" ] || return 0

	rm -f "${SS_INACTIVE_BLOCKLIST_FILE}"
	ss_sync_path "${SS_BLOCKLIST_FILE}"
	mv -f "${SS_BLOCKLIST_FILE}" "${SS_INACTIVE_BLOCKLIST_FILE}" || return 1
	ss_sync_path "${SS_DNSMASQ_DIR}"
	ss_sync_path "${SS_TMP_DIR}"
	return 0
}

ss_restore_staged_blocklist() {
	[ -f "${SS_INACTIVE_BLOCKLIST_FILE}" ] || return 1

	mv -f "${SS_INACTIVE_BLOCKLIST_FILE}" "${SS_BLOCKLIST_FILE}" || return 1
	ss_sync_path "${SS_DNSMASQ_DIR}"
	return 0
}

ss_runtime_deactivate_blocklist() {
	local rc

	ss_mkdirs || return 1

	if [ ! -f "${SS_BLOCKLIST_FILE}" ]; then
		ss_sync_blocklist_status
		return 0
	fi

	log_info "Deactivating SafeShield blocklist"
	ss_stage_active_blocklist || {
		log_error "Failed to stage active blocklist for deactivation"
		return 1
	}

	dnsmasq_restart
	rc=$?
	if [ "$rc" -ne 0 ]; then
		log_error "dnsmasq restart failed while deactivating SafeShield; restoring blocklist"
		ss_restore_staged_blocklist >/dev/null 2>&1 || true
		dnsmasq_restart >/dev/null 2>&1 || true
		ss_sync_blocklist_status
		return "$rc"
	fi

	ss_sync_blocklist_status
	ss_status_set health_dnsmasq_final_restart "1"
	log_ok "SafeShield blocklist deactivated"
	return 0
}

ss_runtime_activate_blocklist() {
	local rc

	ss_mkdirs || return 1

	if [ ! -f "${SS_BLOCKLIST_FILE}" ] && [ -f "${SS_INACTIVE_BLOCKLIST_FILE}" ]; then
		log_info "Restoring staged SafeShield blocklist"
		ss_restore_staged_blocklist || {
			log_error "Failed to restore staged SafeShield blocklist"
			return 1
		}
	fi

	if [ ! -f "${SS_BLOCKLIST_FILE}" ]; then
		ss_sync_blocklist_status
		return 0
	fi

	ss_ensure_dnsmasq_confdir || {
		log_error "dnsmasq confdir is unavailable while activating SafeShield"
		ss_stage_active_blocklist >/dev/null 2>&1 || true
		ss_sync_blocklist_status
		return 1
	}

	dnsmasq_restart
	rc=$?
	if [ "$rc" -ne 0 ]; then
		log_error "dnsmasq restart failed while activating SafeShield"
		ss_stage_active_blocklist >/dev/null 2>&1 || true
		dnsmasq_restart >/dev/null 2>&1 || true
		ss_sync_blocklist_status
		return "$rc"
	fi

	check_blocklist_applied_multi_with_stats 5 3
	rc=$?
	if [ "$rc" -ne 0 ]; then
		log_error "SafeShield blocklist is not active in dnsmasq"
		ss_status_set health_blocklist_verify "0"
		ss_status_set blocklist_verification_ok "0"
		ss_stage_active_blocklist >/dev/null 2>&1 || true
		dnsmasq_restart >/dev/null 2>&1 || true
		ss_sync_blocklist_status
		return "$rc"
	fi

	rm -f "${SS_INACTIVE_BLOCKLIST_FILE}"
	ss_sync_blocklist_status
	ss_status_set health_dnsmasq_final_restart "1"
	ss_status_set health_blocklist_verify "1"
	ss_status_set blocklist_verification_ok "1"
	log_ok "SafeShield blocklist active in dnsmasq"
	return 0
}

safeshield_force_download() {
	local rc

	if ! ss_refresh_lock_open; then
		log_warn "Another refresh is already running, skipping"
		return 0
	fi

	ss_status_reset
	ss_status_set status "running"
	ss_status_set stage "init"
	ss_status_set_now last_attempt
	ss_status_set last_result "running"
	ss_status_set last_error_code ""

	ss_load_config || {
		ss_status_mark_failure "config_load_failed"
		ss_refresh_lock_close
		return 1
	}

	if [ "${ss_enabled}" != "1" ]; then
		log_warn "SafeShield refresh skipped because the service is disabled"
		ss_status_set status "disabled"
		ss_status_set stage "disabled"
		ss_status_set last_result "disabled"
		ss_status_set next_refresh_at "0"
		ss_refresh_lock_close
		return 0
	fi

	ss_sync_detected_device_config || true

	ss_identity_ensure "$(ss_detect_device_model 2>/dev/null || echo OpenWrt)" "$(ss_detect_device_arch 2>/dev/null || echo unknown)" || {
		ss_status_mark_failure "identity_init_failed"
		ss_refresh_lock_close
		return 1
	}

	if ss_should_stop; then
		ss_abort_refresh
		return $?
	fi

	ss_mkdirs || {
		ss_status_mark_failure "mkdir_failed"
		ss_refresh_lock_close
		return 1
	}

	ss_clean_tmp

	if ss_should_stop; then
		ss_abort_refresh
		return $?
	fi

	check_dnsmasq_binary || {
		log_error "dnsmasq binary not found"
		ss_status_set health_dnsmasq_binary "0"
		ss_status_mark_failure "dnsmasq_binary_not_found"
		ss_refresh_lock_close
		return 1
	}
	ss_status_set health_dnsmasq_binary "1"

	ss_ensure_dnsmasq_confdir || {
		log_error "dnsmasq confdir could not be configured automatically for ${SS_DNSMASQ_DIR}"
		ss_status_set health_dnsmasq_confdir "0"
		ss_status_mark_failure "dnsmasq_confdir_not_set"
		ss_refresh_lock_close
		return 1
	}
	ss_status_set health_dnsmasq_confdir "1"

	ss_export_existing_blocklist >/dev/null 2>&1 || true
	if [ -f "${SS_PREV_BLOCKLIST_GZ}" ]; then
		ss_status_set blocklist_backup_available "1"
	else
		ss_status_set blocklist_backup_available "0"
	fi

	if [ "${ss_initial_dnsmasq_restart}" = "1" ]; then
		dnsmasq_restart
		rc=$?
		case "$rc" in
			0)
				ss_status_set health_dnsmasq_initial_restart "1"
				;;
			130)
				ss_abort_refresh
				return $?
				;;
			*)
				log_error "Initial dnsmasq restart failed"
				ss_status_set health_dnsmasq_initial_restart "0"
				ss_status_mark_failure "initial_dnsmasq_restart_failed"
				ss_refresh_lock_close
				return 1
				;;
		esac
	else
		ss_status_set health_dnsmasq_initial_restart ""
	fi

	if ss_should_stop; then
		ss_abort_refresh
		return $?
	fi

	ss_status_set stage "resolve_api"
	ss_resolve_artifact
	rc=$?
	case "$rc" in
		0) ;;
		130)
			ss_abort_refresh
			return $?
			;;
		*)
			ss_status_mark_failure "api_resolve_failed"
			ss_restore_and_restart
			ss_refresh_lock_close
			return 1
			;;
	esac

	if ss_should_stop; then
		ss_abort_refresh
		return $?
	fi

	ss_status_set stage "download_artifact"
	ss_download_api_artifact
	rc=$?
	case "$rc" in
		0) ;;
		130)
			ss_abort_refresh
			return $?
			;;
		*)
			ss_status_mark_failure "artifact_download_failed"
			ss_restore_and_restart
			ss_refresh_lock_close
			return 1
			;;
	esac

	if ss_should_stop; then
		ss_abort_refresh
		return $?
	fi

	ss_status_set stage "local_overrides"
	if [ "$ss_apply_local_overrides" = "1" ]; then
		ss_build_local_allowlist
		ss_build_local_blocklist
	else
		: >"${SS_TMP_DIR}/local.allow.txt"
		: >"${SS_TMP_DIR}/local.block.txt"
	fi

	ss_build_allowlist || {
		log_error "Failed to build allowlist"
		ss_status_mark_failure "allowlist_build_failed"
		ss_restore_and_restart
		ss_refresh_lock_close
		return 1
	}

	if ss_should_stop; then
		ss_abort_refresh
		return $?
	fi

	ss_status_set stage "merge"
	ss_merge_lists
	rc=$?
	case "$rc" in
		0) ;;
		130)
			ss_abort_refresh
			return $?
			;;
		*)
			log_error "Failed to merge API artifact with local overrides"
			ss_status_mark_failure "merge_failed"
			ss_restore_and_restart
			ss_refresh_lock_close
			return 1
			;;
	esac

	if ss_should_stop; then
		ss_abort_refresh
		return $?
	fi

	ss_status_set stage "install"
	ss_install_blocklist || {
		log_error "Failed to install blocklist"
		ss_status_mark_failure "install_failed"
		ss_restore_and_restart
		ss_refresh_lock_close
		return 1
	}

	if ss_should_stop; then
		ss_abort_refresh
		return $?
	fi

	ss_status_set stage "restart_dnsmasq"
	dnsmasq_restart
	rc=$?
	case "$rc" in
		0)
			ss_status_set health_dnsmasq_final_restart "1"
			;;
		130)
			ss_abort_refresh
			return $?
			;;
		*)
			log_error "dnsmasq restart failed"
			ss_status_set health_dnsmasq_final_restart "0"
			ss_status_mark_failure "dnsmasq_restart_failed"
			ss_restore_and_restart
			ss_refresh_lock_close
			return 1
			;;
	esac

	if ss_should_stop; then
		ss_abort_refresh
		return $?
	fi

	ss_status_set stage "runtime_check"
	check_dns_runtime
	rc=$?
	case "$rc" in
		0)
			ss_status_set health_dns_runtime "1"
			;;
		130)
			ss_abort_refresh
			return $?
			;;
		*)
			log_error "DNS runtime check failed, restoring previous blocklist"
			ss_status_set health_dns_runtime "0"
			ss_status_mark_failure "dns_runtime_check_failed"
			ss_restore_and_restart
			ss_refresh_lock_close
			return 1
			;;
	esac

	if ss_should_stop; then
		ss_abort_refresh
		return $?
	fi

	ss_status_set stage "blocklist_verify"
	check_blocklist_applied_multi_with_stats 5 3
	rc=$?

	case "$rc" in
		0)
			log_ok "SafeShield applied successfully"
			ss_status_set health_blocklist_verify "1"
			ss_status_set blocklist_verification_ok "1"
			ss_status_mark_success
			rm -f "${SS_PREV_BLOCKLIST_GZ}" "${SS_INACTIVE_BLOCKLIST_FILE}"
			ss_status_set blocklist_backup_available "0"
			ss_refresh_lock_close
			return 0
			;;
		130)
			ss_abort_refresh
			return $?
			;;
		*)
			log_error "Blocklist verification failed, restoring previous blocklist"
			ss_status_set health_blocklist_verify "0"
			ss_status_set blocklist_verification_ok "0"
			ss_status_mark_failure "blocklist_verification_failed"
			ss_restore_and_restart
			ss_refresh_lock_close
			return 1
			;;
	esac
}
