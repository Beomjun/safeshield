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