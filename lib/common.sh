#!/usr/bin/env bash
# @brief Common utility library for PixiEden.
# @description
# A shared library loaded by every pixied component.
# Provides logging, command execution, temporary file management, and error handling.

if [ -n "${PIXIED_COMMON_LOADED:-}" ]; then
    # shellcheck disable=SC2317 # Sourced by both the source and deployed CLI.
    return 0 2>/dev/null || exit 0
fi
PIXIED_COMMON_LOADED=1

readonly PIXIED_EXIT_OK=0
readonly PIXIED_EXIT_FAILURE=1
readonly PIXIED_EXIT_USAGE=2
readonly PIXIED_EXIT_SIGINT=130
readonly PIXIED_EXIT_SIGTERM=143
export PIXIED_EXIT_OK PIXIED_EXIT_FAILURE PIXIED_EXIT_USAGE \
    PIXIED_EXIT_SIGINT PIXIED_EXIT_SIGTERM

if [ -z "${NO_COLOR:-}" ] && [ -t 2 ]; then
    readonly PIXIED_COLOR_RESET=$'\033[0m'
    readonly PIXIED_COLOR_BLUE=$'\033[34m'
    readonly PIXIED_COLOR_RED=$'\033[31m'
    readonly PIXIED_COLOR_YELLOW=$'\033[33m'
    readonly PIXIED_COLOR_GREEN=$'\033[32m'
    readonly PIXIED_COLOR_DIM=$'\033[2m'
else
    readonly PIXIED_COLOR_RESET=""
    readonly PIXIED_COLOR_BLUE=""
    readonly PIXIED_COLOR_RED=""
    readonly PIXIED_COLOR_YELLOW=""
    readonly PIXIED_COLOR_GREEN=""
    readonly PIXIED_COLOR_DIM=""
fi

PIXIED_TEMP_PATHS=()
PIXIED_TEMP_DIR=""
PIXIED_ERROR_REPORTED=0

# @description Print a log message with the given level and color to stderr.
# The shared implementation behind all logging functions.
#
# @arg $1 string The log level (INFO, WARN, ERROR, OK, debug, etc.)
# @arg $2 string The ANSI color code (empty when colors are disabled)
# @arg $@ string The message to print
# @stderr The formatted log line
# @see pixied_info
# @see pixied_warn
# @see pixied_error
pixied_log() {
    local level=$1 color=$2
    shift 2
    printf '%s[pixied] %s%s %s\n' "$color" "$level" "$PIXIED_COLOR_RESET" "$*" >&2
}

# @description Print an INFO level log message in blue.
# @arg $@ string The message to print
# @stderr The INFO log line
pixied_info() { pixied_log INFO "$PIXIED_COLOR_BLUE" "$@"; }

# @description Print a log message for the current step in blue.
# @arg $@ string The step description
# @stderr The '==>' step log line
pixied_step() { pixied_log '==>' "$PIXIED_COLOR_BLUE" "$@"; }

# @description Print a WARN level log message in yellow.
# @arg $@ string The message to print
# @stderr The WARN log line
pixied_warn() { pixied_log WARN "$PIXIED_COLOR_YELLOW" "$@"; }

# @description Print an ERROR level log message in red.
# @arg $@ string The message to print
# @stderr The ERROR log line
pixied_error() { pixied_log ERROR "$PIXIED_COLOR_RED" "$@"; }

# @description Print an OK level log message in green.
# @arg $@ string The message to print
# @stderr The OK log line
pixied_success() { pixied_log OK "$PIXIED_COLOR_GREEN" "$@"; }

# @description Print a debug log only when PIXIED_DEBUG is set.
# Returns immediately when it is not set.
#
# @arg $@ string The message to print
# @stderr The debug log line (only when PIXIED_DEBUG is set)
pixied_debug() {
    [ -n "${PIXIED_DEBUG:-}" ] || return 0
    pixied_log debug "$PIXIED_COLOR_DIM" "$@"
}

# @description Print an error message at ERROR level and terminate the process with the given exit code.
# The shared entry point for fatal error handling.
#
# @arg $1 string The error message
# @arg $2 integer The exit code (defaults to PIXIED_EXIT_FAILURE)
# @stderr The error message
# @exitcode $2 The given exit code
pixied_die() {
    local message=$1 exit_code=${2:-$PIXIED_EXIT_FAILURE}
    PIXIED_ERROR_REPORTED=1
    pixied_error "$message"
    exit "$exit_code"
}

# @description Check whether the given command exists on PATH.
# @arg $1 string The command name to check
# @exitcode 0 When the command exists
# @exitcode 1 When the command does not exist
pixied_have_cmd() { command -v "$1" >/dev/null 2>&1; }

# @description Check that the given command exists and exit with an error if it does not.
# @arg $1 string The command name to check
# @stderr The error message when the command is missing
# @exitcode 0 When the command exists
# @exitcode 1 When the command does not exist
pixied_require_cmd() {
    pixied_have_cmd "$1" || pixied_die "required command not found: $1"
}

# @description Check that the given file descriptors are interactive TTYs.
# Exits with an error when they are not.
#
# @arg $1 integer The input file descriptor (defaults to 0)
# @arg $2 integer The output file descriptor (defaults to 1)
# @stderr The error message when a TTY is missing
# @exitcode 0 When a TTY is available
# @exitcode 1 When a TTY is not available
pixied_require_tty() {
    local input_fd=${1:-0} output_fd=${2:-1}
    if ! [ -t "$input_fd" ] || ! [ -t "$output_fd" ]; then
        pixied_die "an interactive TTY is required"
    fi
}

# @description Append the command to execute to the log file when PIXIED_COMMAND_LOG is set.
# Returns immediately when it is not set.
#
# @arg $@ string The command and arguments to log
pixied_log_command() {
    local log_path=${PIXIED_COMMAND_LOG:-}
    [ -n "$log_path" ] || return 0
    [ ! -L "$log_path" ] || pixied_die "command log must not be a symlink: $log_path"
    if [ -e "$log_path" ]; then
        if ! [ -f "$log_path" ] || ! [ -O "$log_path" ]; then
            pixied_die "command log must be an owned regular file: $log_path"
        fi
    fi
    printf '%q ' "$@" >>"$PIXIED_COMMAND_LOG"
    printf '\n' >>"$PIXIED_COMMAND_LOG"
}

# @description Check the arguments and run the command.
# Exits with an error when no argument is given, and logs the command to
# PIXIED_COMMAND_LOG when it runs.
#
# @arg $@ string The command and arguments to run
# @stdout The standard output of the executed command
# @exitcode 0 When the command succeeds
# @exitcode 1 When the command fails
pixied_run() {
    [ "$#" -gt 0 ] || pixied_die "pixied_run requires a command"
    pixied_log_command "$@"
    command "$@"
}

# @description Register a temporary path in PIXIED_TEMP_PATHS for cleanup.
# @arg $1 string The temporary path to register
pixied_register_temp() {
    PIXIED_TEMP_PATHS+=("$1")
}

# @description Create a temporary directory, set it in PIXIED_TEMP_DIR, and register it for cleanup.
# @set PIXIED_TEMP_DIR string The path of the created temporary directory
pixied_temp_dir() {
    PIXIED_TEMP_DIR="$(pixied_run mktemp -d "${TMPDIR:-/tmp}/pixied.XXXXXX")"
    pixied_register_temp "$PIXIED_TEMP_DIR"
}

# @description Remove all registered temporary paths and reset the state.
# If a state lock is held, releases it by calling pixied_state_lock_release.
#
# @see pixied_state_lock_release
pixied_cleanup() {
    local path
    for path in "${PIXIED_TEMP_PATHS[@]}"; do
        [ -n "$path" ] || continue
        pixied_run rm -rf -- "$path"
    done
    PIXIED_TEMP_PATHS=()
    PIXIED_TEMP_DIR=""
    if [ -n "${PIXIED_STATE_LOCK_DIR:-}" ] &&
        declare -F pixied_state_lock_release >/dev/null 2>&1; then
        pixied_state_lock_release
    fi
}

# @description Handler for the ERR trap that prints the failed command and a traceback to stderr and exits.
# @stderr The failed command and traceback
# @exitcode The exit code of the failed command
pixied_error_handler() {
    local exit_code=$?
    local failed_command=${BASH_COMMAND:-unknown}
    PIXIED_ERROR_REPORTED=1
    {
        printf '%s[pixied] ERROR%s command failed with status %s\n' \
            "$PIXIED_COLOR_RED" "$PIXIED_COLOR_RESET" "$exit_code"
        printf '  command: %s\n' "$failed_command"
        printf '  traceback:\n'
        local frame=0 line function file
        while read -r line function file < <(caller "$frame" 2>/dev/null); do
            printf '    %s:%s in %s()\n' "$file" "$line" "$function"
            frame=$((frame + 1))
        done
    } >&2
    exit "$exit_code"
}

# @description Handler for the EXIT trap that cleans up temporary paths and prints a message on abnormal exit.
# @see pixied_cleanup
pixied_exit_handler() {
    local exit_code=$?
    pixied_cleanup
    if [ "$exit_code" -ne "$PIXIED_EXIT_OK" ] && [ "$PIXIED_ERROR_REPORTED" -eq 0 ]; then
        pixied_error "terminated with status $exit_code"
    fi
}

# @description Handler for INT and TERM that preserves the conventional signal status.
# @arg $1 string The signal name.
# @exitcode 130 When SIGINT is received.
# @exitcode 143 When SIGTERM is received.
pixied_signal_handler() {
    local signal=${1:-TERM}
    PIXIED_ERROR_REPORTED=1
    case "$signal" in
    INT) exit "$PIXIED_EXIT_SIGINT" ;;
    TERM) exit "$PIXIED_EXIT_SIGTERM" ;;
    *) exit "$PIXIED_EXIT_SIGTERM" ;;
    esac
}

# @description Enable strict mode and the various traps.
# Called at the top of a script; installs the error, exit, and signal handlers.
#
# @see pixied_error_handler
# @see pixied_exit_handler
# @see pixied_signal_handler
pixied_enable_strict_mode() {
    set -Eeuo pipefail
    trap pixied_error_handler ERR
    trap pixied_exit_handler EXIT
    trap 'pixied_signal_handler INT' INT
    trap 'pixied_signal_handler TERM' TERM
}
