# shellcheck shell=sh

log_line() {
    [ -z "$verbosity" ] && verbosity="$(uci_get "$PKG_NAME" 'config' 'verbosity' '1')"

    if [ "$#" -ne 1 ]; then
        case "$1" in
            [0-9]) [ $((verbosity & $1)) -gt 0 ] && shift || return 0 ;;
        esac
    fi

    local msg="$*"
    local queue="/dev/shm/${PKG_NAME}-output"

    if [ -z "$_out_is_tty" ]; then
        [ -t 1 ] && _out_is_tty=1 || _out_is_tty=0
    fi
    [ "$_out_is_tty" -eq 1 ] && printf "%b" "$msg"

    case "$msg" in
        *\\n*)
            if [ -s "$queue" ]; then
                msg="$(cat "$queue")${msg}"
                rm -f "$queue"
            fi

            msg="$(printf "%b" "$msg" | sed 's/\x1b\[[0-9;]*m//g')"

            logger -t "$PKG_NAME [$$]" "%s" "$msg"
        ;;
        *)
            printf "%b" "$msg" >> "$queue"
        ;;
    esac
}