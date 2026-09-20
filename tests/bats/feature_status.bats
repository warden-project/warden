#!/usr/bin/env bats

load '../helpers/setup'

setup() { warden_test_setup; }
teardown() { warden_test_teardown; }

@test "extract_tang_urls pulls a single tang pin URL" {
    local out
    out="$(extract_tang_urls '1: tang '"'"'{"url":"http://tang.example.com:8080"}'"'"'')"
    [ "$out" = "http://tang.example.com:8080" ]
}

@test "extract_tang_urls pulls multiple URLs nested in an sss pin, de-duplicated" {
    local input='1: sss '"'"'{"t":1,"pins":{"tang":[{"url":"http://a.example.com"},{"url":"http://b.example.com"},{"url":"http://a.example.com"}]}}'"'"''
    local out
    out="$(extract_tang_urls "$input")"
    [ "$(echo "$out" | wc -l)" -eq 2 ]
    echo "$out" | grep -qx "http://a.example.com"
    echo "$out" | grep -qx "http://b.example.com"
}

@test "check_tang_reachability reports unreachable for a closed port" {
    run check_tang_reachability "http://127.0.0.1:1"
    [[ "$output" == "unreachable" ]]
}

@test "check_tang_reachability reports reachable and a millisecond figure for a successful response" {
    # Stub curl rather than backgrounding a real HTTP server: bats runs each
    # test in its own subshell and command substitution (used by both `run`
    # and check_tang_reachability itself) blocks until every inherited
    # write end of its output pipe closes -- including an unrelated
    # backgrounded server's, if one happens to still hold it open. That's a
    # bats/job-control interaction, not something check_tang_reachability
    # needs to account for, so stub the one external dependency instead.
    mkdir -p "${TEST_TMPDIR}/bin"
    cat > "${TEST_TMPDIR}/bin/curl" <<'EOF'
#!/usr/bin/env bash
echo "0.123"
exit 0
EOF
    chmod +x "${TEST_TMPDIR}/bin/curl"
    PATH="${TEST_TMPDIR}/bin:${PATH}" run check_tang_reachability "http://127.0.0.1:9"
    [ "$output" = "reachable 123ms" ]
}

@test "tailscale_ordering_dropins finds a matching drop-in" {
    WARDEN_SYSTEMD_SYSTEM_DIR="${TEST_TMPDIR}/systemd"
    mkdir -p "${WARDEN_SYSTEMD_SYSTEM_DIR}/systemd-cryptsetup@data\x2ddisk.service.d"
    cat > "${WARDEN_SYSTEMD_SYSTEM_DIR}/systemd-cryptsetup@data\x2ddisk.service.d/override.conf" <<'EOF'
[Unit]
After=tailscale-online.target
Wants=tailscale-online.target
EOF
    local out
    out="$(tailscale_ordering_dropins)"
    [ -n "$out" ]
}

@test "tailscale_ordering_dropins reports none when absent" {
    WARDEN_SYSTEMD_SYSTEM_DIR="${TEST_TMPDIR}/systemd-empty"
    mkdir -p "$WARDEN_SYSTEMD_SYSTEM_DIR"
    [ -z "$(tailscale_ordering_dropins)" ]
}

@test "unit_state reports 'not present' for a unit that doesn't exist" {
    [ "$(unit_state definitely-not-a-real-unit.service)" = "not present" ]
}

@test "unit_state reports 'active' for a known-running unit" {
    if ! systemctl list-unit-files cron.service --no-legend 2>/dev/null | grep -q .; then
        skip "cron.service not present on this machine"
    fi
    [ "$(unit_state cron.service)" = "active" ]
}

@test "clevis_pins_for_device survives a bare assignment under set -e for a device with no bindings" {
    # Regression test for a real crash class found on real hardware:
    # `clevis luks list` exits non-zero for the very common "no
    # bindings yet" case, and this is called via bare assignment from
    # render_status_report and binding_rotate.sh -- under
    # bin/warden's `set -e`, that silently kills the whole program.
    # bats itself never runs under set -e, so no other test here would
    # have caught this.
    mkdir -p "${TEST_TMPDIR}/bin"
    cat > "${TEST_TMPDIR}/bin/clevis" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "${TEST_TMPDIR}/bin/clevis"
    run env PATH="${TEST_TMPDIR}/bin:${PATH}" bash -c "
        set -euo pipefail
        source '${WARDEN_ROOT}/lib/core/log.sh'
        source '${WARDEN_ROOT}/lib/core/exec.sh'
        WARDEN_LOG_DIR='${WARDEN_LOG_DIR}'
        log_init
        source '${WARDEN_ROOT}/lib/features/status.sh'
        pins=\"\$(clevis_pins_for_device /dev/fake)\"
        echo 'SURVIVED'
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"SURVIVED"* ]]
}

@test "render_status_report shows ZFS pool status instead of an fstab line for a device with an enabled import unit" {
    luks_devices() { printf '/dev/fake1 uuid1\n'; }
    export -f luks_devices
    crypttab_mapper_for_uuid() { printf 'tank1'; }
    export -f crypttab_mapper_for_uuid
    is_systemd_unit_enabled() { [ "$1" = "warden-zfs-import@tank1.service" ]; }
    export -f is_systemd_unit_enabled
    # Not stubbing unit_state: confirmed on real hardware that
    # `systemctl list-unit-files <specific-instance>` (what its
    # existence check relies on) never matches a template-instantiated
    # unit name, so it always reported "not present" here regardless
    # of real state -- the fix calls `systemctl is-active` directly
    # instead, stubbed via PATH below.
    mkdir -p "${TEST_TMPDIR}/bin"
    cat > "${TEST_TMPDIR}/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
[ "$1" = "is-active" ]
EOF
    chmod +x "${TEST_TMPDIR}/bin/systemctl"
    describe_zfs_pool_status() { printf 'pool: tank1\nname\tmounted\tmountpoint\ntank1\tyes\t/mnt/tank1\n'; }
    export -f describe_zfs_pool_status
    clevis_pins_for_device() { :; }
    export -f clevis_pins_for_device

    local out
    out="$(PATH="${TEST_TMPDIR}/bin:${PATH}" render_status_report)"
    [[ "$out" == *"ZFS:      warden-zfs-import@tank1.service enabled, state: active"* ]]
    [[ "$out" == *"pool: tank1"* ]]
    # Tabs must be rendered as spaces, not left as literal tab
    # characters (confirmed on real hardware: whiptail's textbox
    # renders those as visually cramped/misaligned).
    [[ "$out" == *"tank1 yes /mnt/tank1"* ]]
    [[ "$out" != *$'tank1\tyes'* ]]
    [[ "$out" != *"fstab:"* ]]
}

@test "render_status_report shows the normal fstab line for a device with no ZFS import unit" {
    luks_devices() { printf '/dev/fake1 uuid1\n'; }
    export -f luks_devices
    crypttab_mapper_for_uuid() { printf 'disk1'; }
    export -f crypttab_mapper_for_uuid
    is_systemd_unit_enabled() { return 1; }
    export -f is_systemd_unit_enabled
    fstab_has_mapper() { return 1; }
    export -f fstab_has_mapper
    clevis_pins_for_device() { :; }
    export -f clevis_pins_for_device

    local out
    out="$(render_status_report)"
    [[ "$out" == *"fstab:    NO entry for /dev/mapper/disk1"* ]]
    [[ "$out" != *"ZFS:"* ]]
}


@test "feature_status_dashboard survives Escape on its whiptail textbox instead of crashing the whole tool" {
    # Regression test for a real gap found in a full-codebase security
    # review: this call to whiptail --textbox was raw, not routed
    # through warden_msg's Escape-safe wrapper -- and unlike
    # confirm_destructive_device_action (whose only two call sites both
    # wrap it in `if ! ...; then`, which suspends set -e for everything
    # inside), this is invoked as a bare case-statement action from
    # bin/warden's main loop, so an unguarded nonzero exit here really
    # does propagate and kill the whole script under set -euo pipefail.
    # Confirmed empirically before fixing: a bare `if cmd; then` around
    # a failing call does NOT trigger set -e for anything inside it,
    # but a plain un-wrapped statement (like a case branch) does.
    mkdir -p "${TEST_TMPDIR}/bin"
    cat > "${TEST_TMPDIR}/bin/whiptail" <<'INNEREOF'
#!/usr/bin/env bash
exit 1
INNEREOF
    chmod +x "${TEST_TMPDIR}/bin/whiptail"
    render_status_report() { echo "fake report"; }
    export -f render_status_report

    run bash -c "
set -euo pipefail
PATH='${TEST_TMPDIR}/bin:'\$PATH
source '${WARDEN_ROOT}/lib/core/log.sh'
source '${WARDEN_ROOT}/lib/core/exec.sh'
WARDEN_LOG_DIR='${WARDEN_LOG_DIR}'
log_init
render_status_report() { echo fake; }
$(declare -f feature_status_dashboard)
feature_status_dashboard
echo survived
"
    [ "$status" -eq 0 ]
    [[ "$output" == *"survived"* ]]
}
