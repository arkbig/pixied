#!/usr/bin/env bash
# @brief Library responsible for pixied path resolution and validation.
# @description
# Resolves and validates the various paths pixied uses from the home
# directory, XDG directories, machine ID, and so on, then exports them
# as environment variables.

if [ -n "${PIXIED_PATHS_LOADED:-}" ]; then
    # shellcheck disable=SC2317 # Sourced by both the source and deployed CLI.
    return 0 2>/dev/null || exit 0
fi
PIXIED_PATHS_LOADED=1

# @description A thin wrapper that reports path-related errors via pixied_die.
# @arg $1 string The error message
# @arg $2 integer The exit code (defaults to PIXIED_EXIT_FAILURE)
# @stderr The error message
# @see pixied_die
pixied_path_fail() {
    pixied_die "$1" "${2:-$PIXIED_EXIT_FAILURE}"
}

# @description Validate that the path is non-empty, absolute, and contains no line breaks.
# @arg $1 string The path to validate
# @exitcode 0 When the validation succeeds
# @exitcode 2 When the path is not absolute or contains a line break
pixied_require_absolute_path() {
    local path=${1:-}
    [ -n "$path" ] || pixied_path_fail "path must not be empty"
    case "$path" in
    /*) ;;
    *) pixied_path_fail "path must be absolute: $path" "$PIXIED_EXIT_USAGE" ;;
    esac
    case "$path" in
    *$'\n'* | *$'\r'*) pixied_path_fail "path contains a line break" "$PIXIED_EXIT_USAGE" ;;
    esac
}

# @description Canonicalize the path and print it.
# Requires the realpath command and only canonicalizes without resolving symlinks.
#
# @arg $1 string The path to canonicalize
# @stdout The canonicalized path
# @exitcode 0 On success
# @exitcode 1 When realpath is not installed
pixied_canonical_path() {
    local path=${1:-}
    pixied_require_absolute_path "$path"
    pixied_have_cmd realpath || pixied_path_fail "required command not found: realpath"
    pixied_run realpath -m -- "$path"
}

# @description Validate that the path is canonical and contains no symlinks, then print the canonicalized path.
# @arg $1 string The path to validate
# @stdout The canonicalized path
# @exitcode 0 When the validation succeeds
# @exitcode 2 When the path is not canonical
pixied_validate_canonical_path() {
    local path=${1:-} canonical
    pixied_require_absolute_path "$path"
    canonical=$(pixied_canonical_path "$path")
    [ "$path" = "$canonical" ] ||
        pixied_path_fail "path is not canonical or contains a symlink: $path" "$PIXIED_EXIT_USAGE"
    printf '%s' "$canonical"
}

# @description Resolve an XDG base directory and warn when its path is normalized.
# XDG base directories may be symlinks; managed child paths are validated separately.
#
# @arg $1 string The XDG base directory to resolve
# @stdout The resolved canonical path
# @exitcode 0 On success
# @exitcode 2 When the path is not absolute or contains a line break
pixied_resolve_xdg_path() {
    local path=${1:-} canonical
    pixied_require_absolute_path "$path"
    canonical=$(pixied_canonical_path "$path")
    if [ "$path" != "$canonical" ]; then
        pixied_warn "XDG base path is not canonical or contains a symlink; using canonical path: $path -> $canonical"
    fi
    printf '%s' "$canonical"
}

# @description Print the closest existing parent directory of the path.
# Truncates nonexistent segments one by one until an existing directory is found.
#
# @arg $1 string The target path
# @stdout The real path of the existing parent directory
# @exitcode 0 On success
# @exitcode 1 When no existing directory is found
pixied_existing_parent() {
    local path=${1:-} candidate
    pixied_require_absolute_path "$path"
    candidate=$(pixied_canonical_path "$path")
    while [ ! -e "$candidate" ] && [ ! -L "$candidate" ]; do
        [ "$candidate" != / ] || break
        candidate=${candidate%/*}
        [ -n "$candidate" ] || candidate=/
    done
    [ -d "$candidate" ] || pixied_path_fail "no existing directory for path: $path"
    pixied_run realpath -e -- "$candidate"
}

# @description Check whether the existing parent directory of the path is on a local filesystem.
# Uses the df command to check the filesystem type.
#
# @arg $1 string The path to check
# @exitcode 0 When the filesystem is local
# @exitcode 1 When the filesystem is not local (e.g. NFS)
# @exitcode 2 When it cannot be determined
pixied_is_local_filesystem() {
    local path=${1:-} existing exit_code df_output records
    existing=$(pixied_existing_parent "$path")
    pixied_have_cmd df || pixied_path_fail "required command not found: df"
    if df_output=$(pixied_run df -lP -- "$existing" 2>/dev/null); then
        records=${df_output#*$'\n'}
        [ "$records" != "$df_output" ] && [ -n "$records" ] && return 0
        return 1
    else
        exit_code=$?
    fi
    [ "$exit_code" -eq 1 ] ||
        pixied_path_fail "could not determine filesystem type: $existing"
    return 1
}

# @description Determine whether the home directory is local or NFS and print the mode name.
# @arg $1 string The home directory to check (defaults to $HOME)
# @stdout 'local' or 'nfs'
# @exitcode 0 On success
# @exitcode 1 When the check fails
pixied_detect_home_mode() {
    local account_home=${1:-${HOME:-}}
    pixied_require_absolute_path "$account_home"
    if pixied_is_local_filesystem "$account_home"; then
        printf 'local'
    else
        printf 'nfs'
    fi
}

# @description Validate that the home directory is a directory, is writable, and is owned by the current user.
# @arg $1 string The path of the directory to validate
# @arg $2 string The label (defaults to home)
# @stdout The validated canonicalized path
# @exitcode 0 When the validation succeeds
# @exitcode 1 When the validation fails
pixied_validate_home_directory() {
    local path=$1 label=${2:-home} canonical owner current_uid
    canonical=$(pixied_validate_canonical_path "$path")
    [ -d "$canonical" ] || pixied_path_fail "$label is not a directory: $canonical"
    if ! [ -w "$canonical" ] || ! [ -x "$canonical" ]; then
        pixied_path_fail "$label is not writable: $canonical"
    fi
    pixied_have_cmd stat || pixied_path_fail "required command not found: stat"
    owner=$(pixied_run stat -c %u -- "$canonical")
    current_uid=$(pixied_run id -u)
    [ "$owner" = "$current_uid" ] ||
        pixied_path_fail "$label is not owned by the current user: $canonical"
    printf '%s' "$canonical"
}

# @description Check whether the machine ID is safe to use as a path segment.
# Returns false for empty strings, '.', '..', and IDs containing invalid characters.
#
# @arg $1 string The machine ID to check
# @exitcode 0 When the machine ID is safe
# @exitcode 1 When the machine ID is not safe
pixied_machine_id_is_safe() {
    local machine_id=${1:-}
    [ -n "$machine_id" ] || return 1
    [ "$machine_id" != . ] && [ "$machine_id" != .. ] || return 1
    [[ "$machine_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

# @description Determine the machine ID and print it.
# Uses PIXIED_MACHINE_ID, then /etc/machine-id; when neither is available,
# generates a fallback ID from the host name and user information.
#
# @stdout The determined machine ID
# @exitcode 0 On success
# @exitcode 1 When a safe machine ID cannot be determined
pixied_machine_id() {
    local machine_id source fallback
    if [ -n "${PIXIED_MACHINE_ID:-}" ]; then
        machine_id=$PIXIED_MACHINE_ID
        pixied_machine_id_is_safe "$machine_id" ||
            pixied_path_fail "unsafe machine id: $machine_id" "$PIXIED_EXIT_USAGE"
        printf '%s' "$machine_id"
        return 0
    fi

    if [ -r /etc/machine-id ]; then
        IFS= read -r machine_id </etc/machine-id || true
        if [ -n "$machine_id" ]; then
            pixied_machine_id_is_safe "$machine_id" ||
                pixied_path_fail "unsafe machine id in /etc/machine-id: $machine_id"
            printf '%s' "$machine_id"
            return 0
        fi
    fi

    pixied_have_cmd sha256sum || pixied_path_fail "required command not found: sha256sum"
    source="${HOSTNAME:-$(uname -n)}|${PIXIED_ACCOUNT_HOME:-${HOME:-}}|$(id -un)"
    fallback=$(printf '%s' "$source" | sha256sum | cut -d' ' -f1)
    machine_id="fallback-$fallback"
    pixied_machine_id_is_safe "$machine_id" ||
        pixied_path_fail "could not create a safe fallback machine id"
    printf '%s' "$machine_id"
}

# @description Resolve all the paths pixied uses and export them as environment variables.
# Performs home mode detection, optional local home validation on NFS, XDG
# directory resolution, machine ID determination, and pixi home determination.
#
# @arg $1 integer Whether to validate the selected local home (default: yes).
# @set PIXIED_ACCOUNT_HOME string The account home directory
# @set PIXIED_HOME_MODE string The home mode (local or nfs)
# @set PIXIED_LOCAL_HOME string The local home directory
# @set PIXIED_DATA_DIR string The data directory
# @set PIXIED_CONFIG_DIR string The config directory
# @set PIXIED_STATE_DIR string The state directory
# @set PIXIED_COMMAND_BIN string The command placement directory
# @set PIXIED_MACHINE_ID string The machine ID
# @set PIXIED_MACHINE_STATE_DIR string The per-machine state directory
# @set PIXIED_STATE_FILE string The state file path
# @set PIXIED_PIXI_HOME string The pixi home directory
# @exitcode 0 On success
# @exitcode 1 When path resolution fails
# @see pixied_detect_home_mode
# @see pixied_machine_id
pixied_resolve_paths() {
    local validate_home=${1:-1}
    local account_home requested_home_mode home_mode local_home data_home config_home state_home bin_home
    local data_dir config_dir state_dir command_bin

    requested_home_mode=${PIXIED_HOME_MODE:-}
    account_home=$(pixied_validate_home_directory "${HOME:-}" "account home")
    export PIXIED_ACCOUNT_HOME=$account_home

    home_mode=${PIXIED_HOME_MODE:-}
    if [ -z "$home_mode" ]; then
        home_mode=$(pixied_detect_home_mode "$account_home")
    fi
    case "$home_mode" in
    local | nfs) ;;
    *) pixied_path_fail "invalid home mode: $home_mode" "$PIXIED_EXIT_USAGE" ;;
    esac

    if [ "$home_mode" = nfs ]; then
        local_home=${PIXIED_LOCAL_HOME:-/local/${USER:-$(id -un)}}
        if [ "$validate_home" -eq 1 ]; then
            if [ ! -d "$local_home" ]; then
                pixied_path_fail "selected NFS mode requires a local home. Create it before installation and make it writable and owned by the current user (for example: mkdir -p -- '$local_home'), or rerun with --local-home PATH pointing to an existing directory"
            fi
            local_home=$(pixied_validate_home_directory "$local_home" "local home")
            [ "$local_home" != "$account_home" ] ||
                pixied_path_fail "NFS local home must differ from account home"
            pixied_is_local_filesystem "$local_home" ||
                pixied_path_fail "local home is not on a local filesystem: $local_home"
        fi
    else
        local_home=$account_home
        if [ "$validate_home" -eq 1 ] && [ "$requested_home_mode" = local ] &&
            ! pixied_is_local_filesystem "$account_home"; then
            pixied_warn "account home is not on a local filesystem; continuing with explicitly requested local home mode (NFS synchronization is disabled)"
        fi
    fi

    data_home=${XDG_DATA_HOME:-$account_home/.local/share}
    config_home=${XDG_CONFIG_HOME:-$account_home/.config}
    state_home=${XDG_STATE_HOME:-$account_home/.local/state}
    bin_home=${XDG_BIN_HOME:-$account_home/.local/bin}
    data_home=$(pixied_resolve_xdg_path "$data_home")
    config_home=$(pixied_resolve_xdg_path "$config_home")
    state_home=$(pixied_resolve_xdg_path "$state_home")
    bin_home=$(pixied_resolve_xdg_path "$bin_home")

    data_dir=$(pixied_validate_canonical_path "${PIXIED_DATA_DIR:-$data_home/pixied}")
    config_dir=$(pixied_validate_canonical_path "${PIXIED_CONFIG_DIR:-$config_home/pixied}")
    state_dir=$(pixied_validate_canonical_path "${PIXIED_STATE_DIR:-$state_home/pixied}")
    command_bin=$(pixied_validate_canonical_path "${PIXIED_COMMAND_BIN:-$bin_home}")

    export PIXIED_HOME_MODE=$home_mode
    export PIXIED_LOCAL_HOME=$local_home
    export PIXIED_DATA_DIR=$data_dir
    export PIXIED_CONFIG_DIR=$config_dir
    export PIXIED_STATE_DIR=$state_dir
    export PIXIED_COMMAND_BIN=$command_bin
    PIXIED_MACHINE_ID=$(pixied_machine_id)
    export PIXIED_MACHINE_ID
    export PIXIED_MACHINE_STATE_DIR="$state_dir/machines/$PIXIED_MACHINE_ID"
    export PIXIED_STATE_FILE="$PIXIED_MACHINE_STATE_DIR/state"

    if [ "$home_mode" = nfs ]; then
        export PIXIED_PIXI_HOME="${PIXIED_PIXI_HOME:-$local_home/.local/share/pixied/pixi}"
    else
        export PIXIED_PIXI_HOME="${PIXIED_PIXI_HOME:-$data_dir/pixi}"
    fi
    PIXIED_PIXI_HOME=$(pixied_validate_canonical_path "$PIXIED_PIXI_HOME")
    export PIXIED_PIXI_HOME
}

# @description Ensure the local runtime home's ~/.local/bin directory exists.
# In NFS home mode the runtime HOME is the machine-local home, so its own
# ~/.local/bin must exist for the shell/hook environment and so a user's
# ~/.profile (which typically prepends $HOME/.local/bin to PATH) can seed
# locally installed binaries. This is a no-op in local home mode, where the
# local home and account home coincide.
#
# @exitcode 0 Always; the directory is created only in NFS mode.
pixied_ensure_local_home_bin() {
    [ "${PIXIED_HOME_MODE:-local}" = nfs ] || return 0
    pixied_have_cmd mkdir || pixied_die "required command not found: mkdir"
    pixied_run mkdir -p -- "$PIXIED_LOCAL_HOME/.local/bin"
}
