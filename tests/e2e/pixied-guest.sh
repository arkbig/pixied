#!/usr/bin/env bash
# @brief Guest-side real PixiEden systemd and Zellij verification.
# @description
# Runs as root inside a disposable Ubuntu VM. The PixiEden install itself runs
# as an unprivileged user and uses a narrowly scoped sudo rule for linger.

set -Eeuo pipefail

readonly PHASE="${PIXIED_E2E_PHASE:?PIXIED_E2E_PHASE is required}"
readonly TEST_USER="pixied-e2e"
readonly USER_ID="2000"
readonly REAL_HOME="/home/$TEST_USER"
readonly RUNTIME_DIR="/run/user/$USER_ID"
readonly USER_BUS="unix:path=$RUNTIME_DIR/bus"
readonly RELEASE_ARCHIVE="/home/ubuntu/pixied.tar.gz"
readonly RELEASE_ROOT="/opt/pixied-e2e-release"
readonly RELEASE_SOURCE_DIR="$RELEASE_ROOT/pixied"
readonly MACHINE_ID="multipass-e2e"
readonly DATA_DIR="$REAL_HOME/.local/share/pixied"
readonly STATE_DIR="$REAL_HOME/.local/state/pixied"
readonly COMMAND_BIN="$DATA_DIR/bin"
readonly STATE_FILE="$STATE_DIR/machines/$MACHINE_ID/state"
readonly UNIT_NAME="pixied-$MACHINE_ID.service"
readonly UNIT="$REAL_HOME/.config/systemd/user/$UNIT_NAME"
readonly SESSION_NAME="pixied-$MACHINE_ID"

export DEBIAN_FRONTEND=noninteractive

# @description Print an error and terminate the guest check.
# @arg $@ string The error message.
# @stderr The error message.
# @exitcode 1 Always.
fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

# @description Print a phase step.
# @arg $@ string The step description.
# @stdout The step message.
# @exitcode 0 Always.
step() {
    printf '[guest:%s] %s\n' "$PHASE" "$*"
}

# @description Assert that a regular file exists.
# @arg $1 string The expected file path.
# @exitcode 0 When the file exists.
# @exitcode 1 When it does not exist.
assert_file() {
    [ -f "$1" ] || fail "expected file: $1"
}

# @description Assert that a file contains a literal string.
# @arg $1 string The file path.
# @arg $2 string The expected text.
# @exitcode 0 When the text exists.
# @exitcode 1 When it does not exist.
assert_contains() {
    local file=$1 text=$2
    grep -Fq -- "$text" "$file" || fail "expected '$text' in $file"
}

# @description Run a command as the unprivileged test user with the user bus set.
# @arg $@ string The command and arguments.
# @exitcode The child command status.
run_user() {
    (
        cd "$REAL_HOME"
        exec runuser -u "$TEST_USER" -- env \
            HOME="$REAL_HOME" USER="$TEST_USER" LOGNAME="$TEST_USER" \
            XDG_RUNTIME_DIR="$RUNTIME_DIR" DBUS_SESSION_BUS_ADDRESS="$USER_BUS" \
            PATH="$COMMAND_BIN:$DATA_DIR/bin:$DATA_DIR/pixi/bin:/usr/local/bin:/usr/bin:/bin" \
            "$@"
    )
}

# @description Wait for a command to succeed for up to one minute.
# @arg $1 string The condition description.
# @arg $@ string The condition command.
# @exitcode 0 When the condition succeeds.
# @exitcode 1 When the condition times out.
wait_for() {
    local description=$1
    shift
    local attempt=1
    while [ "$attempt" -le 60 ]; do
        if "$@"; then
            return 0
        fi
        sleep 1
        attempt=$((attempt + 1))
    done
    fail "timed out waiting for $description"
}

# @description Install the packages required by this guest check.
# @arg $@ string Package names.
# @exitcode 0 When apt succeeds.
# @exitcode 1 When apt fails.
apt_install() {
    apt-get update
    apt-get install -y --no-install-recommends "$@"
}

# @description Create the fixed-UID unprivileged test user.
# @exitcode 0 When the user is ready.
# @exitcode 1 When the user cannot be prepared.
ensure_test_user() {
    if ! id "$TEST_USER" >/dev/null 2>&1; then
        useradd --uid "$USER_ID" --create-home --shell /bin/bash "$TEST_USER"
    fi
    [ "$(id -u "$TEST_USER")" = "$USER_ID" ] ||
        fail "$TEST_USER must have UID $USER_ID"
}

# @description Prepare a user manager without enabling linger before installation.
# @exitcode 0 When the user bus is available.
# @exitcode 1 When systemd cannot provide the user manager.
prepare_user_manager() {
    loginctl disable-linger "$TEST_USER" >/dev/null 2>&1 || true
    systemctl start "user@$USER_ID.service"
    wait_for "systemd user bus" test -S "$RUNTIME_DIR/bus"
    run_user systemctl --user show-environment >/dev/null
}

# @description Grant only the linger command needed by the PixiEden install.
# @exitcode 0 When sudoers validation succeeds.
# @exitcode 1 When the rule is invalid.
configure_sudo() {
    local sudoers=/etc/sudoers.d/pixied-e2e
    printf '%s ALL=(root) NOPASSWD: /usr/bin/loginctl enable-linger %s\n' \
        "$TEST_USER" "$TEST_USER" >"$sudoers"
    chmod 0440 "$sudoers"
    visudo --check >/dev/null
}

# @description Extract and own the transferred PixiEden release archive.
# @exitcode 0 When the source checkout is ready.
# @exitcode 1 When extraction fails.
prepare_release() {
    rm -rf -- "$RELEASE_ROOT"
    mkdir -p "$RELEASE_ROOT"
    tar -xzf "$RELEASE_ARCHIVE" -C "$RELEASE_ROOT"
    chown -R "$TEST_USER:$TEST_USER" "$RELEASE_ROOT"
    [ -x "$RELEASE_SOURCE_DIR/install-local.sh" ] ||
        fail "PixiEden release source is incomplete"
}

# @description Assert the generated state and enabled systemd unit.
# @exitcode 0 When the persistent session resources are verified.
# @exitcode 1 When any resource is missing or incomplete.
assert_installation() {
    # US-101-1
    assert_file "$STATE_FILE"
    assert_file "$UNIT"
    assert_file "$COMMAND_BIN/pixied"
    assert_file "$COMMAND_BIN/pixi"
    assert_file "$DATA_DIR/pixi/bin/direnv"
    assert_file "$DATA_DIR/pixi/bin/zellij"
    assert_file "$REAL_HOME/.config/pixied/runtime-hook.bash"
    assert_file "$REAL_HOME/.local/bin/pixied"
    assert_contains "$STATE_FILE" "session_manager=zellij"
    assert_contains "$STATE_FILE" "systemd_available=1"
    assert_contains "$STATE_FILE" "linger_enabled=1"
    assert_contains "$STATE_FILE" "created_linger=1"
    grep -Eq '^unit_hash=[0-9a-f]{64}$' "$STATE_FILE" ||
        fail "unit hash is missing"
    assert_contains "$UNIT" "ExecStart=$DATA_DIR/pixi/bin/zellij attach --create-background $SESSION_NAME"
    run_user systemctl --user is-enabled --quiet "$UNIT_NAME" ||
        fail "PixiEden unit is not enabled"
}

# @description Start and attach to the session through a real pseudo-terminal.
# The timeout is expected because the attach remains interactive.
# @exitcode 0 When timeout terminates the expected interactive attach.
# @exitcode 1 When attach exits unexpectedly.
attach_through_pty() {
    local output=/tmp/pixied-e2e-attach.log exit_code
    step "attaching to the session through a PTY"
    set +e
    run_user env TERM=xterm-256color PIXIED_MACHINE_ID="$MACHINE_ID" \
        timeout --signal=TERM --kill-after=5 15 \
        script -qec "timeout --signal=TERM --kill-after=5 10 '$COMMAND_BIN/pixied' shell" \
        /dev/null </dev/null >"$output" 2>&1
    exit_code=$?
    set -e
    if [ "$exit_code" -ne 124 ]; then
        cat "$output" >&2
        fail "interactive attach exited unexpectedly: $exit_code"
    fi
}

# @description Check whether the expected Zellij session exists.
# @exitcode 0 When the session exists.
# @exitcode 1 When the session does not exist or cannot be listed.
# @see run_user
session_exists() {
    local sessions
    sessions="$(run_user zellij list-sessions --no-formatting 2>/dev/null)" || return 1
    grep -Eq "(^|[[:space:]])$SESSION_NAME([[:space:]]|$)" <<<"$sessions"
}

# @description Check whether a Zellij process is running for the test user.
# @exitcode 0 When a Zellij process exists.
# @exitcode 1 When no Zellij process exists.
zellij_process_exists() {
    pgrep -u "$TEST_USER" -x zellij >/dev/null
}

# @description Verify that the enabled unit owns a live Zellij session.
# @exitcode 0 When the unit and session are active.
# @exitcode 1 When either is missing.
assert_session() {
    wait_for "PixiEden unit" run_user systemctl --user is-active --quiet "$UNIT_NAME"
    wait_for "Zellij session" session_exists
    wait_for "Zellij process" zellij_process_exists
}

# @description Install PixiEden and verify the first persistent session.
# @exitcode 0 When install and first attach succeed.
# @exitcode 1 When the guest check fails.
install_phase() {
    [ "$(id -u)" = 0 ] || fail "guest runner must run as root"
    step "installing guest dependencies"
    apt_install bash ca-certificates curl dbus-user-session procps sudo tar util-linux
    ensure_test_user
    configure_sudo
    prepare_user_manager
    prepare_release
    step "installing PixiEden with real Pixi and Zellij"
    run_user env PIXIED_HOME_MODE=local PIXIED_SESSION_MANAGER=zellij \
        PIXIED_USE_SUDO=1 PIXIED_MACHINE_ID="$MACHINE_ID" \
        bash "$RELEASE_SOURCE_DIR/install-local.sh" \
        --home-mode local --session-manager zellij --use-sudo yes --yes
    assert_installation
    # US-105-3
    attach_through_pty
    assert_session
}

# @description Verify linger-backed user-manager and session recovery after reboot.
# @exitcode 0 When the persistent session survives reboot.
# @exitcode 1 When recovery fails.
verify_after_reboot_phase() {
    [ "$(id -u)" = 0 ] || fail "guest runner must run as root"
    wait_for "systemd user bus after reboot" test -S "$RUNTIME_DIR/bus"
    wait_for "PixiEden unit after reboot" run_user systemctl --user is-active --quiet "$UNIT_NAME"
    assert_installation
    assert_session
    # US-105-2
    attach_through_pty
    step "reboot recovery verified"
}

# @description Dispatch the requested guest phase.
# @exitcode 0 When the selected phase succeeds.
# @exitcode 1 When the phase is invalid or fails.
main() {
    case "$PHASE" in
    install) install_phase ;;
    verify-after-reboot) verify_after_reboot_phase ;;
    *) fail "invalid guest phase: $PHASE" ;;
    esac
}

main "$@"
