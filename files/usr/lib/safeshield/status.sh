# shellcheck shell=sh

is_enabled() {
    uci_get "$1" 'config' 'enabled' '0'
}

is_active() {
    local st

    st="$(json get status)"

    [ -n "$st" ] || return 1
    [ "$st" = 'statusStopped' ] && return 1
    [ "$st" = 'idle' ] && return 1

    return 0
}