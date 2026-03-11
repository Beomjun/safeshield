# shellcheck shell=sh

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

ss_filter_valid_domains() {
    grep -E '^[a-z0-9._-]+$'
}

ss_download_source() {
    local section="$1"
    local name enabled action url output raw
    local line_count size_kb retries ok

    enabled="$(ss_config_get "$section" enabled 0)"
    action="$(str_to_lower "$(ss_config_get "$section" action block)")"
    url="$(ss_config_get "$section" url '')"
    name="$(ss_config_get "$section" name "$section")"

    ss_status_set_source_field "$section" name "$name"
    ss_status_set_source_field "$section" action "$action"
    ss_status_set_source_field "$section" enabled "$enabled"
    ss_status_set_source_field "$section" url "$url"
    ss_status_set_source_field "$section" line_count "0"
    ss_status_set_source_field "$section" size_kb "0"

    if [ "$enabled" != "1" ]; then
        ss_status_set_source_field "$section" result "disabled"
        return 0
    fi

    if [ -z "$url" ]; then
        ss_status_set_source_field "$section" result "no_url"
        return 0
    fi

    case "$action" in
        block) raw="${SS_TMP_DIR}/${section}.block.txt" ;;
        allow) raw="${SS_TMP_DIR}/${section}.allow.txt" ;;
        *)
            log_warn "Unknown action '${action}' in section '${section}', skipping"
            ss_status_add_warning "unknown_action_${section}"
            ss_status_set_source_field "$section" result "unknown_action"
            return 0
            ;;
    esac

    output="${SS_TMP_DIR}/${section}.txt.raw"
    ok=0
    retries=1

    while [ "$retries" -le "$ss_download_retry" ]; do
        ss_should_stop && return 130

        log_info "Downloading [${action}] ${name} (try ${retries}/${ss_download_retry})"

        if uclient-fetch "$url" -O- --timeout="${ss_download_timeout}" \
            | head -c "${ss_max_blocklist_file_part_size_kb}k" > "$output"; then
            ok=1
            break
        fi

        ss_should_stop && return 130

        retries=$((retries + 1))
        sleep 1
    done

    if [ "$ok" != "1" ]; then
        log_warn "Download failed: ${name}"
        ss_status_add_warning "download_failed_${section}"
        ss_status_set_source_field "$section" result "download_failed"
        [ "$ss_download_failed_action" = "STOP" ] && return 1
        return 0
    fi

    ss_should_stop && return 130

    ss_normalize_domains < "$output" \
        | ss_filter_valid_domains \
        | sort -u > "$raw"

    line_count="$(grep -c . "$raw" 2>/dev/null)"
    size_kb="$(du -k "$raw" 2>/dev/null | awk '{print $1}')"

    [ -n "$line_count" ] || line_count=0
    [ -n "$size_kb" ] || size_kb=0

    ss_status_set_source_field "$section" line_count "$line_count"
    ss_status_set_source_field "$section" size_kb "$size_kb"

    if [ "$line_count" -lt "$ss_min_blocklist_file_part_line_count" ]; then
        log_warn "Downloaded ${name} but line count ${line_count} is below minimum ${ss_min_blocklist_file_part_line_count}"
        ss_status_add_warning "low_line_count_${section}"
        ss_status_set_source_field "$section" result "low_line_count"
        rm -f "$raw"
        [ "$ss_download_failed_action" = "STOP" ] && return 1
        return 0
    fi

    ss_status_set_source_field "$section" result "ok"
    log_ok "Downloaded ${name} (${line_count} lines, ${size_kb} KB)"
}

ss_build_local_allowlist() {
    local out="${SS_TMP_DIR}/local.allow.txt"

    : > "$out"

    if [ -f "${ss_local_allowlist_path}" ]; then
        ss_normalize_domains < "${ss_local_allowlist_path}" \
            | ss_filter_valid_domains \
            | sort -u >> "$out"
    fi
}

ss_build_local_blocklist() {
    local out="${SS_TMP_DIR}/local.block.txt"

    : > "$out"

    if [ -f "${ss_local_blocklist_path}" ]; then
        ss_normalize_domains < "${ss_local_blocklist_path}" \
            | ss_filter_valid_domains \
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
    local final
    local allowlist="${SS_TMP_DIR}/allowlist.txt"
    local final_size_kb
    local f

    final="$(ss_blocklist_tmp_path)" || return 1

    : > "$merged"
    : > "$final" || return 1

    for f in "${SS_TMP_DIR}"/*.block.txt; do
        ss_should_stop && {
            rm -f "$final"
            return 130
        }

        [ -f "$f" ] || continue
        cat "$f"
    done \
        | ss_filter_valid_domains \
        | sort -u > "$merged"

    ss_should_stop && {
        rm -f "$final"
        return 130
    }

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
        ' "$allowlist" "$merged" > "${merged}.filtered" || {
            rm -f "$final"
            return 1
        }

        mv "${merged}.filtered" "$merged" || {
            rm -f "$final"
            return 1
        }
    fi

    ss_should_stop && {
        rm -f "$final"
        return 130
    }

    awk '{
        print "address=/" $0 "/0.0.0.0"
        print "address=/" $0 "/::"
    }' "$merged" > "$final" || {
        rm -f "$final"
        return 1
    }

    if [ -s "$allowlist" ]; then
        awk '{ print "server=/" $0 "/#" }' "$allowlist" >> "$final" || {
            rm -f "$final"
            return 1
        }
    fi

    ss_should_stop && {
        rm -f "$final"
        return 130
    }

    ss_valid_line_count="$(grep -c . "$final" 2>/dev/null)"
    [ -n "$ss_valid_line_count" ] || ss_valid_line_count=0
    ss_status_set valid_line_count "$ss_valid_line_count"
    log_info "Final valid line count: ${ss_valid_line_count}"

    if [ "$ss_valid_line_count" -lt "$ss_min_valid_line_count" ]; then
        ss_status_set health_min_valid_line_count "0"
        log_error "valid line count below minimum: ${ss_valid_line_count} < ${ss_min_valid_line_count}"
        ss_status_add_error "valid_line_count_below_minimum"
        rm -f "$final"
        return 1
    fi
    ss_status_set health_min_valid_line_count "1"

    final_size_kb="$(du -k "$final" 2>/dev/null | awk '{print $1}')"
    [ -n "$final_size_kb" ] || final_size_kb=0
    ss_status_set blocklist_file_size_kb "$final_size_kb"

    if [ "$final_size_kb" -gt "$ss_max_blocklist_file_size_kb" ]; then
        ss_status_set health_max_file_size "0"
        log_error "final blocklist too large (${final_size_kb} KB > ${ss_max_blocklist_file_size_kb} KB)"
        ss_status_add_error "blocklist_too_large"
        rm -f "$final"
        return 1
    fi
    ss_status_set health_max_file_size "1"

    if [ "${ss_dnsmasq_sanity_check}" = "1" ]; then
        if ! dnsmasq --test --conf-file="$final" >/dev/null 2>&1; then
            log_error "dnsmasq --test failed"
            ss_status_add_error "dnsmasq_test_failed"
            rm -f "$final"
            return 1
        fi
    fi

    ss_should_stop && {
        rm -f "$final"
        return 130
    }

    ss_install_blocklist_atomic "$final" "${SS_BLOCKLIST_FILE}" || {
        rm -f "$final"
        return 1
    }

    ss_status_set blocklist_installed "1"
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

find_test_domains() {
    local limit="${1:-5}"

    [ -f "${SS_BLOCKLIST_FILE}" ] || return 1

    awk -F'/' '
        $1 == "address=" && ($3 == "0.0.0.0" || $3 == "::") {
            if (!seen[$2]++) {
                print $2
            }
        }
    ' "${SS_BLOCKLIST_FILE}" | head -n "$limit"
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

check_blocklist_applied_multi_with_stats() {
    local limit="${1:-5}"
    local min_success="${2:-2}"
    local domain
    local tested=0
    local success=0
    local first_domain=""
    local domains=""

    while read -r domain; do
        [ -n "$domain" ] || continue

        ss_should_stop && return 130

        tested=$((tested + 1))

        if [ -z "$first_domain" ]; then
            first_domain="$domain"
        fi

        if [ -n "$domains" ]; then
            domains="${domains},${domain}"
        else
            domains="$domain"
        fi

        if check_blocklist_applied_for_domain "$domain"; then
            success=$((success + 1))
        fi
    done <<EOF
$(find_test_domains "$limit")
EOF

    ss_status_set blocklist_test_domain_sample_count "$tested"
    ss_status_set blocklist_test_domain_success_count "$success"
    ss_status_set blocklist_test_domains "$domains"

    if [ -n "$first_domain" ]; then
        ss_status_set blocklist_test_domain "$first_domain"
    fi

    [ "$tested" -gt 0 ] || return 1
    [ "$success" -ge "$min_success" ]
}