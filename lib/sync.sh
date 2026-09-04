#!/usr/bin/env bash
# @brief Allowlist synchronization for PixiEden NFS home mode.
# @description
# Synchronizes a fixed set of shell startup files between the account home and
# the machine-local runtime home. The account home is authoritative: existing
# account files seed the local home, while local edits are preserved and only
# warned about. Synchronization never overwrites a local file and never pushes
# local changes back to the account home.

if [ -n "${PIXIED_SYNC_LOADED:-}" ]; then
    # shellcheck disable=SC2317 # Sourced by both the source and deployed CLI.
    return 0 2>/dev/null || exit 0
fi
PIXIED_SYNC_LOADED=1

readonly PIXIED_SYNC_ALLOWLIST=(
    .bashrc .bash_profile .profile .bash_logout
    .zshrc .zprofile .zlogin .zlogout
)

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

# @description Remove one allowlisted file after validating its ownership.
# An in-bounds symlink is the managed entry itself: only the link is removed,
# never the file it points to, so an owned dotfile repository is untouched.
# Symlink targets are dereferenced only on copy, where the real content is
# synchronized. Accepted symlinks produce neither an error nor a warning.
#
# @arg $1 string The destination file path.
# @exitcode 0 When the file is absent or removed.
# @exitcode 1 When the destination is unsafe or cannot be removed.
pixied_sync_remove_file() {
    local path=$1 resolved
    resolved=$(pixied_sync_resolve_file_path "$path" "$PIXIED_ACCOUNT_HOME")
    if [ ! -e "$path" ] && ! [ -L "$path" ]; then
        return 0
    fi
    if [ -L "$path" ]; then
        : # remove the symlink entry directly below
    elif ! [ -f "$path" ]; then
        pixied_die "sync removal target is not a regular file: $path"
    fi
    # Ownership and mount checks use the resolved target so an in-bounds symlink
    # entry is removed without dereferencing (deletion targets the link only).
    pixied_validate_owned_path "$resolved"
    pixied_run rm -f -- "$path"
    if [ -e "$path" ] || [ -L "$path" ]; then
        pixied_die "could not remove sync target: $path"
    fi
}

# @description Reconcile the allowlist using an account-authoritative policy.
# The account home is treated as the source of truth. An account file that has
# no local copy seeds the local home. A local copy is never overwritten, so a
# local-only file or any local edit that diverges from the account is kept
# untouched and only reported with a warning; local changes are never pushed
# back to the account home.
#
# @exitcode 0 When reconciliation completes (warnings are non-fatal).
# @exitcode 1 When a required seed copy fails fatally.
pixied_sync_reconcile() {
    local item account_path local_path account_state local_state
    for item in "${PIXIED_SYNC_ALLOWLIST[@]}"; do
        account_path=$(pixied_sync_account_path "$item")
        local_path=$(pixied_sync_local_path "$item")
        account_state=$(pixied_sync_file_state "$account_path")
        local_state=$(pixied_sync_file_state "$local_path")
        if [ "$account_state" = missing ] && [ "$local_state" = missing ]; then
            continue
        fi
        if [ "$account_state" = missing ]; then
            pixied_warn "sync: local '$item' has changes that are not reflected to the account (no account copy exists)"
            continue
        fi
        if [ "$local_state" = missing ]; then
            pixied_sync_copy_atomic "$account_path" "$local_path"
            pixied_info "sync: seeded local '$item' from the account home"
            continue
        fi
        if [ "$account_state" = "$local_state" ]; then
            continue
        fi
        pixied_warn "sync: local '$item' differs from the account and is not reflected to the account"
    done
}

# @description Attempt to acquire the short state lock without dying.
# Mirrors pixied_state_lock_acquire but reports contention through the exit
# status instead of a fatal error, so a runtime start can retry. A successful
# acquire records the lock directory in PIXIED_STATE_LOCK_DIR for cleanup.
#
# @arg $1 string The lock directory path.
# @set PIXIED_STATE_LOCK_DIR string The path of the acquired lock directory.
# @exitcode 0 When the lock was acquired.
# @exitcode 1 When the lock already exists.
pixied_sync_try_lock() {
    local lock_dir=$1 parent
    parent=${lock_dir%/*}
    [ -d "$parent" ] || pixied_die "state lock parent does not exist: $parent"
    pixied_validate_owned_path "$parent"
    if [ -e "$lock_dir" ]; then
        return 1
    fi
    pixied_run mkdir -- "$lock_dir" || return 1
    if ! pixied_run chmod 0700 -- "$lock_dir"; then
        pixied_run rmdir -- "$lock_dir"
        pixied_die "could not protect state lock: $lock_dir"
    fi
    # shellcheck disable=SC2034 # Read by pixied_state_lock_release and pixied_cleanup.
    PIXIED_STATE_LOCK_DIR=$lock_dir
}

# @description Reconcile the allowlist under a short-lived state lock.
# Called once at runtime start. Synchronization is skipped when disabled. The
# short lock is acquired with a bounded retry (0.1s x up to 10 attempts) so a
# concurrent install/uninstall or another runtime start briefly holding the
# lock does not fail this start. When the lock cannot be acquired in time, a
# warning is emitted and synchronization is skipped. Acquisition, reconciliation,
# and release are a straight line so the EXIT-trap cleanup releases the lock
# even if reconciliation fails. Reconciliation runs again on the next start.
#
# @exitcode 0 Always; a skipped synchronization is treated as success.
# @see pixied_sync_reconcile
# @see pixied_state_lock_acquire
pixied_sync_reconcile_guarded() {
    pixied_sync_enabled || return 0
    local lock_dir attempt
    lock_dir=$(pixied_state_lock_path)
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        if pixied_sync_try_lock "$lock_dir"; then
            break
        fi
        [ "$attempt" -lt 10 ] || {
            pixied_warn "another PixiEden state operation still holds the state lock; skipping this start's synchronization and continuing. Synchronization runs again on the next start."
            return 0
        }
        pixied_run sleep 0.1
    done
    pixied_sync_reconcile
    pixied_state_lock_release
}
