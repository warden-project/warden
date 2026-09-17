# shellcheck shell=bash
# lib/core/net.sh — Tang network checks shared by status.sh and tang_bindings.sh

# check_tang_reachability <url> — prints "reachable <ms>" or "unreachable".
check_tang_reachability() {
    local url="$1" result
    result="$(curl -sf -m 3 -o /dev/null -w '%{time_total}' "${url%/}/adv" 2>/dev/null)" || {
        echo "unreachable"
        return
    }
    printf 'reachable %sms\n' "$(awk -v t="$result" 'BEGIN{printf "%.0f", t*1000}')"
}

# fetch_tang_adv <url> — prints the raw /adv response body, empty on failure.
fetch_tang_adv() {
    local url="$1"
    curl -sf -m 3 "${url%/}/adv" 2>/dev/null
}
