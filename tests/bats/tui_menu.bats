#!/usr/bin/env bats

load '../helpers/setup'

setup() { warden_test_setup; }
teardown() { warden_test_teardown; }

# Simulates pressing Escape on a dialog that only has an OK button:
# whiptail exits 1 even though there's nothing to "cancel" into, since
# it wasn't given --no-cancel.
_stub_whiptail_escaped() {
    mkdir -p "${TEST_TMPDIR}/bin"
    cat > "${TEST_TMPDIR}/bin/whiptail" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "${TEST_TMPDIR}/bin/whiptail"
}

@test "warden_msg does not propagate a nonzero exit when its dialog is cancelled" {
    # Found live while exercising menu 6 (root-drive unlock): bin/warden runs under
    # set -euo pipefail, and warden_msg previously called whiptail
    # unguarded -- pressing Escape on what's meant to be a purely
    # informational message dialog silently killed the entire running
    # tool instead of just moving on, discovered mid-session on a real
    # VM.
    _stub_whiptail_escaped
    PATH="${TEST_TMPDIR}/bin:${PATH}" run bash -c "
set -euo pipefail
source '${WARDEN_ROOT}/lib/tui/menu.sh'
warden_msg 'title' 'text'
echo 'survived'
"
    [ "$status" -eq 0 ]
    [[ "$output" == *"survived"* ]]
}

@test "danger_msg does not propagate a nonzero exit when its dialog is cancelled" {
    _stub_whiptail_escaped
    PATH="${TEST_TMPDIR}/bin:${PATH}" run bash -c "
set -euo pipefail
source '${WARDEN_ROOT}/lib/tui/menu.sh'
danger_msg 'text'
echo 'survived'
"
    [ "$status" -eq 0 ]
    [[ "$output" == *"survived"* ]]
}

@test "danger_textbox does not propagate a nonzero exit when its dialog is cancelled" {
    _stub_whiptail_escaped
    PATH="${TEST_TMPDIR}/bin:${PATH}" run bash -c "
set -euo pipefail
source '${WARDEN_ROOT}/lib/tui/menu.sh'
danger_textbox '/etc/hostname'
echo 'survived'
"
    [ "$status" -eq 0 ]
    [[ "$output" == *"survived"* ]]
}

@test "warden_yesno still propagates its exit status -- only the info dialogs are guarded" {
    # warden_yesno's whole point is to distinguish yes from no via exit
    # status -- it must NOT swallow that the way warden_msg now does.
    _stub_whiptail_escaped
    PATH="${TEST_TMPDIR}/bin:${PATH}" run bash -c "
source '${WARDEN_ROOT}/lib/tui/menu.sh'
warden_yesno 'title' 'text'
"
    [ "$status" -eq 1 ]
}
