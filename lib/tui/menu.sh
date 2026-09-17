# shellcheck shell=bash
# lib/tui/menu.sh — whiptail wrappers
#
# danger_msg gives the Danger Zone a visually distinct treatment
# (--backtitle banner + red-flagged heading text) so it never looks like
# a routine menu screen, per the safety spec.

warden_menu() {
    local title="$1" text="$2"
    shift 2
    whiptail --title "$title" --menu "$text" 24 78 15 "$@" 3>&1 1>&2 2>&3
}

warden_msg() {
    local title="$1" text="$2"
    whiptail --title "$title" --msgbox "$text" 16 78
}

warden_yesno() {
    # Only for non-destructive confirmations. Destructive operations
    # must use confirm_typed_phrase instead, never this.
    local title="$1" text="$2"
    whiptail --title "$title" --yesno "$text" 12 78
}

danger_msg() {
    local text="$1"
    whiptail --title "!!! DANGER ZONE !!!" --backtitle "WARDEN - IRREVERSIBLE ACTION" --msgbox "$text" 18 78
}

danger_yesno() {
    local text="$1"
    whiptail --title "!!! DANGER ZONE !!!" --backtitle "WARDEN - IRREVERSIBLE ACTION" --yesno "$text" 14 78
}

danger_textbox() {
    local file="$1"
    whiptail --title "!!! DANGER ZONE !!!" --backtitle "WARDEN - IRREVERSIBLE ACTION" --scrolltext --textbox "$file" 24 100
}

# shellcheck disable=SC2034  # used by lib/features/danger_erase.sh to pass into confirm_destructive_device_action's backtitle
readonly WARDEN_DANGER_BACKTITLE="WARDEN - IRREVERSIBLE ACTION"
