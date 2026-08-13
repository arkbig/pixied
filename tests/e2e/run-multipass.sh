#!/usr/bin/env bash
# @brief Run PixiEden release-level checks in a disposable Multipass VM.
# @description
# Uses the Windows Multipass client explicitly when running from WSL. The
# guest verifies the real Pixi, direct Zellij attach, and PTY behavior without
# modifying the WSL host.

set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly REPO_ROOT
readonly GUEST_RUNNER="$REPO_ROOT/tests/e2e/pixied-guest.sh"
readonly PACKAGE_SCRIPT="$REPO_ROOT/scripts/package-release.sh"

MULTIPASS="${PIXIED_E2E_MULTIPASS:-multipass.exe}"
IMAGE="${PIXIED_E2E_IMAGE:-24.04}"
CPUS="${PIXIED_E2E_CPUS:-2}"
MEMORY="${PIXIED_E2E_MEMORY:-3G}"
DISK="${PIXIED_E2E_DISK:-16G}"
COMMAND_TIMEOUT="${PIXIED_E2E_TIMEOUT_SECONDS:-3600}"
KEEP_VM=0
CURRENT_VM=""
WORK_DIR=""

# @description Print an error and terminate the runner.
# @arg $@ string The error message.
# @stderr The error message.
# @exitcode 1 Always.
fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

# @description Print runner usage.
# @stdout The usage text.
# @exitcode 0 Always.
usage() {
    cat <<'USAGE'
Usage: tests/e2e/run-multipass.sh [OPTIONS]

Run the real local/zellij PixiEden E2E in a disposable Ubuntu VM.

Options:
  --keep-vm     Keep the VM after success or failure for investigation.
  -h, --help    Show this help.

Environment:
  PIXIED_E2E_MULTIPASS       Multipass executable (default: multipass.exe).
  PIXIED_E2E_IMAGE           Ubuntu image (default: 24.04).
  PIXIED_E2E_CPUS            VM CPUs (default: 2).
  PIXIED_E2E_MEMORY          VM memory (default: 3G).
  PIXIED_E2E_DISK            VM disk (default: 16G).
  PIXIED_E2E_TIMEOUT_SECONDS Per-command timeout (default: 3600).
USAGE
}

# @description Parse command-line options.
# @arg $@ string Runner options.
# @exitcode 0 When options are valid.
# @exitcode 1 When an option is invalid.
parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
        --keep-vm)
            KEEP_VM=1
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            fail "unknown option: $1"
            ;;
        esac
    done
}

# @description Resolve and validate the requested Multipass executable.
# @exitcode 0 When the executable is available.
# @exitcode 1 When it cannot be found.
detect_multipass() {
    if command -v "$MULTIPASS" >/dev/null 2>&1; then
        MULTIPASS="$(command -v "$MULTIPASS")"
    elif [ ! -x "$MULTIPASS" ]; then
        fail "Multipass executable not found: $MULTIPASS"
    fi
}

# @description Convert a WSL path for the Windows Multipass client.
# @arg $1 string The local WSL path.
# @stdout The path accepted by Multipass.
# @exitcode 0 Always.
multipass_path() {
    local path=$1
    if [[ "$MULTIPASS" == *.exe ]] && command -v wslpath >/dev/null 2>&1; then
        wslpath -w "$path"
    else
        printf '%s\n' "$path"
    fi
}

# @description Run Multipass with a bounded timeout.
# @arg $@ string Multipass arguments.
# @exitcode The Multipass command status.
run_multipass() {
    timeout --foreground "$COMMAND_TIMEOUT" "$MULTIPASS" "$@"
}

# @description Wait until a VM accepts exec requests.
# @arg $1 string The VM name.
# @exitcode 0 When the VM is ready.
# @exitcode 1 When readiness times out.
wait_for_vm() {
    local vm=$1 attempt=1
    printf '[E2E] waiting for %s' "$vm"
    while [ "$attempt" -le 36 ]; do
        if timeout --foreground 10 "$MULTIPASS" exec "$vm" -- true >/dev/null 2>&1; then
            printf ' ready\n'
            return 0
        fi
        printf '.'
        sleep 5
        attempt=$((attempt + 1))
    done
    printf ' failed\n' >&2
    run_multipass info "$vm" >&2 || true
    fail "VM did not become ready: $vm"
}

# @description Delete a VM without masking the original test status.
# @arg $1 string The VM name.
# @exitcode 0 Always.
delete_vm() {
    run_multipass delete --purge "$1" >/dev/null 2>&1 || true
}

# @description Clean the VM and local archive after the runner exits.
# @exitcode The original runner status.
cleanup() {
    local exit_code=$?
    if [ -n "$CURRENT_VM" ]; then
        if [ "$KEEP_VM" -eq 1 ]; then
            printf 'INFO: keeping Multipass VM: %s\n' "$CURRENT_VM" >&2
        else
            delete_vm "$CURRENT_VM"
        fi
    fi
    if [ -n "$WORK_DIR" ]; then
        rm -rf -- "$WORK_DIR"
    fi
    exit "$exit_code"
}

# @description Build the release archive and run the direct-attach guest check.
# @exitcode 0 When all guest checks succeed.
# @exitcode 1 When the VM or guest check fails.
main() {
    local archive guest_runner
    parse_args "$@"
    detect_multipass
    command -v timeout >/dev/null 2>&1 || fail "timeout command is required"
    [ -f "$GUEST_RUNNER" ] || fail "guest runner not found: $GUEST_RUNNER"
    [ -x "$PACKAGE_SCRIPT" ] || fail "release packager not found: $PACKAGE_SCRIPT"

    WORK_DIR=$(mktemp -d)
    trap cleanup EXIT INT TERM
    archive="$WORK_DIR/pixied.tar.gz"
    bash "$PACKAGE_SCRIPT" "$archive" >/dev/null

    CURRENT_VM="pixied-e2e-$(date +%s)-$$"
    run_multipass launch "$IMAGE" --name "$CURRENT_VM" \
        --cpus "$CPUS" --memory "$MEMORY" --disk "$DISK" --timeout 900
    wait_for_vm "$CURRENT_VM"

    run_multipass transfer "$(multipass_path "$archive")" \
        "$CURRENT_VM:/home/ubuntu/pixied.tar.gz"
    guest_runner=$(multipass_path "$GUEST_RUNNER")
    run_multipass transfer "$guest_runner" \
        "$CURRENT_VM:/home/ubuntu/pixied-guest.sh"

    printf '[E2E] installing real Pixi and attaching directly to Zellij\n'
    run_multipass exec "$CURRENT_VM" -- sudo env \
        PIXIED_E2E_PHASE=install bash /home/ubuntu/pixied-guest.sh

    printf 'PASS: PixiEden Multipass E2E completed\n'
}

main "$@"
