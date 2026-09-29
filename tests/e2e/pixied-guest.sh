#!/usr/bin/env bash
# @brief Guest-side real PixiEden and direct runtime verification.
# @description
# Runs as root inside a disposable Ubuntu VM. The PixiEden install itself runs
# as an unprivileged user and verifies its direct shell and job paths.

set -Eeuo pipefail
umask 022

readonly PHASE="${PIXIED_E2E_PHASE:?PIXIED_E2E_PHASE is required}"
readonly TEST_USER="pixied-e2e"
readonly USER_ID="2000"
readonly REAL_HOME="/home/$TEST_USER"
readonly RELEASE_ARCHIVE="/home/ubuntu/pixied.tar.gz"
readonly RELEASE_ROOT="/opt/pixied-e2e-release"
readonly RELEASE_SOURCE_DIR="$RELEASE_ROOT/pixied"
readonly MACHINE_ID="multipass-e2e"
readonly DATA_DIR="$REAL_HOME/.local/share/pixied"
readonly STATE_DIR="$REAL_HOME/.local/state/pixied"
readonly COMMAND_BIN="$DATA_DIR/bin"
readonly STATE_FILE="$STATE_DIR/machines/$MACHINE_ID/state"
readonly PROJECT_DIR="$REAL_HOME/pixied-e2e-project"
readonly JOB_LOG="$REAL_HOME/pixied-e2e-job.log"
readonly JOB_PID_FILE="$REAL_HOME/pixied-e2e-job.pid"

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

# @description Assert that a path does not exist.
# @arg $1 string The path that must be absent.
# @exitcode 0 When the path does not exist.
# @exitcode 1 When the path exists.
assert_absent() {
    [ ! -e "$1" ] || fail "unexpected path: $1"
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
            PIXIED_MACHINE_ID="$MACHINE_ID" \
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

# @description Assert the generated state and direct runtime artifacts.
# @exitcode 0 When the installation resources are verified.
# @exitcode 1 When any resource is missing or incomplete.
assert_installation() {
    # US-101-1
    assert_file "$STATE_FILE"
    assert_file "$COMMAND_BIN/pixied"
    assert_file "$COMMAND_BIN/pixi"
    assert_file "$DATA_DIR/pixi/bin/direnv"
    assert_file "$REAL_HOME/.config/pixied/runtime-hook.bash"
    assert_file "$REAL_HOME/.local/bin/pixied"
    [ -d "$DATA_DIR/pixi/bin/trampoline_configuration" ] ||
        fail "Pixi Global package configuration is missing"
    [ -z "$(find "$DATA_DIR/pixi/bin" -mindepth 1 -maxdepth 1 \
        ! -name direnv ! -name trampoline_configuration -print -quit)" ] ||
        fail "unexpected Pixi global package artifact"
    if grep -Eq '^(systemd|linger|unit_)' "$STATE_FILE"; then
        fail "obsolete host-service state remains"
    fi
    assert_absent "$REAL_HOME/.config/systemd"
}

# @description Verify the real direnv hook in an interactive Bash on a PTY.
# @exitcode 0 When the hook function is available.
# @exitcode 1 When the hook cannot be evaluated.
verify_direnv_hook_through_pty() {
    local output=/tmp/pixied-e2e-direnv.log
    step "evaluating the real direnv hook through a PTY"
    if ! printf '%s\n' \
        'eval "$(pixied hook bash)"' \
        'if declare -F _direnv_hook >/dev/null; then printf "direnv-hook=ready\\n"; else exit 1; fi' \
        'exit' |
        run_user env -u PIXIED_RUNTIME_HOOK_ACTIVE TERM=xterm-256color \
            timeout --foreground 20 script -qec 'bash --noprofile --norc -i' \
            /dev/null >"$output" 2>&1; then
        cat "$output" >&2
        fail "real direnv hook did not load"
    fi
    assert_contains "$output" 'direnv-hook=ready'
}

# @description Start and exit the direct interactive Bash through a PTY.
# @exitcode 0 When the shell accepts input and exits cleanly.
# @exitcode 1 When the shell does not complete as expected.
direct_shell_through_pty() {
    local output=/tmp/pixied-e2e-shell.log
    step "starting the direct interactive Bash through a PTY"
    if ! printf '%s\n' \
        'printf "shell-home=%s\\n" "$HOME"' \
        'printf "shell-pixi=%s\\n" "$PIXI_HOME"' \
        'exit' |
        run_user env TERM=xterm-256color \
            timeout --foreground 20 script -qec "$COMMAND_BIN/pixied shell" \
            /dev/null >"$output" 2>&1; then
        cat "$output" >&2
        fail "direct interactive shell did not exit cleanly"
    fi
    assert_contains "$output" "shell-home=$REAL_HOME"
    assert_contains "$output" "shell-pixi=$DATA_DIR/pixi"
}

# @description Create a small real Pixi project for the background-job check.
# @exitcode 0 When the project manifest is ready.
# @exitcode 1 When the manifest cannot be written.
prepare_pixi_project() {
    rm -rf -- "$PROJECT_DIR"
    mkdir -p "$PROJECT_DIR"
    cat >"$PROJECT_DIR/pixi.toml" <<'TOML'
[workspace]
name = "pixied-e2e"
channels = ["conda-forge"]
platforms = ["linux-64"]

[tasks]
sighup-survival = "printf started; sleep 2; printf survived-after-sighup"
TOML
    chown -R "$TEST_USER:$TEST_USER" "$PROJECT_DIR"
}

# @description Start a nohup Pixi task and send SIGHUP to its launcher.
# @exitcode 0 When the launcher is interrupted after starting the job.
# @exitcode 1 When the launcher or job cannot be started.
start_nohup_pixi_job() {
    local exit_code
    rm -f -- "$JOB_LOG" "$JOB_PID_FILE"
    step "starting a nohup Pixi task and sending SIGHUP to its launcher"
    set +e
    run_user env PIXI_HOME="$DATA_DIR/pixi" \
        PIXI_CACHE_DIR="$DATA_DIR/pixi/cache" \
        bash -c '
            cd -- "$1"
            nohup pixi run sighup-survival >"$2" 2>&1 &
            printf "%s\n" "$!" >"$3"
            kill -HUP "$$"
        ' bash "$PROJECT_DIR" "$JOB_LOG" "$JOB_PID_FILE"
    exit_code=$?
    set -e
    case "$exit_code" in
    0 | 129) ;;
    *) fail "SIGHUP launcher exited unexpectedly: $exit_code" ;;
    esac
    assert_file "$JOB_PID_FILE"
}

# @description Verify that the nohup Pixi task completes after SIGHUP.
# @exitcode 0 When the task writes its completion marker.
# @exitcode 1 When the task exits early or times out.
assert_nohup_pixi_job() {
    job_completed() {
        [ -f "$JOB_LOG" ] && grep -Fq -- 'survived-after-sighup' "$JOB_LOG"
    }
    wait_for "nohup Pixi task" job_completed
    assert_contains "$JOB_LOG" 'started'
    assert_contains "$JOB_LOG" 'survived-after-sighup'
}

# @description Install PixiEden and verify direct runtime behavior.
# @exitcode 0 When install and direct runtime checks succeed.
# @exitcode 1 When the guest check fails.
install_phase() {
    [ "$(id -u)" = 0 ] || fail "guest runner must run as root"
    step "installing guest dependencies"
    apt_install bash ca-certificates curl tar util-linux
    ensure_test_user
    prepare_release
    step "installing PixiEden with real Pixi"
    run_user env PIXIED_HOME_MODE=local PIXIED_MACHINE_ID="$MACHINE_ID" \
        bash "$RELEASE_SOURCE_DIR/install-local.sh" \
        --home-mode local --yes
    assert_installation
    verify_direnv_hook_through_pty
    direct_shell_through_pty
    prepare_pixi_project
    start_nohup_pixi_job
    assert_nohup_pixi_job
}

# @description Dispatch the requested guest phase.
# @exitcode 0 When the selected phase succeeds.
# @exitcode 1 When the phase is invalid or fails.
main() {
    case "$PHASE" in
    install) install_phase ;;
    *) fail "invalid guest phase: $PHASE" ;;
    esac
}

main "$@"
