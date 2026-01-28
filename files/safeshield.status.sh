# shellcheck shell=sh

is_enabled() { uci_get "$1" 'config' 'enabled' '0'; }
is_active() {
	local st ub
	st="$(json get status)"
	ub="$(ubus_get_data status)"

	if [ "$st" = 'statusStopped' ] || [ -z "${st}${ub}" ]; then
		return 1
	else
		return 0
	fi
}