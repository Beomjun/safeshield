# shellcheck shell=ash

# Variables below are populated by sourced helpers and ss_load_config()
# shellcheck disable=SC2154

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

ss_json_escape() {
	printf '%s' "$1" | tr -d '\r\n' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

ss_json_value() {
	printf '"%s"' "$(ss_json_escape "$1")"
}

ss_json_get_file() {
	local file="$1"
	local expr="$2"

	jsonfilter -i "$file" -e "$expr" 2>/dev/null | head -n 1
}

ss_detect_device_model() {
	local value

	[ -n "$ss_device_model" ] && {
		printf '%s' "$ss_device_model"
		return 0
	}

	value="$(ubus call system board 2>/dev/null | jsonfilter -e '@.model' 2>/dev/null | head -n 1)"
	[ -n "$value" ] || value="$(cat /tmp/sysinfo/model 2>/dev/null)"
	[ -n "$value" ] || value="OpenWrt"

	printf '%s' "$value"
}

ss_detect_device_vendor() {
	local model="$1"
	local value

	[ -n "$ss_device_vendor" ] && {
		printf '%s' "$ss_device_vendor"
		return 0
	}

	value="$(printf '%s\n' "$model" | awk '{print $1}')"
	[ -n "$value" ] || value="OpenWrt"

	printf '%s' "$value"
}

ss_detect_device_arch() {
	local value

	[ -n "$ss_device_arch" ] && {
		printf '%s' "$ss_device_arch"
		return 0
	}

	if [ -r /etc/openwrt_release ]; then
		# shellcheck disable=SC1091
		. /etc/openwrt_release
		value="${DISTRIB_ARCH:-}"
	fi

	[ -n "$value" ] || value="$(uname -m 2>/dev/null)"
	[ -n "$value" ] || value="unknown"

	printf '%s' "$value"
}

ss_detect_device_memory_mb() {
	local value

	[ -n "$ss_device_memory_mb" ] && {
		printf '%s' "$ss_device_memory_mb"
		return 0
	}

	value="$(awk '/MemTotal:/ { printf "%d", ($2 + 1023) / 1024 }' /proc/meminfo 2>/dev/null)"
	[ -n "$value" ] || value="0"

	printf '%s' "$value"
}

ss_detect_primary_mac() {
	local iface mac

	for iface in br-lan eth0 wan lan wlan0; do
		mac="$(cat "/sys/class/net/${iface}/address" 2>/dev/null)"
		case "$mac" in
			'' | 00:00:00:00:00:00) ;;
			*)
				printf '%s' "$mac"
				return 0
				;;
		esac
	done

	ip link 2>/dev/null | awk '/link\/ether/ { print $2; exit }'
}

ss_get_or_create_device_fingerprint() {
	local model="$1"
	local arch="$2"
	local mac value material

	[ -n "$ss_device_fingerprint" ] && {
		printf '%s' "$ss_device_fingerprint"
		return 0
	}

	if [ -s "$SS_DEVICE_ID_FILE" ]; then
		value="$(cat "$SS_DEVICE_ID_FILE" 2>/dev/null | head -n 1)"
		[ -n "$value" ] && {
			printf '%s' "$value"
			return 0
		}
	fi

	mac="$(ss_detect_primary_mac)"
	material="${model}|${arch}|${mac}|$(cat /etc/openwrt_release 2>/dev/null)"

	if command_exists sha256sum; then
		value="$(printf '%s' "$material" | sha256sum | awk '{print $1}')"
	else
		value="${model}-${arch}-${mac}"
	fi

	mkdir -p "${SS_DEVICE_ID_FILE%/*}" >/dev/null 2>&1 || true
	printf '%s\n' "$value" >"$SS_DEVICE_ID_FILE" 2>/dev/null || true
	chmod 0600 "$SS_DEVICE_ID_FILE" 2>/dev/null || true

	printf '%s' "$value"
}

ss_write_resolve_payload() {
	local out="$1"
	local model vendor arch memory fingerprint

	model="$(ss_detect_device_model)"
	vendor="$(ss_detect_device_vendor "$model")"
	arch="$(ss_detect_device_arch)"
	memory="$(ss_detect_device_memory_mb)"
	fingerprint="$(ss_get_or_create_device_fingerprint "$model" "$arch")"

	is_valid_integer "$memory" || memory="0"

	cat >"$out" <<EOF
{"license_key":$(ss_json_value "$ss_license_key"),"device":{"fingerprint":$(ss_json_value "$fingerprint"),"vendor":$(ss_json_value "$vendor"),"model":$(ss_json_value "$model"),"arch":$(ss_json_value "$arch"),"memory_mb":${memory},"safeshield_version":$(ss_json_value "${PKG_VERSION:-unknown}")}}
EOF

	ss_status_set device_fingerprint "$fingerprint"
}

ss_uclient_supports() {
	uclient-fetch --help 2>&1 | grep -q -- "$1"
}

ss_http_post_json() {
	local url="$1"
	local payload="$2"
	local out="$3"
	local data

	if command_exists curl; then
		curl -fsS \
			--connect-timeout "$ss_download_timeout" \
			--max-time "$ss_download_timeout" \
			-H 'Content-Type: application/json' \
			-H 'Accept: application/json' \
			--data-binary "@${payload}" \
			-o "$out" \
			"$url"
		return $?
	fi

	command_exists uclient-fetch || return 1

	if ss_uclient_supports '--post-file' && ss_uclient_supports '--header'; then
		uclient-fetch "$url" -O "$out" --timeout="${ss_download_timeout}" \
			--header='Content-Type: application/json' \
			--header='Accept: application/json' \
			--post-file="$payload"
		return $?
	fi

	if ss_uclient_supports '--post-file'; then
		uclient-fetch "$url" -O "$out" --timeout="${ss_download_timeout}" --post-file="$payload"
		return $?
	fi

	if ss_uclient_supports '--post-data'; then
		data="$(cat "$payload")"
		if ss_uclient_supports '--header'; then
			uclient-fetch "$url" -O "$out" --timeout="${ss_download_timeout}" \
				--header='Content-Type: application/json' \
				--header='Accept: application/json' \
				--post-data="$data"
		else
			uclient-fetch "$url" -O "$out" --timeout="${ss_download_timeout}" --post-data="$data"
		fi
		return $?
	fi

	return 1
}

ss_http_get_file() {
	local url="$1"
	local out="$2"

	if command_exists curl; then
		curl -fLSs \
			--connect-timeout "$ss_download_timeout" \
			--max-time "$ss_download_timeout" \
			-o "$out" \
			"$url"
		return $?
	fi

	command_exists uclient-fetch || return 1
	uclient-fetch "$url" -O "$out" --timeout="${ss_download_timeout}"
}

ss_resolve_artifact() {
	local url response payload retries ok

	if [ -z "$ss_license_key" ]; then
		log_error "license_key is required for Hub API resolve"
		ss_status_add_error "license_key_missing"
		return 1
	fi

	url='https://www.smartsafehub.com/api/v1/licenses/resolve'
	payload="$SS_API_PAYLOAD"
	response="$SS_API_RESPONSE"

	ss_status_set artifact_download_url_present "0"

	ss_write_resolve_payload "$payload" || return 1

	retries=1
	ok=0
	while [ "$retries" -le "$ss_download_retry" ]; do
		ss_should_stop && return 130
		log_info "Resolving SafeShield artifact via Hub API (try ${retries}/${ss_download_retry})"

		if ss_http_post_json "$url" "$payload" "$response" && [ -s "$response" ]; then
			ok=1
			break
		fi

		ss_should_stop && return 130
		retries=$((retries + 1))
		sleep 1
	done

	if [ "$ok" != "1" ]; then
		log_error "Hub API resolve failed"
		ss_status_set health_api_resolve "0"
		ss_status_add_error "api_resolve_failed"
		return 1
	fi

	ss_resolved_download_url="$(ss_json_get_file "$response" '@.artifact.download_url')"
	ss_resolved_artifact_sha256="$(ss_json_get_file "$response" '@.artifact.sha256')"
	ss_resolved_artifact_tier="$(ss_json_get_file "$response" '@.artifact.tier')"
	ss_resolved_artifact_version="$(ss_json_get_file "$response" '@.artifact.version')"
	ss_resolved_artifact_unique_domains="$(ss_json_get_file "$response" '@.artifact.unique_domains')"
	ss_resolved_artifact_rules="$(ss_json_get_file "$response" '@.artifact.rules')"
	ss_resolved_license_plan="$(ss_json_get_file "$response" '@.license.plan')"
	ss_resolved_license_status="$(ss_json_get_file "$response" '@.license.status')"
	ss_resolved_device_profile="$(ss_json_get_file "$response" '@.device.profile')"

	if [ -z "$ss_resolved_download_url" ]; then
		log_error "Hub API response did not include artifact.download_url"
		ss_status_set health_api_resolve "0"
		ss_status_add_error "api_response_missing_download_url"
		return 1
	fi

	ss_status_set health_api_resolve "1"
	ss_status_set artifact_download_url_present "1"
	ss_status_set artifact_sha256 "$ss_resolved_artifact_sha256"
	ss_status_set artifact_tier "$ss_resolved_artifact_tier"
	ss_status_set artifact_version "$ss_resolved_artifact_version"
	ss_status_set artifact_unique_domains "${ss_resolved_artifact_unique_domains:-0}"
	ss_status_set artifact_rules "${ss_resolved_artifact_rules:-0}"
	ss_status_set license_plan "$ss_resolved_license_plan"
	ss_status_set license_status "$ss_resolved_license_status"
	ss_status_set device_profile "$ss_resolved_device_profile"

	log_ok "Resolved artifact ${ss_resolved_artifact_tier:-unknown}/${ss_resolved_artifact_version:-unknown}"
}

ss_verify_artifact_sha256() {
	local file="$1"
	local expected="$2"
	local actual

	case "$expected" in
		'' | '...')
			ss_status_set health_artifact_sha256 ""
			return 0
			;;
	esac

	command_exists sha256sum || {
		log_warn "sha256sum not found; skipping artifact checksum verification"
		ss_status_add_warning "sha256sum_not_found"
		ss_status_set health_artifact_sha256 ""
		return 0
	}

	actual="$(sha256sum "$file" 2>/dev/null | awk '{print $1}')"
	if [ "$actual" != "$expected" ]; then
		log_error "Artifact sha256 mismatch"
		ss_status_set health_artifact_sha256 "0"
		ss_status_add_error "artifact_sha256_mismatch"
		return 1
	fi

	ss_status_set health_artifact_sha256 "1"
	return 0
}

ss_download_api_artifact() {
	local output raw_size_kb line_count retries ok

	output="$SS_ARTIFACT_RAW"
	retries=1
	ok=0

	while [ "$retries" -le "$ss_download_retry" ]; do
		ss_should_stop && return 130
		log_info "Downloading SafeShield artifact (try ${retries}/${ss_download_retry})"

		if ss_http_get_file "$ss_resolved_download_url" "$output" && [ -s "$output" ]; then
			ok=1
			break
		fi

		ss_should_stop && return 130
		retries=$((retries + 1))
		sleep 1
	done

	if [ "$ok" != "1" ]; then
		log_error "Artifact download failed"
		ss_status_set health_artifact_download "0"
		ss_status_add_error "artifact_download_failed"
		return 1
	fi

	raw_size_kb="$(du -k "$output" 2>/dev/null | awk '{print $1}')"
	[ -n "$raw_size_kb" ] || raw_size_kb=0

	if [ "$raw_size_kb" -gt "$ss_max_blocklist_file_size_kb" ]; then
		log_error "downloaded artifact too large (${raw_size_kb} KB > ${ss_max_blocklist_file_size_kb} KB)"
		ss_status_set health_artifact_download "0"
		ss_status_add_error "artifact_too_large"
		rm -f "$output"
		return 1
	fi

	ss_verify_artifact_sha256 "$output" "$ss_resolved_artifact_sha256" || {
		rm -f "$output"
		return 1
	}

	ss_normalize_domains <"$output" |
		ss_filter_valid_domains |
		sort -u >"$SS_ARTIFACT_DOMAINS"

	line_count="$(grep -c . "$SS_ARTIFACT_DOMAINS" 2>/dev/null)"
	[ -n "$line_count" ] || line_count=0

	ss_status_set health_artifact_download "1"
	log_ok "Downloaded artifact (${line_count} unique domains, ${raw_size_kb} KB raw)"
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

		if uclient-fetch "$url" -O- --timeout="${ss_download_timeout}" 2>/dev/null |
			head -c "${ss_max_blocklist_file_size_kb}k" >"$output"; then
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
		return 0
	fi

	ss_should_stop && return 130

	ss_normalize_domains <"$output" |
		ss_filter_valid_domains |
		sort -u >"$raw"

	line_count="$(grep -c . "$raw" 2>/dev/null)"
	size_kb="$(du -k "$raw" 2>/dev/null | awk '{print $1}')"

	[ -n "$line_count" ] || line_count=0
	[ -n "$size_kb" ] || size_kb=0

	ss_status_set_source_field "$section" line_count "$line_count"
	ss_status_set_source_field "$section" size_kb "$size_kb"

	ss_status_set_source_field "$section" result "ok"
	log_ok "Downloaded ${name} (${line_count} lines, ${size_kb} KB)"
}

ss_build_local_allowlist() {
	local out="${SS_TMP_DIR}/local.allow.txt"

	: >"$out"

	if [ -f "${ss_local_allowlist_path}" ]; then
		ss_normalize_domains <"${ss_local_allowlist_path}" |
			ss_filter_valid_domains |
			sort -u >>"$out"
	fi
}

ss_build_local_blocklist() {
	local out="${SS_TMP_DIR}/local.block.txt"

	: >"$out"

	if [ -f "${ss_local_blocklist_path}" ]; then
		ss_normalize_domains <"${ss_local_blocklist_path}" |
			ss_filter_valid_domains |
			sort -u >>"$out"
	fi
}

ss_build_allowlist() {
	local merged_allow="${SS_TMP_DIR}/allowlist.txt"
	local f

	: >"$merged_allow"

	for f in "${SS_TMP_DIR}"/*.allow.txt; do
		[ -f "$f" ] || continue
		cat "$f"
	done | sort -u >"$merged_allow"
}

ss_merge_lists() {
	local final
	local allowlist="${SS_TMP_DIR}/allowlist.txt"
	local final_size_kb
	local valid_count
	local have_blocks=0
	local i

	final="$(ss_blocklist_tmp_path)" || return 1
	: >"$final" || return 1

	for i in "${SS_TMP_DIR}"/*.block.txt; do
		ss_should_stop && {
			rm -f "$final"
			return 130
		}

		[ -f "$i" ] || continue
		have_blocks=1
		break
	done

	if [ "$have_blocks" -eq 1 ]; then
		if [ -s "$allowlist" ]; then
			awk '
                FNR == NR {
                    allow[$0] = 1
                    next
                }

                /^[a-z0-9._-]+$/ {
                    if (seen[$0]++) {
                        next
                    }

                    n = split($0, arr, ".")
                    cur = arr[n]

                    for (i = n - 1; i >= 1; i--) {
                        cur = arr[i] "." cur
                        if (allow[cur]) {
                            next
                        }
                    }

                    print "address=/" $0 "/0.0.0.0"
                    print "address=/" $0 "/::"
                }
            ' "$allowlist" "${SS_TMP_DIR}"/*.block.txt >"$final" || {
				rm -f "$final"
				return 1
			}
		else
			awk '
                /^[a-z0-9._-]+$/ {
                    if (seen[$0]++) {
                        next
                    }

                    print "address=/" $0 "/0.0.0.0"
                    print "address=/" $0 "/::"
                }
            ' "${SS_TMP_DIR}"/*.block.txt >"$final" || {
				rm -f "$final"
				return 1
			}
		fi
	fi

	ss_should_stop && {
		rm -f "$final"
		return 130
	}

	if [ -s "$allowlist" ]; then
		awk '{ print "server=/" $0 "/#" }' "$allowlist" >>"$final" || {
			rm -f "$final"
			return 1
		}
	fi

	ss_should_stop && {
		rm -f "$final"
		return 130
	}

	valid_count="$(grep -c . "$final" 2>/dev/null)"
	[ -n "$valid_count" ] || valid_count=0
	ss_valid_line_count="$valid_count"
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

	nslookup "$domain" 127.0.0.1 2>/dev/null |
		grep -Eq '^Address: *(0\.0\.0\.0|::)$'
}

check_blocklist_applied_for_domain() {
	local domain="$1"

	check_blocklist_rule_present "$domain" || return 1
	check_domain_blocked "$domain" || return 1
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
