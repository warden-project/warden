# shellcheck shell=bash
# lib/features/tang_bindings.sh — menu 3: Tang servers to trust (bindings)
#
# Builds and saves the pin configuration (single tang / sss / tpm2) that
# the LUKS enrolment wizard (menu 5) binds devices against.
# This is deliberately a Day-0 "what do we trust and how" step, separate
# from binding any specific device.
#
# The Tailscale systemd-cryptsetup@<mapper> ordering drop-in described
# in the spec is NOT created here: it targets a specific device's mapper
# unit, and no device has been chosen yet at this stage. Any address
# saved here as Tailscale-flagged carries that flag into the saved
# config so the enrolment wizard can offer the drop-in once it knows
# which device/mapper it applies to.

: "${WARDEN_STATE_DIR:=/etc/warden}"
: "${WARDEN_BINDINGS_FILE:=${WARDEN_STATE_DIR}/tang-bindings.json}"

# parse_host_port <input> — prints "host<TAB>port", defaulting to port 80
# if none was given.
parse_host_port() {
    local input="$1" host port
    if [[ "$input" == *:* ]]; then
        host="${input%:*}"
        port="${input##*:}"
    else
        host="$input"
        port=80
    fi
    printf '%s\t%s\n' "$host" "$port"
}

# is_cgnat_address <host> — true if host is a literal IPv4 address in
# 100.64.0.0/10, the range Tailscale uses. This is a heuristic, not
# proof -- callers must still ask the person to confirm.
is_cgnat_address() {
    local host="$1"
    [[ "$host" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
    local o1="${BASH_REMATCH[1]}" o2="${BASH_REMATCH[2]}"
    [[ "$o1" == "100" ]] || return 1
    (( o2 >= 64 && o2 <= 127 ))
}

tailscale_cli_present() {
    command -v tailscale >/dev/null 2>&1
}

# tailscale_status_json — wrapped so tests can stub it independently of
# the tailscale_cli_present check. Always returns 0 (see
# load_bindings_config's comment for why): `tailscale status` exits
# non-zero when tailscaled isn't running/logged in, which is a normal
# "can't confirm, fall back to the heuristic" outcome here, not a
# script-ending error, and this is called via bare assignment inside
# classify_tailscale.
tailscale_status_json() {
    tailscale status --json 2>/dev/null
    return 0
}

# tailscale_peer_match <host> <status_json> — true if host matches a
# known peer's Tailscale IP, DNS name, or hostname.
tailscale_peer_match() {
    local host="$1" json="$2"
    [[ -n "$json" ]] || return 1
    python3 -c '
import json, sys
host = sys.argv[1]
try:
    data = json.loads(sys.argv[2])
except ValueError:
    sys.exit(1)

candidates = []
self_peer = data.get("Self")
if self_peer:
    candidates.append(self_peer)
peers = data.get("Peer") or {}
candidates.extend(peers.values())

host_l = host.rstrip(".").lower()
for peer in candidates:
    for ip in (peer.get("TailscaleIPs") or []):
        if ip == host:
            sys.exit(0)
    for key in ("DNSName", "HostName"):
        name = (peer.get(key) or "").rstrip(".").lower()
        if name and (name == host_l or name.split(".")[0] == host_l):
            sys.exit(0)
sys.exit(1)
' "$host" "$json"
}

# classify_tailscale <host> — echoes one of: confirmed | heuristic | no
classify_tailscale() {
    local host="$1"
    if tailscale_cli_present; then
        local json
        json="$(tailscale_status_json)"
        if [[ -n "$json" ]] && tailscale_peer_match "$host" "$json"; then
            echo "confirmed"
            return
        fi
        echo "no"
        return
    fi
    if is_cgnat_address "$host"; then
        echo "heuristic"
        return
    fi
    echo "no"
}

build_tang_pin_config() {
    local url="$1"
    python3 -c 'import json,sys; print(json.dumps({"url": sys.argv[1]}))' "$url"
}

build_tpm2_pin_config() {
    echo '{}'
}

# build_sss_pin_config <threshold> <tang_urls_newline_separated> <include_tpm2:0|1>
build_sss_pin_config() {
    local threshold="$1" urls="$2" include_tpm2="$3"
    python3 -c '
import json, sys
threshold = int(sys.argv[1])
urls = [u for u in sys.argv[2].split("\n") if u]
include_tpm2 = sys.argv[3] == "1"

pins = {}
if urls:
    pins["tang"] = [{"url": u} for u in urls]
if include_tpm2:
    pins["tpm2"] = [{}]

print(json.dumps({"t": threshold, "pins": pins}))
' "$threshold" "$urls" "$include_tpm2"
}

# group_same_server — reads "<url>\t<adv_body>" lines from stdin, prints
# one space-separated line per group of >=2 URLs that returned an
# identical /adv response (i.e. the same physical Tang server, reached
# by more than one address).
group_same_server() {
    local -A groups=()
    local url body
    while IFS=$'\t' read -r url body; do
        [[ -n "$url" && -n "$body" ]] || continue
        groups["$body"]+="${groups[$body]:+ }${url}"
    done
    local key
    for key in "${!groups[@]}"; do
        [[ "${groups[$key]}" == *" "* ]] && echo "${groups[$key]}"
    done
    return 0
}

# save_bindings_config <json> — backs up any existing saved config first.
#
# Locked to 700/600: this file names the exact Tang server
# addresses/ports and SSS threshold this host trusts for automatic
# unlock -- real reconnaissance value to a local unprivileged user if
# left world-readable, unlike every other Warden-created artifact of
# comparable sensitivity (logs, header backups, keyfiles, recovery
# kits are all similarly locked down).
save_bindings_config() {
    local json="$1"
    mkdir -p "$WARDEN_STATE_DIR"
    chmod 700 "$WARDEN_STATE_DIR"
    if [[ -f "$WARDEN_BINDINGS_FILE" ]]; then
        backup_file "$WARDEN_BINDINGS_FILE" >/dev/null
    fi
    local before after
    before="$(mktemp)"; after="$(mktemp)"
    if [[ -f "$WARDEN_BINDINGS_FILE" ]]; then
        cp -p "$WARDEN_BINDINGS_FILE" "$before"
    else
        : > "$before"
    fi
    printf '%s\n' "$json" > "$WARDEN_BINDINGS_FILE"
    chmod 600 "$WARDEN_BINDINGS_FILE"
    cp -p "$WARDEN_BINDINGS_FILE" "$after"
    log_diff "$WARDEN_BINDINGS_FILE" "$before" "$after"
    rm -f "$before" "$after"
}

# load_bindings_config — echoes the saved config, or nothing if none
# exists yet. Always returns 0: this is a getter, not a predicate, and
# every caller is a bare `x="$(load_bindings_config)"` assignment --
# under bin/warden's `set -e`, returning non-zero here (e.g. from a
# naive `[[ -f ... ]] && cat ...`, which is false/1 when the file
# doesn't exist) kills the entire program the first time this runs
# before any config has been saved. Confirmed on real hardware: menu 3
# crashed the whole TUI outright on a fresh install for exactly this
# reason.
load_bindings_config() {
    if [[ -f "$WARDEN_BINDINGS_FILE" ]]; then
        cat "$WARDEN_BINDINGS_FILE"
    fi
    return 0
}

# describe_saved_bindings <json> — a human-readable summary of a saved
# trust configuration, for showing before offering to replace it.
describe_saved_bindings() {
    local json="$1"
    python3 -c '
import json, sys
data = json.loads(sys.argv[1])
pin_type = data.get("pin_type", "?")
pin_config = data.get("pin_config", {})
addresses = data.get("addresses", [])

if pin_type == "sss":
    t = pin_config.get("t", "?")
    n = sum(len(v) for v in pin_config.get("pins", {}).values())
    print(f"Pin type: sss (threshold {t} of {n})")
elif pin_type == "tpm2":
    print("Pin type: tpm2 (this machine'"'"'s TPM chip only)")
else:
    print(f"Pin type: {pin_type}")

if addresses:
    print("Addresses:")
    for a in addresses:
        tag = ""
        if a.get("is_tailscale"):
            method = a.get("detection_method", "?")
            tag = " (Tailscale, " + method + ")"
        print("  - " + a["url"] + tag)
' "$json"
}

readonly WARDEN_SSS_TIMEOUT_CAVEAT="One of these groups of addresses appears to be the same physical Tang server, reached over both a LAN path and a Tailscale path. This works, but if the Tailscale path is ever unreachable, Clevis does not fail over quickly -- the unreachable pin can take several minutes to time out before falling through to the one that works. This is documented upstream Clevis behaviour, not a Warden bug, but it's worth knowing about before you commit to this combination."

feature_tang_bindings_menu() {
    local existing
    existing="$(load_bindings_config)"
    if [[ -n "$existing" ]]; then
        if ! warden_yesno "Existing trust configuration" "$(describe_saved_bindings "$existing")\n\nReplace this configuration?"; then
            return 0
        fi
    else
        warden_msg "No trust configuration yet" "No Tang trust configuration is currently saved for this host."
    fi

    local -a addresses=()
    local -a is_ts=()
    local -a ts_method=()

    if is_pkg_installed tang && [[ -x "$(command -v systemctl)" ]] && is_systemd_unit_active "${WARDEN_TANGD_SOCKET_UNIT:-tangd.socket}" 2>/dev/null; then
        if warden_yesno "Local Tang server" "Tang is running on this host. Include it (127.0.0.1:$(configured_tangd_port)) as a trusted server?"; then
            addresses+=("127.0.0.1:$(configured_tangd_port)")
        fi
    fi

    while true; do
        local entry
        entry="$(whiptail --inputbox "Add a Tang server address (host:port). Leave blank and press OK to finish." 10 70 3>&1 1>&2 2>&3)" || break
        [[ -z "$entry" ]] && break
        addresses+=("$entry")
    done

    if [[ "${#addresses[@]}" -eq 0 ]]; then
        warden_msg "No addresses" "No Tang server addresses were entered. Nothing saved."
        return 0
    fi

    # De-duplicate while preserving order.
    local -a deduped=()
    local a seen
    for a in "${addresses[@]}"; do
        seen=0
        for seen_a in "${deduped[@]:-}"; do
            [[ "$seen_a" == "$a" ]] && seen=1 && break
        done
        [[ "$seen" == "0" ]] && deduped+=("$a")
    done
    addresses=("${deduped[@]}")

    local -a urls=()
    local host port url method
    for a in "${addresses[@]}"; do
        IFS=$'\t' read -r host port < <(parse_host_port "$a")
        url="http://${host}:${port}"
        urls+=("$url")
        method="$(classify_tailscale "$host")"
        if [[ "$method" == "heuristic" ]]; then
            if warden_yesno "Tailscale address? (guess, not certain)" "${host} is in the 100.64.0.0/10 range Tailscale uses, but the tailscale CLI isn't available here to confirm automatically.\n\nIs this actually a Tailscale address?"; then
                method="heuristic-confirmed"
            else
                method="no"
            fi
        fi
        if [[ "$method" == "confirmed" || "$method" == "heuristic-confirmed" ]]; then
            is_ts+=("1")
        else
            is_ts+=("0")
        fi
        ts_method+=("$method")
    done

    # Reachability + /adv body collection, for the summary and for
    # same-physical-server grouping.
    local summary="" pair_input="" reach body any_unreachable=0
    for i in "${!urls[@]}"; do
        url="${urls[$i]}"
        reach="$(check_tang_reachability "$url")"
        summary+="${url}  ${reach}"$'\n'
        if [[ "$reach" == reachable* ]]; then
            body="$(fetch_tang_adv "$url")"
            pair_input+="${url}"$'\t'"${body}"$'\n'
        else
            any_unreachable=1
        fi
    done
    warden_msg "Reachability check" "$summary"
    if [[ "$any_unreachable" == "1" ]]; then
        if ! warden_yesno "Some addresses unreachable" "One or more addresses did not respond just now. That's not necessarily a problem (e.g. a Tailscale peer not connected from this shell), but double-check before continuing.\n\nContinue anyway?"; then
            return 0
        fi
    fi

    local group
    while IFS= read -r group; do
        [[ -n "$group" ]] || continue
        local has_ts=0 has_non_ts=0 gurl
        for gurl in $group; do
            for i in "${!urls[@]}"; do
                if [[ "${urls[$i]}" == "$gurl" ]]; then
                    [[ "${is_ts[$i]}" == "1" ]] && has_ts=1 || has_non_ts=1
                fi
            done
        done
        if [[ "$has_ts" == "1" && "$has_non_ts" == "1" ]]; then
            warden_msg "Same server, two paths" "$WARDEN_SSS_TIMEOUT_CAVEAT"
        fi
    done < <(printf '%s' "$pair_input" | group_same_server)

    local include_tpm2=0
    if is_pkg_installed clevis-tpm2; then
        if warden_yesno "Include TPM2?" "Also include this machine's TPM2 chip as a pin?\n\nCaveat: PCR-sealed bindings can break after firmware/kernel updates and need a re-bind."; then
            include_tpm2=1
        fi
    fi

    local total_pins=$(( ${#urls[@]} + include_tpm2 ))
    local pin_type threshold=1 pin_config urls_joined
    urls_joined="$(printf '%s\n' "${urls[@]}")"

    if [[ "$total_pins" -eq 1 && "$include_tpm2" == "0" ]]; then
        pin_type="tang"
        pin_config="$(build_tang_pin_config "${urls[0]}")"
    elif [[ "$total_pins" -eq 1 && "$include_tpm2" == "1" ]]; then
        pin_type="tpm2"
        pin_config="$(build_tpm2_pin_config)"
    else
        pin_type="sss"
        local has_localhost=0
        for url in "${urls[@]}"; do
            [[ "$url" == *"://127.0.0.1"* || "$url" == *"://localhost"* ]] && has_localhost=1
        done
        local threshold_note="With ${total_pins} pins configured:\n\n- Threshold 1 means ANY ONE pin unlocks the device (most available, least strict).\n- Threshold ${total_pins} means ALL pins are required (least available, most strict).\n\nSuggested default: 1."
        if [[ "$has_localhost" == "1" ]]; then
            threshold_note+="\n\nNote: one of your pins is this host's own local Tang server. With threshold 1, the device can always unlock using just that local pin, regardless of whether any external/network server is reachable -- which may defeat the point of tying unlock to network reachability. Consider raising the threshold to 2 if you want an external pin to actually be required."
        fi
        threshold="$(whiptail --inputbox "$threshold_note" 20 78 "1" 3>&1 1>&2 2>&3)" || return 0
        if ! [[ "$threshold" =~ ^[0-9]+$ ]] || (( threshold < 1 || threshold > total_pins )); then
            warden_msg "Invalid threshold" "Threshold must be a number between 1 and ${total_pins}."
            return 0
        fi
        pin_config="$(build_sss_pin_config "$threshold" "$urls_joined" "$include_tpm2")"
    fi

    warden_msg "Pin configuration" "This will be saved as the trust configuration for future device enrolment:\n\nType: ${pin_type}\n\n${pin_config}"

    local metadata
    metadata="$(python3 -c '
import json, sys
urls = sys.argv[1].split("\n") if sys.argv[1] else []
is_ts = sys.argv[2].split(",") if sys.argv[2] else []
methods = sys.argv[3].split(",") if sys.argv[3] else []
pin_type = sys.argv[4]
pin_config = json.loads(sys.argv[5])
addresses = []
for i, u in enumerate(urls):
    if not u:
        continue
    addresses.append({
        "url": u,
        "is_tailscale": is_ts[i] == "1" if i < len(is_ts) else False,
        "detection_method": methods[i] if i < len(methods) else "no",
    })
print(json.dumps({
    "pin_type": pin_type,
    "pin_config": pin_config,
    "addresses": addresses,
}, indent=2))
' "$urls_joined" "$(IFS=,; echo "${is_ts[*]}")" "$(IFS=,; echo "${ts_method[*]}")" "$pin_type" "$pin_config")"

    save_bindings_config "$metadata"
    warden_msg "Saved" "Trust configuration saved to ${WARDEN_BINDINGS_FILE}.\n\nAny address flagged as Tailscale will be offered its systemd ordering drop-in when you enrol a device against this configuration (menu 5)."
}
