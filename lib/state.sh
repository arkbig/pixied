#!/usr/bin/env bash
# @brief Library responsible for pixied state management.
# @description
# Manages state validation and read/write through the PIXIED_STATE associative array.
# File writes are atomic and a locking mechanism prevents concurrent writes.

if [ -n "${PIXIED_STATE_LOADED:-}" ]; then
    # shellcheck disable=SC2317 # Sourced by both the source and deployed CLI.
    return 0 2>/dev/null || exit 0
fi
PIXIED_STATE_LOADED=1

declare -gA PIXIED_STATE=()
PIXIED_STATE_LOCK_DIR=""

# @description Bit mask of the group-write and other-write permission bits (octal 022).
readonly PIXIED_MODE_GROUP_OTHER_WRITE=18

readonly PIXIED_STATE_KEY_ORDER=(
    state_version
    machine_id
    account_home
    home_mode
    local_home
    session_manager
    data_dir
    config_dir
    state_dir
    command_bin
    pixi_home
    pixi_binary_path
    pixi_binary_hash
    direnv_path
    direnv_hash
    zellij_path
    zellij_hash
    runtime_hook_path
    runtime_hook_hash
    launcher_path
    launcher_hash
    created_data
    created_pixi_home
    sync_baseline
)

# @description Check whether the given key is a known state key.
# @arg $1 string The key to check
# @exitcode 0 When the key is known
# @exitcode 1 When the key is unknown
pixied_state_known_key() {
    local known_key
    for known_key in "${PIXIED_STATE_KEY_ORDER[@]}"; do
        [ "$known_key" = "$1" ] && return 0
    done
    return 1
}

# @description Reject state keys from the removed host-service implementation.
# @arg $1 string The state key to inspect.
# @exitcode 0 When the key belongs to the obsolete state format.
# @exitcode 1 When the key is not obsolete.
pixied_state_obsolete_key() {
    case "$1" in
    systemd_user_dir | unit_path | unit_hash | systemd_available | linger_enabled | created_linger) return 0 ;;
    *) return 1 ;;
    esac
}

# @description Fail with an actionable message for an obsolete state file.
# @arg $1 string The obsolete state key.
# @exitcode 1 Always.
pixied_state_reject_obsolete_key() {
    pixied_die "obsolete state key: $1; reinstall PixiEden before continuing"
}

# @description Check whether the given key holds a path-format value.
# @arg $1 string The key to check
# @exitcode 0 When the key is a path-format key
# @exitcode 1 Otherwise
pixied_state_path_key() {
    case "$1" in
    account_home | local_home | data_dir | config_dir | state_dir | command_bin | pixi_home | pixi_binary_path | direnv_path | zellij_path | runtime_hook_path | launcher_path | sync_baseline) return 0 ;;
    *) return 1 ;;
    esac
}

# @description Validate a state key and value pair.
# Checks whether the key is known, whether the value contains a line break,
# and the per-key format (version, ID, mode, flag, hash, or path).
#
# @arg $1 string The state key
# @arg $2 string The value to validate
# @exitcode 0 When the validation succeeds
# @exitcode 1 When the validation fails
# @see pixied_state_known_key
# @see pixied_machine_id_is_safe
pixied_state_validate_value() {
    local key=$1 value=${2-}
    pixied_state_known_key "$key" ||
        pixied_die "unknown state key: $key"
    case "$value" in
    *$'\n'* | *$'\r'*) pixied_die "state value contains a line break: $key" "$PIXIED_EXIT_FAILURE" ;;
    esac
    case "$key" in
    state_version)
        [ "$value" = 1 ] || pixied_die "unsupported state version: $value"
        ;;
    machine_id)
        pixied_machine_id_is_safe "$value" || pixied_die "unsafe state machine id: $value"
        ;;
    home_mode)
        case "$value" in local | nfs) ;; *) pixied_die "invalid state home mode: $value" ;; esac
        ;;
    session_manager)
        case "$value" in none | zellij) ;; *) pixied_die "invalid state session manager: $value" ;; esac
        ;;
    created_data | created_pixi_home)
        case "$value" in 0 | 1) ;; *) pixied_die "invalid state creation flag: $key" ;; esac
        ;;
    pixi_binary_hash | direnv_hash | zellij_hash | runtime_hook_hash | launcher_hash)
        [ -z "$value" ] || [[ "$value" =~ ^[0-9a-f]{64}$ ]] ||
            pixied_die "invalid state hash: $key"
        ;;
    *)
        if pixied_state_path_key "$key"; then
            [ -n "$value" ] || pixied_die "state path is empty: $key"
            pixied_validate_canonical_path "$value" >/dev/null
        fi
        ;;
    esac
}

# @description Clear and initialize the PIXIED_STATE associative array.
pixied_state_reset() {
    PIXIED_STATE=()
}

# @description Validate the value and set it in PIXIED_STATE.
# @arg $1 string The state key
# @arg $2 string The value to set
# @exitcode 0 On success
# @exitcode 1 When the validation fails
# @see pixied_state_validate_value
pixied_state_set() {
    local key=$1 value=${2-}
    pixied_state_validate_value "$key" "$value"
    PIXIED_STATE["$key"]=$value
}

# @description Check whether the given state key exists in PIXIED_STATE.
# @arg $1 string The state key
# @exitcode 0 When the key exists
# @exitcode 1 When the key does not exist
pixied_state_has() {
    [ "${PIXIED_STATE[$1]+present}" = present ]
}

# @description Print the value of the given state key.
# Exits with an error when the key does not exist.
#
# @arg $1 string The state key
# @stdout The value of the state key
# @exitcode 0 When the key exists
# @exitcode 1 When the key does not exist
pixied_state_get() {
    local key=$1
    pixied_state_has "$key" || pixied_die "state key is missing: $key"
    printf '%s' "${PIXIED_STATE[$key]}"
}

# @description Check that all required core state keys exist.
# @exitcode 0 When all keys exist
# @exitcode 1 When any key is missing
pixied_state_require_core() {
    local key
    for key in state_version machine_id account_home home_mode local_home session_manager pixi_home sync_baseline; do
        pixied_state_has "$key" || pixied_die "state key is missing: $key"
    done
}

# @description Validate the state structure without binding it to this process.
# Checks that the core keys exist and every value uses an allowed format. This
# is used when inspecting another machine's state as shared-resource evidence.
#
# @exitcode 0 When the state structure is valid.
# @exitcode 1 When the state structure is invalid.
# @see pixied_state_require_core
pixied_state_validate_structure() {
    local key
    pixied_state_require_core
    for key in "${!PIXIED_STATE[@]}"; do
        pixied_state_validate_value "$key" "${PIXIED_STATE[$key]}"
    done
}

# @description Validate the entire PIXIED_STATE for the current process.
# Checks that the core keys exist, each value is valid, and the machine ID
# and account home match the current process identity.
#
# @exitcode 0 When the validation succeeds
# @exitcode 1 When the validation fails
# @see pixied_state_validate_structure
pixied_state_validate() {
    pixied_state_validate_structure
    [ "${PIXIED_STATE[machine_id]}" = "$PIXIED_MACHINE_ID" ] ||
        pixied_die "state machine id does not match this machine"
    [ "${PIXIED_STATE[account_home]}" = "$PIXIED_ACCOUNT_HOME" ] ||
        pixied_die "state account home does not match the current account home"
}

# @description Initialize state from the environment variables and set it in PIXIED_STATE.
# Resets the state and populates the core keys and creation flags with defaults.
#
# @set PIXIED_STATE assoc The initialized state
# @see pixied_state_reset
# @see pixied_state_set
pixied_state_initialize_from_paths() {
    pixied_state_reset
    pixied_state_set state_version 1
    pixied_state_set machine_id "$PIXIED_MACHINE_ID"
    pixied_state_set account_home "$PIXIED_ACCOUNT_HOME"
    pixied_state_set home_mode "$PIXIED_HOME_MODE"
    pixied_state_set local_home "$PIXIED_LOCAL_HOME"
    pixied_state_set session_manager "${PIXIED_SESSION_MANAGER:-zellij}"
    pixied_state_set data_dir "$PIXIED_DATA_DIR"
    pixied_state_set config_dir "$PIXIED_CONFIG_DIR"
    pixied_state_set state_dir "$PIXIED_STATE_DIR"
    pixied_state_set command_bin "$PIXIED_COMMAND_BIN"
    pixied_state_set pixi_home "$PIXIED_PIXI_HOME"
    pixied_state_set created_data 0
    pixied_state_set created_pixi_home 0
    pixied_state_set sync_baseline "$PIXIED_MACHINE_STATE_DIR/sync-baseline"
}

# @description Print the SHA-256 hash of a file.
# Exits with an error when the file is not a regular file.
#
# @arg $1 string The path of the file to hash
# @stdout The SHA-256 hash (64 hexadecimal digits)
# @exitcode 1 When the file is not a regular file or sha256sum is unavailable
pixied_sha256_file() {
    local path=${1:-} hash
    if ! [ -f "$path" ] || [ -L "$path" ]; then
        pixied_die "cannot hash non-regular file: $path"
    fi
    pixied_have_cmd sha256sum || pixied_die "required command not found: sha256sum"
    hash=$(pixied_run sha256sum -- "$path")
    printf '%s' "${hash%% *}"
}

# @description Check whether the file hash matches the expected value.
# @arg $1 string The target file path
# @arg $2 string The expected hash
# @exitcode 0 When the hash matches
# @exitcode 1 When the hash does not match
# @see pixied_sha256_file
pixied_hash_matches() {
    local path=$1 expected=$2 actual
    actual=$(pixied_sha256_file "$path")
    [ "$actual" = "$expected" ]
}

# @description Validate the ownership, mount state, hash, and permissions of a managed path.
# Confirms the path is owned by the current user, is not a mount point,
# matches the hash when required, and is not writable by group or others.
#
# @arg $1 string The path to validate
# @arg $2 string The expected hash (skipped when empty)
# @exitcode 0 When the validation succeeds
# @exitcode 1 When the validation fails
# @see pixied_hash_matches
pixied_validate_owned_path() {
    local path=$1 expected_hash=${2:-} canonical owner current_uid mode
    canonical=$(pixied_validate_canonical_path "$path")
    if ! [ -e "$canonical" ] || [ -L "$canonical" ]; then
        pixied_die "managed path is missing or is a symlink: $path"
    fi
    pixied_have_cmd stat || pixied_die "required command not found: stat"
    pixied_have_cmd mountpoint || pixied_die "required command not found: mountpoint"
    owner=$(pixied_run stat -c %u -- "$canonical")
    current_uid=$(pixied_run id -u)
    [ "$owner" = "$current_uid" ] || pixied_die "managed path is not owned by the current user: $path"
    if pixied_run mountpoint -q -- "$canonical"; then
        pixied_die "managed path is a mount point: $path"
    fi
    if [ -n "$expected_hash" ]; then
        [ -f "$canonical" ] || pixied_die "hashed managed path is not a regular file: $path"
        pixied_hash_matches "$canonical" "$expected_hash" ||
            pixied_die "managed path hash does not match: $path"
    fi
    mode=$(pixied_run stat -c %a -- "$canonical")
    [ $((8#$mode & PIXIED_MODE_GROUP_OTHER_WRITE)) -eq 0 ] ||
        pixied_die "managed path is writable by group or others: $path"
}

# @description Write the given content to the target path atomically through a temporary file.
# Creates and protects the temporary file, then replaces the target with mv
# after a successful write.
#
# @arg $1 string The target path to write
# @arg $2 string The content to write
# @exitcode 0 On success
# @exitcode 1 On failure
# @see pixied_validate_owned_path
pixied_atomic_write() {
    local target=$1 content=$2 directory temporary
    target=$(pixied_validate_canonical_path "$target")
    directory=${target%/*}
    [ -d "$directory" ] || pixied_die "atomic write parent does not exist: $directory"
    [ ! -L "$target" ] || pixied_die "atomic write target is a symlink: $target"
    pixied_validate_owned_path "$directory"
    temporary=$(pixied_run mktemp --tmpdir="$directory" .pixied-atomic.XXXXXX)
    pixied_register_temp "$temporary"
    if ! pixied_run chmod 0600 -- "$temporary"; then
        pixied_run rm -f -- "$temporary"
        pixied_die "could not protect atomic write temporary file"
    fi
    if ! printf '%s' "$content" >"$temporary"; then
        pixied_run rm -f -- "$temporary"
        pixied_die "could not write atomic temporary file"
    fi
    if ! pixied_run mv -f -- "$temporary" "$target"; then
        pixied_run rm -f -- "$temporary"
        pixied_die "could not commit atomic write: $target"
    fi
}

# @description Validate PIXIED_STATE and write it atomically to the state file.
# Requires the lock to be held and appends a trailing newline.
#
# @arg $1 string The state file path (defaults to $PIXIED_STATE_FILE)
# @exitcode 0 On success
# @exitcode 1 On failure
# @see pixied_state_require_lock
# @see pixied_state_validate
# @see pixied_atomic_write
pixied_state_write() {
    local state_file=${1:-${PIXIED_STATE_FILE:-}} content
    pixied_state_require_lock
    [ -n "$state_file" ] || pixied_die "state file path is not set"
    pixied_state_validate
    content="$(pixied_state_serialize)"
    content+=$'\n'
    pixied_atomic_write "$state_file" "$content"
}

# @description Check that the lock is held before writing state.
# Confirms the canonical paths of the state directory and lock directory match,
# and that the lock can be validated as a managed lock.
#
# @exitcode 0 When the lock is held and correct
# @exitcode 1 When the lock is not held or is invalid
# @see pixied_validate_owned_path
pixied_state_require_lock() {
    local expected_lock canonical_lock
    [ -n "${PIXIED_STATE_DIR:-}" ] || pixied_die "state directory is not set"
    [ -n "${PIXIED_STATE_LOCK_DIR:-}" ] ||
        pixied_die "state lock is required before writing state"
    expected_lock=$(pixied_state_lock_path)
    canonical_lock=$(pixied_canonical_path "$PIXIED_STATE_LOCK_DIR")
    [ "$canonical_lock" = "$expected_lock" ] ||
        pixied_die "unexpected state lock for state write"
    pixied_validate_owned_path "$canonical_lock"
}

# @description Load the state file into PIXIED_STATE and validate it.
# Checks the format, known keys, and duplicates of each line, then validates the result.
#
# @arg $1 string The state file path (defaults to $PIXIED_STATE_FILE)
# @set PIXIED_STATE assoc The loaded state
# @exitcode 0 On success
# @exitcode 1 When load or validation fails
# @see pixied_validate_owned_path
# @see pixied_state_validate
pixied_state_load() {
    local state_file=${1:-${PIXIED_STATE_FILE:-}} line key value
    [ -n "$state_file" ] || pixied_die "state file path is not set"
    pixied_validate_owned_path "$state_file"
    [ -f "$state_file" ] || pixied_die "state is not a regular file: $state_file"
    pixied_state_reset
    while IFS= read -r line || [ -n "$line" ]; do
        [ -n "$line" ] || pixied_die "malformed state line"
        case "$line" in
        *=*) ;;
        *) pixied_die "malformed state line" ;;
        esac
        key=${line%%=*}
        value=${line#*=}
        if ! pixied_state_known_key "$key"; then
            pixied_state_obsolete_key "$key" && pixied_state_reject_obsolete_key "$key"
            pixied_die "unknown state key: $key"
        fi
        pixied_state_has "$key" && pixied_die "duplicate state key: $key"
        pixied_state_set "$key" "$value"
    done <"$state_file"
    pixied_state_validate
}

# @description Load and validate a state file without current identity checks.
# The file and all values remain subject to ownership, canonical-path, format,
# and machine-ID validation, but its account home and machine ID may differ from
# the current process because it describes another machine.
#
# @arg $1 string The state file path.
# @set PIXIED_STATE assoc The loaded external state.
# @exitcode 0 When load or structural validation succeeds.
# @exitcode 1 When load or validation fails.
pixied_state_load_external() {
    local state_file=${1:-} line key value
    [ -n "$state_file" ] || pixied_die "external state file path is not set"
    pixied_validate_owned_path "$state_file"
    [ -f "$state_file" ] || pixied_die "external state is not a regular file: $state_file"
    pixied_state_reset
    while IFS= read -r line || [ -n "$line" ]; do
        [ -n "$line" ] || pixied_die "malformed external state line"
        case "$line" in
        *=*) ;;
        *) pixied_die "malformed external state line" ;;
        esac
        key=${line%%=*}
        value=${line#*=}
        if ! pixied_state_known_key "$key"; then
            pixied_state_obsolete_key "$key" && pixied_state_reject_obsolete_key "$key"
            pixied_die "unknown state key: $key"
        fi
        pixied_state_has "$key" && pixied_die "duplicate state key: $key"
        pixied_state_set "$key" "$value"
    done <"$state_file"
    pixied_state_validate_structure
}

# @description Serialize the current PIXIED_STATE into key=value lines.
# Used to recover a loaded state across a subshell boundary so a fatal load
# error can be converted into a return code instead of aborting the process.
# Present keys are emitted in PIXIED_STATE_KEY_ORDER; empty values are kept so
# optional state fields survive the round trip.
#
# @stdout One key=value line per present state key, in canonical key order.
pixied_state_serialize() {
    local key
    for key in "${PIXIED_STATE_KEY_ORDER[@]}"; do
        case "${PIXIED_STATE[$key]+present}" in
        present) printf '%s=%s\n' "$key" "${PIXIED_STATE[$key]}" ;;
        esac
    done
}

# @description Load the verified active runtime state, returning 1 on failure.
# Unlike pixied_state_load_external, a malformed, unowned, or invalid state file
# does not abort the process. The load runs in a command-substitution subshell so
# the pixied_die inside pixied_state_load_external becomes a non-zero exit, then
# the serialized state is repopulated in the caller. This lets the active-runtime
# bootstrap translate the failure into the shared fatal error via
# || pixied_state_active_runtime_error.
#
# @arg $1 string The state file path.
# @set PIXIED_STATE assoc The loaded active state.
# @exitcode 0 When the active state loads and validates.
# @exitcode 1 When load or validation fails.
pixied_state_load_active() {
    local serialized line key value
    serialized=$(
        if pixied_state_load_external "$1"; then
            pixied_state_serialize
        else
            exit 1
        fi
    ) || return 1
    pixied_state_reset
    while IFS= read -r line || [ -n "$line" ]; do
        [ -n "$line" ] || continue
        key=${line%%=*}
        value=${line#*=}
        pixied_state_set "$key" "$value"
    done <<<"$serialized"
    return 0
}

# @description Return the lock path for the current installation.
# This is a short-lived lock, unrelated to a runtime lease: a running runtime
# holds no lock, so liveness is expressed only through lib/lease.sh. The lock is
# held briefly during install/uninstall state writes and runtime-start
# synchronization. NFS installations keep the state registry shared but isolate
# locks by machine. Local installations retain the historical state-root lock
# path.
#
# @stdout The canonical lock path.
# @exitcode 0 When the required state path is available.
# @exitcode 1 When the lock path cannot be determined.
# @see pixied_lease_dir
pixied_state_lock_path() {
    local state_dir=${PIXIED_STATE_DIR:-} machine_state_dir=${PIXIED_MACHINE_STATE_DIR:-}
    if [ "${PIXIED_HOME_MODE:-local}" = nfs ]; then
        if [ -z "$machine_state_dir" ] && [ -n "${PIXIED_MACHINE_ID:-}" ] && [ -n "$state_dir" ]; then
            machine_state_dir="$state_dir/machines/$PIXIED_MACHINE_ID"
        fi
        [ -n "$machine_state_dir" ] || pixied_die "machine state directory is not set"
        printf '%s/.lock' "$machine_state_dir"
    else
        [ -n "$state_dir" ] || pixied_die "state directory is not set"
        printf '%s/.lock' "$state_dir"
    fi
}

# @description Acquire the state lock as a directory.
# Validates the parent directory, creates the lock with mkdir, and
# protects its permissions.
#
# @arg $1 string The lock directory path (local mode defaults to
# $PIXIED_STATE_DIR/.lock; NFS mode always uses the current machine state lock)
# @set PIXIED_STATE_LOCK_DIR string The path of the acquired lock directory
# @exitcode 0 On success
# @exitcode 1 When the lock could not be acquired
# @see pixied_validate_owned_path
pixied_state_lock_acquire() {
    local lock_dir=${1:-${PIXIED_STATE_DIR:-}/.lock} parent message
    if [ -z "$lock_dir" ] || {
        [ "${PIXIED_HOME_MODE:-local}" = nfs ] &&
            [ "$lock_dir" = "${PIXIED_STATE_DIR:-}/.lock" ]
    }; then
        lock_dir=$(pixied_state_lock_path)
    fi
    parent=${lock_dir%/*}
    [ -d "$parent" ] || pixied_die "state lock parent does not exist: $parent"
    pixied_validate_owned_path "$parent"
    if [ -e "$lock_dir" ]; then
        message="state lock already exists: $lock_dir"
        message+=$'\nAnother PixiEden install or uninstall may be writing state right now. If no such process is running, remove only the empty lock directory:'
        message+=$'\n  rmdir -- '
        message+="'$lock_dir'"
        message+=$'\nDo not use rm -rf.'
        pixied_die "$message"
    fi
    if ! pixied_run mkdir -- "$lock_dir"; then
        pixied_die "could not acquire state lock: $lock_dir"
    fi
    if ! pixied_run chmod 0700 -- "$lock_dir"; then
        pixied_run rmdir -- "$lock_dir"
        pixied_die "could not protect state lock: $lock_dir"
    fi
    PIXIED_STATE_LOCK_DIR=$lock_dir
}

# @description Release the held state lock.
# Returns immediately when no lock is held.
#
# @set PIXIED_STATE_LOCK_DIR string Becomes an empty string after release
pixied_state_lock_release() {
    [ -n "$PIXIED_STATE_LOCK_DIR" ] || return 0
    pixied_run rmdir -- "$PIXIED_STATE_LOCK_DIR"
    PIXIED_STATE_LOCK_DIR=""
}

# @description Fail with the shared active-runtime error used by install and uninstall entry points.
# An active runtime cannot fall back to $HOME or guess a state file, so a
# missing or unverifiable state is always fatal with the same message.
#
# @arg $1 string Optional detail describing the failure
# @exitcode 1 Always
pixied_state_active_runtime_error() {
    local detail=${1:-}
    local message="active runtime state is missing or unverifiable"
    [ -z "$detail" ] || message="$message: $detail"
    pixied_die "$message; PixiEden refuses to change identity from an active runtime; re-source the runtime from a valid deployment" "$PIXIED_EXIT_FAILURE"
}

# @description Load the verified active runtime state and export its identity.
# The verified state file is the source of truth for an active runtime; the
# runtime environment only locates and gates entry to it and is never used as an
# unverified path value.
#
# Entry condition: an active runtime is present only when BOTH
# PIXIED_RUNTIME_HOOK_ACTIVE=1 and a non-empty PIXIED_RUNTIME_STATE_FILE are set.
# A single signal is not sufficient and falls through to the non-active path.
#
# Non-active: no-op, sets PIXIED_ACTIVE_RUNTIME=0, returns 0.
# Active and verified: sets PIXIED_ACTIVE_RUNTIME=1 and exports the identity and
# managed path variables derived from the verified state.
# Active and missing or invalid: fatal via pixied_state_active_runtime_error.
#
# @set PIXIED_ACTIVE_RUNTIME string 1 when bootstrap succeeded in an active runtime
# @set PIXIED_ACCOUNT_HOME string Verified account home from state
# @set PIXIED_LOCAL_HOME string Verified local home from state
# @set PIXIED_HOME_MODE string Verified home mode from state
# @set PIXIED_DATA_DIR string Verified data directory from state
# @set PIXIED_CONFIG_DIR string Verified config directory from state
# @set PIXIED_COMMAND_BIN string Verified command bin from state
# @set PIXIED_PIXI_HOME string Verified pixi home from state
# @set PIXIED_MACHINE_ID string Verified machine id from state
# @set PIXIED_STATE_DIR string Verified state directory from state
# @set PIXIED_STATE_FILE string Verified state file (runtime state file)
# @set PIXIED_MACHINE_STATE_DIR string Verified machine state directory
# @exitcode 0 Non-active or active-verified
# @exitcode 1 Active but missing or invalid
# @see pixied_state_load_external
# @see pixied_state_active_runtime_error
pixied_state_bootstrap_active_runtime() {
    PIXIED_ACTIVE_RUNTIME=0
    export PIXIED_ACTIVE_RUNTIME
    if [ "${PIXIED_RUNTIME_HOOK_ACTIVE:-0}" != 1 ] || [ -z "${PIXIED_RUNTIME_STATE_FILE:-}" ]; then
        return 0
    fi

    local runtime_state_file state_file_basename state_machine_id state_grandparent
    local expected_state_file canonical
    runtime_state_file=${PIXIED_RUNTIME_STATE_FILE:-}
    [ -n "$runtime_state_file" ] || pixied_state_active_runtime_error "runtime state file is not set"
    case "$runtime_state_file" in
    /*) ;;
    *) pixied_state_active_runtime_error "runtime state file must be absolute: $runtime_state_file" ;;
    esac
    canonical=$(pixied_run realpath -m -- "$runtime_state_file") ||
        pixied_state_active_runtime_error "runtime state file cannot be resolved: $runtime_state_file"
    [ "$runtime_state_file" = "$canonical" ] ||
        pixied_state_active_runtime_error "runtime state file is not canonical (contains a symlink): $runtime_state_file"
    runtime_state_file=$canonical

    # The state file must have the form machines/<machine_id>/state.
    state_file_basename=$(pixied_run basename -- "$runtime_state_file")
    state_machine_id=$(pixied_run basename -- "$(pixied_run dirname -- "$runtime_state_file")")
    state_grandparent=$(pixied_run basename -- "$(pixied_run dirname -- "$(pixied_run dirname -- "$runtime_state_file")")")
    [ "$state_file_basename" = state ] ||
        pixied_state_active_runtime_error "runtime state file is not named 'state': $runtime_state_file"
    [ "$state_grandparent" = machines ] ||
        pixied_state_active_runtime_error "runtime state file is not under a machines/ directory: $runtime_state_file"

    # Load the verified active state. The soft loader returns 1 on any failure
    # (malformed, unowned, invalid, or missing) instead of aborting, so a failed
    # load reaches the shared fatal error below with the same message contract.
    pixied_state_load_active "$runtime_state_file" ||
        pixied_state_active_runtime_error "runtime state file failed to load: $runtime_state_file"

    # Explicitly verify the state machine id matches the state file directory and
    # the runtime state file's expected location. The structural check against the
    # state content is required; the previous runtime environment check is dropped
    # so an explicit --machine-id can be rejected through the standard
    # active-identity message instead of a bootstrap-specific one.
    [ "${PIXIED_STATE[machine_id]:-}" = "$state_machine_id" ] ||
        pixied_state_active_runtime_error "state machine id does not match the runtime state file directory"
    expected_state_file="${PIXIED_STATE[state_dir]:-}/machines/${state_machine_id}/state"
    [ "$runtime_state_file" = "$expected_state_file" ] ||
        pixied_state_active_runtime_error "runtime state file is not at the verified state location: $runtime_state_file"

    # The verified state must carry the managed paths bootstrap exports. Core
    # validation does not require them, so assert them here to avoid an unbound
    # variable under set -u and to guarantee a usable active runtime.
    local managed_key
    for managed_key in data_dir config_dir command_bin state_dir; do
        pixied_state_has "$managed_key" ||
            pixied_state_active_runtime_error "runtime state is missing a required managed path: $managed_key"
        [ -n "${PIXIED_STATE[$managed_key]}" ] ||
            pixied_state_active_runtime_error "runtime state managed path is empty: $managed_key"
    done

    PIXIED_ACCOUNT_HOME=${PIXIED_STATE[account_home]}
    # Identity-changing options supplied explicitly by the CLI or environment must
    # survive bootstrap so pixied_install_assert_active_identity can reject them.
    # When not explicit, the verified state is the source of truth for these values.
    if ! pixied_options_is_explicit local_home; then
        PIXIED_LOCAL_HOME=${PIXIED_STATE[local_home]}
    fi
    if ! pixied_options_is_explicit home_mode; then
        PIXIED_HOME_MODE=${PIXIED_STATE[home_mode]}
    fi
    PIXIED_DATA_DIR=${PIXIED_STATE[data_dir]}
    PIXIED_CONFIG_DIR=${PIXIED_STATE[config_dir]}
    PIXIED_COMMAND_BIN=${PIXIED_STATE[command_bin]}
    if ! pixied_options_is_explicit pixi_home; then
        PIXIED_PIXI_HOME=${PIXIED_STATE[pixi_home]}
    fi
    if ! pixied_options_is_explicit session_manager; then
        PIXIED_SESSION_MANAGER=${PIXIED_STATE[session_manager]}
    fi
    # When machine id is not supplied explicitly it comes from the verified state.
    # An explicit --machine-id survives bootstrap so pixied_install_assert_active_identity
    # can reject an identity change through the standard active-identity message.
    if ! pixied_options_is_explicit machine_id; then
        PIXIED_MACHINE_ID=${PIXIED_STATE[machine_id]}
    fi
    PIXIED_STATE_DIR=${PIXIED_STATE[state_dir]}
    PIXIED_STATE_FILE=$runtime_state_file
    PIXIED_MACHINE_STATE_DIR=$(pixied_run dirname -- "$runtime_state_file")

    export PIXIED_ACCOUNT_HOME PIXIED_LOCAL_HOME PIXIED_HOME_MODE PIXIED_DATA_DIR
    export PIXIED_CONFIG_DIR PIXIED_COMMAND_BIN PIXIED_PIXI_HOME PIXIED_MACHINE_ID
    export PIXIED_STATE_DIR PIXIED_STATE_FILE PIXIED_MACHINE_STATE_DIR
    export PIXIED_ACTIVE_RUNTIME=1

    pixied_debug "active runtime bootstrap loaded verified state: $PIXIED_STATE_FILE"
}

# @description Verify exported identity and path variables match the verified active state.
# Only acts within an active runtime. Call after identity resolution or after
# applying the loaded state so a later code path cannot silently drift the
# active identity away from the verified state.
#
# @exitcode 0 Non-active, or active with matching variables
# @exitcode 1 Active and a variable drifted from the verified state
pixied_state_assert_active_consistency() {
    [ "${PIXIED_ACTIVE_RUNTIME:-0}" = 1 ] || return 0
    [ "${PIXIED_ACCOUNT_HOME:-}" = "${PIXIED_STATE[account_home]}" ] ||
        pixied_die "active runtime account home drifted from the verified state"
    [ "${PIXIED_LOCAL_HOME:-}" = "${PIXIED_STATE[local_home]}" ] ||
        pixied_die "active runtime local home drifted from the verified state"
    [ "${PIXIED_HOME_MODE:-}" = "${PIXIED_STATE[home_mode]}" ] ||
        pixied_die "active runtime home mode drifted from the verified state"
    [ "${PIXIED_DATA_DIR:-}" = "${PIXIED_STATE[data_dir]}" ] ||
        pixied_die "active runtime data dir drifted from the verified state"
    [ "${PIXIED_CONFIG_DIR:-}" = "${PIXIED_STATE[config_dir]}" ] ||
        pixied_die "active runtime config dir drifted from the verified state"
    [ "${PIXIED_COMMAND_BIN:-}" = "${PIXIED_STATE[command_bin]}" ] ||
        pixied_die "active runtime command bin drifted from the verified state"
    [ "${PIXIED_PIXI_HOME:-}" = "${PIXIED_STATE[pixi_home]}" ] ||
        pixied_die "active runtime pixi home drifted from the verified state"
    [ "${PIXIED_STATE_DIR:-}" = "${PIXIED_STATE[state_dir]}" ] ||
        pixied_die "active runtime state dir drifted from the verified state"
    [ "${PIXIED_MACHINE_STATE_DIR:-}" = "${PIXIED_STATE[state_dir]}/machines/${PIXIED_STATE[machine_id]}" ] ||
        pixied_die "active runtime machine state dir drifted from the verified state"
    [ "${PIXIED_STATE_FILE:-}" = "${PIXIED_STATE[state_dir]}/machines/${PIXIED_STATE[machine_id]}/state" ] ||
        pixied_die "active runtime state file drifted from the verified state"
}
