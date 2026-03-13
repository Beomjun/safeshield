# shellcheck shell=sh

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
. "${IPKG_INSTROOT}/usr/lib/safeshield/dns.sh"
# shellcheck disable=SC1091
. "${IPKG_INSTROOT}/usr/lib/safeshield/blocklist.sh"

readonly SS_TMP_DIR="/tmp/safeshield"
readonly SS_DNSMASQ_DIR="/tmp/dnsmasq.d"
readonly SS_BLOCKLIST_FILE="${SS_DNSMASQ_DIR}/safeshield.blocklist"
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

safeshield_force_download() {
    local section
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

    if ss_should_stop; then
        ss_abort_refresh
        return $?
    fi

    ss_status_reset_source_fields

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

    ss_check_dnsmasq_confdir || {
        log_error "dnsmasq confdir is not set to ${SS_DNSMASQ_DIR}"
        log_error "Set: uci set dhcp.@dnsmasq[0].confdir='${SS_DNSMASQ_DIR}' && uci commit dhcp"
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

    ss_status_set stage "prepare"
    ss_build_local_allowlist
    ss_build_local_blocklist

    if ss_should_stop; then
        ss_abort_refresh
        return $?
    fi

    ss_status_set stage "download"
    for section in $ss_file_url_sections; do
        ss_download_source "$section"
        rc=$?

        case "$rc" in
            0)
                ;;
            130)
                ss_abort_refresh
                return $?
                ;;
            *)
                log_error "Aborting because a required list failed"
                ss_status_mark_failure "required_list_failed"
                ss_restore_and_restart
                ss_refresh_lock_close
                return 1
                ;;
        esac
    done

    if ss_should_stop; then
        ss_abort_refresh
        return $?
    fi

    ss_status_set stage "allowlist"
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
        0)
            ;;
        130)
            ss_abort_refresh
            return $?
            ;;
        *)
            log_error "Failed to merge lists"
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
            rm -f "${SS_PREV_BLOCKLIST_GZ}"
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