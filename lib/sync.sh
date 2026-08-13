#!/usr/bin/env bash
# @brief Allowlist synchronization for PixiEden NFS home mode.
# @description
# Synchronizes a fixed set of shell startup files between the account home and
# the machine-local runtime home using a hash baseline and a three-way plan.

if [ -n "${PIXIED_SYNC_LOADED:-}" ]; then
    # shellcheck disable=SC2317 # Sourced by both the source and deployed CLI.
    return 0 2>/dev/null || exit 0
fi
PIXIED_SYNC_LOADED=1

readonly PIXIED_SYNC_ALLOWLIST=(
    .bashrc .bash_profile .profile .bash_logout
    .zshrc .zprofile .zlogin .zlogout
)
declare -gA PIXIED_SYNC_BASELINE=()
declare -gA PIXIED_SYNC_ACCOUNT_STATE=()
declare -gA PIXIED_SYNC_LOCAL_STATE=()
declare -gA PIXIED_SYNC_ACTION=()
PIXIED_SYNC_CONFLICT_ITEMS=()
PIXIED_SYNC_LOCK_HELD=0

# @description Return whether allowlist synchronization is enabled.
# @exitcode 0 When the runtime is in NFS home mode.
# @exitcode 1 When synchronization is disabled.
pixied_sync_enabled() {
    [ "${PIXIED_HOME_MODE:-local}" = nfs ]
}

# @description Validate that a file name belongs to the fixed synchronization allowlist.
# @arg $1 string The file name to validate.
# @exitcode 0 When the file name is allowed.
# @exitcode 1 When the file name is outside the allowlist.
pixied_sync_allowlisted() {
    local item
    for item in "${PIXIED_SYNC_ALLOWLIST[@]}"; do
        [ "$item" = "$1" ] && return 0
    done
    return 1
}

# @description Resolve one allowlisted file to its safe regular-file target.
# Existing symlinks are accepted only when they resolve inside the account home;
# this preserves common dotfile links without allowing synchronization to escape
# the managed home boundary.
#
# @arg $1 string The absolute file path.
# @stdout The canonical regular-file path.
# @exitcode 0 When the path is absent or resolves to a safe regular file.
# @exitcode 1 When the path is unsafe or non-regular.
pixied_sync_resolve_file_path() {
    local path=$1 root=$2 resolved
    if [ -L "$path" ]; then
        [ -e "$path" ] || pixied_die "sync target is not a regular file: $path"
        resolved=$(pixied_run realpath -e -- "$path") ||
            pixied_die "sync target is not a regular file: $path"
        case "$resolved/" in
        "$root/"*) ;;
        *) pixied_die "sync target symlink escapes account home: $path" ;;
        esac
    else
        resolved=$(pixied_validate_canonical_path "$path")
    fi
    if [ -e "$resolved" ] || [ -L "$resolved" ]; then
        if ! [ -f "$resolved" ] || [ -L "$resolved" ]; then
            pixied_die "sync target is not a regular file: $path"
        fi
    fi
    printf '%s' "$resolved"
}

# @description Return the hash or missing marker for one allowlisted file.
# Symlinks resolving inside the account home are hashed at their target.
#
# @arg $1 string The absolute file path.
# @stdout A SHA-256 digest or the literal 'missing'.
# @exitcode 0 When the file state is read.
# @exitcode 1 When the path is not a regular file or cannot be hashed.
pixied_sync_file_state() {
    local path=$1 resolved
    resolved=$(pixied_sync_resolve_file_path "$path" "$PIXIED_ACCOUNT_HOME")
    if [ -e "$resolved" ]; then
        pixied_sha256_file "$resolved"
    else
        printf 'missing'
    fi
}

# @description Return the absolute account-home path for an allowlisted file.
# @arg $1 string The allowlisted file name.
# @stdout The account-side file path.
# @exitcode 0 When the file name is allowlisted.
# @exitcode 1 When the file name is not allowlisted.
pixied_sync_account_path() {
    pixied_sync_allowlisted "$1" || pixied_die "sync file is outside the allowlist: $1"
    printf '%s/%s' "$PIXIED_ACCOUNT_HOME" "$1"
}

# @description Return the absolute local-home path for an allowlisted file.
# @arg $1 string The allowlisted file name.
# @stdout The local-side file path.
# @exitcode 0 When the file name is allowlisted.
# @exitcode 1 When the file name is not allowlisted.
pixied_sync_local_path() {
    pixied_sync_allowlisted "$1" || pixied_die "sync file is outside the allowlist: $1"
    printf '%s/%s' "$PIXIED_LOCAL_HOME" "$1"
}

# @description Return whether a path is an account-side allowlisted file.
# @arg $1 string The absolute path to check.
# @exitcode 0 When the path exactly names an allowlisted account file.
# @exitcode 1 When the path is outside the account allowlist.
pixied_sync_account_path_allowlisted() {
    local item path=$1 account_home=${PIXIED_ACCOUNT_HOME:-}
    [ -n "$account_home" ] || return 1
    for item in "${PIXIED_SYNC_ALLOWLIST[@]}"; do
        [ "$path" = "$account_home/$item" ] && return 0
    done
    return 1
}

# @description Validate the parent directory of the baseline manifest.
# @exitcode 0 When the baseline parent is a managed directory.
# @exitcode 1 When the baseline parent is missing or unsafe.
pixied_sync_validate_baseline_parent() {
    local baseline=${PIXIED_STATE[sync_baseline]:-} parent
    [ -n "$baseline" ] || pixied_die "sync baseline path is missing"
    parent=${baseline%/*}
    [ "$parent" != "$baseline" ] || pixied_die "sync baseline path has no parent"
    pixied_validate_canonical_path "$baseline" >/dev/null
    [ -d "$parent" ] || pixied_die "sync baseline parent is missing: $parent"
    pixied_validate_owned_path "$parent"
}

# @description Validate and load the hash baseline without sourcing it as shell code.
# The manifest must contain exactly one valid entry for every allowlisted file.
#
# @set PIXIED_SYNC_BASELINE assoc The loaded baseline values.
# @exitcode 0 When a valid baseline exists.
# @exitcode 1 When no baseline exists or the baseline is malformed.
pixied_sync_baseline_load() {
    local baseline=${PIXIED_STATE[sync_baseline]:-} line item value
    local -A seen=()
    pixied_sync_validate_baseline_parent
    PIXIED_SYNC_BASELINE=()
    if [ ! -e "$baseline" ] && ! [ -L "$baseline" ]; then
        return 1
    fi
    if ! [ -f "$baseline" ] || [ -L "$baseline" ]; then
        pixied_die "sync baseline is not a regular file: $baseline"
    fi
    pixied_validate_owned_path "$baseline"
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
        *=*) ;;
        *) pixied_die "malformed sync baseline line" "$PIXIED_EXIT_FAILURE" ;;
        esac
        item=${line%%=*}
        value=${line#*=}
        pixied_sync_allowlisted "$item" || pixied_die "unknown sync baseline item: $item"
        [ -z "${seen[$item]+present}" ] ||
            pixied_die "duplicate sync baseline item: $item"
        case "$value" in
        missing) ;;
        *)
            [[ "$value" =~ ^[0-9a-f]{64}$ ]] ||
                pixied_die "invalid sync baseline hash: $item"
            ;;
        esac
        seen["$item"]=1
        PIXIED_SYNC_BASELINE["$item"]=$value
    done <"$baseline"
    for item in "${PIXIED_SYNC_ALLOWLIST[@]}"; do
        if [ -z "${seen[$item]+present}" ]; then
            return 1
        fi
    done
    return 0
}

# @description Copy one regular file atomically within the destination filesystem.
# The source and destination are validated before the temporary file is moved.
#
# @arg $1 string The source file path.
# @arg $2 string The destination file path.
# @exitcode 0 When the copy and destination hash verification succeed.
# @exitcode 1 When the copy cannot be completed safely.
pixied_sync_copy_atomic() {
    local source=$1 destination=$2 directory temporary source_hash destination_hash
    if [ -L "$source" ] && pixied_sync_account_path_allowlisted "$source"; then
        source=$(pixied_sync_resolve_file_path "$source" "$PIXIED_ACCOUNT_HOME")
    elif [ -L "$source" ] || ! [ -f "$source" ]; then
        pixied_die "sync source is not a regular file: $source"
    else
        source=$(pixied_validate_canonical_path "$source")
    fi
    pixied_validate_owned_path "$source"
    if [ -L "$destination" ]; then
        destination=$(pixied_sync_resolve_file_path "$destination" "$PIXIED_ACCOUNT_HOME")
    else
        destination=$(pixied_validate_canonical_path "$destination")
    fi
    directory=${destination%/*}
    [ -d "$directory" ] || pixied_die "sync destination parent is missing: $directory"
    pixied_validate_owned_path "$directory"
    if [ -e "$destination" ] || [ -L "$destination" ]; then
        if ! [ -f "$destination" ] || [ -L "$destination" ]; then
            pixied_die "sync destination is not a regular file: $destination"
        fi
    fi
    source_hash=$(pixied_sha256_file "$source")
    temporary=$(pixied_run mktemp --tmpdir="$directory" .pixied-sync.XXXXXX)
    pixied_register_temp "$temporary"
    pixied_run cp -p -- "$source" "$temporary"
    pixied_run mv -f -- "$temporary" "$destination"
    destination_hash=$(pixied_sha256_file "$destination")
    [ "$source_hash" = "$destination_hash" ] ||
        pixied_die "sync destination hash verification failed: $destination"
}

# @description Remove one allowlisted regular file after validating its ownership.
# @arg $1 string The destination file path.
# @exitcode 0 When the file is absent or removed.
# @exitcode 1 When the destination is unsafe or cannot be removed.
pixied_sync_remove_file() {
    local path=$1
    pixied_validate_canonical_path "$path" >/dev/null
    if [ ! -e "$path" ] && ! [ -L "$path" ]; then
        return 0
    fi
    if ! [ -f "$path" ] || [ -L "$path" ]; then
        pixied_die "sync removal target is not a regular file: $path"
    fi
    pixied_validate_owned_path "$path"
    pixied_run rm -f -- "$path"
    if [ -e "$path" ] || [ -L "$path" ]; then
        pixied_die "could not remove sync target: $path"
    fi
}

# @description Write one missing-side marker into a conflict artifact.
# @arg $1 string The artifact path.
# @exitcode 0 When the marker is written.
# @exitcode 1 When the artifact path is unsafe.
pixied_sync_write_missing_marker() {
    local path=$1
    pixied_atomic_write "$path" $'missing\n'
}

# @description Create a persistent artifact for detected conflicts.
# The artifact stores account and local copies, missing markers, and metadata.
# Conflict artifacts are intentionally not registered for temporary cleanup.
#
# @exitcode 0 When all conflict artifacts are saved.
# @exitcode 1 When an artifact cannot be written.
pixied_sync_write_conflict_artifact() {
    local conflict_root artifact item account_path local_path account_dest local_dest
    local metadata=""
    conflict_root="$PIXIED_STATE_DIR/conflicts"
    pixied_validate_owned_path "$PIXIED_STATE_DIR"
    if [ -e "$conflict_root" ] || [ -L "$conflict_root" ]; then
        if ! [ -d "$conflict_root" ] || [ -L "$conflict_root" ]; then
            pixied_die "sync conflict path is not a directory: $conflict_root"
        fi
    else
        pixied_run mkdir -- "$conflict_root"
        pixied_run chmod 0700 -- "$conflict_root"
    fi
    pixied_validate_owned_path "$conflict_root"
    artifact=$(pixied_run mktemp -d --tmpdir="$conflict_root" pixied-sync-conflict.XXXXXX)
    pixied_run chmod 0700 -- "$artifact"
    pixied_run mkdir -- "$artifact/account" "$artifact/local" "$artifact/meta"
    pixied_run chmod 0700 -- "$artifact/account" "$artifact/local" "$artifact/meta"

    for item in "${PIXIED_SYNC_CONFLICT_ITEMS[@]}"; do
        account_path=$(pixied_sync_account_path "$item")
        local_path=$(pixied_sync_local_path "$item")
        account_dest="$artifact/account/$item"
        local_dest="$artifact/local/$item"
        if [ "${PIXIED_SYNC_ACCOUNT_STATE[$item]}" = missing ]; then
            pixied_sync_write_missing_marker "$account_dest.missing"
        else
            pixied_sync_copy_atomic "$account_path" "$account_dest"
        fi
        if [ "${PIXIED_SYNC_LOCAL_STATE[$item]}" = missing ]; then
            pixied_sync_write_missing_marker "$local_dest.missing"
        else
            pixied_sync_copy_atomic "$local_path" "$local_dest"
        fi
        metadata+="item=$item"$'\n'
        metadata+="account_state=${PIXIED_SYNC_ACCOUNT_STATE[$item]}"$'\n'
        metadata+="local_state=${PIXIED_SYNC_LOCAL_STATE[$item]}"$'\n'
        if [ -n "${PIXIED_SYNC_BASELINE[$item]+present}" ]; then
            metadata+="baseline_state=${PIXIED_SYNC_BASELINE[$item]}"$'\n'
        else
            metadata+="baseline_state=uninitialized"$'\n'
        fi
        metadata+=$'---\n'
    done
    pixied_atomic_write "$artifact/meta/metadata" "$metadata"
    pixied_info "saved sync conflict artifact: $artifact"
}

# @description Collect a complete three-way synchronization plan.
# No file is changed while this plan is being collected.
#
# @arg $1 integer Whether a valid baseline is available.
# @set PIXIED_SYNC_ACCOUNT_STATE assoc Current account-side hashes.
# @set PIXIED_SYNC_LOCAL_STATE assoc Current local-side hashes.
# @set PIXIED_SYNC_ACTION assoc Planned one-way actions.
# @set PIXIED_SYNC_CONFLICT_ITEMS array Items that must stop synchronization.
# @exitcode 0 When the plan is conflict-free.
# @exitcode 1 When one or more conflicts are present.
pixied_sync_collect_plan() {
    local baseline_available=$1 item account_state local_state baseline_state
    PIXIED_SYNC_ACCOUNT_STATE=()
    PIXIED_SYNC_LOCAL_STATE=()
    PIXIED_SYNC_ACTION=()
    PIXIED_SYNC_CONFLICT_ITEMS=()
    for item in "${PIXIED_SYNC_ALLOWLIST[@]}"; do
        account_state=$(pixied_sync_file_state "$(pixied_sync_account_path "$item")")
        local_state=$(pixied_sync_file_state "$(pixied_sync_local_path "$item")")
        PIXIED_SYNC_ACCOUNT_STATE["$item"]=$account_state
        PIXIED_SYNC_LOCAL_STATE["$item"]=$local_state
        if [ "$baseline_available" -eq 1 ]; then
            baseline_state=${PIXIED_SYNC_BASELINE[$item]}
            if [ "$account_state" = "$baseline_state" ] &&
                [ "$local_state" != "$baseline_state" ]; then
                PIXIED_SYNC_ACTION["$item"]=local_to_account
            elif [ "$local_state" = "$baseline_state" ] &&
                [ "$account_state" != "$baseline_state" ]; then
                PIXIED_SYNC_ACTION["$item"]=account_to_local
            elif [ "$account_state" = "$local_state" ]; then
                PIXIED_SYNC_ACTION["$item"]=none
            else
                PIXIED_SYNC_CONFLICT_ITEMS+=("$item")
            fi
        elif [ "$account_state" = missing ] && [ "$local_state" != missing ]; then
            PIXIED_SYNC_ACTION["$item"]=local_to_account
        elif [ "$local_state" = missing ] && [ "$account_state" != missing ]; then
            PIXIED_SYNC_ACTION["$item"]=account_to_local
        elif [ "$account_state" = "$local_state" ]; then
            PIXIED_SYNC_ACTION["$item"]=none
        else
            PIXIED_SYNC_CONFLICT_ITEMS+=("$item")
        fi
    done
    [ "${#PIXIED_SYNC_CONFLICT_ITEMS[@]}" -eq 0 ]
}

# @description Apply the collected plan and write a verified baseline manifest.
# Baseline replacement happens only after every account/local pair agrees.
#
# @exitcode 0 When all planned changes and baseline verification succeed.
# @exitcode 1 When a copy, removal, or hash verification fails.
pixied_sync_apply_plan() {
    local item action account_path local_path
    for item in "${PIXIED_SYNC_ALLOWLIST[@]}"; do
        action=${PIXIED_SYNC_ACTION[$item]}
        account_path=$(pixied_sync_account_path "$item")
        local_path=$(pixied_sync_local_path "$item")
        case "$action" in
        local_to_account)
            if [ "${PIXIED_SYNC_LOCAL_STATE[$item]}" = missing ]; then
                pixied_sync_remove_file "$account_path"
            else
                pixied_sync_copy_atomic "$local_path" "$account_path"
            fi
            ;;
        account_to_local)
            if [ "${PIXIED_SYNC_ACCOUNT_STATE[$item]}" = missing ]; then
                pixied_sync_remove_file "$local_path"
            else
                pixied_sync_copy_atomic "$account_path" "$local_path"
            fi
            ;;
        none) ;;
        *) pixied_die "unknown sync action: $action" ;;
        esac
    done

    local baseline_content="" account_state local_state
    for item in "${PIXIED_SYNC_ALLOWLIST[@]}"; do
        account_state=$(pixied_sync_file_state "$(pixied_sync_account_path "$item")")
        local_state=$(pixied_sync_file_state "$(pixied_sync_local_path "$item")")
        [ "$account_state" = "$local_state" ] ||
            pixied_die "sync sides differ after reconciliation: $item"
        baseline_content+="$item=$account_state"$'\n'
    done
    pixied_atomic_write "${PIXIED_STATE[sync_baseline]}" "$baseline_content"
}

# @description Reconcile the allowlist using the current baseline.
# With no baseline, an existing side is copied to the missing side and
# differing existing sides are recorded as an unresolved conflict.
#
# @exitcode 0 When reconciliation and baseline update succeed.
# @exitcode 1 When a conflict or synchronization failure occurs.
pixied_sync_reconcile() {
    local baseline_available=0
    if pixied_sync_baseline_load; then
        baseline_available=1
    fi
    if pixied_sync_collect_plan "$baseline_available"; then
        pixied_sync_apply_plan
        return 0
    fi
    pixied_sync_write_conflict_artifact
    pixied_die "sync conflict detected; see $PIXIED_STATE_DIR/conflicts"
}

# @description Pull and reconcile the fixed allowlist before a runtime starts.
# @exitcode 0 When synchronization is disabled or reconciliation succeeds.
# @exitcode 1 When synchronization cannot be completed.
pixied_sync_pull() {
    pixied_sync_enabled || return 0
    pixied_sync_reconcile
}

# @description Push and reconcile the fixed allowlist after a clean runtime exit.
# @exitcode 0 When synchronization is disabled or reconciliation succeeds.
# @exitcode 1 When synchronization cannot be completed.
pixied_sync_push() {
    pixied_sync_enabled || return 0
    pixied_sync_reconcile
}

# @description Acquire the runtime lock and perform the NFS pull when enabled.
# The lock remains held across every child process, including local mode, so
# start and uninstall cannot remove a runtime while it is still executing.
#
# @set PIXIED_SYNC_LOCK_HELD integer Whether the runtime sync lock is held.
# @exitcode 0 When synchronization is disabled or the pull succeeds.
# @exitcode 1 When the lock or pull fails.
pixied_sync_runtime_begin() {
    PIXIED_SYNC_LOCK_HELD=0
    pixied_state_lock_acquire "$PIXIED_STATE_DIR/.lock"
    PIXIED_SYNC_LOCK_HELD=1
    pixied_sync_enabled || return 0
    pixied_sync_pull
}

# @description Finish runtime synchronization and release the lock.
# Push is permitted only for a successful child and an attach flow known not
# to leave a resident Zellij session.
#
# @arg $1 integer The child or attach exit status.
# @arg $2 integer Whether the runtime flow permits a clean-exit push.
# @exitcode The original child status, unless push fails fatally.
pixied_sync_runtime_finish() {
    local child_status=$1 push_allowed=${2:-0}
    if [ "$PIXIED_SYNC_LOCK_HELD" -eq 1 ]; then
        if [ "$child_status" -eq 0 ] && [ "$push_allowed" -eq 1 ]; then
            pixied_sync_push
        elif [ "$child_status" -ne 0 ]; then
            pixied_warn "skipping sync push because the child exited with status $child_status"
        else
            pixied_warn "skipping sync push because the runtime session is still present"
        fi
        pixied_state_lock_release
        PIXIED_SYNC_LOCK_HELD=0
    fi
    return "$child_status"
}

# @description Check whether a named Zellij session remains after attach returns.
# @arg $1 string The expected Zellij session name.
# @exitcode 0 When the session is still present.
# @exitcode 1 When the session is absent.
# @exitcode 2 When the session list cannot be inspected.
pixied_sync_zellij_session_status() {
    local session_name=$1 sessions line
    if ! sessions=$(pixied_run "$PIXIED_ZELLIJ_PATH" list-sessions --no-formatting 2>/dev/null); then
        return 2
    fi
    while IFS= read -r line; do
        case "$line" in
        "$session_name" | "$session_name "*) return 0 ;;
        esac
    done <<<"$sessions"
    return 1
}
