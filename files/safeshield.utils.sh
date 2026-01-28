# shellcheck shell=sh

# shellcheck disable=SC3060
str_contains() { [ "${1//$2}" != "$1" ]; }

str_contains_word() { echo "$1" | grep -qw "$2"; }

str_first_word() { echo "${1%% *}"; }

# shellcheck disable=SC2018,SC2019
str_to_lower() { echo "$1" | tr 'A-Z' 'a-z'; }

# shellcheck disable=SC2018,SC2019
str_to_upper() { echo "$1" | tr 'a-z' 'A-Z'; }

# shellcheck disable=SC3060
str_replace() { echo "${1//$2/$3}"; }

command_exists() { command -v "$1" >/dev/null 2>&1; }

is_valid_integer() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$1" -ge 1 ] 2>/dev/null && [ "$1" -le 65535 ] 2>/dev/null
}
is_greater() {
    [ "$#" -eq 2 ] || return 2
    [ "$1" != "$2" ] || return 1
    [ "$(printf '%s\n' "$1" "$2" | sort -V | tail -n 1)" = "$1" ]
}
is_greater_equal() {
    [ "$#" -eq 2 ] || return 2
    [ "$(printf '%s\n' "$1" "$2" | sort -V | tail -n 1)" = "$1" ]
}

json() {
    local action="$1" key="$2"
    shift 2 2>/dev/null
    local value="$*"

    local rc=0

    mkdir -p "${RUNNING_STATUS_LOCK%/*}" || rc=1

    if [ "$rc" -eq 0 ]; then
        eval "exec ${LOCK_FD}>\"${RUNNING_STATUS_LOCK}\"" || rc=1
    fi

    if [ "$rc" -eq 0 ]; then
        flock -x "${LOCK_FD}" || rc=1
    fi

    if [ "$rc" -eq 0 ]; then
        mkdir -p "${RUNNING_STATUS_FILE%/*}" || rc=1
    fi

    if [ "$rc" -eq 0 ]; then
        if ! json_load_file "$RUNNING_STATUS_FILE" 2>/dev/null; then
            json_init
        fi

        json_select data 2>/dev/null || {
            json_add_object data
            json_close_object
            json_select data 2>/dev/null || rc=1
        }
    fi

    if [ "$rc" -eq 0 ]; then
        case "${action}:${key}" in
            get:*)
                local out=""
                json_get_var out "$key" 2>/dev/null || true
                printf "%s" "$out"
            ;;
            set:*)
                json_add_string "$key" "$value"
                json_select .. 2>/dev/null || true
                json_dump > "$RUNNING_STATUS_FILE" || rc=1
            ;;
            add:error|add:warning)
                local arr="${key}s"
                json_select .. 2>/dev/null || true
                json_select "$arr" 2>/dev/null || {
                    json_add_array "$arr"
                    json_close_array
                    json_select "$arr" 2>/dev/null || rc=1
                }
                if [ "$rc" -eq 0 ]; then
                    json_add_object ""
                    json_add_string code "$value"
                    json_add_string info "$value"
                    json_close_object
                    json_select .. 2>/dev/null || true
                    json_dump > "$RUNNING_STATUS_FILE" || rc=1
                fi
            ;;
            *)
                rc=1
            ;;
        esac

        json_cleanup 2>/dev/null || true
    fi

    flock -u "${LOCK_FD}" 2>/dev/null || true
    eval "exec ${LOCK_FD}>&-" 2>/dev/null || true

    return "$rc"
}