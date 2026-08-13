#!/usr/bin/env bash
# @brief Runtime state and child-process helpers for PixiEden.
# @description
# Loads and validates the installation state at runtime, prepares the
# dedicated environment, and waits for child commands or sessions.

if [ -n "${PIXIED_SESSION_LOADED:-}" ]; then
    # shellcheck disable=SC2317 # Sourced by both the source and deployed CLI.
    return 0 2>/dev/null || exit 0
fi
PIXIED_SESSION_LOADED=1

# @description Establish the account-home and machine identity used to validate runtime state.
# Uses the explicit runtime identity when a generated hook supplies it;
# otherwise derives both values from the current process environment.
#
# @set PIXIED_ACCOUNT_HOME string The validated account home.
# @set PIXIED_MACHINE_ID string The validated machine ID.
# @exitcode 0 When the identity is valid.
# @exitcode 1 When the identity cannot be validated.
pixied_runtime_set_identity() {
    local account_home machine_id
    if [ -n "${PIXIED_ACCOUNT_HOME:-}" ]; then
        account_home=$(pixied_validate_canonical_path "$PIXIED_ACCOUNT_HOME")
    else
        account_home=$(pixied_validate_home_directory "${HOME:-}" "account home")
    fi
    export PIXIED_ACCOUNT_HOME=$account_home

    if [ -n "${PIXIED_MACHINE_ID:-}" ]; then
        pixied_machine_id_is_safe "$PIXIED_MACHINE_ID" ||
            pixied_die "unsafe runtime machine id: $PIXIED_MACHINE_ID"
        machine_id=$PIXIED_MACHINE_ID
    else
        machine_id=$(pixied_machine_id)
    fi
    export PIXIED_MACHINE_ID=$machine_id
}

# @description Apply validated state values to the runtime environment variables.
# Does not source the state file; all values have already passed the state parser.
#
# @set PIXIED_* string Runtime values copied from PIXIED_STATE.
# @exitcode 0 When all required runtime values are present.
# @exitcode 1 When a required value is missing.
pixied_runtime_apply_state() {
    local key
    for key in state_version machine_id account_home home_mode local_home session_manager \
        data_dir config_dir state_dir command_bin pixi_home pixi_binary_path \
        pixi_binary_hash direnv_path direnv_hash runtime_hook_path runtime_hook_hash \
        sync_baseline; do
        pixied_state_has "$key" || pixied_die "runtime state key is missing: $key"
    done

    export PIXIED_MACHINE_ID=${PIXIED_STATE[machine_id]}
    export PIXIED_ACCOUNT_HOME=${PIXIED_STATE[account_home]}
    export PIXIED_HOME_MODE=${PIXIED_STATE[home_mode]}
    export PIXIED_LOCAL_HOME=${PIXIED_STATE[local_home]}
    export PIXIED_SESSION_MANAGER=${PIXIED_STATE[session_manager]}
    export PIXIED_DATA_DIR=${PIXIED_STATE[data_dir]}
    export PIXIED_CONFIG_DIR=${PIXIED_STATE[config_dir]}
    export PIXIED_STATE_DIR=${PIXIED_STATE[state_dir]}
    export PIXIED_COMMAND_BIN=${PIXIED_STATE[command_bin]}
    export PIXIED_PIXI_HOME=${PIXIED_STATE[pixi_home]}
    export PIXIED_PIXI_BINARY_PATH=${PIXIED_STATE[pixi_binary_path]}
    export PIXIED_PIXI_BINARY_HASH=${PIXIED_STATE[pixi_binary_hash]}
    export PIXIED_DIRENV_PATH=${PIXIED_STATE[direnv_path]}
    export PIXIED_DIRENV_HASH=${PIXIED_STATE[direnv_hash]}
    export PIXIED_RUNTIME_HOOK_PATH=${PIXIED_STATE[runtime_hook_path]}
    export PIXIED_RUNTIME_HOOK_HASH=${PIXIED_STATE[runtime_hook_hash]}
    export PIXIED_SYNC_BASELINE=${PIXIED_STATE[sync_baseline]}
    if pixied_state_has zellij_path; then
        export PIXIED_ZELLIJ_PATH=${PIXIED_STATE[zellij_path]}
    else
        unset PIXIED_ZELLIJ_PATH
    fi
}

# @description Validate runtime ownership, hashes, and generated artifact boundaries.
# Ensures state values cannot redirect runtime execution to an arbitrary path.
#
# @exitcode 0 When the runtime installation is complete and verified.
# @exitcode 1 When a required path, hash, or artifact is invalid.
pixied_runtime_validate_state() {
    local expected account_home local_home

    expected=$(pixied_canonical_path "${PIXIED_STATE[state_dir]}/machines/${PIXIED_STATE[machine_id]}/state")
    [ "$PIXIED_STATE_FILE" = "$expected" ] ||
        pixied_die "runtime state file is outside its machine state path"

    expected=$(pixied_canonical_path "${PIXIED_STATE[data_dir]}/bin/pixi")
    [ "${PIXIED_STATE[pixi_binary_path]}" = "$expected" ] ||
        pixied_die "runtime Pixi binary path is outside the dedicated data directory"
    expected=$(pixied_canonical_path "${PIXIED_STATE[pixi_home]}/bin/direnv")
    [ "${PIXIED_STATE[direnv_path]}" = "$expected" ] ||
        pixied_die "runtime direnv path is outside the dedicated Pixi home"
    expected=$(pixied_canonical_path "${PIXIED_STATE[config_dir]}/runtime-hook.bash")
    [ "${PIXIED_STATE[runtime_hook_path]}" = "$expected" ] ||
        pixied_die "runtime hook path is outside the dedicated config directory"
    expected=$(pixied_canonical_path \
        "${PIXIED_STATE[state_dir]}/machines/${PIXIED_STATE[machine_id]}/sync-baseline")
    [ "${PIXIED_STATE[sync_baseline]}" = "$expected" ] ||
        pixied_die "runtime sync baseline path is outside the machine state directory"
    [ -n "${PIXIED_STATE[pixi_binary_hash]}" ] ||
        pixied_die "runtime Pixi binary hash is missing"
    [ -n "${PIXIED_STATE[direnv_hash]}" ] ||
        pixied_die "runtime direnv hash is missing"
    [ -n "${PIXIED_STATE[runtime_hook_hash]}" ] ||
        pixied_die "runtime hook hash is missing"

    pixied_validate_owned_path "${PIXIED_STATE[state_dir]}"
    pixied_validate_owned_path "${PIXIED_STATE[data_dir]}"
    pixied_validate_owned_path "${PIXIED_STATE[config_dir]}"
    pixied_validate_owned_path "${PIXIED_STATE[pixi_home]}"
    pixied_validate_owned_path "${PIXIED_STATE[pixi_binary_path]}" \
        "${PIXIED_STATE[pixi_binary_hash]}"
    [ -x "${PIXIED_STATE[pixi_binary_path]}" ] ||
        pixied_die "dedicated Pixi binary is not executable"
    pixied_validate_owned_path "${PIXIED_STATE[direnv_path]}" "${PIXIED_STATE[direnv_hash]}"
    [ -x "${PIXIED_STATE[direnv_path]}" ] ||
        pixied_die "dedicated direnv is not executable"
    pixied_validate_owned_path "${PIXIED_STATE[runtime_hook_path]}" \
        "${PIXIED_STATE[runtime_hook_hash]}"
    [ -x "${PIXIED_STATE[data_dir]}/bin/pixied" ] ||
        pixied_die "deployed PixiEden CLI is not executable"

    if [ "${PIXIED_STATE[session_manager]}" = zellij ]; then
        pixied_state_has zellij_path || pixied_die "runtime Zellij path is missing"
        pixied_state_has zellij_hash || pixied_die "runtime Zellij hash is missing"
        expected=$(pixied_canonical_path "${PIXIED_STATE[pixi_home]}/bin/zellij")
        [ "${PIXIED_STATE[zellij_path]}" = "$expected" ] ||
            pixied_die "runtime Zellij path is outside the dedicated Pixi home"
        [ -n "${PIXIED_STATE[zellij_hash]}" ] ||
            pixied_die "runtime Zellij hash is missing"
        pixied_validate_owned_path "${PIXIED_STATE[zellij_path]}" "${PIXIED_STATE[zellij_hash]}"
        [ -x "${PIXIED_STATE[zellij_path]}" ] ||
            pixied_die "dedicated Zellij is not executable"
    fi

    account_home=$(pixied_validate_home_directory "${PIXIED_STATE[account_home]}" "account home")
    local_home=$(pixied_validate_home_directory "${PIXIED_STATE[local_home]}" "local home")
    [ "$account_home" = "${PIXIED_STATE[account_home]}" ] ||
        pixied_die "runtime account home is not canonical"
    [ "$local_home" = "${PIXIED_STATE[local_home]}" ] ||
        pixied_die "runtime local home is not canonical"
    if [ "${PIXIED_STATE[home_mode]}" = local ]; then
        [ "$account_home" = "$local_home" ] ||
            pixied_die "local home mode has a different local home"
    else
        [ "$account_home" != "$local_home" ] ||
            pixied_die "NFS home mode must use a separate local home"
        pixied_is_local_filesystem "$local_home" ||
            pixied_die "runtime local home is not on a local filesystem"
    fi
}

# @description Load and validate the current machine's runtime state.
# A generated hook supplies an exact state path so runtime HOME changes never
# cause account-side paths to be recalculated.
#
# @set PIXIED_STATE assoc The validated state.
# @set PIXIED_STATE_FILE string The validated state file path.
# @exitcode 0 When the state and all runtime artifacts are valid.
# @exitcode 1 When PixiEden is not installed or validation fails.
pixied_runtime_load_state() {
    local state_file state_dir
    if [ -n "${PIXIED_RUNTIME_STATE_FILE:-}" ]; then
        state_file=$(pixied_validate_canonical_path "$PIXIED_RUNTIME_STATE_FILE")
        pixied_runtime_set_identity
        if [ -n "${PIXIED_STATE_DIR:-}" ]; then
            state_dir=$(pixied_validate_canonical_path "$PIXIED_STATE_DIR")
        else
            # Generated hooks provide PIXIED_STATE_DIR explicitly. Keep this
            # fallback for direct start calls with an explicit state file;
            # the loaded state validates the derived path before use.
            state_dir=${state_file%/machines/*}
            [ "$state_dir" != "$state_file" ] ||
                pixied_die "runtime state file has an invalid path"
            state_dir=$(pixied_validate_canonical_path "$state_dir")
        fi
        export PIXIED_STATE_DIR=$state_dir
    else
        pixied_resolve_paths
        state_file=$PIXIED_STATE_FILE
    fi

    [ -f "$state_file" ] ||
        pixied_die "PixiEden is not installed; run pixied install first"
    export PIXIED_STATE_FILE=$state_file
    pixied_state_load "$state_file"
    pixied_runtime_apply_state
    export PIXIED_STATE_FILE=$state_file
    pixied_runtime_validate_state
}

# @description Print the validated state for the generated runtime hook.
# This command is intentionally data-only so the hook can validate state in a
# child Bash process before changing the shell that sourced it.
#
# @stdout The serialized, validated state.
# @exitcode 0 When the state is valid.
# @exitcode 1 When validation fails.
pixied_runtime_dump_state() {
    pixied_runtime_load_state
    pixied_state_serialize
}

# @description Return PATH with the supplied prefixes and existing entries deduplicated.
# Empty PATH entries are discarded so activation cannot accidentally add the
# current working directory to the runtime search path.
#
# @arg $@ string Prefix paths to place before the inherited PATH.
# @stdout The deduplicated PATH.
# @exitcode 0 Always.
pixied_path_prepend_unique() {
    local -a path_entries=()
    local prefix entry path_key path_result=""
    declare -A seen_paths=()

    for prefix in "$@"; do
        [ -n "$prefix" ] || continue
        path_key="x$prefix"
        if [ -z "${seen_paths[$path_key]+present}" ]; then
            seen_paths[$path_key]=1
            if [ -n "$path_result" ]; then
                path_result+=:
            fi
            path_result+=$prefix
        fi
    done

    IFS=: read -r -a path_entries <<<"${PATH:-}"
    for entry in "${path_entries[@]}"; do
        [ -n "$entry" ] || continue
        path_key="x$entry"
        if [ -z "${seen_paths[$path_key]+present}" ]; then
            seen_paths[$path_key]=1
            if [ -n "$path_result" ]; then
                path_result+=:
            fi
            path_result+=$entry
        fi
    done
    printf '%s' "$path_result"
}

# @description Export the dedicated runtime environment for a child process.
# The caller's process is already the PixiEden CLI, so these exports only affect
# the command that follows and never the shell that invoked the CLI.
#
# @set HOME string The validated local runtime home.
# @set PIXI_HOME string The dedicated Pixi home.
# @set PIXI_CACHE_DIR string The dedicated Pixi cache.
# @set PIXI_NO_PATH_UPDATE integer Disables Pixi PATH mutation.
# @set PATH string The deduplicated runtime PATH.
# @exitcode 0 Always.
pixied_runtime_export_environment() {
    export HOME=$PIXIED_LOCAL_HOME
    export PIXI_HOME=$PIXIED_PIXI_HOME
    export PIXI_CACHE_DIR=$PIXIED_PIXI_HOME/cache
    export PIXI_NO_PATH_UPDATE=1
    export PIXIED_RUNTIME_STATE_FILE=$PIXIED_STATE_FILE
    export PIXIED_RUNTIME_HOOK_ACTIVE=1
    PATH=$(pixied_path_prepend_unique \
        "$PIXIED_COMMAND_BIN" "$PIXIED_DATA_DIR/bin" "$PIXIED_PIXI_HOME/bin")
    export PATH
}

# @description Run a child process with the dedicated environment and collect its status.
# The child is deliberately not exec'd so the caller can decide whether a
# successful exit permits later work in a future runtime phase. The child's
# status, including the conventional 128-plus-signal status, is preserved.
#
# @arg $@ string The child command and arguments.
# @exitcode The child process exit status.
pixied_runtime_wait_for_child() {
    local child_status
    if pixied_run env HOME="$HOME" PIXI_HOME="$PIXI_HOME" \
        PIXI_CACHE_DIR="$PIXI_CACHE_DIR" PIXI_NO_PATH_UPDATE=1 \
        "$@"; then
        child_status=$PIXIED_EXIT_OK
    else
        child_status=$?
    fi
    # Suppress the EXIT trap's duplicate error message. Future sync decisions
    # must use this function's return status, not PIXIED_ERROR_REPORTED.
    export PIXIED_ERROR_REPORTED=1
    return "$child_status"
}

# @description Run a child and finish synchronization using its exit status.
# The child is allowed to push only after a successful exit.
#
# @arg $@ string The child command and arguments.
# @exitcode The child or synchronization exit status.
pixied_runtime_run_child() {
    local child_status finish_status
    if pixied_runtime_wait_for_child "$@"; then
        child_status=$PIXIED_EXIT_OK
    else
        child_status=$?
    fi
    if pixied_sync_runtime_finish "$child_status" 1; then
        return "$PIXIED_EXIT_OK"
    else
        finish_status=$?
        return "$finish_status"
    fi
}

# @description Prepare the runtime before running a command or session.
# @exitcode 0 When the runtime is ready.
pixied_runtime_prepare() {
    pixied_runtime_load_state
    pixied_runtime_export_environment
    pixied_sync_runtime_begin
}

# @description Run a command directly in the prepared PixiEden runtime.
#
# @arg $@ string The command and arguments.
# @exitcode 0 When the child exits successfully.
# @exitcode The child exit status, including 128 plus the signal number when
# the process was terminated by a signal.
pixied_runtime_run() {
    pixied_runtime_prepare
    pixied_runtime_run_child "$@"
}

# @description Attach to a direct Zellij session or start an interactive Bash.
# A session-less shell opens an interactive Bash child; Zellij mode attaches
# directly unless the caller is already inside Zellij.
#
# @exitcode 0 When the child shell or attach process exits successfully.
# @exitcode The child or attach process exit status, including 128 plus the
# signal number when the process was terminated by a signal.
pixied_runtime_shell() {
    local session_name child_status push_allowed=1 session_status
    if [ "${PIXIED_RUNTIME_HOOK_ACTIVE:-0}" -eq 1 ] &&
        [ "${PIXIED_RUNTIME_HOOK_AUTOSTART:-0}" -ne 1 ]; then
        pixied_die "PixiEden is already active in this shell; use exit to leave it" \
            "$PIXIED_EXIT_FAILURE"
    fi
    pixied_runtime_prepare

    pixied_require_tty
    if [ "$PIXIED_SESSION_MANAGER" = none ] || [ -n "${ZELLIJ:-}" ]; then
        pixied_runtime_run_child bash -i
        return $?
    fi

    session_name=pixied
    if pixied_runtime_wait_for_child "$PIXIED_ZELLIJ_PATH" attach --create "$session_name"; then
        child_status=$PIXIED_EXIT_OK
    else
        child_status=$?
    fi
    if [ "$child_status" -eq "$PIXIED_EXIT_OK" ]; then
        if pixied_sync_zellij_session_status "$session_name"; then
            push_allowed=0
            pixied_warn "skipping sync push because Zellij session remains: $session_name"
        else
            session_status=$?
            if [ "$session_status" -eq 2 ]; then
                push_allowed=0
                pixied_warn "skipping sync push because Zellij session status is unavailable"
            fi
        fi
    fi
    if pixied_sync_runtime_finish "$child_status" "$push_allowed"; then
        return "$PIXIED_EXIT_OK"
    else
        return $?
    fi
}
