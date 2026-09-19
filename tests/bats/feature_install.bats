#!/usr/bin/env bats

load '../helpers/setup'

setup() { warden_test_setup; }
teardown() { warden_test_teardown; }

@test "install_selected in dry-run mode does not actually install anything" {
    if is_pkg_installed tang; then
        skip "tang is already installed on this machine, dry-run-vs-real can't be distinguished"
    fi
    WARDEN_DRY_RUN=1 install_selected tang 0
    run is_pkg_installed tang
    [ "$status" -ne 0 ]
    grep -q "DRY-RUN" "$WARDEN_LOG_FILE"
}

@test "install_selected skips already-installed packages (idempotent)" {
    WARDEN_DRY_RUN=1 install_selected tang 0
    grep -q "install package tang" "$WARDEN_LOG_FILE" || grep -q "already installed" "$WARDEN_LOG_FILE"
}

@test "install_selected only requests tpm2 when explicitly asked" {
    WARDEN_DRY_RUN=1 install_selected clevis 0
    run grep -q "clevis-tpm2" "$WARDEN_LOG_FILE"
    [ "$status" -ne 0 ]
}

@test "install_selected requests tpm2 when asked" {
    WARDEN_DRY_RUN=1 install_selected clevis 1
    grep -q "clevis-tpm2" "$WARDEN_LOG_FILE"
}

@test "install_selected only requests zfsutils-linux when explicitly asked" {
    WARDEN_DRY_RUN=1 install_selected clevis 0 0
    run grep -q "zfsutils-linux" "$WARDEN_LOG_FILE"
    [ "$status" -ne 0 ]
}

@test "install_selected requests zfsutils-linux when asked" {
    WARDEN_DRY_RUN=1 install_selected clevis 0 1
    grep -q "zfsutils-linux" "$WARDEN_LOG_FILE"
}

@test "install_selected only requests tailscale when explicitly asked" {
    WARDEN_DRY_RUN=1 install_selected clevis 0 0 0
    run grep -q "tailscale" "$WARDEN_LOG_FILE"
    [ "$status" -ne 0 ]
}

@test "install_selected requests tailscale when asked, for tang, clevis, or both" {
    for choice in tang clevis both; do
        WARDEN_LOG_FILE="${TEST_TMPDIR}/log-${choice}"
        : > "$WARDEN_LOG_FILE"
        WARDEN_DRY_RUN=1 install_selected "$choice" 0 0 1
        grep -q "tailscale" "$WARDEN_LOG_FILE"
    done
}

@test "ubuntu_codename reads VERSION_CODENAME from the os-release file" {
    WARDEN_OS_RELEASE_FILE="${TEST_TMPDIR}/os-release"
    printf 'NAME="Ubuntu"\nVERSION_CODENAME=noble\n' > "$WARDEN_OS_RELEASE_FILE"
    [ "$(ubuntu_codename)" = "noble" ]
}

@test "ubuntu_codename falls back to noble when the file is missing or has no codename" {
    WARDEN_OS_RELEASE_FILE="${TEST_TMPDIR}/does-not-exist"
    [ "$(ubuntu_codename)" = "noble" ]
    WARDEN_OS_RELEASE_FILE="${TEST_TMPDIR}/empty-os-release"
    printf 'NAME="Ubuntu"\n' > "$WARDEN_OS_RELEASE_FILE"
    [ "$(ubuntu_codename)" = "noble" ]
}

@test "is_tailscale_repo_configured is false when the apt list file doesn't exist" {
    WARDEN_TAILSCALE_APT_LIST="${TEST_TMPDIR}/does-not-exist.list"
    run is_tailscale_repo_configured
    [ "$status" -ne 0 ]
}

@test "is_tailscale_repo_configured is true once the apt list references pkgs.tailscale.com" {
    WARDEN_TAILSCALE_APT_LIST="${TEST_TMPDIR}/tailscale.list"
    printf 'deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/ubuntu noble main\n' > "$WARDEN_TAILSCALE_APT_LIST"
    is_tailscale_repo_configured
}

@test "ensure_tailscale_repo_configured in dry-run mode does not write anything" {
    WARDEN_TAILSCALE_APT_LIST="${TEST_TMPDIR}/tailscale.list"
    WARDEN_TAILSCALE_KEYRING="${TEST_TMPDIR}/tailscale-archive-keyring.gpg"
    WARDEN_DRY_RUN=1 ensure_tailscale_repo_configured
    [ ! -f "$WARDEN_TAILSCALE_APT_LIST" ]
    [ ! -f "$WARDEN_TAILSCALE_KEYRING" ]
    grep -q "DRY-RUN" "$WARDEN_LOG_FILE"
}

@test "ensure_tailscale_repo_configured is idempotent: skips entirely once already configured" {
    WARDEN_TAILSCALE_APT_LIST="${TEST_TMPDIR}/tailscale.list"
    printf 'deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/ubuntu noble main\n' > "$WARDEN_TAILSCALE_APT_LIST"
    WARDEN_DRY_RUN=0 ensure_tailscale_repo_configured
    grep -q "already configured, skipping" "$WARDEN_LOG_FILE"
}

@test "ensure_tailscale_repo_configured fetches the keyring and apt list from Tailscale's own server, never piping into a shell" {
    WARDEN_TAILSCALE_APT_LIST="${TEST_TMPDIR}/tailscale.list"
    WARDEN_TAILSCALE_KEYRING="${TEST_TMPDIR}/tailscale-archive-keyring.gpg"
    WARDEN_OS_RELEASE_FILE="${TEST_TMPDIR}/os-release"
    printf 'VERSION_CODENAME=noble\n' > "$WARDEN_OS_RELEASE_FILE"
    mkdir -p "${TEST_TMPDIR}/bin"
    cat > "${TEST_TMPDIR}/bin/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl $*" >> "${CALL_LOG}"
# Emulate curl -o writing to the requested output file.
for ((i=1; i<=$#; i++)); do
    if [ "${!i}" = "-o" ]; then
        j=$((i+1))
        touch "${!j}"
    fi
done
exit 0
EOF
    chmod +x "${TEST_TMPDIR}/bin/curl"
    cat > "${TEST_TMPDIR}/bin/apt-get" <<'EOF'
#!/usr/bin/env bash
echo "apt-get $*" >> "${CALL_LOG}"
exit 0
EOF
    chmod +x "${TEST_TMPDIR}/bin/apt-get"
    export CALL_LOG="${TEST_TMPDIR}/calls.log"

    PATH="${TEST_TMPDIR}/bin:${PATH}" WARDEN_DRY_RUN=0 ensure_tailscale_repo_configured

    [ -f "$WARDEN_TAILSCALE_KEYRING" ]
    [ -f "$WARDEN_TAILSCALE_APT_LIST" ]
    grep -qF "curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.noarmor.gpg -o ${WARDEN_TAILSCALE_KEYRING}" "$CALL_LOG"
    grep -qF "curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.tailscale-keyring.list -o ${WARDEN_TAILSCALE_APT_LIST}" "$CALL_LOG"
    grep -qF "apt-get update" "$CALL_LOG"
    # Neither curl invocation should ever be piped into a shell -- both
    # write straight to a file via -o.
    run grep -q '|' "$CALL_LOG"
    [ "$status" -ne 0 ]
}

@test "describe_install_status reports a line for every managed package" {
    local out
    out="$(describe_install_status)"
    for pkg in tang clevis clevis-luks clevis-systemd clevis-tpm2 zfsutils-linux tailscale; do
        echo "$out" | grep -qE "^  ${pkg}: (installed|not installed)$"
    done
}

@test "describe_install_status reflects real dpkg state for tang" {
    local out expected
    out="$(describe_install_status)"
    if is_pkg_installed tang; then expected="  tang: installed"; else expected="  tang: not installed"; fi
    echo "$out" | grep -qxF "$expected"
}
