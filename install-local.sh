#!/usr/bin/env bash

PIXIED_SOURCE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly PIXIED_SOURCE_DIR

# shellcheck source=lib/common.sh
. "$PIXIED_SOURCE_DIR/lib/common.sh"
# shellcheck source=lib/paths.sh
. "$PIXIED_SOURCE_DIR/lib/paths.sh"
# shellcheck source=lib/state.sh
. "$PIXIED_SOURCE_DIR/lib/state.sh"
# shellcheck source=lib/options.sh
. "$PIXIED_SOURCE_DIR/lib/options.sh"
pixied_enable_strict_mode

# @description Print the local installer usage and available installation options.
# @stdout The installer help message.
# @exitcode 0 Always.
pixied_install_help() {
    cat <<'USAGE'
Usage: install-local.sh [OPTIONS]

Deploy PixiEden from the local source tree and run its installer.

Options:
    --help                         Show this help.
    --yes                          Skip interactive confirmation prompts.
    --home-mode local|nfs          Select the account home mode.
    --local-home PATH              Set the machine-local home used by NFS mode.
    --session-manager none|zellij  Select the runtime session manager.
    --machine-id ID                Set the machine-specific state identifier.

The same installation options can be passed to `pixied install`.
USAGE
}

# @description Deploy PixiEden from the local source tree to the resolved data directory.
# Parses options, resolves deployment paths, stages the managed CLI and library
# files on the same filesystem as the destination, then promotes them per-file
# with atomic mv. A rollback restores the previous deployment when promotion
# fails; once promotion succeeds, delegation failures leave the promoted CLI in
# place and never trigger deployment rollback.
#
# @arg $@ string The installation options forwarded to the deployed CLI.
# @exitcode 0 When deployment and delegation succeed.
# @exitcode 1 When deployment or delegation fails.
# @see pixied_resolve_paths
# @see pixied_options_parse
pixied_install_local() {
    local destination file created_data
    local pixied_opt_var
    local -A pixied_orig_opt=()
    local deploy_bin="bin/pixied"
    local deploy_libs=(
        lib/common.sh
        lib/paths.sh
        lib/state.sh
        lib/lease.sh
        lib/options.sh
        lib/pixi.sh
        lib/sync.sh
        lib/session.sh
        lib/hook.sh
        lib/generate.sh
        lib/uninstall.sh
    )
    # Capture the user-supplied option overrides (original environment) before any
    # resolve runs. The resolve below exports derived values such as PIXIED_HOME_MODE
    # into this process; those must not leak into the delegated CLI as if they were
    # explicit user overrides, or pixied_options_apply_state would skip restoring the
    # saved home mode from an existing installation.
    for pixied_opt_var in PIXIED_HOME_MODE PIXIED_LOCAL_HOME PIXIED_SESSION_MANAGER PIXIED_MACHINE_ID PIXIED_PIXI_HOME; do
        pixied_orig_opt[$pixied_opt_var]=${!pixied_opt_var:-}
    done

    # Parse options before resolving deployment paths so CLI values such as
    # --local-home are available during the bootstrap deployment.
    pixied_options_parse "$@"
    # Load the verified active runtime state (no-op when not active). In an
    # active runtime this sets the identity and managed paths from the verified
    # state file and refuses a missing or invalid state before any deployment.
    pixied_state_bootstrap_active_runtime
    # Reject identity-changing options before any deployment work runs, so an
    # active runtime cannot be silently re-pointed by an install invocation.
    pixied_install_assert_active_identity
    # Deployment only needs the destination paths; install validates the selected
    # home mode after the interactive wizard has completed.
    pixied_resolve_paths 0
    destination=$PIXIED_DATA_DIR
    if [ -e "$destination" ] || [ -L "$destination" ]; then
        created_data=0
    else
        created_data=1
    fi
    export PIXIED_DEPLOY_CREATED_DATA=$created_data
    [ -f "$PIXIED_SOURCE_DIR/$deploy_bin" ] || pixied_die "source file is missing: $deploy_bin"
    for file in "${deploy_libs[@]}"; do
        [ -f "$PIXIED_SOURCE_DIR/$file" ] || pixied_die "source file is missing: $file"
    done

    # Staging and backup live beside the destination, on the same filesystem, so
    # promotion can use atomic mv -f. They are never placed under PIXIED_STATE_DIR.
    pixied_run mkdir -p -- "${destination%/*}"
    local stage_dir backup_dir target backup entry file_kind
    local -a manifest_entries=()
    stage_dir=$(pixied_run mktemp -d "${destination%/*}/.pixied-stage.XXXXXX")
    pixied_register_temp "$stage_dir"
    backup_dir=$(pixied_run mktemp -d "${destination%/*}/.pixied-backup.XXXXXX")
    pixied_register_temp "$backup_dir"

    pixied_step "Staging PixiEden deployment under $stage_dir"
    pixied_run mkdir -p "$stage_dir/bin" "$stage_dir/lib"
    pixied_run cp "$PIXIED_SOURCE_DIR/$deploy_bin" "$stage_dir/$deploy_bin"
    for file in "${deploy_libs[@]}"; do
        pixied_run cp "$PIXIED_SOURCE_DIR/$file" "$stage_dir/$file"
    done
    pixied_run chmod 0755 "$stage_dir/$deploy_bin"
    for file in "${deploy_libs[@]}"; do
        pixied_run chmod 0644 "$stage_dir/$file"
    done
    # Verify every staged file is a regular, non-symlink file.
    if [ ! -f "$stage_dir/$deploy_bin" ] || [ -L "$stage_dir/$deploy_bin" ]; then
        pixied_die "staged CLI is not a regular file: $stage_dir/$deploy_bin"
    fi
    for file in "${deploy_libs[@]}"; do
        if [ ! -f "$stage_dir/$file" ] || [ -L "$stage_dir/$file" ]; then
            pixied_die "staged library is not a regular file: $stage_dir/$file"
        fi
    done

    # Build a backup manifest of existing targets. Present files are copied into
    # the backup directory; absent targets are recorded so rollback can remove
    # the promoted file and restore the prior non-existence.
    for file in "$deploy_bin" "${deploy_libs[@]}"; do
        target=$destination/$file
        if [ -e "$target" ] || [ -L "$target" ]; then
            backup=$backup_dir/$file
            pixied_run mkdir -p -- "$(dirname "$backup")"
            pixied_run cp -a -- "$target" "$backup"
            manifest_entries+=("$file|backup")
        else
            manifest_entries+=("$file|absent")
        fi
    done

    # @description Restore the previous deployment from the backup manifest.
    # Applies entries in reverse so the last promoted file is reverted first.
    pixied_install_rollback() {
        local entry file target backup
        local i
        for ((i = ${#manifest_entries[@]} - 1; i >= 0; i--)); do
            entry=${manifest_entries[i]}
            file=${entry%%|*}
            file_kind=${entry##*|}
            target=$destination/$file
            if [ "$file_kind" = backup ]; then
                backup=$backup_dir/$file
                if [ -e "$backup" ] || [ -L "$backup" ]; then
                    pixied_run mv -f -- "$backup" "$target"
                fi
            else
                pixied_run rm -f -- "$target"
            fi
        done
    }

    # @description Reject a deployment destination that escapes its boundary through a symlink.
    # Promotion creates and writes under "$destination/bin" and "$destination/lib"
    # with atomic mv. If any of those directories is a pre-existing symlink,
    # promotion would write outside the managed deployment directory, so reject
    # it before any file moves.
    pixied_install_validate_destination_boundaries() {
        local dir
        for dir in "$destination" "$destination/bin" "$destination/lib"; do
            if [ -L "$dir" ]; then
                pixied_die "deployment destination path is a symlink and escapes its boundary: $dir"
            fi
        done
    }

    # @description Roll back and re-raise a signal received during promotion.
    # Registered only around the promotion block so a SIGINT/SIGTERM mid-promotion
    # restores the previous deployment before the process exits with the signal's
    # exit code, instead of leaving a half-promoted deployment behind.
    pixied_install_promote_interrupt() {
        local sig=$1 rc=$2
        pixied_install_rollback
        trap - INT TERM 2>/dev/null || true
        eval "$pixied_prev_int_trap" 2>/dev/null || true
        eval "$pixied_prev_term_trap" 2>/dev/null || true
        kill -"$sig" "$$"
        exit "$rc"
    }

    # @description Promote staged files to the managed destination per-file.
    # Uses atomic mv -f. A deterministic failure can be injected before any file
    # through PIXIED_DEPLOY_FAIL_PROMOTE for rollback testing. Returns 1 on
    # failure so the caller can roll back; it never calls pixied_die.
    pixied_install_promote() {
        (
            # Run promotion in a subshell so the errtrace ERR trap and errexit
            # can be disabled here without leaking into the caller. A real
            # promotion failure must return to the caller for rollback instead
            # of aborting the script via the global error trap.
            trap - ERR 2>/dev/null || true
            set +e
            local entry file target
            for entry in "${manifest_entries[@]}"; do
                file=${entry%%|*}
                target=$destination/$file
                if [ "${PIXIED_DEPLOY_FAIL_PROMOTE:-0}" = 1 ]; then
                    exit 1
                fi
                pixied_run mkdir -p -- "$(dirname "$target")"
                if ! pixied_run mv -f -- "$stage_dir/$file" "$target"; then
                    exit 1
                fi
            done
        )
        return $?
    }

    # Promotion runs with errexit disabled so a failing mv returns to the caller
    # instead of aborting the script. Rollback targets only promotion failures;
    # once promotion succeeds, delegation failures keep the promoted CLI in place
    # and never trigger deployment rollback. pixied_install_rollback is written to
    # be safe to call from a trap as well.
    # errtrace (set -E) fires the ERR trap even with errexit disabled, so the
    # non-zero return from promotion must not be swallowed by the global error
    # handler. Suspend the trap around the call and restore it afterward so the
    # caller's rollback contract runs, then re-enable errexit.
    pixied_install_validate_destination_boundaries
    local pixied_promote_rc pixied_promote_err_trap pixied_prev_int_trap pixied_prev_term_trap
    pixied_promote_err_trap="$(trap -p ERR 2>/dev/null || true)"
    pixied_prev_int_trap="$(trap -p INT 2>/dev/null || true)"
    pixied_prev_term_trap="$(trap -p TERM 2>/dev/null || true)"
    trap - ERR 2>/dev/null || true
    trap 'pixied_install_promote_interrupt INT 130' INT
    trap 'pixied_install_promote_interrupt TERM 143' TERM
    set +e
    pixied_install_promote
    pixied_promote_rc=$?
    set -e
    eval "$pixied_promote_err_trap" 2>/dev/null || true
    trap - INT TERM 2>/dev/null || true
    eval "$pixied_prev_int_trap" 2>/dev/null || true
    eval "$pixied_prev_term_trap" 2>/dev/null || true
    if [ "$pixied_promote_rc" -ne 0 ]; then
        pixied_install_rollback
        pixied_die "deployment promotion failed; restored the previous PixiEden deployment"
    fi

    pixied_success "PixiEden CLI deployed to $destination/bin/pixied"
    # PIXIED_PIXI_HOME may have been derived only to locate the deployment
    # directory. Do not make that bootstrap value override the wizard's local home.
    if ! pixied_options_is_explicit pixi_home; then
        unset PIXIED_PIXI_HOME
    fi
    # Restore the user-supplied option overrides captured before the deployment
    # resolve. This clears any values derived by pixied_resolve_paths so the
    # delegated CLI re-derives them and pixied_options_apply_state can restore the
    # saved configuration from an existing installation instead of treating the
    # derived value as an explicit override.
    for pixied_opt_var in PIXIED_HOME_MODE PIXIED_LOCAL_HOME PIXIED_SESSION_MANAGER PIXIED_MACHINE_ID PIXIED_PIXI_HOME; do
        if [ -n "${pixied_orig_opt[$pixied_opt_var]:-}" ]; then
            export "$pixied_opt_var=${pixied_orig_opt[$pixied_opt_var]}"
        else
            unset "$pixied_opt_var"
        fi
    done
    # Delegate to the now-promoted CLI. Delegation failures are intentionally not
    # turned into a deployment rollback.
    "$destination/bin/pixied" install "$@"
}

if [ "$#" -eq 1 ] && [ "$1" = '--help' ]; then
    pixied_install_help
    exit 0
fi

pixied_install_local "$@"
