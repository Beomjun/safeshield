# shellcheck shell=sh

# shellcheck disable=SC1091
. "${IPKG_INSTROOT}/usr/share/libubox/jshn.sh"
# shellcheck disable=SC1091
. "${IPKG_INSTROOT}/usr/lib/safeshield/utils.sh"
# shellcheck disable=SC1091
. "${IPKG_INSTROOT}/usr/lib/safeshield/status.sh"
# shellcheck disable=SC1091
. "${IPKG_INSTROOT}/usr/lib/safeshield/log.sh"

readonly SS_TMP_DIR="/tmp/safeshield"
readonly SS_DNSMASQ_DIR="/tmp/dnsmasq.d"
readonly SS_BLOCKLIST_FILE="${SS_DNSMASQ_DIR}/safeshield.blocklist"
readonly SS_PREV_BLOCKLIST_GZ="/tmp/safeshield.prev.blocklist.gz"
readonly SS_RUNTIME_OUT="${SS_TMP_DIR}/runtime.out"
readonly SS_REFRESH_LOCK='/var/lock/safeshield-refresh.lock'
readonly SS_REFRESH_LOCK_FD=307

ss_enabled="0"
ss_verbosity="2"
ss_dns="dnsmasq.conf"
ss_dnsmasq_instance="*"
ss_local_allowlist_path="/etc/safeshield/allowlist"
ss_local_blocklist_path="/etc/safeshield/blocklist"
ss_min_blocklist_file_part_line_count="1"
ss_max_blocklist_file_part_size_kb="20000"
ss_max_blocklist_file_size_kb="30000"
ss_min_good_line_count="100000"
ss_compress_blocklist="0"
ss_initial_dnsmasq_restart="0"
ss_rogue_element_action="SKIP_PARTIAL"
ss_download_failed_action="SKIP_PARTIAL"
ss_download_timeout="10"
ss_download_retry="3"
ss_parallel_downloads="0"
ss_pause_timeout="20"
ss_boot_start_delay_s="30"
ss_dnsmasq_sanity_check="1"
ss_debug="0"

ss_file_url_sections=""
ss_good_line_count="0"

ss_status_set() {
    json set "$1" "$2" >/dev/null 2>&1 || true
}

ss_status_add_error() {
    json add error "$1" >/dev/null 2>&1 || true
}

ss_status_add_warning() {
    json add warning "$1" >/dev/null 2>&1 || true
}

ss_status_reset() {
    ss_status_set status "idle"
    ss_status_set stage ""
    ss_status_set good_line_count "0"
}

ss_config_get() {
    local section="$1"
    local option="$2"
    local default="$3"
    local value

    config_get value "$section" "$option"
    if [ -n "$value" ]; then
        printf '%s' "$value"
    else
        printf '%s' "$default"
    fi
}

ss_collect_file_url_section() {
    [ -n "$ss_file_url_sections" ] && ss_file_url_sections="${ss_file_url_sections} "
    ss_file_url_sections="${ss_file_url_sections}$1"
}

ss_validate_bool() {
    local var_name="$1"
    local default="$2"
    local warning_code="$3"
    local value

    eval "value=\${$var_name}"

    case "$value" in
        0|1) return 0 ;;
    esac

    log_warn "Invalid ${var_name} '${value}', using default ${default}"
    ss_status_add_warning "$warning_code"
    eval "$var_name=\$default"
}

ss_validate_int() {
    local var_name="$1"
    local default="$2"
    local warning_code="$3"
    local value

    eval "value=\${$var_name}"

    if ! is_valid_integer "$value"; then
        log_warn "Invalid ${var_name} '${value}', using default ${default}"
        ss_status_add_warning "$warning_code"
        eval "$var_name=\$default"
    fi
}

ss_validate_config() {
    ss_validate_int ss_download_timeout 10 invalid_download_timeout
    ss_validate_int ss_download_retry 3 invalid_download_retry
    ss_validate_int ss_min_blocklist_file_part_line_count 1 invalid_min_blocklist_file_part_line_count
    ss_validate_int ss_max_blocklist_file_part_size_kb 20000 invalid_max_blocklist_file_part_size_kb
    ss_validate_int ss_max_blocklist_file_size_kb 30000 invalid_max_blocklist_file_size_kb
    ss_validate_int ss_min_good_line_count 100000 invalid_min_good_line_count
    ss_validate_int ss_pause_timeout 20 invalid_pause_timeout
    ss_validate_int ss_boot_start_delay_s 30 invalid_boot_start_delay_s

    ss_validate_bool ss_compress_blocklist 0 invalid_compress_blocklist
    ss_validate_bool ss_initial_dnsmasq_restart 0 invalid_initial_dnsmasq_restart
    ss_validate_bool ss_dnsmasq_sanity_check 1 invalid_dnsmasq_sanity_check
}

ss_load_config() {
    config_load safeshield || return 1

    ss_enabled="$(ss_config_get config enabled 0)"
    ss_verbosity="$(ss_config_get config verbosity 2)"
    ss_dns="$(ss_config_get config dns dnsmasq.conf)"
    ss_dnsmasq_instance="$(ss_config_get config dnsmasq_instance '*')"
    ss_local_allowlist_path="$(ss_config_get config local_allowlist_path /etc/safeshield/allowlist)"
    ss_local_blocklist_path="$(ss_config_get config local_blocklist_path /etc/safeshield/blocklist)"
    ss_min_blocklist_file_part_line_count="$(ss_config_get config min_blocklist_file_part_line_count 1)"
    ss_max_blocklist_file_part_size_kb="$(ss_config_get config max_blocklist_file_part_size_kb 20000)"
    ss_max_blocklist_file_size_kb="$(ss_config_get config max_blocklist_file_size_kb 30000)"
    ss_min_good_line_count="$(ss_config_get config min_good_line_count 100000)"
    ss_compress_blocklist="$(ss_config_get config compress_blocklist 0)"
    ss_initial_dnsmasq_restart="$(ss_config_get config initial_dnsmasq_restart 0)"
    ss_rogue_element_action="$(ss_config_get config rogue_element_action SKIP_PARTIAL)"
    ss_download_failed_action="$(ss_config_get config download_failed_action SKIP_PARTIAL)"
    ss_download_timeout="$(ss_config_get config download_timeout 10)"
    ss_download_retry="$(ss_config_get config download_retry 3)"
    ss_parallel_downloads="$(ss_config_get config parallel_downloads 0)"
    ss_pause_timeout="$(ss_config_get config pause_timeout 20)"
    ss_boot_start_delay_s="$(ss_config_get config boot_start_delay_s 30)"
    ss_dnsmasq_sanity_check="$(ss_config_get config dnsmasq_sanity_check 1)"
    ss_debug="$(ss_config_get config debug 0)"

    ss_file_url_sections=""
    config_foreach ss_collect_file_url_section file_url

    ss_validate_config
}

ss_mkdirs() {
    mkdir -p "${SS_TMP_DIR}" "${SS_DNSMASQ_DIR}"
}

ss_clean_tmp() {
    rm -f \
        "${SS_TMP_DIR}"/*.txt \
        "${SS_TMP_DIR}"/*.raw \
        "${SS_TMP_DIR}"/*.filtered \
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
            if nslookup "$domain" 127.0.0.1 > "${SS_RUNTIME_OUT}" 2>/dev/null; then
                if ! grep -Eq '^Address: *(0\.0\.0\.0|::)$' "${SS_RUNTIME_OUT}"; then
                    rm -f "${SS_RUNTIME_OUT}"
                    return 0
                fi
            fi
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

    for i in 1 2 3 4 5 6 7 8 9 10 \
             11 12 13 14 15 16 17 18 19 20 \
             21 22 23 24 25 26 27 28 29 30; do
        nslookup localhost 127.0.0.1 >/dev/null 2>&1 && break
        sleep 1
    done

    log_ok "dnsmasq restart done"
    return 0
}

ss_export_existing_blocklist() {
    [ -f "${SS_BLOCKLIST_FILE}" ] || return 1
    command_exists gzip || return 1

    gzip -c "${SS_BLOCKLIST_FILE}" > "${SS_PREV_BLOCKLIST_GZ}" || return 1
}

ss_restore_previous_blocklist() {
    [ -f "${SS_PREV_BLOCKLIST_GZ}" ] || return 1
    command_exists gunzip || return 1

    gunzip -c "${SS_PREV_BLOCKLIST_GZ}" > "${SS_BLOCKLIST_FILE}" || return 1
}

ss_normalize_domains() {
    sed \
        -e 'y/ABCDEFGHIJKLMNOPQRSTUVWXYZ/abcdefghijklmnopqrstuvwxyz/' \
        -e 's/\r$//' \
        -e 's/^[[:space:]]*//' \
        -e 's/[[:space:]]*$//' \
        -e '/^$/d' \
        -e '/^!/d' \
        -e '/^#/d' \
        -e 's/^0\.0\.0\.0[[:space:]][[:space:]]*//' \
        -e 's/^127\.0\.0\.1[[:space:]][[:space:]]*//' \
        -e 's#^local=/##' \
        -e 's#^address=/##' \
        -e 's#/0\.0\.0\.0$##' \
        -e 's#/::$##' \
        -e 's#/$##' \
        -e 's#^/##'
}

ss_is_valid_domain_stream() {
    grep -E '^[a-z0-9._-]+$'
}

ss_download_one_list() {
    local section="$1"
    local name enabled action url output raw
    local line_count size_kb retries ok

    enabled="$(ss_config_get "$section" enabled 0)"
    [ "$enabled" = "1" ] || return 0

    action="$(str_to_lower "$(ss_config_get "$section" action block)")"
    url="$(ss_config_get "$section" url '')"
    name="$(ss_config_get "$section" name "$section")"

    [ -n "$url" ] || return 0

    case "$action" in
        block) raw="${SS_TMP_DIR}/${section}.block.txt" ;;
        allow) raw="${SS_TMP_DIR}/${section}.allow.txt" ;;
        *)
            log_warn "Unknown action '${action}' in section '${section}', skipping"
            ss_status_add_warning "unknown_action_${section}"
            return 0
            ;;
    esac

    output="${SS_TMP_DIR}/${section}.txt.raw"
    ok=0
    retries=1

    while [ "$retries" -le "$ss_download_retry" ]; do
        log_info "Downloading [${action}] ${name} (try ${retries}/${ss_download_retry})"

        if uclient-fetch "$url" -O- --timeout="${ss_download_timeout}" \
            | head -c "${ss_max_blocklist_file_part_size_kb}k" > "$output"; then
            ok=1
            break
        fi

        retries=$((retries + 1))
        sleep 1
    done

    if [ "$ok" != "1" ]; then
        log_warn "Download failed: ${name}"
        ss_status_add_warning "download_failed_${section}"
        [ "$ss_download_failed_action" = "STOP" ] && return 1
        return 0
    fi

    ss_normalize_domains < "$output" \
        | ss_is_valid_domain_stream \
        | sort -u > "$raw"

    line_count="$(grep -c . "$raw" 2>/dev/null)"
    size_kb="$(du -k "$raw" 2>/dev/null | awk '{print $1}')"

    if [ -z "$size_kb" ]; then
        size_kb=0
    fi

    if [ "$line_count" -lt "$ss_min_blocklist_file_part_line_count" ]; then
        log_warn "Downloaded ${name} but line count ${line_count} is below minimum ${ss_min_blocklist_file_part_line_count}"
        ss_status_add_warning "low_line_count_${section}"
        rm -f "$raw"
        [ "$ss_download_failed_action" = "STOP" ] && return 1
        return 0
    fi

    log_ok "Downloaded ${name} (${line_count} lines, ${size_kb} KB)"
}

ss_build_local_allowlist() {
    local out="${SS_TMP_DIR}/local.allow.txt"

    : > "$out"

    if [ -f "${ss_local_allowlist_path}" ]; then
        ss_normalize_domains < "${ss_local_allowlist_path}" \
            | ss_is_valid_domain_stream \
            | sort -u >> "$out"
    fi
}

ss_build_local_blocklist() {
    local out="${SS_TMP_DIR}/local.block.txt"

    : > "$out"

    if [ -f "${ss_local_blocklist_path}" ]; then
        ss_normalize_domains < "${ss_local_blocklist_path}" \
            | ss_is_valid_domain_stream \
            | sort -u >> "$out"
    fi
}

ss_build_allowlist() {
    local merged_allow="${SS_TMP_DIR}/allowlist.txt"
    local f

    : > "$merged_allow"

    for f in "${SS_TMP_DIR}"/*.allow.txt; do
        [ -f "$f" ] || continue
        cat "$f"
    done | sort -u > "$merged_allow"
}

ss_merge_lists() {
    local merged="${SS_TMP_DIR}/merged-domains.txt"
    local final="${SS_TMP_DIR}/final-dnsmasq.conf"
    local allowlist="${SS_TMP_DIR}/allowlist.txt"
    local final_size_kb
    local f

    : > "$merged"

    for f in "${SS_TMP_DIR}"/*.block.txt; do
        [ -f "$f" ] || continue
        cat "$f"
    done \
        | ss_is_valid_domain_stream \
        | sort -u > "$merged"

    if [ -s "$allowlist" ]; then
        awk '
            NR == FNR {
                allow[$0] = 1
                next
            }
            {
                n = split($0, arr, ".")
                cur = arr[n]
                for (i = n - 1; i >= 1; i--) {
                    cur = arr[i] "." cur
                    if (allow[cur]) next
                }
                print
            }
        ' "$allowlist" "$merged" > "${merged}.filtered" || return 1

        mv "${merged}.filtered" "$merged" || return 1
    fi

    : > "$final"

    awk '{
        print "address=/" $0 "/0.0.0.0"
        print "address=/" $0 "/::"
    }' "$merged" > "$final" || return 1

    if [ -s "$allowlist" ]; then
        awk '{ print "server=/" $0 "/#" }' "$allowlist" >> "$final" || return 1
    fi

    ss_good_line_count="$(grep -c . "$final" 2>/dev/null)"
    ss_status_set good_line_count "$ss_good_line_count"
    log_info "Final good line count: ${ss_good_line_count}"

    if [ "$ss_good_line_count" -lt "$ss_min_good_line_count" ]; then
        log_error "good line count below minimum: ${ss_good_line_count} < ${ss_min_good_line_count}"
        ss_status_add_error "good_line_count_below_minimum"
        return 1
    fi

    final_size_kb="$(du -k "$final" 2>/dev/null | awk '{print $1}')"
    if [ -z "$final_size_kb" ]; then
        final_size_kb=0
    fi

    if [ "$final_size_kb" -gt "$ss_max_blocklist_file_size_kb" ]; then
        log_error "final blocklist too large (${final_size_kb} KB > ${ss_max_blocklist_file_size_kb} KB)"
        ss_status_add_error "blocklist_too_large"
        return 1
    fi

    if [ "${ss_dnsmasq_sanity_check}" = "1" ]; then
        if ! dnsmasq --test --conf-file="$final" >/dev/null 2>&1; then
            log_error "dnsmasq --test failed"
            ss_status_add_error "dnsmasq_test_failed"
            return 1
        fi
    fi

    mv "$final" "${SS_BLOCKLIST_FILE}" || return 1
}

ss_install_blocklist() {
    if [ "${ss_compress_blocklist}" = "1" ]; then
        log_warn "compress_blocklist=1 is not implemented in this revision, using uncompressed blocklist"
        ss_status_add_warning "compress_blocklist_not_implemented"
    fi

    [ -f "${SS_BLOCKLIST_FILE}" ] || return 1
}

check_blocklist_rule_present() {
    local domain="$1"

    [ -n "$domain" ] || return 1
    [ -f "${SS_BLOCKLIST_FILE}" ] || return 1

    awk -F'/' -v d="$domain" '
        $1 == "address=" && $2 == d && ($3 == "0.0.0.0" || $3 == "::") {
            found = 1
        }
        END {
            exit(found ? 0 : 1)
        }
    ' "${SS_BLOCKLIST_FILE}"
}

check_domain_blocked() {
    local domain="$1"

    [ -n "$domain" ] || return 1

    nslookup "$domain" 127.0.0.1 2>/dev/null \
        | grep -Eq '^Address: *(0\.0\.0\.0|::)$'
}

check_blocklist_applied_for_domain() {
    local domain="$1"

    check_blocklist_rule_present "$domain" || return 1
    check_domain_blocked "$domain" || return 1
}

find_first_test_domain() {
    [ -f "${SS_BLOCKLIST_FILE}" ] || return 1

    awk -F'/' '
        $1 == "address=" && ($3 == "0.0.0.0" || $3 == "::") {
            print $2
            exit
        }
    ' "${SS_BLOCKLIST_FILE}"
}

check_blocklist_applied() {
    local domain="${1:-}"
    local test_domain

    if [ -n "$domain" ]; then
        check_blocklist_applied_for_domain "$domain"
        return $?
    fi

    test_domain="$(find_first_test_domain)"
    [ -n "$test_domain" ] || return 1

    check_blocklist_applied_for_domain "$test_domain"
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

ss_restore_and_restart() {
    ss_restore_previous_blocklist >/dev/null 2>&1 || true
    dnsmasq_restart >/dev/null 2>&1 || true
}

safeshield_force_download() {
    local section

    if ! ss_refresh_lock_open; then
        log_warn "Another refresh is already running, skipping"
        ss_status_add_warning "refresh_already_running"
        return 0
    fi

    ss_status_reset
    ss_status_set status "running"
    ss_status_set stage "init"

    ss_load_config || {
        ss_status_set status "error"
        ss_status_add_error "config_load_failed"
        ss_refresh_lock_close
        return 1
    }

    ss_mkdirs || {
        ss_status_set status "error"
        ss_status_add_error "mkdir_failed"
        ss_refresh_lock_close
        return 1
    }

    ss_clean_tmp

    check_dnsmasq_binary || {
        log_error "dnsmasq binary not found"
        ss_status_set status "error"
        ss_status_add_error "dnsmasq_binary_not_found"
        ss_refresh_lock_close
        return 1
    }

    ss_check_dnsmasq_confdir || {
        log_error "dnsmasq confdir is not set to ${SS_DNSMASQ_DIR}"
        log_error "Set: uci set dhcp.@dnsmasq[0].confdir='${SS_DNSMASQ_DIR}' && uci commit dhcp"
        ss_status_set status "error"
        ss_status_add_error "dnsmasq_confdir_not_set"
        ss_refresh_lock_close
        return 1
    }

    ss_export_existing_blocklist >/dev/null 2>&1 || true

    if [ "${ss_initial_dnsmasq_restart}" = "1" ]; then
        dnsmasq_restart || {
            log_error "Initial dnsmasq restart failed"
            ss_status_set status "error"
            ss_status_add_error "initial_dnsmasq_restart_failed"
            ss_refresh_lock_close
            return 1
        }
    fi

    ss_status_set stage "prepare"
    ss_build_local_allowlist
    ss_build_local_blocklist

    ss_status_set stage "download"
    for section in $ss_file_url_sections; do
        ss_download_one_list "$section" || {
            log_error "Aborting because a required list failed"
            ss_status_set status "error"
            ss_status_add_error "required_list_failed"
            ss_restore_and_restart
            ss_refresh_lock_close
            return 1
        }
    done

    ss_status_set stage "allowlist"
    ss_build_allowlist || {
        log_error "Failed to build allowlist"
        ss_status_set status "error"
        ss_status_add_error "allowlist_build_failed"
        ss_restore_and_restart
        ss_refresh_lock_close
        return 1
    }

    ss_status_set stage "merge"
    ss_merge_lists || {
        log_error "Failed to merge lists"
        ss_status_set status "error"
        ss_status_add_error "merge_failed"
        ss_restore_and_restart
        ss_refresh_lock_close
        return 1
    }

    ss_status_set stage "install"
    ss_install_blocklist || {
        log_error "Failed to install blocklist"
        ss_status_set status "error"
        ss_status_add_error "install_failed"
        ss_restore_and_restart
        ss_refresh_lock_close
        return 1
    }

    ss_status_set stage "restart_dnsmasq"
    dnsmasq_restart || {
        log_error "dnsmasq restart failed"
        ss_status_set status "error"
        ss_status_add_error "dnsmasq_restart_failed"
        ss_restore_and_restart
        ss_refresh_lock_close
        return 1
    }

    ss_status_set stage "runtime_check"
    if ! check_dns_runtime; then
        log_error "DNS runtime check failed, restoring previous blocklist"
        ss_status_set status "error"
        ss_status_add_error "dns_runtime_check_failed"
        ss_restore_and_restart
        ss_refresh_lock_close
        return 1
    fi

    ss_status_set stage "blocklist_verify"
    if check_blocklist_applied; then
        log_ok "SafeShield applied successfully"
        ss_status_set status "ready"
        ss_status_set stage "done"
        rm -f "${SS_PREV_BLOCKLIST_GZ}"
        ss_refresh_lock_close
        return 0
    fi

    log_error "Blocklist verification failed, restoring previous blocklist"
    ss_status_set status "error"
    ss_status_add_error "blocklist_verification_failed"
    ss_restore_and_restart
    ss_refresh_lock_close
    return 1
}