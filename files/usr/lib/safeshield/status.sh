# shellcheck shell=ash

# Variables below are populated by sourced helpers and ss_load_config()
# shellcheck disable=SC2154

readonly SS_STATUS_STORE='/usr/lib/safeshield/status-store.uc'

ss_status_exec() {
	ucode "${SS_STATUS_STORE}" "${RUNNING_STATUS_FILE}" "$@"
}

ss_status_apply() {
	local tmp="${RUNNING_STATUS_FILE}.tmp"

	mkdir -p "${RUNNING_STATUS_FILE%/*}" || return 1

	ss_status_exec "$@" >"${tmp}" || {
		rm -f "${tmp}"
		return 1
	}

	[ -s "${tmp}" ] || {
		rm -f "${tmp}"
		return 1
	}

	mv -f "${tmp}" "${RUNNING_STATUS_FILE}" || {
		rm -f "${tmp}"
		return 1
	}

	return 0
}

is_enabled() {
	uci_get "$1" 'config' 'enabled' '0'
}

is_active() {
	local st

	st="$(jsonfilter -i "${RUNNING_STATUS_FILE}" -e '@.data.status' 2>/dev/null)"

	[ -n "$st" ] || return 1
	[ "$st" = 'statusStopped' ] && return 1
	[ "$st" = 'idle' ] && return 1

	return 0
}

ss_now() {
	date +%s
}

ss_status_set_now() {
	ss_status_set "$1" "$(ss_now)"
}

ss_status_set_source_field() {
	local section="$1"
	local field="$2"
	local value="$3"

	ss_status_set "source_${section}_${field}" "$value"
}

ss_status_reset_source_fields() {
	local section

	for section in $ss_file_url_sections; do
		ss_status_set_source_field "$section" name ""
		ss_status_set_source_field "$section" action ""
		ss_status_set_source_field "$section" enabled "0"
		ss_status_set_source_field "$section" url ""
		ss_status_set_source_field "$section" result ""
		ss_status_set_source_field "$section" line_count "0"
		ss_status_set_source_field "$section" size_kb "0"
	done
}

ss_status_reset_health_fields() {
	ss_status_set health_dnsmasq_binary ""
	ss_status_set health_dnsmasq_confdir ""
	ss_status_set health_dnsmasq_initial_restart ""
	ss_status_set health_dnsmasq_final_restart ""
	ss_status_set health_dns_runtime ""
	ss_status_set health_blocklist_verify ""
	ss_status_set health_min_valid_line_count ""
	ss_status_set health_max_file_size ""
	ss_status_set health_api_resolve ""
	ss_status_set health_artifact_download ""
	ss_status_set health_artifact_sha256 ""
}

ss_status_reset_blocklist_fields() {
	ss_status_set blocklist_installed "0"
	ss_status_set blocklist_file_size_kb "0"
	ss_status_set blocklist_verification_ok "0"
	ss_status_set blocklist_test_domain ""
	ss_status_set blocklist_test_domain_sample_count "0"
	ss_status_set blocklist_test_domain_success_count "0"
	ss_status_set blocklist_test_domains ""
	ss_status_set blocklist_backup_available "0"
}

ss_status_reset_artifact_fields() {
	ss_status_set license_plan ""
	ss_status_set license_status ""
	ss_status_set device_fingerprint ""
	ss_status_set device_profile ""
	ss_status_set artifact_tier ""
	ss_status_set artifact_version ""
	ss_status_set artifact_sha256 ""
	ss_status_set artifact_unique_domains "0"
	ss_status_set artifact_rules "0"
	ss_status_set artifact_download_url_present "0"
}

ss_status_mark_failure() {
	local code="$1"

	ss_status_set status "error"
	ss_status_set_now last_failure
	ss_status_set last_result "error"
	ss_status_set last_error_code "$code"
	ss_status_add_error "$code"
}

ss_status_mark_success() {
	ss_status_apply clear_messages >/dev/null 2>&1 || true
	ss_status_set status "ready"
	ss_status_set stage "done"
	ss_status_set_now last_success
	ss_status_set last_result "success"
	ss_status_set last_error_code ""
}

ss_status_set() {
	local key="$1"
	local value="$2"

	[ -n "$key" ] || return 0
	ss_status_apply set "$key" "$value" >/dev/null 2>&1 || true
}

ss_status_add_error() {
	local code="$1"

	[ -n "$code" ] || return 0
	ss_status_apply add_error "$code" >/dev/null 2>&1 || true
}

ss_status_add_warning() {
	local code="$1"

	[ -n "$code" ] || return 0
	ss_status_apply add_warning "$code" >/dev/null 2>&1 || true
}

ss_status_reset() {
	rm -f "${RUNNING_STATUS_FILE}" "${RUNNING_STATUS_FILE}.tmp"

	ss_status_apply reset >/dev/null 2>&1 || return 1

	ss_status_set status "idle"
	ss_status_set stage ""
	ss_status_set valid_line_count "0"

	ss_status_set last_result "idle"
	ss_status_set last_error_code ""
	ss_status_set last_attempt "0"
	ss_status_set last_success "0"
	ss_status_set last_failure "0"
	ss_status_set next_refresh_at "0"

	ss_status_reset_health_fields
	ss_status_reset_blocklist_fields
	ss_status_reset_artifact_fields
	ss_status_apply clear_messages >/dev/null 2>&1 || true
}

ss_blocklist_tmp_path() {
	printf '%s/.safeshield.blocklist.tmp.%s' "${SS_DNSMASQ_DIR}" "$$"
}

ss_backup_tmp_path() {
	printf '%s.tmp.%s' "${SS_PREV_BLOCKLIST_GZ}" "$$"
}

ss_sync_path() {
	local path="$1"

	[ -n "$path" ] || return 0

	sync -f "$path" 2>/dev/null && return 0
	sync "$path" 2>/dev/null && return 0
	sync 2>/dev/null || true
}

ss_install_blocklist_atomic() {
	local src="$1"
	local dst="$2"
	local dir

	[ -f "$src" ] || return 1
	[ -n "$dst" ] || return 1

	dir="${dst%/*}"

	ss_sync_path "$src"
	mv -f "$src" "$dst" || return 1
	ss_sync_path "$dir"

	return 0
}

ss_export_existing_blocklist() {
	local tmp

	[ -f "${SS_BLOCKLIST_FILE}" ] || return 1
	command_exists gzip || return 1

	tmp="$(ss_backup_tmp_path)" || return 1

	gzip -c "${SS_BLOCKLIST_FILE}" >"$tmp" || {
		rm -f "$tmp"
		return 1
	}

	ss_sync_path "$tmp"
	mv -f "$tmp" "${SS_PREV_BLOCKLIST_GZ}" || {
		rm -f "$tmp"
		return 1
	}
	ss_sync_path "${SS_PREV_BLOCKLIST_GZ%/*}"

	return 0
}

ss_restore_previous_blocklist() {
	local tmp

	[ -f "${SS_PREV_BLOCKLIST_GZ}" ] || return 1
	command_exists gunzip || return 1

	tmp="$(ss_blocklist_tmp_path)" || return 1

	gunzip -c "${SS_PREV_BLOCKLIST_GZ}" >"$tmp" || {
		rm -f "$tmp"
		return 1
	}

	ss_install_blocklist_atomic "$tmp" "${SS_BLOCKLIST_FILE}" || {
		rm -f "$tmp"
		return 1
	}

	return 0
}

ss_refresh_lock_open() {
	mkdir -p "${SS_REFRESH_LOCK%/*}" || return 1
	eval "exec ${SS_REFRESH_LOCK_FD}>\"${SS_REFRESH_LOCK}\"" || return 1
	flock -n "${SS_REFRESH_LOCK_FD}" || {
		eval "exec ${SS_REFRESH_LOCK_FD}>&-"
		return 1
	}
}

ss_refresh_lock_close() {
	flock -u "${SS_REFRESH_LOCK_FD}" 2>/dev/null || true
	eval "exec ${SS_REFRESH_LOCK_FD}>&-" 2>/dev/null || true
}
