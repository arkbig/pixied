#!/usr/bin/env bash
# @brief Ownership validation and uninstall support for PixiEden.
# @description
# Validates the current machine state, keeps resources referenced by other
# machine states, and removes owned resources through same-filesystem
# quarantine renames.

if [ -n "${PIXIED_UNINSTALL_LOADED:-}" ]; then
    # shellcheck disable=SC2317 # Sourced by both the source and deployed CLI.
    return 0 2>/dev/null || exit 0
fi
PIXIED_UNINSTALL_LOADED=1

declare -gA PIXIED_UNINSTALL_CURRENT_STATE=()
declare -ga PIXIED_UNINSTALL_TARGET_PATHS=()
declare -ga PIXIED_UNINSTALL_TARGET_HASHES=()
declare -ga PIXIED_UNINSTALL_TARGET_KINDS=()
declare -ga PIXIED_UNINSTALL_QUARANTINE_PATHS=()
declare -ga PIXIED_UNINSTALL_OTHER_DATA=()
declare -ga PIXIED_UNINSTALL_OTHER_CONFIG=()
declare -ga PIXIED_UNINSTALL_OTHER_COMMAND=()
declare -ga PIXIED_UNINSTALL_OTHER_PIXI_HOME=()
PIXIED_UNINSTALL_OTHER_STATE_COUNT=0
PIXIED_UNINSTALL_SHARED_DATA=0
PIXIED_UNINSTALL_SHARED_CONFIG=0
PIXIED_UNINSTALL_SHARED_COMMAND=0
PIXIED_UNINSTALL_SHARED_PIXI_HOME=0
PIXIED_UNINSTALL_QUARANTINE_COUNTER=0

# @description Print the uninstall subcommand usage to standard output.
# @stdout The uninstall command help message.
# @exitcode 0 Always.
pixied_uninstall_usage() {
    cat <<'USAGE'
Usage: pixied uninstall [--yes] [--force]

Remove the PixiEden installation.

Options:
    --yes     Skip the final confirmation prompt.
    --force   Downgrade active-runtime lease and resident Zellij session
              checks to warnings. The final confirmation is still required
              unless --yes is also given.
USAGE
}

# @description Parse the arguments accepted by uninstall.
# Only confirmation control and the force flag are accepted; installation
# options cannot redirect an uninstall to a different resource set.
#
# @arg $@ string Uninstall arguments.
# @set PIXIED_INSTALL_ASSUME_YES integer Whether confirmation is skipped.
# @set PIXIED_UNINSTALL_FORCE integer Whether active-lease and resident-session
# checks are downgraded to warnings.
# @exitcode 0 When arguments are valid.
# @exitcode 2 When an argument is unknown or malformed.
pixied_uninstall_parse() {
    local option
    PIXIED_INSTALL_ASSUME_YES=${PIXIED_INSTALL_ASSUME_YES:-0}
    PIXIED_UNINSTALL_FORCE=${PIXIED_UNINSTALL_FORCE:-0}
    while [ "$#" -gt 0 ]; do
        option=$1
        case "$option" in
        --help | -h | -help) pixied_die "$(pixied_uninstall_usage)" "$PIXIED_EXIT_USAGE" ;;
        --yes) PIXIED_INSTALL_ASSUME_YES=1 ;;
        --force) PIXIED_UNINSTALL_FORCE=1 ;;
        --*) pixied_die "unknown uninstall option: $option" "$PIXIED_EXIT_USAGE" ;;
        *) pixied_die "unexpected uninstall argument: $option" "$PIXIED_EXIT_USAGE" ;;
        esac
        shift
    done
    case "$PIXIED_INSTALL_ASSUME_YES" in
    0 | 1) export PIXIED_INSTALL_ASSUME_YES ;;
    *) pixied_die "invalid --yes setting" "$PIXIED_EXIT_USAGE" ;;
    esac
    case "$PIXIED_UNINSTALL_FORCE" in
    0 | 1) export PIXIED_UNINSTALL_FORCE ;;
    *) pixied_die "invalid --force setting" "$PIXIED_EXIT_USAGE" ;;
    esac
}

# @description Resolve only the account and state paths needed by uninstall.
# The saved state, rather than current home-mode detection, controls the
# resources that will be examined and removed.
#
# @set PIXIED_ACCOUNT_HOME string The current account home.
# @set PIXIED_STATE_DIR string The state root.
# @set PIXIED_MACHINE_ID string The current machine ID.
# @set PIXIED_STATE_FILE string The current machine state file.
# @exitcode 0 When identity and state paths are valid.
# @exitcode 1 When identity or path resolution fails.
pixied_uninstall_resolve_identity() {
    local account_home state_home state_dir
    if [ "${PIXIED_ACTIVE_RUNTIME:-0}" = 1 ]; then
        # The verified active state is the identity source of truth. Never
        # re-derive paths from $HOME, which the runtime may have remapped (for
        # example, NFS mode sets HOME to the machine-local home).
        [ -n "${PIXIED_STATE_DIR:-}" ] ||
            pixied_die "active runtime state directory is not set"
        [ -n "${PIXIED_MACHINE_STATE_DIR:-}" ] ||
            pixied_die "active runtime machine state directory is not set"
        [ -n "${PIXIED_STATE_FILE:-}" ] ||
            pixied_die "active runtime state file is not set"
        [ -n "${PIXIED_MACHINE_ID:-}" ] ||
            pixied_die "active runtime machine id is not set"
        export PIXIED_ACCOUNT_HOME PIXIED_STATE_DIR PIXIED_MACHINE_ID \
            PIXIED_MACHINE_STATE_DIR PIXIED_STATE_FILE
        return 0
    fi
    account_home=$(pixied_validate_home_directory "${HOME:-}" "account home")
    export PIXIED_ACCOUNT_HOME=$account_home
    state_home=${XDG_STATE_HOME:-$account_home/.local/state}
    state_home=$(pixied_resolve_xdg_path "$state_home")
    state_dir=${PIXIED_STATE_DIR:-$state_home/pixied}
    state_dir=$(pixied_validate_canonical_path "$state_dir")
    export PIXIED_STATE_DIR=$state_dir
    PIXIED_MACHINE_ID=$(pixied_machine_id)
    export PIXIED_MACHINE_ID
    export PIXIED_MACHINE_STATE_DIR="$state_dir/machines/$PIXIED_MACHINE_ID"
    export PIXIED_STATE_FILE="$PIXIED_MACHINE_STATE_DIR/state"
}

# @description Copy the loaded state into a stable uninstall snapshot.
# @set PIXIED_UNINSTALL_CURRENT_STATE assoc The current machine state.
# @exitcode 0 Always.
pixied_uninstall_snapshot_state() {
    local key
    PIXIED_UNINSTALL_CURRENT_STATE=()
    for key in "${PIXIED_STATE_KEY_ORDER[@]}"; do
        if pixied_state_has "$key"; then
            PIXIED_UNINSTALL_CURRENT_STATE["$key"]=${PIXIED_STATE[$key]}
        fi
    done
}

# @description Restore the current machine state after inspecting another state.
# @set PIXIED_STATE assoc The current machine state.
# @exitcode 0 Always.
pixied_uninstall_restore_state() {
    local key
    PIXIED_STATE=()
    for key in "${PIXIED_STATE_KEY_ORDER[@]}"; do
        if [ "${PIXIED_UNINSTALL_CURRENT_STATE[$key]+present}" = present ]; then
            pixied_state_set "$key" "${PIXIED_UNINSTALL_CURRENT_STATE[$key]}"
        fi
    done
}

# @description Require a state path to match an expected canonical path.
# @arg $1 string The state key label.
# @arg $2 string The actual path.
# @arg $3 string The expected path.
# @exitcode 0 When the paths match.
# @exitcode 1 When the paths differ.
pixied_uninstall_require_path_match() {
    local label=$1 actual=$2 expected=$3 canonical_expected
    canonical_expected=$(pixied_canonical_path "$expected")
    [ "$actual" = "$canonical_expected" ] ||
        pixied_die "uninstall state $label is outside its managed boundary: $actual"
}

# @description Reject a directory target that could contain an account or local home.
# @arg $1 string The directory target.
# @exitcode 0 When the target is not an account or local home ancestor.
# @exitcode 1 When removing it could remove a protected home.
pixied_uninstall_validate_directory_boundary() {
    local target=$1 protected
    target=$(pixied_canonical_path "$target")
    [ "$target" != / ] || pixied_die "refusing to uninstall the filesystem root"
    for protected in "${PIXIED_UNINSTALL_CURRENT_STATE[account_home]}" \
        "${PIXIED_UNINSTALL_CURRENT_STATE[local_home]}"; do
        protected=$(pixied_canonical_path "$protected")
        [ "$target" != "$protected" ] ||
            pixied_die "refusing to remove a protected home: $target"
        case "$protected/" in
        "$target"/*) pixied_die "uninstall target contains a protected home: $target" ;;
        esac
    done
}

# @description Check whether two canonical paths overlap as directory roots.
# @arg $1 string The first path.
# @arg $2 string The second path.
# @exitcode 0 When either path contains the other or they are equal.
# @exitcode 1 When the paths are disjoint.
pixied_uninstall_paths_overlap() {
    local left right
    left=$(pixied_canonical_path "$1")
    right=$(pixied_canonical_path "$2")
    [ "$left" = "$right" ] && return 0
    case "$left/" in
    "$right"/*) return 0 ;;
    esac
    case "$right/" in
    "$left"/*) return 0 ;;
    esac
    return 1
}

# @description Check whether a managed root belongs to an NFS machine-local home.
# Path equality alone cannot prove that two NFS hosts share a filesystem: the
# same local-home string can name a different local filesystem on each host.
#
# @arg $1 string The managed root path.
# @arg $2 string The state home mode.
# @arg $3 string The state local home path.
# @exitcode 0 When the root is strictly below an NFS local home.
# @exitcode 1 When the root is shared or the state is not NFS.
pixied_uninstall_path_is_machine_local() {
    local path=$1 home_mode=$2 local_home=$3
    [ "$home_mode" = nfs ] || return 1
    path=$(pixied_canonical_path "$path")
    local_home=$(pixied_canonical_path "$local_home")
    [ "$path" != "$local_home" ] || return 1
    case "$path/" in
    "$local_home/"*) return 0 ;;
    esac
    return 1
}

# @description Reject a full-directory uninstall target that physically contains
# a managed root owned by another machine state.
# A full-directory target (the current data directory or pixi home) is removed
# wholesale, so any other state whose managed root (data, config, command bin, or
# pixi home) sits strictly inside it would lose that resource even though it is
# not part of the current machine's deployment. Equality is allowed because an
# equal root is covered by the shared-resource guard and never becomes a
# full-directory target.
#
# @arg $1 string The full-directory target path.
# @arg $2 string The target label used in the error message.
# @exitcode 0 When no other state root is strictly contained.
# @exitcode 1 When an other state root sits inside the target.
pixied_uninstall_reject_contained_roots() {
    local target=$1 label=$2 index root
    target=$(pixied_canonical_path "$target")
    for index in "${!PIXIED_UNINSTALL_OTHER_DATA[@]}"; do
        for root in "${PIXIED_UNINSTALL_OTHER_DATA[$index]}" \
            "${PIXIED_UNINSTALL_OTHER_CONFIG[$index]}" \
            "${PIXIED_UNINSTALL_OTHER_COMMAND[$index]}" \
            "${PIXIED_UNINSTALL_OTHER_PIXI_HOME[$index]}"; do
            [ -n "$root" ] || continue
            [ "$root" = "$target" ] && continue
            case "$root/" in
            "$target"/*) pixied_die "uninstall $label target contains another machine state resource: $target contains $root" ;;
            esac
        done
    done
}

# @description Validate state paths and their relationships before any rename.
# Optional paths are allowed to be absent so an interrupted uninstall can be
# resumed, but every present managed object must pass ownership and hash checks.
#
# @exitcode 0 When the current state is safe to uninstall.
# @exitcode 1 When state paths or managed objects are unsafe.
pixied_uninstall_validate_current_state() {
    local expected path hash kind left_name right_name check
    local root_index other_index
    local -a root_names=(data_dir config_dir state_dir command_bin)
    local -a checks=()

    pixied_uninstall_require_path_match state_dir "${PIXIED_STATE[state_dir]}" "$PIXIED_STATE_DIR"
    expected="$PIXIED_STATE_DIR/machines/$PIXIED_MACHINE_ID/state"
    pixied_uninstall_require_path_match state_file "$PIXIED_STATE_FILE" "$expected"
    [ "${PIXIED_STATE[machine_id]}" = "$PIXIED_MACHINE_ID" ] ||
        pixied_die "uninstall state machine ID does not match this machine"

    expected="${PIXIED_STATE[data_dir]}/bin/pixi"
    if pixied_state_has pixi_binary_path; then
        pixied_uninstall_require_path_match pixi_binary_path \
            "${PIXIED_STATE[pixi_binary_path]}" "$expected"
    fi
    expected="${PIXIED_STATE[config_dir]}/runtime-hook.bash"
    if pixied_state_has runtime_hook_path; then
        pixied_uninstall_require_path_match runtime_hook_path \
            "${PIXIED_STATE[runtime_hook_path]}" "$expected"
    fi
    expected="${PIXIED_STATE[command_bin]}/pixied"
    if pixied_state_has launcher_path; then
        pixied_uninstall_require_path_match launcher_path \
            "${PIXIED_STATE[launcher_path]}" "$expected"
    fi

    if pixied_state_has direnv_path; then
        expected="${PIXIED_STATE[pixi_home]}/bin/direnv"
        pixied_uninstall_require_path_match direnv_path \
            "${PIXIED_STATE[direnv_path]}" "$expected"
    fi
    if pixied_state_has zellij_path; then
        expected="${PIXIED_STATE[pixi_home]}/bin/zellij"
        pixied_uninstall_require_path_match zellij_path \
            "${PIXIED_STATE[zellij_path]}" "$expected"
    fi
    # The pixi home that was recorded in the state is the source of truth,
    # covering local, nfs, and an explicit --pixi-home uniformly. Recomputing it
    # from home_mode would reject a custom pixi home during uninstall.
    expected=$(pixied_canonical_path "${PIXIED_STATE[pixi_home]}")
    pixied_uninstall_require_path_match pixi_home "${PIXIED_STATE[pixi_home]}" "$expected"
    pixied_uninstall_validate_directory_boundary "${PIXIED_STATE[data_dir]}"
    pixied_uninstall_validate_directory_boundary "${PIXIED_STATE[pixi_home]}"
    for ((root_index = 0; root_index < ${#root_names[@]} - 1; root_index++)); do
        left_name=${root_names[$root_index]}
        for ((other_index = root_index + 1; other_index < ${#root_names[@]}; other_index++)); do
            right_name=${root_names[$other_index]}
            if pixied_uninstall_paths_overlap "${PIXIED_STATE[$left_name]}" \
                "${PIXIED_STATE[$right_name]}"; then
                pixied_die "uninstall managed roots overlap: $left_name and $right_name"
            fi
        done
    done

    checks+=(
        "${PIXIED_STATE[state_dir]}|dir"
        "${PIXIED_STATE[data_dir]}|dir"
        "${PIXIED_STATE[config_dir]}|dir"
        "${PIXIED_STATE[pixi_home]}|dir"
        "${PIXIED_STATE[state_dir]}/machines/${PIXIED_STATE[machine_id]}|dir"
    )
    if pixied_state_has pixi_binary_path && pixied_state_has pixi_binary_hash; then
        checks+=("${PIXIED_STATE[pixi_binary_path]}|file|${PIXIED_STATE[pixi_binary_hash]}")
    fi
    if pixied_state_has direnv_path && pixied_state_has direnv_hash; then
        checks+=("${PIXIED_STATE[direnv_path]}|file|${PIXIED_STATE[direnv_hash]}")
    fi
    if pixied_state_has zellij_path && pixied_state_has zellij_hash; then
        checks+=("${PIXIED_STATE[zellij_path]}|file|${PIXIED_STATE[zellij_hash]}")
    fi
    if pixied_state_has runtime_hook_path && pixied_state_has runtime_hook_hash; then
        checks+=("${PIXIED_STATE[runtime_hook_path]}|file|${PIXIED_STATE[runtime_hook_hash]}")
    fi
    if pixied_state_has launcher_path && pixied_state_has launcher_hash; then
        checks+=("${PIXIED_STATE[launcher_path]}|file|${PIXIED_STATE[launcher_hash]}")
    fi
    checks+=("${PIXIED_STATE_FILE}|file")

    for check in "${checks[@]}"; do
        IFS='|' read -r path kind hash <<<"$check"
        if [ -e "$path" ] || [ -L "$path" ]; then
            case "$kind" in
            dir)
                if ! [ -d "$path" ] || [ -L "$path" ]; then
                    pixied_die "managed uninstall path is not a directory: $path"
                fi
                ;;
            file)
                if ! [ -f "$path" ] || [ -L "$path" ]; then
                    pixied_die "managed uninstall path is not a regular file: $path"
                fi
                ;;
            esac
            pixied_validate_owned_path "$path" "$hash"
        fi
    done
}

# @description Scan other machine state files without changing the current snapshot.
# Every discovered state is parsed and validated as data. An invalid or
# misplaced state blocks cleanup so shared resources are never guessed at.
#
# @set PIXIED_UNINSTALL_OTHER_STATE_COUNT integer Number of other valid states.
# @exitcode 0 When all other states are valid.
# @exitcode 1 When another state is malformed or unsafe.
pixied_uninstall_scan_other_states() {
    local machines_dir machine_dir candidate candidate_name expected key
    local current_home_mode current_local_home
    local current_data current_config current_command current_pixi
    local other_home_mode other_local_home
    local other_data other_config other_command other_pixi
    local -A seen_machine_ids=()
    machines_dir="${PIXIED_STATE_DIR}/machines"
    PIXIED_UNINSTALL_OTHER_STATE_COUNT=0
    PIXIED_UNINSTALL_SHARED_DATA=0
    PIXIED_UNINSTALL_SHARED_CONFIG=0
    PIXIED_UNINSTALL_SHARED_COMMAND=0
    PIXIED_UNINSTALL_SHARED_PIXI_HOME=0
    PIXIED_UNINSTALL_OTHER_DATA=()
    PIXIED_UNINSTALL_OTHER_CONFIG=()
    PIXIED_UNINSTALL_OTHER_COMMAND=()
    PIXIED_UNINSTALL_OTHER_PIXI_HOME=()
    [ -d "$machines_dir" ] || return 0
    pixied_validate_owned_path "$machines_dir"
    seen_machine_ids["$PIXIED_MACHINE_ID"]=1
    # Canonicalize the current machine's managed roots once so sibling states are
    # compared by physical path instead of raw, possibly symlinked, strings.
    current_home_mode=${PIXIED_UNINSTALL_CURRENT_STATE[home_mode]}
    current_local_home=$(pixied_canonical_path "${PIXIED_UNINSTALL_CURRENT_STATE[local_home]}")
    current_data=$(pixied_canonical_path "${PIXIED_UNINSTALL_CURRENT_STATE[data_dir]}")
    current_config=$(pixied_canonical_path "${PIXIED_UNINSTALL_CURRENT_STATE[config_dir]}")
    current_command=$(pixied_canonical_path "${PIXIED_UNINSTALL_CURRENT_STATE[command_bin]}")
    current_pixi=$(pixied_canonical_path "${PIXIED_UNINSTALL_CURRENT_STATE[pixi_home]}")

    for machine_dir in "$machines_dir"/*; do
        [ -e "$machine_dir" ] || [ -L "$machine_dir" ] || continue
        [ ! -L "$machine_dir" ] || pixied_die "machine state directory is a symlink: $machine_dir"
        [ -d "$machine_dir" ] || pixied_die "machine state entry is not a directory: $machine_dir"
        candidate="$machine_dir/state"
        if [ ! -e "$candidate" ] && [ ! -L "$candidate" ]; then
            continue
        fi
        [ ! -L "$candidate" ] || pixied_die "machine state file is a symlink: $candidate"
        candidate_name=${machine_dir##*/}
        pixied_machine_id_is_safe "$candidate_name" ||
            pixied_die "unsafe machine state directory name: $candidate_name"
        if [ "$candidate_name" = "$PIXIED_MACHINE_ID" ]; then
            expected=$(pixied_canonical_path "$machine_dir/state")
            if [ "$candidate" != "$PIXIED_STATE_FILE" ] || [ "$candidate" != "$expected" ]; then
                pixied_die "current machine state path is unexpected: $candidate"
            fi
            continue
        fi
        pixied_state_load_external "$candidate"
        [ "${PIXIED_STATE[machine_id]}" = "$candidate_name" ] ||
            pixied_die "machine state ID does not match its directory: $candidate"
        expected=$(pixied_canonical_path "$machine_dir/state")
        [ "$candidate" = "$expected" ] ||
            pixied_die "machine state path is not canonical: $candidate"
        [ "${PIXIED_STATE[state_dir]}" = "$PIXIED_STATE_DIR" ] ||
            pixied_die "machine state uses a different state directory: $candidate"
        [ -z "${seen_machine_ids[${PIXIED_STATE[machine_id]}]+present}" ] ||
            pixied_die "duplicate machine state ID: ${PIXIED_STATE[machine_id]}"
        # pixi_home is a core key for every valid state. Requiring it here keeps an
        # incomplete sibling state from silently participating in shared detection.
        for key in data_dir config_dir command_bin pixi_home; do
            [ -n "${PIXIED_STATE[$key]:-}" ] ||
                pixied_die "machine state key is missing: $key"
        done
        # An other state must be internally consistent before its shared-resource
        # claims can be trusted. Overlapping managed roots would make the
        # shared/non-shared classification ambiguous, so block cleanup.
        if pixied_uninstall_paths_overlap "${PIXIED_STATE[data_dir]}" \
            "${PIXIED_STATE[config_dir]}"; then
            pixied_die "machine state managed roots are inconsistent: $candidate"
        fi
        if pixied_uninstall_paths_overlap "${PIXIED_STATE[data_dir]}" \
            "${PIXIED_STATE[command_bin]}"; then
            pixied_die "machine state managed roots are inconsistent: $candidate"
        fi
        if pixied_uninstall_paths_overlap "${PIXIED_STATE[config_dir]}" \
            "${PIXIED_STATE[command_bin]}"; then
            pixied_die "machine state managed roots are inconsistent: $candidate"
        fi
        other_home_mode=${PIXIED_STATE[home_mode]}
        other_local_home=$(pixied_canonical_path "${PIXIED_STATE[local_home]}")
        other_data=$(pixied_canonical_path "${PIXIED_STATE[data_dir]}")
        other_config=$(pixied_canonical_path "${PIXIED_STATE[config_dir]}")
        other_command=$(pixied_canonical_path "${PIXIED_STATE[command_bin]}")
        other_pixi=$(pixied_canonical_path "${PIXIED_STATE[pixi_home]}")
        if ! pixied_uninstall_path_is_machine_local "$current_data" \
            "$current_home_mode" "$current_local_home" &&
            ! pixied_uninstall_path_is_machine_local "$other_data" \
                "$other_home_mode" "$other_local_home" &&
            [ "$other_data" = "$current_data" ]; then
            PIXIED_UNINSTALL_SHARED_DATA=1
        fi
        if ! pixied_uninstall_path_is_machine_local "$current_config" \
            "$current_home_mode" "$current_local_home" &&
            ! pixied_uninstall_path_is_machine_local "$other_config" \
                "$other_home_mode" "$other_local_home" &&
            [ "$other_config" = "$current_config" ]; then
            PIXIED_UNINSTALL_SHARED_CONFIG=1
        fi
        [ "$other_command" = "$current_command" ] && PIXIED_UNINSTALL_SHARED_COMMAND=1
        if ! pixied_uninstall_path_is_machine_local "$current_pixi" \
            "$current_home_mode" "$current_local_home" &&
            ! pixied_uninstall_path_is_machine_local "$other_pixi" \
                "$other_home_mode" "$other_local_home" &&
            [ "$other_pixi" = "$current_pixi" ]; then
            PIXIED_UNINSTALL_SHARED_PIXI_HOME=1
        fi
        if pixied_uninstall_path_is_machine_local "$other_data" \
            "$other_home_mode" "$other_local_home"; then
            PIXIED_UNINSTALL_OTHER_DATA+=("")
        else
            PIXIED_UNINSTALL_OTHER_DATA+=("$other_data")
        fi
        if pixied_uninstall_path_is_machine_local "$other_config" \
            "$other_home_mode" "$other_local_home"; then
            PIXIED_UNINSTALL_OTHER_CONFIG+=("")
        else
            PIXIED_UNINSTALL_OTHER_CONFIG+=("$other_config")
        fi
        PIXIED_UNINSTALL_OTHER_COMMAND+=("$other_command")
        if pixied_uninstall_path_is_machine_local "$other_pixi" \
            "$other_home_mode" "$other_local_home"; then
            PIXIED_UNINSTALL_OTHER_PIXI_HOME+=("")
        else
            PIXIED_UNINSTALL_OTHER_PIXI_HOME+=("$other_pixi")
        fi
        seen_machine_ids["${PIXIED_STATE[machine_id]}"]=1
        PIXIED_UNINSTALL_OTHER_STATE_COUNT=$((PIXIED_UNINSTALL_OTHER_STATE_COUNT + 1))
    done
    pixied_uninstall_restore_state
}

# @description Add an existing managed object to the uninstall target list.
# @arg $1 string The target path.
# @arg $2 string The expected SHA-256 hash, or empty for no hash check.
# @arg $3 string The target kind, file or dir.
# @exitcode 0 When the target is recorded or absent.
# @exitcode 1 When the target path is unsafe.
pixied_uninstall_add_target() {
    local path=$1 hash=${2:-} kind=$3 existing index
    path=$(pixied_validate_canonical_path "$path")
    case "$kind" in file | dir) ;; *) pixied_die "invalid uninstall target kind: $kind" ;; esac
    if [ ! -e "$path" ] && [ ! -L "$path" ]; then
        return 0
    fi
    for index in "${!PIXIED_UNINSTALL_TARGET_PATHS[@]}"; do
        [ "${PIXIED_UNINSTALL_TARGET_PATHS[$index]}" != "$path" ] || return 0
    done
    existing=$path
    PIXIED_UNINSTALL_TARGET_PATHS+=("$existing")
    PIXIED_UNINSTALL_TARGET_HASHES+=("$hash")
    PIXIED_UNINSTALL_TARGET_KINDS+=("$kind")
}

# @description Build a complete, non-overlapping uninstall target list.
# Shared objects are preserved while another machine state exists. A freshly
# created parent may be quarantined as one unit; nested targets are then omitted.
#
# @exitcode 0 When the target list is safe to execute.
# @exitcode 1 When state values cannot form a safe target list.
pixied_uninstall_prepare_targets() {
    local full_data=0 full_pixi=0 pixi_nested=0
    PIXIED_UNINSTALL_TARGET_PATHS=()
    PIXIED_UNINSTALL_TARGET_HASHES=()
    PIXIED_UNINSTALL_TARGET_KINDS=()

    if [ "$PIXIED_UNINSTALL_SHARED_DATA" -eq 0 ] &&
        [ "${PIXIED_STATE[created_data]:-0}" -eq 1 ]; then
        full_data=1
        pixied_uninstall_add_target "${PIXIED_STATE[data_dir]}" "" dir
    fi
    case "${PIXIED_STATE[pixi_home]}/" in
    "${PIXIED_STATE[data_dir]}"/*) pixi_nested=1 ;;
    esac
    if [ "$PIXIED_UNINSTALL_SHARED_PIXI_HOME" -eq 0 ] &&
        [ "${PIXIED_STATE[created_pixi_home]:-0}" -eq 1 ] &&
        { [ "$full_data" -eq 0 ] || [ "$pixi_nested" -eq 0 ]; }; then
        full_pixi=1
        pixied_uninstall_add_target "${PIXIED_STATE[pixi_home]}" "" dir
    fi
    if [ "$full_data" -eq 1 ]; then
        pixied_uninstall_reject_contained_roots "${PIXIED_STATE[data_dir]}" data_dir
    fi
    if [ "$full_pixi" -eq 1 ]; then
        pixied_uninstall_reject_contained_roots "${PIXIED_STATE[pixi_home]}" pixi_home
    fi

    if [ "$PIXIED_UNINSTALL_SHARED_DATA" -eq 0 ] && [ "$full_data" -eq 0 ] &&
        pixied_state_has pixi_binary_path &&
        pixied_state_has pixi_binary_hash; then
        pixied_uninstall_add_target "${PIXIED_STATE[pixi_binary_path]}" \
            "${PIXIED_STATE[pixi_binary_hash]}" file
    fi
    if [ "$PIXIED_UNINSTALL_SHARED_PIXI_HOME" -eq 0 ] && [ "$full_pixi" -eq 0 ]; then
        if pixied_state_has direnv_path && pixied_state_has direnv_hash; then
            pixied_uninstall_add_target "${PIXIED_STATE[direnv_path]}" \
                "${PIXIED_STATE[direnv_hash]}" file
        fi
        if pixied_state_has zellij_path && pixied_state_has zellij_hash; then
            pixied_uninstall_add_target "${PIXIED_STATE[zellij_path]}" \
                "${PIXIED_STATE[zellij_hash]}" file
        fi
    fi
    if [ "$PIXIED_UNINSTALL_SHARED_CONFIG" -eq 0 ] || [ "$PIXIED_UNINSTALL_SHARED_COMMAND" -eq 0 ]; then
        if [ "$PIXIED_UNINSTALL_SHARED_CONFIG" -eq 0 ] &&
            pixied_state_has runtime_hook_path && pixied_state_has runtime_hook_hash; then
            pixied_uninstall_add_target "${PIXIED_STATE[runtime_hook_path]}" \
                "${PIXIED_STATE[runtime_hook_hash]}" file
        fi
        if [ "$PIXIED_UNINSTALL_SHARED_COMMAND" -eq 0 ] &&
            pixied_state_has launcher_path && pixied_state_has launcher_hash; then
            pixied_uninstall_add_target "${PIXIED_STATE[launcher_path]}" \
                "${PIXIED_STATE[launcher_hash]}" file
        fi
    fi
    local lease_dir
    lease_dir=$(pixied_lease_dir)
    if [ -e "$lease_dir" ] || [ -L "$lease_dir" ]; then
        pixied_uninstall_add_target "$lease_dir" "" dir
    fi
    pixied_uninstall_add_target "$PIXIED_STATE_FILE" "" file
}

# @description Validate every uninstall target immediately before any rename.
# @exitcode 0 When all targets still match their state.
# @exitcode 1 When a target changed or became unsafe.
pixied_uninstall_validate_targets() {
    local index path hash kind
    for index in "${!PIXIED_UNINSTALL_TARGET_PATHS[@]}"; do
        path=${PIXIED_UNINSTALL_TARGET_PATHS[$index]}
        hash=${PIXIED_UNINSTALL_TARGET_HASHES[$index]}
        kind=${PIXIED_UNINSTALL_TARGET_KINDS[$index]}
        if [ ! -e "$path" ] && [ ! -L "$path" ]; then
            continue
        fi
        case "$kind" in
        dir)
            if ! [ -d "$path" ] || [ -L "$path" ]; then
                pixied_die "uninstall target is not a directory: $path"
            fi
            ;;
        file)
            if ! [ -f "$path" ] || [ -L "$path" ]; then
                pixied_die "uninstall target is not a regular file: $path"
            fi
            ;;
        esac
        pixied_validate_owned_path "$path" "$hash"
    done
}

# @description Return a unique quarantine sibling for a target path.
# @arg $1 string The target path.
# @stdout The quarantine path on the target filesystem.
# @exitcode 0 When a unique sibling is found.
pixied_uninstall_quarantine_path() {
    local target=$1 parent base candidate
    parent=${target%/*}
    base=${target##*/}
    while :; do
        PIXIED_UNINSTALL_QUARANTINE_COUNTER=$((PIXIED_UNINSTALL_QUARANTINE_COUNTER + 1))
        candidate="$parent/.pixied-quarantine-$PIXIED_MACHINE_ID-$$-$PIXIED_UNINSTALL_QUARANTINE_COUNTER-$base"
        if [ ! -e "$candidate" ] && [ ! -L "$candidate" ]; then
            printf '%s' "$candidate"
            return 0
        fi
    done
}

# @description Move all validated targets to same-filesystem quarantine siblings.
# Quarantines are deliberately not registered as temporary paths, so an
# interrupted purge leaves evidence for the next uninstall attempt.
#
# @exitcode 0 When all targets are moved and purged.
# @exitcode 1 When a move or purge fails.
pixied_uninstall_quarantine_targets() {
    local index path quarantine
    PIXIED_UNINSTALL_QUARANTINE_PATHS=()
    pixied_uninstall_validate_targets
    for index in "${!PIXIED_UNINSTALL_TARGET_PATHS[@]}"; do
        path=${PIXIED_UNINSTALL_TARGET_PATHS[$index]}
        [ "$path" != "$PIXIED_STATE_FILE" ] || continue
        if [ ! -e "$path" ] && [ ! -L "$path" ]; then
            continue
        fi
        quarantine=$(pixied_uninstall_quarantine_path "$path")
        pixied_run mv -- "$path" "$quarantine"
        PIXIED_UNINSTALL_QUARANTINE_PATHS+=("$quarantine")
        pixied_run rm -rf -- "$quarantine"
        if [ -e "$quarantine" ] || [ -L "$quarantine" ]; then
            pixied_die "could not purge uninstall quarantine: $quarantine"
        fi
    done

    for index in "${!PIXIED_UNINSTALL_TARGET_PATHS[@]}"; do
        path=${PIXIED_UNINSTALL_TARGET_PATHS[$index]}
        [ "$path" = "$PIXIED_STATE_FILE" ] || continue
        if [ ! -e "$path" ] && [ ! -L "$path" ]; then
            continue
        fi
        quarantine=$(pixied_uninstall_quarantine_path "$path")
        pixied_run mv -- "$path" "$quarantine"
        PIXIED_UNINSTALL_QUARANTINE_PATHS+=("$quarantine")
        pixied_run rm -rf -- "$quarantine"
        if [ -e "$quarantine" ] || [ -L "$quarantine" ]; then
            pixied_die "could not purge uninstall quarantine: $quarantine"
        fi
    done
}

# @description Restore a state file left in quarantine by an interrupted uninstall.
# Only one owned, regular quarantine state is accepted for the current machine.
# @exitcode 0 When no restore is needed or the state is restored.
# @exitcode 1 When the pending state is ambiguous or unsafe.
pixied_uninstall_restore_pending_state() {
    local machine_dir candidate found=""
    machine_dir=$PIXIED_MACHINE_STATE_DIR
    [ -d "$machine_dir" ] || return 0
    [ ! -L "$machine_dir" ] || pixied_die "machine state directory is a symlink: $machine_dir"
    pixied_validate_owned_path "$machine_dir"
    [ ! -e "$PIXIED_STATE_FILE" ] && [ ! -L "$PIXIED_STATE_FILE" ] || return 0
    for candidate in "$machine_dir"/.pixied-quarantine-"$PIXIED_MACHINE_ID"-*-state; do
        [ -e "$candidate" ] || [ -L "$candidate" ] || continue
        [ -z "$found" ] || pixied_die "multiple pending uninstall states found"
        found=$candidate
    done
    [ -n "$found" ] || return 0
    [ ! -L "$found" ] || pixied_die "pending uninstall state is a symlink: $found"
    pixied_validate_owned_path "$found"
    pixied_run mv -- "$found" "$PIXIED_STATE_FILE"
}

# @description Purge stale non-state quarantine objects from a previous run.
# Parents are taken only from the current validated state, and symlinks or
# ownership mismatches stop the run instead of being followed.
# @exitcode 0 When stale quarantine objects are absent or purged.
# @exitcode 1 When a stale quarantine object is unsafe.
pixied_uninstall_purge_stale_quarantines() {
    local parent candidate
    local -a parents=(
        "${PIXIED_STATE[data_dir]%/*}"
        "${PIXIED_STATE[data_dir]}"
        "${PIXIED_STATE[config_dir]}"
        "${PIXIED_STATE[pixi_home]%/*}"
        "${PIXIED_STATE[pixi_home]}"
        "${PIXIED_STATE[command_bin]}"
        "$PIXIED_MACHINE_STATE_DIR"
    )
    for parent in "${parents[@]}"; do
        [ -d "$parent" ] || continue
        for candidate in "$parent"/.pixied-quarantine-"$PIXIED_MACHINE_ID"-*; do
            [ -e "$candidate" ] || [ -L "$candidate" ] || continue
            [ ! -L "$candidate" ] || pixied_die "stale uninstall quarantine is a symlink: $candidate"
            pixied_validate_owned_path "$candidate"
            pixied_run rm -rf -- "$candidate"
            if [ -e "$candidate" ] || [ -L "$candidate" ]; then
                pixied_die "could not purge stale uninstall quarantine: $candidate"
            fi
        done
    done
}

# @description Confirm the destructive uninstall operation.
# @exitcode 0 When approved.
# @exitcode 1 When declined or no interactive confirmation is available.
pixied_uninstall_confirm() {
    local answer
    if [ "${PIXIED_INSTALL_ASSUME_YES:-0}" -eq 1 ]; then
        return 0
    fi
    if ! [ -t 0 ] || ! [ -t 1 ]; then
        pixied_warn "uninstall requires an interactive confirmation or --yes"
        return 1
    fi
    printf '%sRemove the current PixiEden installation? [y/N] %s' \
        "$PIXIED_COLOR_YELLOW" "$PIXIED_COLOR_RESET" >&2
    IFS= read -r answer
    case "$answer" in
    [yY] | [yY][eE][sS]) return 0 ;;
    *)
        pixied_warn "uninstall was declined"
        return 1
        ;;
    esac
}

# @description Refuse to remove resources while the managed Zellij session exists.
# Direct attach leaves the session resident. If the session list is unavailable,
# warn and continue because the user explicitly requested the uninstall.
# With --force the resident-session refusal is downgraded to a warning so the
# uninstall proceeds; the session then keeps using files that were removed.
# @exitcode 0 When no managed session is present, inspection fails, or --force.
# @exitcode 1 When the session is active without --force or state validation fails.
pixied_uninstall_require_no_active_session() {
    local session_name sessions line message
    [ "${PIXIED_STATE[session_manager]}" = zellij ] || return 0
    pixied_state_has zellij_path || pixied_die "uninstall state is missing Zellij path"
    pixied_state_has zellij_hash || pixied_die "uninstall state is missing Zellij hash"
    pixied_validate_owned_path "${PIXIED_STATE[zellij_path]}" "${PIXIED_STATE[zellij_hash]}"
    session_name=pixied
    if ! sessions=$(pixied_run "${PIXIED_STATE[zellij_path]}" list-sessions --no-formatting 2>/dev/null); then
        pixied_warn "could not inspect the managed Zellij session before uninstall; continuing"
        return 0
    fi
    while IFS= read -r line; do
        case "$line" in
        "$session_name" | "$session_name "*)
            if [ "${PIXIED_UNINSTALL_FORCE:-0}" = 1 ]; then
                pixied_warn "uninstalling with --force while the managed Zellij session 'pixied' is still active; the session keeps using files that were just removed, so end it with: zellij delete-session pixied"
                return 0
            fi
            message="cannot uninstall while the managed Zellij session is active: $session_name"
            message+=$'\nTo uninstall:'
            message+=$'\n  1. Verify the session: '
            message+="${PIXIED_STATE[zellij_path]} list-sessions --no-formatting"
            message+=$'\n  2. End the session: '
            message+="${PIXIED_STATE[zellij_path]} delete-session $session_name"
            message+=$'\n  3. Rerun: pixied uninstall'
            pixied_die "$message"
            ;;
        esac
    done <<<"$sessions"
}

# @description Refuse to uninstall while another runtime holds a live lease.
# Scans the alive leases recorded by a preceding pixied_lease_sweep, excluding
# this process and its ancestor chain (a runtime uninstalling itself is
# allowed). With --force the refusal is downgraded to a warning and the
# uninstall proceeds.
#
# Entry condition: call right after pixied_lease_sweep so PIXIED_LEASE_ACTIVE_LIST
# reflects the current leases.
#
# @set PIXIED_UNINSTALL_FORCE integer Read to decide whether to downgrade.
# @exitcode 0 When no foreign lease is active or --force is set.
# @exitcode 1 When a foreign runtime lease is active without --force.
# @see pixied_lease_sweep
# @see pixied_lease_other_active
pixied_uninstall_require_no_active_lease() {
    local message
    pixied_lease_other_active >/dev/null
    [ "${PIXIED_LEASE_OTHER_COUNT:-0}" -eq 0 ] && return 0
    if [ "${PIXIED_UNINSTALL_FORCE:-0}" = 1 ]; then
        message="uninstalling with --force while PixiEden runtimes are active:"
        message+=$'\n'
        message+=$(pixied_lease_format_entries)
        message+=$'\nThe listed runtimes may keep using files that were just removed; exit them now.'
        pixied_warn "$message"
        return 0
    fi
    message="cannot uninstall while another PixiEden runtime is active on this machine:"
    message+=$'\n'
    message+=$(pixied_lease_format_entries)
    message+=$'\nThe listed runtimes are using the managed files that uninstall removes.'
    message+=$'\nTo uninstall:'
    message+=$'\n  1. Exit the listed runtime shells, or wait for the listed commands to finish.'
    message+=$'\n  2. Rerun: pixied uninstall'
    message+=$'\nTo remove the installation anyway while runtimes stay active, rerun with --force:'
    message+=$'\n  pixied uninstall --force'
    message+=$'\n--force still asks for the final confirmation unless you also pass --yes.'
    pixied_die "$message"
}

# @description Print the canonical NFS dispatcher content for a state registry.
# The dispatcher resolves the current machine state at invocation time, so the
# shared account-side launcher never embeds a machine-local payload path.
#
# @arg $1 string The canonical shared state directory.
# @stdout The dispatcher shell script without a trailing newline.
# @exitcode 0 Always.
pixied_launcher_nfs_dispatcher_content() {
    local state_root=$1 state_root_literal content
    printf -v state_root_literal '%q' "$state_root"
    content="#!/usr/bin/env bash"$'\n'
    content+="set -Eeuo pipefail"$'\n'
    content+="state_root=$state_root_literal"$'\n'
    content+='machine_id=${PIXIED_MACHINE_ID:-}'$'\n'
    content+='if [ -z "$machine_id" ]; then'$'\n'
    content+='    if [ -r /etc/machine-id ]; then'$'\n'
    content+='        IFS= read -r machine_id </etc/machine-id || true'$'\n'
    content+='    else'$'\n'
    content+='        identity_source="${HOSTNAME:-$(uname -n)}|${PIXIED_ACCOUNT_HOME:-${HOME:-}}|$(id -un)"'$'\n'
    content+='        machine_id="fallback-$(printf "%s" "$identity_source" | sha256sum | cut -d" " -f1)"'$'\n'
    content+='    fi'$'\n'
    content+='fi'$'\n'
    content+='case "$machine_id" in'$'\n'
    content+="'' | .* | *[!A-Za-z0-9._-]*) printf '%s\\n' '[pixied] ERROR invalid machine ID.' >&2; exit 1 ;;"$'\n'
    content+='esac'$'\n'
    content+='state_file="$state_root/machines/$machine_id/state"'$'\n'
    content+='[ -f "$state_file" ] || { printf "%s\\n" "[pixied] ERROR state is unavailable for this machine: $machine_id" >&2; exit 1; }'$'\n'
    content+='home_mode=""'$'\n'
    content+='command_bin=""'$'\n'
    content+='data_dir=""'$'\n'
    content+='while IFS="=" read -r state_key state_value; do'$'\n'
    content+='    case "$state_key" in home_mode) home_mode=$state_value ;; command_bin) command_bin=$state_value ;; data_dir) data_dir=$state_value ;; esac'$'\n'
    content+='done < "$state_file"'$'\n'
    content+='case "$home_mode" in local | nfs) ;; *) printf "%s\\n" "[pixied] ERROR state home mode is invalid." >&2; exit 1 ;; esac'$'\n'
    content+='case "$command_bin" in'$'\n'
    content+='    /*) ;;'$'\n'
    content+='    *) printf "%s\\n" "[pixied] ERROR state command directory is invalid." >&2; exit 1 ;;'$'\n'
    content+='esac'$'\n'
    content+='case "$data_dir" in'$'\n'
    content+='    /*) ;;'$'\n'
    content+='    *) printf "%s\\n" "[pixied] ERROR state data directory is invalid." >&2; exit 1 ;;'$'\n'
    content+='esac'$'\n'
    content+='[ -x "$data_dir/bin/pixied" ] || { printf "%s\\n" "[pixied] ERROR local PixiEden CLI is unavailable: $data_dir/bin/pixied" >&2; exit 1; }'$'\n'
    content+='export PIXIED_STATE_DIR="$state_root" PIXIED_MACHINE_ID="$machine_id" PIXIED_HOME_MODE="$home_mode" PIXIED_COMMAND_BIN="$command_bin"'$'\n'
    content+='exec "$data_dir/bin/pixied" "$@"'$'\n'
    printf '%s' "$content"
}

# @description Check whether a launcher exactly matches the canonical NFS dispatcher.
#
# @arg $1 string The launcher path.
# @arg $2 string The canonical shared state directory.
# @exitcode 0 When the launcher content matches.
# @exitcode 1 When the launcher is not the canonical dispatcher.
pixied_launcher_nfs_dispatcher_matches() {
    local path=$1 state_dir=$2 expected actual
    [ -f "$path" ] && [ ! -L "$path" ] || return 1
    [ -r "$path" ] || return 1
    expected=$(pixied_launcher_nfs_dispatcher_content "$state_dir")
    actual=$(<"$path")
    [ "$actual" = "$expected" ]
}

# @description Adopt a shared launcher recorded by another machine state.
# An existing launcher is reusable only when its exact path and hash are
# recorded by a valid state file from the shared state directory.
#
# @arg $1 string The expected launcher path.
# @exitcode 0 When a trusted shared launcher was adopted.
# @exitcode 1 When no trusted state records the launcher.
pixied_launcher_adopt_shared() {
    local target=$1 machines_dir machine_dir candidate candidate_name expected actual key
    local -A saved_state=()
    for key in "${PIXIED_STATE_KEY_ORDER[@]}"; do
        if pixied_state_has "$key"; then
            saved_state["$key"]=${PIXIED_STATE[$key]}
        fi
    done
    target=$(pixied_validate_canonical_path "$target")
    machines_dir="${PIXIED_STATE_DIR}/machines"
    [ -d "$machines_dir" ] || return 1
    pixied_validate_owned_path "$machines_dir"

    for machine_dir in "$machines_dir"/*; do
        [ -e "$machine_dir" ] || [ -L "$machine_dir" ] || continue
        [ ! -L "$machine_dir" ] || pixied_die "machine state directory is a symlink: $machine_dir"
        [ -d "$machine_dir" ] || pixied_die "machine state entry is not a directory: $machine_dir"
        candidate="$machine_dir/state"
        if [ ! -e "$candidate" ] && [ ! -L "$candidate" ]; then
            continue
        fi
        [ ! -L "$candidate" ] || pixied_die "machine state file is a symlink: $candidate"
        candidate_name=${machine_dir##*/}
        pixied_machine_id_is_safe "$candidate_name" ||
            pixied_die "unsafe machine state directory name: $candidate_name"
        expected=$(pixied_canonical_path "$candidate")
        [ "$candidate" = "$expected" ] || pixied_die "machine state path is not canonical: $candidate"
        pixied_state_load_external "$candidate"
        [ "${PIXIED_STATE[machine_id]}" = "$candidate_name" ] ||
            pixied_die "machine state ID does not match its directory: $candidate"
        [ "${PIXIED_STATE[state_dir]}" = "$PIXIED_STATE_DIR" ] ||
            pixied_die "machine state uses a different state directory: $candidate"
        if [ "${PIXIED_STATE[launcher_path]:-}" = "$target" ] &&
            [ -n "${PIXIED_STATE[launcher_hash]:-}" ]; then
            if pixied_hash_matches "$target" "${PIXIED_STATE[launcher_hash]}"; then
                pixied_validate_owned_path "$target" "${PIXIED_STATE[launcher_hash]}"
                actual=${PIXIED_STATE[launcher_hash]}
            else
                continue
            fi
            PIXIED_STATE=()
            for key in "${PIXIED_STATE_KEY_ORDER[@]}"; do
                if [ "${saved_state[$key]+present}" = present ]; then
                    pixied_state_set "$key" "${saved_state[$key]}"
                fi
            done
            pixied_state_set launcher_path "$target"
            pixied_state_set launcher_hash "$actual"
            return 0
        fi
    done

    PIXIED_STATE=()
    for key in "${PIXIED_STATE_KEY_ORDER[@]}"; do
        if [ "${saved_state[$key]+present}" = present ]; then
            pixied_state_set "$key" "${saved_state[$key]}"
        fi
    done
    return 1
}

# @description Generate the public launcher for a deployed PixiEden CLI.
# The launcher is omitted for direct source-tree installs where no deployed
# CLI exists, preserving the existing direct test and development workflow.
#
# @set PIXIED_STATE[launcher_path] string The launcher path.
# @set PIXIED_STATE[launcher_hash] string The launcher hash.
# @exitcode 0 When the launcher is absent by design or generated safely.
# @exitcode 1 When an existing unverified launcher blocks installation.
pixied_launcher_generate() {
    local launcher_path cli_path cli_literal content
    cli_path=$(pixied_validate_canonical_path "$PIXIED_DATA_DIR/bin/pixied")
    [ -f "$cli_path" ] && [ ! -L "$cli_path" ] || return 0
    pixied_run mkdir -p -- "$PIXIED_COMMAND_BIN"
    launcher_path=$(pixied_validate_canonical_path "$PIXIED_COMMAND_BIN/pixied")
    if [ -e "$launcher_path" ] || [ -L "$launcher_path" ]; then
        if ! pixied_state_has launcher_path || ! pixied_state_has launcher_hash ||
            [ "${PIXIED_STATE[launcher_path]}" != "$launcher_path" ] ||
            [ -z "${PIXIED_STATE[launcher_hash]}" ] ||
            ! pixied_hash_matches "$launcher_path" "${PIXIED_STATE[launcher_hash]}"; then
            if ! pixied_launcher_adopt_shared "$launcher_path"; then
                pixied_die "existing launcher is not managed by PixiEden: $launcher_path"
            fi
        fi
        pixied_validate_owned_path "$launcher_path" "${PIXIED_STATE[launcher_hash]}"
        if [ "${PIXIED_HOME_MODE:-local}" = nfs ] &&
            ! pixied_launcher_nfs_dispatcher_matches "$launcher_path" "$PIXIED_STATE_DIR"; then
            content=$(pixied_launcher_nfs_dispatcher_content "$PIXIED_STATE_DIR")
            content+=$'\n'
            pixied_atomic_write "$launcher_path" "$content"
            pixied_run chmod 0755 -- "$launcher_path"
        fi
    else
        if [ "${PIXIED_HOME_MODE:-local}" = nfs ]; then
            content=$(pixied_launcher_nfs_dispatcher_content "$PIXIED_STATE_DIR")
            content+=$'\n'
        else
            printf -v cli_literal '%q' "$cli_path"
            content="#!/usr/bin/env bash"$'\n'
            content+="exec $cli_literal \"\$@\""$'\n'
        fi
        pixied_atomic_write "$launcher_path" "$content"
        pixied_run chmod 0755 -- "$launcher_path"
    fi
    pixied_state_set launcher_path "$launcher_path"
    pixied_state_set launcher_hash "$(pixied_sha256_file "$launcher_path")"
}

# @description Run the validated current-machine uninstall.
# @arg $@ string Uninstall arguments.
# @exitcode 0 When the installation is removed.
# @exitcode 1 When confirmation, validation, or cleanup fails.
# @exitcode 2 When arguments are invalid.
# The order is deliberate: restore pending state before loading it, validate
# all ownership before confirmation, keep stale quarantine cleanup after
# confirmation, stop session infrastructure before quarantine, and quarantine
# the state file last so an interruption leaves a recovery checkpoint.
#
# The runtime no longer holds the state lock, so uninstall always acquires a
# fresh short lock. After loading state, stale leases are swept and any live
# foreign lease blocks the uninstall unless --force is given; a lease held by
# this process's own ancestor chain (uninstalling from inside a runtime) is
# excluded. The resident Zellij session check is likewise downgraded by --force.
#
# An active runtime bootstraps the verified state file as the identity source
# of truth, so identity is never re-derived from the (possibly remapped) $HOME.
# A missing or invalid active state is fatal before any removal. An active
# Zellij runtime is rejected because the managed session is still attached.
pixied_uninstall_run() {
    pixied_uninstall_parse "$@"
    pixied_state_bootstrap_active_runtime
    pixied_uninstall_resolve_identity
    if [ -z "${PIXIED_STATE_DIR:-}" ] || [ -z "${PIXIED_MACHINE_STATE_DIR:-}" ] ||
        [ -z "${PIXIED_STATE_FILE:-}" ]; then
        pixied_die "uninstall identity is incomplete; refusing to remove anything"
    fi
    pixied_state_lock_acquire "$PIXIED_STATE_DIR/.lock"
    pixied_uninstall_restore_pending_state
    [ -f "$PIXIED_STATE_FILE" ] ||
        pixied_die "PixiEden state is unavailable; refusing to guess what to remove"
    pixied_state_load "$PIXIED_STATE_FILE"
    pixied_uninstall_snapshot_state
    if [ "${PIXIED_ACTIVE_RUNTIME:-0}" = 1 ] &&
        [ "${PIXIED_STATE[session_manager]:-}" = zellij ] &&
        [ -n "${ZELLIJ:-}" ]; then
        pixied_die "cannot uninstall from an attached Zellij runtime session; detach the managed Zellij session (exit the session) and rerun the uninstall"
    fi
    pixied_lease_sweep
    pixied_uninstall_require_no_active_lease
    pixied_uninstall_validate_current_state
    pixied_uninstall_scan_other_states
    pixied_uninstall_restore_state
    pixied_uninstall_prepare_targets
    pixied_uninstall_confirm || pixied_die "uninstall was not confirmed"
    pixied_uninstall_purge_stale_quarantines
    pixied_uninstall_require_no_active_session
    pixied_step "Removing the PixiEden installation for $PIXIED_MACHINE_ID"
    pixied_uninstall_quarantine_targets
    pixied_success "PixiEden installation removed for $PIXIED_MACHINE_ID"
    if [ "${PIXIED_ACTIVE_RUNTIME:-0}" = 1 ]; then
        pixied_info "The active runtime shell still holds the previous environment. Run 'exit' to leave this runtime shell, then restart or re-attach the runtime to use the account without PixiEden."
    fi
}
