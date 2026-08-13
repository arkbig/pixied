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

# @description Print PIXIED_STATE as 'key=value' entries in key order.
# @stdout The serialized state
pixied_state_serialize() {
    local key
    for key in "${PIXIED_STATE_KEY_ORDER[@]}"; do
        if pixied_state_has "$key"; then
            printf '%s=%s\n' "$key" "${PIXIED_STATE[$key]}"
        fi
    done
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
    expected_lock=$(pixied_canonical_path "$PIXIED_STATE_DIR/.lock")
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

# @description Acquire the state lock as a directory.
# Validates the parent directory, creates the lock with mkdir, and
# protects its permissions.
#
# @arg $1 string The lock directory path (defaults to $PIXIED_STATE_DIR/.lock)
# @set PIXIED_STATE_LOCK_DIR string The path of the acquired lock directory
# @exitcode 0 On success
# @exitcode 1 When the lock could not be acquired
# @see pixied_validate_owned_path
pixied_state_lock_acquire() {
    local lock_dir=${1:-${PIXIED_STATE_DIR:-}/.lock} parent
    lock_dir=$(pixied_validate_canonical_path "$lock_dir")
    parent=${lock_dir%/*}
    [ -d "$parent" ] || pixied_die "state lock parent does not exist: $parent"
    pixied_validate_owned_path "$parent"
    if [ -e "$lock_dir" ]; then
        pixied_die "state lock already exists: $lock_dir; PixiEden may already be active or the lock may be stale; stop the active runtime or remove the stale lock directory manually"
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
