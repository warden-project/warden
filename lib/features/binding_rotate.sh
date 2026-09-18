# shellcheck shell=bash
# lib/features/binding_rotate.sh — menu 8: add/remove/rotate a binding
#
# The safe pattern for changing an existing binding: bind the new
# config into a fresh slot first, verify it actually works, and only
# then unbind the old one. Never edit a binding in place, and never
# unbind anything before its replacement is proven to work. The person
# is never asked to remember or type a slot number by hand -- Warden
# looks up and displays slots itself.
#
# NOTE: `clevis luks unbind -d DEV -s SLT -f` is implemented per
# documented Clevis CLI usage but has not been exercised against a
# real clevis binary in this development environment (clevis isn't
# installed here). Verify against a real host/VM before relying on it.

# parse_clevis_slots <clevis_luks_list_output> — "<slot>\t<pintype>\t<json>"
# per line.
parse_clevis_slots() {
    local text="$1" line
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        if [[ "$line" =~ ^([0-9]+):\ ([^\ ]+)\ \'(.*)\'$ ]]; then
            printf '%s\t%s\t%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
        fi
    done <<<"$text"
}

# describe_binding_slot <pintype> <json> — one-line human summary.
describe_binding_slot() {
    local pintype="$1" json="$2"
    case "$pintype" in
        sss)
            python3 -c '
import json, sys
d = json.loads(sys.argv[1])
t = d.get("t", "?")
n = sum(len(v) for v in d.get("pins", {}).values())
print("sss (threshold " + str(t) + " of " + str(n) + ")")
' "$json"
            ;;
        tang)
            python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print("tang " + d.get("url","?"))' "$json"
            ;;
        tpm2)
            echo "tpm2"
            ;;
        *)
            echo "$pintype"
            ;;
    esac
}

# describe_slots <dev> — human-readable listing of every bound slot,
# or a plain statement that there are none.
describe_slots() {
    local dev="$1" slot pintype json
    local pins
    pins="$(clevis_pins_for_device "$dev")"
    if [[ -z "$pins" ]]; then
        echo "(no Clevis bindings on this device)"
        return
    fi
    while IFS=$'\t' read -r slot pintype json; do
        [[ -n "$slot" ]] || continue
        printf 'Slot %s: %s\n' "$slot" "$(describe_binding_slot "$pintype" "$json")"
    done < <(parse_clevis_slots "$pins")
}

# slot_numbers <dev> — every currently-bound slot number, one per line.
slot_numbers() {
    local dev="$1"
    parse_clevis_slots "$(clevis_pins_for_device "$dev")" | cut -f1
}

# new_slots <before> <after> — slot numbers present in <after> but not
# <before> (both newline-separated), one per line.
new_slots() {
    comm -13 <(sort -u <<<"$1") <(sort -u <<<"$2")
}

# clevis_token_slots <dev> — every keyslot number that has a Clevis
# token attached, one per line, read directly from cryptsetup's own
# LUKS2 metadata (`luksDump`) -- a source independent of `clevis luks
# list`, so a bug or version quirk in one can't silently defeat the
# other.
#
# NOTE: parses cryptsetup's human-readable luksDump text output (there
# is no machine-readable mode in the cryptsetup versions this was
# written against). Verify this parsing against a real LUKS2 device
# with a real Clevis binding on a test host -- not exercised against
# real cryptsetup output in this development environment.
clevis_token_slots() {
    local dev="$1"
    cryptsetup luksDump "$dev" 2>/dev/null | python3 -c '
import re, sys

in_tokens = False
current_type = None
slots = set()
for line in sys.stdin:
    stripped = line.rstrip("\n")
    if stripped.strip() == "Tokens:":
        in_tokens = True
        continue
    if not in_tokens:
        continue
    if stripped and not stripped[0].isspace():
        break
    m = re.match(r"\s*\d+:\s*(\S+)", stripped)
    if m and re.match(r"^\s*\d+:", stripped) and not re.search(r"Keyslot", stripped):
        current_type = m.group(1)
        continue
    m2 = re.search(r"Keyslot:\s*(\d+)", stripped)
    if m2 and current_type == "clevis":
        slots.add(int(m2.group(1)))

for s in sorted(slots):
    print(s)
'
}

# slot_has_clevis_token <dev> <slot> — the hard gate every unbind must
# pass: true only if cryptsetup's own token metadata (not just what
# the UI happened to display) confirms this slot is Clevis-managed.
slot_has_clevis_token() {
    local dev="$1" slot="$2"
    clevis_token_slots "$dev" | grep -qxF "$slot"
}

run_clevis_luks_unbind() {
    local dev="$1" slot="$2"
    if ! slot_has_clevis_token "$dev" "$slot"; then
        log_line "REFUSED: slot ${slot} on ${dev} has no Clevis token attached -- refusing to unbind a non-Clevis slot (passphrase/keyfile/etc)"
        return 3
    fi
    run_cmd "unbind slot ${slot} on ${dev}" -- clevis luks unbind -d "$dev" -s "$slot" -f
}

feature_binding_rotate_menu() {
    local -a menu_items=()
    local dev uuid mapper
    # shellcheck disable=SC2034  # uuid is unused here but must be consumed to split managed_luks_devices' 3 columns correctly
    while read -r dev uuid mapper; do
        [[ -n "$dev" ]] || continue
        menu_items+=("$dev" "mapper: ${mapper}")
    done < <(managed_luks_devices)

    if [[ "${#menu_items[@]}" -eq 0 ]]; then
        warden_msg "No managed devices" "No managed crypto_LUKS devices were found to operate on."
        return 0
    fi

    dev="$(warden_menu "Select a device" "Managed devices:" "${menu_items[@]}")" || return 0

    warden_msg "Current bindings on ${dev}" "$(describe_slots "$dev")"

    local action
    action="$(warden_menu "Choose an action" "What do you want to do with ${dev}?" \
        add "Add a new binding (new slot)" \
        remove "Remove an existing binding" \
        rotate "Rotate: bind new, verify, then remove old")" || return 0

    case "$action" in
        add) binding_action_add "$dev" ;;
        remove) binding_action_remove "$dev" ;;
        rotate) binding_action_rotate "$dev" ;;
    esac
}

binding_action_add() {
    local dev="$1"
    local trust
    trust="$(load_trust_config_or_warn)" || return 0
    local pin_type="${trust%%$'\t'*}" pin_config="${trust#*$'\t'}"

    local passphrase
    passphrase="$(whiptail --passwordbox "Enter this device's EXISTING LUKS passphrase (or an existing working binding won't be needed, but Clevis still requires an existing key to authorise the new one):" 12 70 3>&1 1>&2 2>&3)" || return 0

    local trust_summary
    trust_summary="$(describe_saved_bindings "$(load_bindings_config)")"
    if ! warden_yesno "Confirm" "This will add a new binding to ${dev} using:\n${trust_summary}\n\nProceed?"; then
        return 0
    fi

    if ! run_clevis_luks_bind "$dev" "$passphrase" "$pin_type" "$pin_config" >/dev/null; then
        warden_msg "Bind failed" "clevis luks bind did not succeed. Check the session log at ${WARDEN_LOG_FILE}."
        return 0
    fi

    warden_msg "Binding added" "New bindings on ${dev}:\n\n$(describe_slots "$dev")"
}

binding_action_remove() {
    local dev="$1"
    local pins
    pins="$(clevis_pins_for_device "$dev")"
    if [[ -z "$pins" ]]; then
        warden_msg "Nothing to remove" "${dev} has no Clevis bindings."
        return 0
    fi

    local -a menu_items=()
    local slot pintype json
    local total=0
    while IFS=$'\t' read -r slot pintype json; do
        [[ -n "$slot" ]] || continue
        total=$((total + 1))
        menu_items+=("$slot" "$(describe_binding_slot "$pintype" "$json")")
    done < <(parse_clevis_slots "$pins")

    slot="$(warden_menu "Select a slot to remove" "Current bindings on ${dev}:" "${menu_items[@]}")" || return 0

    local warning="Removing slot ${slot} from ${dev}."
    if [[ "$total" -eq 1 ]]; then
        warning+="\n\nThis is the ONLY Clevis binding on this device -- removing it disables automatic unlock entirely. You will need the LUKS passphrase to unlock it manually from then on."
    fi
    warning+="\n\nDo you have the recovery passphrase (or another working binding on this device) in hand before continuing?"

    if ! warden_yesno "Confirm removal" "$warning"; then
        return 0
    fi

    run_clevis_luks_unbind "$dev" "$slot"
    local unbind_status=$?
    if [[ "$unbind_status" -eq 3 ]]; then
        warden_msg "Refused" "Slot ${slot} on ${dev} has no Clevis token attached according to cryptsetup's own metadata -- this doesn't match a Clevis binding, so Warden refuses to touch it. This should be unreachable (the list above only ever shows Clevis-bound slots), so if you're seeing this, something is inconsistent -- check the session log at ${WARDEN_LOG_FILE} and investigate before doing anything else with this device."
        return 0
    elif [[ "$unbind_status" -ne 0 ]]; then
        warden_msg "Unbind failed" "clevis luks unbind did not succeed. Check the session log at ${WARDEN_LOG_FILE}."
        return 0
    fi

    warden_msg "Binding removed" "Remaining bindings on ${dev}:\n\n$(describe_slots "$dev")"
}

binding_action_rotate() {
    local dev="$1"
    local trust
    trust="$(load_trust_config_or_warn)" || return 0
    local pin_type="${trust%%$'\t'*}" pin_config="${trust#*$'\t'}"

    local passphrase
    passphrase="$(whiptail --passwordbox "Enter this device's EXISTING LUKS passphrase, to authorise adding the new binding:" 12 70 3>&1 1>&2 2>&3)" || return 0

    local trust_summary
    trust_summary="$(describe_saved_bindings "$(load_bindings_config)")"
    if ! warden_yesno "Confirm" "This will:\n\n1. Bind a NEW slot on ${dev} using:\n${trust_summary}\n2. Verify the new slot actually unlocks the device\n3. Only if that succeeds, offer to remove the OLD slot(s)\n\nThe old binding is never touched if verification fails.\n\nProceed?"; then
        return 0
    fi

    local before after
    before="$(slot_numbers "$dev")"

    if ! run_clevis_luks_bind "$dev" "$passphrase" "$pin_type" "$pin_config" >/dev/null; then
        warden_msg "Bind failed" "clevis luks bind did not succeed. The existing binding(s) are untouched. Check the session log at ${WARDEN_LOG_FILE}."
        return 0
    fi

    after="$(slot_numbers "$dev")"
    local new_slot
    new_slot="$(new_slots "$before" "$after" | head -n1)"

    # A ZFS-backed device is already open under its real mapper name
    # (the pool is imported there), unlike a plain-filesystem device --
    # confirmed on real hardware that cryptsetup refuses a second
    # mapping of the same underlying device outright ("Cannot use
    # device ... which is in use"), so the generic test-unlock below
    # would fail here for reasons unrelated to whether the new binding
    # actually works. Same fix as menu 4/5's enrolment wizard.
    local unlock_result mapper
    mapper="$(crypttab_mapper_for_uuid "$(uuid_for_device "$dev")")"
    if [[ -n "$mapper" ]] && is_systemd_unit_enabled "warden-zfs-import@${mapper}.service" 2>/dev/null; then
        local mountpoint
        mountpoint="$(zfs list -H -o mountpoint "$mapper" 2>/dev/null | head -n1)"
        unlock_result="$(test_unlock_and_cleanup_zfs "$dev" "$mapper" "$passphrase" "${mountpoint:-unknown}")"
    else
        unlock_result="$(test_unlock_and_cleanup "$dev")"
    fi
    if [[ "$unlock_result" != "ok" ]]; then
        warden_msg "New binding did not verify -- old binding left in place" "The new binding (slot ${new_slot}) was added but failed to test-unlock. The old binding is untouched, so this device can still unlock as before.\n\nInvestigate before retrying (check Tang reachability and the session log at ${WARDEN_LOG_FILE}). You can remove the failed new slot ${new_slot} from menu 8's Remove action if you want to abandon this attempt."
        return 0
    fi

    if [[ -z "$before" ]]; then
        warden_msg "Rotation complete" "New binding (slot ${new_slot}) verified working. There was no previous binding to remove."
        return 0
    fi

    if ! warden_yesno "New binding verified" "The new binding (slot ${new_slot}) verified successfully.\n\nOld slot(s): $(echo "$before" | tr '\n' ' ')\n\nRemove the old slot(s) now?"; then
        warden_msg "Old binding kept" "The new binding is active, but the old slot(s) were left in place at your choice. Remove them later from this menu's Remove action if you want to."
        return 0
    fi

    local old_slot refused=""
    while IFS= read -r old_slot; do
        [[ -n "$old_slot" ]] || continue
        run_clevis_luks_unbind "$dev" "$old_slot"
        [[ $? -eq 3 ]] && refused+="${old_slot} "
    done <<<"$before"

    if [[ -n "$refused" ]]; then
        warden_msg "Some old slots were refused" "Slot(s) ${refused}had no Clevis token attached according to cryptsetup's own metadata and were left untouched -- this should be unreachable, since these came from the same Clevis-sourced list as the new binding. Check the session log at ${WARDEN_LOG_FILE} and investigate before doing anything else with this device.\n\nRemaining bindings on ${dev}:\n\n$(describe_slots "$dev")"
        return 0
    fi

    warden_msg "Rotation complete" "Final bindings on ${dev}:\n\n$(describe_slots "$dev")"
}
