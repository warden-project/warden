#!/usr/bin/env bats

load '../helpers/setup'

setup() { warden_test_setup; }
teardown() { warden_test_teardown; }

@test "resolve_root_luks_device finds the crypto_LUKS ancestor on a real LUKS-encrypted root" {
    if [ "$(id -u)" -ne 0 ]; then
        skip "requires root for findmnt/lsblk to see the real root device"
    fi
    if [[ "$(findmnt -no FSTYPE /)" == "overlay" ]]; then
        skip "root is an overlay filesystem in this sandbox, not backed by a real block device"
    fi
    # Confirmed on real hardware (see docs/future-work.md): correctly
    # returns empty on a plain (non-LUKS) root, and the actual
    # crypto_LUKS partition (walking through LVM) on an encrypted one.
    # This sandbox/VM's actual root may be either -- just confirm the
    # function agrees with what luks_devices independently reports.
    local resolved
    resolved="$(resolve_root_luks_device)"
    if [[ -n "$resolved" ]]; then
        luks_devices | grep -qF "$resolved "
    fi
}

@test "resolve_root_luks_device is empty when root's source can't be determined" {
    findmnt() { return 1; }
    export -f findmnt
    [ -z "$(resolve_root_luks_device)" ]
}

@test "is_boot_separate_from_root is true when /boot has a different source than /" {
    findmnt() {
        if [[ "$3" == "/" ]]; then echo "/dev/root-device"; else echo "/dev/boot-device"; fi
    }
    export -f findmnt
    is_boot_separate_from_root
}

@test "is_boot_separate_from_root is false when /boot has no separate mountpoint" {
    findmnt() {
        if [[ "$3" == "/" ]]; then echo "/dev/root-device"; else return 1; fi
    }
    export -f findmnt
    run is_boot_separate_from_root
    [ "$status" -ne 0 ]
}

@test "is_boot_separate_from_root is false when /boot somehow reports the same source as /" {
    findmnt() { echo "/dev/same-device"; }
    export -f findmnt
    run is_boot_separate_from_root
    [ "$status" -ne 0 ]
}

@test "is_tpm2_present is true when a TPM device node exists" {
    if [ ! -e /dev/tpmrm0 ] && [ ! -e /dev/tpm0 ]; then
        skip "no real TPM device node on this machine"
    fi
    is_tpm2_present
}

@test "is_tpm2_present is false when no TPM device node exists" {
    if [ -e /dev/tpmrm0 ] || [ -e /dev/tpm0 ]; then
        skip "this machine has a real TPM device node, can't test the negative case directly"
    fi
    run is_tpm2_present
    [ "$status" -ne 0 ]
}

@test "is_local_address is true for loopback addresses without any lookup" {
    is_local_address "127.0.0.1"
    is_local_address "localhost"
    is_local_address "::1"
}

@test "is_local_address is true for one of this machine's own currently-assigned addresses" {
    local own_ip
    own_ip="$(ip -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)"
    if [ -z "$own_ip" ]; then
        skip "no global-scope address found on this machine to test against"
    fi
    is_local_address "$own_ip"
}

@test "is_local_address is false for an address that isn't this machine's" {
    run is_local_address "203.0.113.1"
    [ "$status" -ne 0 ]
}

@test "is_local_address resolves a hostname before checking, not just literal IPs" {
    mkdir -p "${TEST_TMPDIR}/bin"
    cat > "${TEST_TMPDIR}/bin/getent" <<'EOF'
#!/usr/bin/env bash
echo "127.0.0.1 fake-self-hostname"
EOF
    chmod +x "${TEST_TMPDIR}/bin/getent"
    PATH="${TEST_TMPDIR}/bin:${PATH}" is_local_address "fake-self-hostname"
}

@test "has_enough_disk_space is true for a tiny request and false for an absurd one" {
    has_enough_disk_space "${TEST_TMPDIR}" 1024
    run has_enough_disk_space "${TEST_TMPDIR}" $((1024 * 1024 * 1024 * 1024 * 1024))
    [ "$status" -ne 0 ]
}

@test "has_enough_disk_space checks the nearest existing ancestor when the path itself doesn't exist yet" {
    has_enough_disk_space "${TEST_TMPDIR}/does/not/exist/yet" 1024
}

@test "generate_recovery_guide_text includes every value passed in, with no leftover placeholders" {
    local out
    out="$(generate_recovery_guide_text "20260920T000000Z" "myhost" "abc-uuid-123" "def-boot-uuid-456" "6.8.0-generic" "/boot/warden-root-unlock-recovery/20260920T000000Z" "/root/warden-root-unlock-recovery/20260920T000000Z/initrd.img.bak" "/boot/initrd.img-6.8.0-generic")"
    [[ "$out" == *"20260920T000000Z"* ]]
    [[ "$out" == *"myhost"* ]]
    [[ "$out" == *"abc-uuid-123"* ]]
    [[ "$out" == *"def-boot-uuid-456"* ]]
    [[ "$out" == *"6.8.0-generic"* ]]
    [[ "$out" == *"/root/warden-root-unlock-recovery/20260920T000000Z/initrd.img.bak"* ]]
    [[ "$out" == *"/boot/initrd.img-6.8.0-generic"* ]]
    # No angle-bracket-style "fill this in yourself" placeholders left
    # for the reader to resolve under pressure.
    [[ "$out" != *"<this"* ]]
    [[ "$out" != *"as appropriate>"* ]]
}

@test "generate_recovery_guide_text states the staleness caveat explicitly" {
    local out
    out="$(generate_recovery_guide_text "ts" "h" "u" "bu" "k" "b" "r" "t")"
    [[ "$out" == *"reflects the system as of"* ]]
    [[ "$out" == *"will also undo those"* ]]
}

@test "generate_recovery_script_text produces syntactically valid bash" {
    local script_file
    script_file="${TEST_TMPDIR}/restore.sh"
    generate_recovery_script_text "ts" "/root/backup" "/boot/target" "6.8.0-generic" > "$script_file"
    bash -n "$script_file"
}

@test "generate_recovery_script_text is fully self-contained: no reference to Warden's own lib files" {
    local out
    out="$(generate_recovery_script_text "ts" "/root/backup" "/boot/target" "6.8.0-generic")"
    [[ "$out" != *"lib/core"* ]]
    [[ "$out" != *"lib/features"* ]]
    [[ "$out" != *"source "*".sh"* ]]
}

@test "the generated recovery script cancels cleanly on anything other than RESTORE" {
    local backup_file="${TEST_TMPDIR}/backup.img" target_file="${TEST_TMPDIR}/target.img" script_file="${TEST_TMPDIR}/restore.sh"
    printf 'backup-content' > "$backup_file"
    printf 'original-target-content' > "$target_file"
    generate_recovery_script_text "ts" "$backup_file" "$target_file" "some-other-kernel" > "$script_file"
    chmod +x "$script_file"
    run bash -c "echo 'not restore' | '$script_file'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Cancelled"* ]]
    [ "$(cat "$target_file")" = "original-target-content" ]
}

@test "the generated recovery script restores the backup and preserves the overwritten file when confirmed" {
    local backup_file="${TEST_TMPDIR}/backup.img" target_file="${TEST_TMPDIR}/target.img" script_file="${TEST_TMPDIR}/restore.sh"
    printf 'backup-content' > "$backup_file"
    printf 'original-target-content' > "$target_file"
    generate_recovery_script_text "ts" "$backup_file" "$target_file" "some-other-kernel" > "$script_file"
    chmod +x "$script_file"
    run bash -c "echo 'RESTORE' | '$script_file'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Restored"* ]]
    [ "$(cat "$target_file")" = "backup-content" ]
    # The file it overwrote must itself have been preserved, not lost.
    local preserved
    preserved="$(find "${TEST_TMPDIR}" -maxdepth 1 -name 'target.img.pre-restore-*')"
    [ -n "$preserved" ]
    [ "$(cat "$preserved")" = "original-target-content" ]
}

@test "the generated recovery script refuses cleanly when the backup file is missing" {
    local backup_file="${TEST_TMPDIR}/does-not-exist.img" target_file="${TEST_TMPDIR}/target2.img" script_file="${TEST_TMPDIR}/restore2.sh"
    printf 'original' > "$target_file"
    generate_recovery_script_text "ts" "$backup_file" "$target_file" "k" > "$script_file"
    chmod +x "$script_file"
    run bash -c "echo 'RESTORE' | '$script_file'"
    [ "$status" -ne 0 ]
    [[ "$output" == *"backup file not found"* ]]
    [ "$(cat "$target_file")" = "original" ]
}

@test "the generated recovery script warns when run on a system already on the target kernel" {
    local backup_file="${TEST_TMPDIR}/backup3.img" target_file="${TEST_TMPDIR}/target3.img" script_file="${TEST_TMPDIR}/restore3.sh"
    printf 'backup' > "$backup_file"
    printf 'target' > "$target_file"
    generate_recovery_script_text "ts" "$backup_file" "$target_file" "$(uname -r)" > "$script_file"
    chmod +x "$script_file"
    run bash -c "echo 'not restore' | '$script_file'"
    [[ "$output" == *"WARNING"* ]]
    [[ "$output" == *"likely nothing to restore"* ]]
}

@test "prune_recovery_kits keeps only the most recent N and removes the rest" {
    local dir="${TEST_TMPDIR}/kits"
    mkdir -p "$dir"/2026010100000{1,2,3,4,5}Z
    prune_recovery_kits "$dir" 3
    [ "$(find "$dir" -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 3 ]
    [ ! -d "${dir}/20260101000001Z" ]
    [ ! -d "${dir}/20260101000002Z" ]
    [ -d "${dir}/20260101000005Z" ]
}

@test "prune_recovery_kits never prunes below 1 even if retain is passed as 0" {
    local dir="${TEST_TMPDIR}/kits2"
    mkdir -p "$dir"/2026010100000{1,2}Z
    prune_recovery_kits "$dir" 0
    [ "$(find "$dir" -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 1 ]
}

@test "prune_recovery_kits does nothing when the directory doesn't exist yet" {
    run prune_recovery_kits "${TEST_TMPDIR}/does-not-exist-kits" 3
    [ "$status" -eq 0 ]
}

@test "create_root_unlock_recovery_kit in dry-run mode does not write anything" {
    WARDEN_ROOT_UNLOCK_BOOT_DIR="${TEST_TMPDIR}/boot-kits"
    WARDEN_ROOT_UNLOCK_ROOT_DIR="${TEST_TMPDIR}/root-kits"
    local source="${TEST_TMPDIR}/initrd.img-fake"
    printf 'fake-initramfs-content' > "$source"
    WARDEN_DRY_RUN=1 create_root_unlock_recovery_kit "$source" >/dev/null
    [ ! -d "$WARDEN_ROOT_UNLOCK_BOOT_DIR" ]
    [ ! -d "$WARDEN_ROOT_UNLOCK_ROOT_DIR" ]
    grep -q "DRY-RUN" "$WARDEN_LOG_FILE"
}

@test "create_root_unlock_recovery_kit writes a full kit with backup, guide, script, and latest symlinks" {
    WARDEN_ROOT_UNLOCK_BOOT_DIR="${TEST_TMPDIR}/boot-kits"
    WARDEN_ROOT_UNLOCK_ROOT_DIR="${TEST_TMPDIR}/root-kits"
    local source="${TEST_TMPDIR}/initrd.img-6.8.0-fake"
    printf 'fake-initramfs-content' > "$source"

    local ts
    ts="$(WARDEN_DRY_RUN=0 create_root_unlock_recovery_kit "$source")"
    [ -n "$ts" ]

    [ -f "${WARDEN_ROOT_UNLOCK_BOOT_DIR}/${ts}/GUIDE.txt" ]
    [ -x "${WARDEN_ROOT_UNLOCK_BOOT_DIR}/${ts}/restore.sh" ]
    [ -f "${WARDEN_ROOT_UNLOCK_ROOT_DIR}/${ts}/initrd.img.bak" ]
    [ "$(cat "${WARDEN_ROOT_UNLOCK_ROOT_DIR}/${ts}/initrd.img.bak")" = "fake-initramfs-content" ]
    [ "$(readlink "${WARDEN_ROOT_UNLOCK_BOOT_DIR}/latest")" = "$ts" ]
    [ "$(readlink "${WARDEN_ROOT_UNLOCK_ROOT_DIR}/latest")" = "$ts" ]
}

@test "create_root_unlock_recovery_kit refuses when the source initramfs doesn't exist" {
    WARDEN_ROOT_UNLOCK_BOOT_DIR="${TEST_TMPDIR}/boot-kits3"
    WARDEN_ROOT_UNLOCK_ROOT_DIR="${TEST_TMPDIR}/root-kits3"
    run create_root_unlock_recovery_kit "${TEST_TMPDIR}/does-not-exist-initramfs"
    [ "$status" -ne 0 ]
}

@test "current_initramfs_path uses the running kernel version" {
    [ "$(current_initramfs_path)" = "/boot/initrd.img-$(uname -r)" ]
}

@test "is_root_unlock_enabled reflects whether clevis-initramfs is installed" {
    local out expected
    out="$(is_root_unlock_enabled && echo yes || echo no)"
    if is_pkg_installed clevis-initramfs; then expected="yes"; else expected="no"; fi
    [ "$out" = "$expected" ]
}

@test "install_clevis_initramfs_and_regenerate in dry-run mode does not touch anything" {
    WARDEN_DRY_RUN=1 install_clevis_initramfs_and_regenerate
    grep -q "DRY-RUN" "$WARDEN_LOG_FILE"
    run grep -q "RUN regenerate initramfs" "$WARDEN_LOG_FILE"
    [ "$status" -ne 0 ]
}

@test "any_tang_address_is_local is true for a plain tang pin pointing at this host" {
    local own_ip
    own_ip="$(ip -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)"
    if [ -z "$own_ip" ]; then
        skip "no global-scope address found on this machine to test against"
    fi
    local pin_config
    pin_config="$(build_tang_pin_config "http://${own_ip}:7500")"
    any_tang_address_is_local "$pin_config"
}

@test "any_tang_address_is_local is false for a plain tang pin pointing elsewhere" {
    local pin_config
    pin_config="$(build_tang_pin_config "http://203.0.113.1:7500")"
    run any_tang_address_is_local "$pin_config"
    [ "$status" -ne 0 ]
}

@test "any_tang_address_is_local checks every address nested inside an sss pin, not just the first" {
    local pin_config
    pin_config="$(build_sss_pin_config 1 "$(printf 'http://203.0.113.1:7500\nhttp://127.0.0.1:7500')" 0)"
    any_tang_address_is_local "$pin_config"
}

@test "any_tang_address_is_local is false for a plain tpm2 pin (no tang addresses at all)" {
    run any_tang_address_is_local "$(build_tpm2_pin_config)"
    [ "$status" -ne 0 ]
}

@test "create_root_unlock_recovery_kit respects retention across repeated calls" {
    WARDEN_ROOT_UNLOCK_BOOT_DIR="${TEST_TMPDIR}/boot-kits4"
    WARDEN_ROOT_UNLOCK_ROOT_DIR="${TEST_TMPDIR}/root-kits4"
    WARDEN_ROOT_UNLOCK_RETAIN=2
    local source="${TEST_TMPDIR}/initrd.img-x"
    printf 'v1' > "$source"
    create_root_unlock_recovery_kit "$source" >/dev/null
    sleep 1
    printf 'v2' > "$source"
    create_root_unlock_recovery_kit "$source" >/dev/null
    sleep 1
    printf 'v3' > "$source"
    create_root_unlock_recovery_kit "$source" >/dev/null

    [ "$(find "$WARDEN_ROOT_UNLOCK_BOOT_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 2 ]
    [ "$(find "$WARDEN_ROOT_UNLOCK_ROOT_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 2 ]
}

@test "root_unlock_action_enable refuses to redo setup once already enabled" {
    local body
    body="$(declare -f root_unlock_action_enable)"
    [[ "$body" == *"is_root_unlock_enabled"* ]]
}

@test "root_unlock_action_enable refuses a root that isn't LUKS-encrypted" {
    local body
    body="$(declare -f root_unlock_action_enable)"
    [[ "$body" == *"resolve_root_luks_device"* ]]
}

@test "root_unlock_action_enable checks the boot-layout precondition" {
    local body
    body="$(declare -f root_unlock_action_enable)"
    [[ "$body" == *"is_boot_separate_from_root"* ]]
}

@test "root_unlock_action_enable requires the recovery-media confirmation before the pin menu" {
    local body before after
    body="$(declare -f root_unlock_action_enable)"
    [[ "$body" == *"Recovery media check"* ]]
    before="${body%%Recovery media check*}"
    after="${body#*Recovery media check}"
    [[ "$before" != *"Pin type"* ]]
    [[ "$after" == *"Pin type"* ]]
}

@test "root_unlock_action_enable checks TPM2 presence before offering the tpm2 pin" {
    local body
    body="$(declare -f root_unlock_action_enable)"
    [[ "$body" == *"is_tpm2_present"* ]]
}

@test "root_unlock_action_enable also checks clevis-tpm2 is installed, not just TPM hardware presence" {
    # Found while preparing the real-hardware test: is_tpm2_present only
    # confirms the TPM device node exists -- it says nothing about
    # whether the clevis-tpm2 package (which actually implements the
    # tpm2 pin for clevis) is installed. Binding would otherwise fail
    # confusingly mid-sequence, after the recovery-media confirmation
    # and initramfs regeneration had already happened.
    local body
    body="$(declare -f root_unlock_action_enable)"
    [[ "$body" == *'is_pkg_installed clevis-tpm2'* ]]
}

@test "root_unlock_action_enable hard-blocks a same-host Tang address" {
    local body
    body="$(declare -f root_unlock_action_enable)"
    [[ "$body" == *"is_local_address \"\$host\""* ]]
    [[ "$body" == *"bootstrapping deadlock"* ]]
}

@test "root_unlock_action_enable sequences backup, then regenerate, then bind -- never bind first" {
    # The must-fix ordering detail from docs/future-work.md: binding
    # before regenerating risks the regeneration immediately
    # invalidating a TPM2 seal it just created. Confirms the real
    # (non-preview) calls appear in the right order in the function
    # body, not just that all three are present somewhere.
    local body real_section backup_idx regen_idx bind_idx
    body="$(declare -f root_unlock_action_enable)"
    # Skip past the dry-run preview block (which also calls all three,
    # deliberately) by looking only at what follows it.
    real_section="${body#*Proceed with the real changes now?}"
    backup_idx="${real_section%%create_root_unlock_recovery_kit*}"
    regen_idx="${real_section%%install_clevis_initramfs_and_regenerate*}"
    bind_idx="${real_section%%run_clevis_luks_bind*}"
    [ "${#backup_idx}" -lt "${#regen_idx}" ]
    [ "${#regen_idx}" -lt "${#bind_idx}" ]
}

@test "root_unlock_action_enable never removes the existing passphrase -- only ever calls bind, never unbind" {
    local body
    body="$(declare -f root_unlock_action_enable)"
    [[ "$body" == *"run_clevis_luks_bind"* ]]
    [[ "$body" != *"unbind"* ]]
    [[ "$body" != *"luksKillSlot"* ]]
    [[ "$body" != *"luksRemoveKey"* ]]
}

@test "root_unlock_action_enable never attempts a live test-unlock -- root's device is always in use while Warden runs" {
    # Regression test for a real failure found on real hardware:
    # root's LUKS device is *always* already open/mounted whenever
    # Warden itself is running (Warden runs from the booted OS on that
    # very device), so cryptsetup refuses a second mapping outright
    # every single time ("Cannot use device ... which is in use").
    # Unlike the ZFS case, there is no export/close/reopen workaround
    # possible here: you cannot unmount a running system's own root
    # filesystem to test it. The first version of this action called
    # test_unlock_and_cleanup anyway and it failed on the very first
    # real-hardware run.
    local body
    body="$(declare -f root_unlock_action_enable)"
    [[ "$body" != *"test_unlock_and_cleanup"* ]]
    [[ "$body" == *"could NOT be verified with a live test-unlock"* ]]
    [[ "$body" == *"actual reboot is the only real proof"* || "$body" == *"reboot and confirmed"* ]]
}

# --- Add --------------------------------------------------------------

@test "root_unlock_action_add refuses when root-drive unlock isn't enabled yet" {
    local body
    body="$(declare -f root_unlock_action_add)"
    [[ "$body" == *"is_root_unlock_enabled"* ]]
    [[ "$body" == *"Not enabled yet"* ]]
}

@test "root_unlock_action_add shows current bindings before offering the pin menu" {
    local body before after
    body="$(declare -f root_unlock_action_add)"
    before="${body%%Pin type*}"
    after="${body#*Pin type}"
    [[ "$before" == *"Current bindings"* ]]
}

@test "root_unlock_action_add hard-blocks a same-host Tang address, same as Enable" {
    local body
    body="$(declare -f root_unlock_action_add)"
    [[ "$body" == *"is_local_address \"\$host\""* ]]
    [[ "$body" == *"bootstrapping deadlock"* ]]
}

@test "root_unlock's Tang reachability check is explicit that it doesn't prove initramfs-stage reachability" {
    # Raised as a question, not found as a live failure: check_tang_reachability
    # runs curl from the already-booted OS's full network stack -- it says
    # nothing about whether clevis-initramfs's own network bring-up can reach
    # the same server before the real OS is even running. Every place root
    # unlock offers a Tang pin (Enable, Add, Rotate) must say so explicitly,
    # since that gap is exactly what an actual reboot is still needed to prove.
    for fn in root_unlock_action_enable root_unlock_action_add root_unlock_action_rotate; do
        local body
        body="$(declare -f "$fn")"
        [[ "$body" == *"does NOT prove clevis-initramfs can reach it"* ]]
    done
}

@test "root_unlock_action_add checks clevis-tpm2 is installed, not just TPM hardware presence" {
    local body
    body="$(declare -f root_unlock_action_add)"
    [[ "$body" == *"is_tpm2_present"* ]]
    [[ "$body" == *'is_pkg_installed clevis-tpm2'* ]]
}

@test "root_unlock_action_add never regenerates the initramfs and never attempts a live test-unlock" {
    # Add only ever needs run_clevis_luks_bind -- no
    # install_clevis_initramfs_and_regenerate (the hook already reads
    # bindings live off the LUKS header), and no test_unlock_and_cleanup
    # for the same fundamental reason as Enable.
    local body
    body="$(declare -f root_unlock_action_add)"
    [[ "$body" == *"run_clevis_luks_bind"* ]]
    [[ "$body" != *"install_clevis_initramfs_and_regenerate"* ]]
    [[ "$body" != *"test_unlock_and_cleanup"* ]]
    [[ "$body" != *"unbind"* ]]
}

# --- Remove -------------------------------------------------------------

@test "root_unlock_action_remove refuses when root-drive unlock isn't enabled yet" {
    local body
    body="$(declare -f root_unlock_action_remove)"
    [[ "$body" == *"is_root_unlock_enabled"* ]]
    [[ "$body" == *"Not enabled yet"* ]]
}

@test "root_unlock_action_remove only ever unbinds through the hard-gated primitive" {
    local body
    body="$(declare -f root_unlock_action_remove)"
    [[ "$body" == *"run_clevis_luks_unbind"* ]]
    [[ "$body" != *"luksKillSlot"* ]]
    [[ "$body" != *"luksRemoveKey"* ]]
}

@test "root_unlock_action_remove warns explicitly when removing the only remaining binding" {
    local body
    body="$(declare -f root_unlock_action_remove)"
    [[ "$body" == *"ONLY Clevis binding on root"* ]]
}

# --- Rotate ---------------------------------------------------------------

@test "root_unlock_action_rotate refuses when root-drive unlock isn't enabled yet" {
    local body
    body="$(declare -f root_unlock_action_rotate)"
    [[ "$body" == *"is_root_unlock_enabled"* ]]
    [[ "$body" == *"Not enabled yet"* ]]
}

@test "root_unlock_action_rotate never removes the old binding before the new bind call succeeds" {
    local body bind_idx unbind_idx
    body="$(declare -f root_unlock_action_rotate)"
    bind_idx="${body%%run_clevis_luks_bind*}"
    unbind_idx="${body%%run_clevis_luks_unbind*}"
    [ "${#bind_idx}" -lt "${#unbind_idx}" ]
}

@test "root_unlock_action_rotate is explicit that the new binding is not live-verified before offering to remove the old one" {
    # Unlike menu 10's rotate (which test-unlocks the new slot before
    # ever offering to remove the old one), root's rotate can't do
    # that -- root's device is always in use while Warden runs. This
    # must never be silently glossed over.
    local body
    body="$(declare -f root_unlock_action_rotate)"
    [[ "$body" != *"test_unlock_and_cleanup"* ]]
    [[ "$body" == *"NOT the same as a verified working binding"* || "$body" == *"cannot be confirmed with a live test-unlock"* ]]
}

@test "root_unlock_action_rotate hard-blocks a same-host Tang address, same as Enable" {
    local body
    body="$(declare -f root_unlock_action_rotate)"
    [[ "$body" == *"is_local_address \"\$host\""* ]]
    [[ "$body" == *"bootstrapping deadlock"* ]]
}

# --- Status / drift check --------------------------------------------------

@test "record_initramfs_reference then drift_status reports no drift for the same file" {
    export WARDEN_ROOT_UNLOCK_ROOT_DIR="${TEST_TMPDIR}/root-kit"
    local fake_initrd="${TEST_TMPDIR}/initrd.img-fake"
    echo "same content" > "$fake_initrd"
    current_initramfs_path() { echo "$fake_initrd"; }
    export -f current_initramfs_path

    record_initramfs_reference "$fake_initrd"

    local out
    out="$(root_unlock_initramfs_drift_status)"
    [[ "$out" == *"no drift detected"* ]]
}

@test "root_unlock_initramfs_drift_status reports drift when the current initramfs no longer matches the recorded reference" {
    export WARDEN_ROOT_UNLOCK_ROOT_DIR="${TEST_TMPDIR}/root-kit"
    local fake_initrd="${TEST_TMPDIR}/initrd.img-fake"
    echo "content as it was when last recorded" > "$fake_initrd"
    current_initramfs_path() { echo "$fake_initrd"; }
    export -f current_initramfs_path
    record_initramfs_reference "$fake_initrd"

    echo "new content -- something regenerated this" > "$fake_initrd"

    local out
    out="$(root_unlock_initramfs_drift_status)"
    [[ "$out" == *"DRIFT DETECTED"* ]]
}

@test "a recovery kit's own pre-change backup never matching the post-change initramfs is not reported as drift" {
    # Regression test for a real bug found live: right after a real
    # Enable, Status previously reported DRIFT DETECTED permanently,
    # because the drift check compared against the recovery kit's own
    # backup file -- which is deliberately the PRE-change image (needed
    # to revert), and so can never match the initramfs once
    # install_clevis_initramfs_and_regenerate has actually run. The fix
    # is a separate reference file, recorded only after the action that
    # changed the initramfs finishes, decoupled from the kit backup.
    export WARDEN_ROOT_UNLOCK_ROOT_DIR="${TEST_TMPDIR}/root-kit"
    mkdir -p "${WARDEN_ROOT_UNLOCK_ROOT_DIR}/20260101T000000Z"
    echo "pre-change content" > "${WARDEN_ROOT_UNLOCK_ROOT_DIR}/20260101T000000Z/initrd.img.bak"
    ln -sfn "20260101T000000Z" "${WARDEN_ROOT_UNLOCK_ROOT_DIR}/latest"

    local fake_initrd="${TEST_TMPDIR}/initrd.img-fake"
    echo "post-change content, as Warden itself just left it" > "$fake_initrd"
    current_initramfs_path() { echo "$fake_initrd"; }
    export -f current_initramfs_path
    record_initramfs_reference "$fake_initrd"

    local out
    out="$(root_unlock_initramfs_drift_status)"
    [[ "$out" == *"no drift detected"* ]]
}

@test "build_tpm2_pin_config never sets pcr_bank/pcr_ids -- Warden's tpm2 bindings are never PCR-sealed" {
    # Confirmed live by decoding a real bound JWE token on the LUKS-root
    # test VM: the protected header contained only {"hash":"sha256",
    # "key":"ecc"} under clevis.tpm2 -- no pcr_bank or pcr_ids anywhere.
    # This means an initramfs content change (a kernel update, a manual
    # update-initramfs -u run) can never invalidate a Warden-created
    # tpm2 binding, since there is no PCR policy tying it to measured
    # boot state at all. The drift check must never claim otherwise.
    local out
    out="$(build_tpm2_pin_config)"
    [[ "$out" != *"pcr"* ]]
}

@test "root_unlock_initramfs_drift_status never claims drift could invalidate a TPM2 binding" {
    # Regression test: an earlier version of this message warned that
    # drift could "silently invalidate a PCR-sealed binding" when a
    # tpm2 pin was in use. False for Warden's own bindings -- see the
    # build_tpm2_pin_config test above -- and has been removed.
    local body
    body="$(declare -f root_unlock_initramfs_drift_status)"
    [[ "$body" != *"PCR-sealed"* ]]
    [[ "$body" != *"invalidate"* ]]
}

@test "root_unlock_initramfs_drift_status reports no reference recorded yet when there is none" {
    export WARDEN_ROOT_UNLOCK_ROOT_DIR="${TEST_TMPDIR}/root-kit-empty"
    local fake_initrd="${TEST_TMPDIR}/initrd.img-fake2"
    echo "content" > "$fake_initrd"
    current_initramfs_path() { echo "$fake_initrd"; }
    export -f current_initramfs_path

    local out
    out="$(root_unlock_initramfs_drift_status)"
    [[ "$out" == *"No reference recorded yet"* ]]
}

@test "root_unlock_action_status is read-only and includes the drift check" {
    local body
    body="$(declare -f root_unlock_action_status)"
    [[ "$body" == *"root_unlock_initramfs_drift_status"* ]]
    [[ "$body" != *"run_cmd"* ]]
    [[ "$body" != *"run_clevis_luks_bind"* ]]
    [[ "$body" != *"run_clevis_luks_unbind"* ]]
}

# --- Snapshot ---------------------------------------------------------------

@test "root_unlock_action_snapshot refuses when root-drive unlock isn't enabled yet" {
    local body
    body="$(declare -f root_unlock_action_snapshot)"
    [[ "$body" == *"is_root_unlock_enabled"* ]]
    [[ "$body" == *"Not enabled yet"* ]]
}

@test "root_unlock_action_snapshot creates a recovery kit independent of any binding change" {
    local body
    body="$(declare -f root_unlock_action_snapshot)"
    [[ "$body" == *"create_root_unlock_recovery_kit"* ]]
    [[ "$body" != *"run_clevis_luks_bind"* ]]
    [[ "$body" != *"run_clevis_luks_unbind"* ]]
}

@test "root_unlock_action_snapshot updates the drift-check reference, not just the kit" {
    local body
    body="$(declare -f root_unlock_action_snapshot)"
    [[ "$body" == *"record_initramfs_reference"* ]]
}

@test "root_unlock_action_enable records the drift-check reference only after a successful bind" {
    local body bind_idx record_idx real_section
    body="$(declare -f root_unlock_action_enable)"
    [[ "$body" == *"record_initramfs_reference"* ]]
    real_section="${body#*Proceed with the real changes now?}"
    bind_idx="${real_section%%run_clevis_luks_bind*}"
    record_idx="${real_section%%record_initramfs_reference*}"
    [ "${#bind_idx}" -lt "${#record_idx}" ]
}

# --- Disable ----------------------------------------------------------------

@test "root_unlock_action_disable is a no-op when already disabled" {
    local body
    body="$(declare -f root_unlock_action_disable)"
    [[ "$body" == *"is_root_unlock_enabled"* ]]
    [[ "$body" == *"Already disabled"* ]]
}

@test "root_unlock_action_disable removes every binding before touching the clevis-initramfs package" {
    local body unbind_idx remove_pkg_idx
    body="$(declare -f root_unlock_action_disable)"
    unbind_idx="${body%%run_clevis_luks_unbind*}"
    remove_pkg_idx="${body%%ensure_pkg_removed*}"
    [ "${#unbind_idx}" -lt "${#remove_pkg_idx}" ]
}

@test "root_unlock_action_disable backs up the initramfs before removing the package" {
    local body backup_idx remove_pkg_idx
    body="$(declare -f root_unlock_action_disable)"
    backup_idx="${body%%create_root_unlock_recovery_kit*}"
    remove_pkg_idx="${body%%ensure_pkg_removed*}"
    [ "${#backup_idx}" -lt "${#remove_pkg_idx}" ]
}

@test "root_unlock_action_disable never removes existing recovery kits" {
    local body
    body="$(declare -f root_unlock_action_disable)"
    [[ "$body" != *"rm -rf \${WARDEN_ROOT_UNLOCK"* ]]
    [[ "$body" != *"rm -rf \"\${WARDEN_ROOT_UNLOCK"* ]]
}

# --- Menu wiring --------------------------------------------------------

@test "feature_root_unlock_menu offers all seven actions" {
    local body
    body="$(declare -f feature_root_unlock_menu)"
    for action in root_unlock_action_enable root_unlock_action_add root_unlock_action_remove root_unlock_action_rotate root_unlock_action_status root_unlock_action_snapshot root_unlock_action_disable; do
        [[ "$body" == *"$action"* ]]
    done
}
