#!/usr/bin/env bash

PIXIED_SOURCE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly PIXIED_SOURCE_DIR

# shellcheck source=lib/common.sh
. "$PIXIED_SOURCE_DIR/lib/common.sh"
# shellcheck source=lib/paths.sh
. "$PIXIED_SOURCE_DIR/lib/paths.sh"
# shellcheck source=lib/release.sh
. "$PIXIED_SOURCE_DIR/lib/release.sh"
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
    --machine-id ID                Set the machine-specific state identifier.

The same installation options can be passed to `pixied install`.
USAGE
}

# @description Deploy a validated source directory into the local payload path.
# The source may be a checkout or a release stage; both use the same allowlist,
# regular-file checks, per-file atomic promotion, and rollback behavior.
#
# @arg $1 string The source directory.
# @arg $2 string The local payload destination.
# @set PIXIED_DEPLOY_CREATED_DATA integer Whether the destination was absent.
# @exitcode 0 When every payload file is promoted successfully.
# @exitcode 1 When promotion fails and the previous payload is restored.
pixied_install_deploy_source() {
    local source_root=$1 destination=$2
    local file created_data
    local deploy_bin="bin/pixied"
    local -a deploy_libs=() deploy_templates=()
    local stage_dir backup_dir target backup entry file_kind
    local -a manifest_entries=()
    local pixied_promote_rc pixied_promote_err_trap pixied_prev_int_trap pixied_prev_term_trap

    source_root=$(realpath -m -- "$source_root")
    if ! [ -d "$source_root" ] || [ -L "$source_root" ]; then
        pixied_die "deployment source is not a regular directory: $source_root"
    fi
    pixied_release_payload_paths "$source_root"
    if [ -f "$source_root/release-manifest" ]; then
        pixied_release_validate_tree "$source_root" "$source_root/release-manifest" archive
    fi
    for file in "${PIXIED_RELEASE_PAYLOAD_PATHS[@]}"; do
        case "$file" in
        install-local.sh) ;;
        bin/pixied) deploy_bin=$file ;;
        lib/templates/*/*.tmpl | lib/templates/*/*.tmpl.*) deploy_templates+=("$file") ;;
        lib/*.sh) deploy_libs+=("$file") ;;
        esac
    done

    if [ -e "$destination" ] || [ -L "$destination" ]; then
        created_data=0
    else
        created_data=1
    fi
    export PIXIED_DEPLOY_CREATED_DATA=$created_data
    [ -f "$source_root/$deploy_bin" ] || pixied_die "source file is missing: $deploy_bin"
    for file in "${deploy_libs[@]}" "${deploy_templates[@]}"; do
        [ -f "$source_root/$file" ] || pixied_die "source file is missing: $file"
    done

    # Staging and backup live beside the destination, on the same filesystem, so
    # promotion can use atomic mv -f. They are never placed under PIXIED_STATE_DIR.
    pixied_run mkdir -p -- "${destination%/*}"
    pixied_run mkdir -p -- "$destination"
    stage_dir=$(pixied_run mktemp -d "${destination%/*}/.pixied-stage.XXXXXX")
    pixied_register_temp "$stage_dir"
    backup_dir=$(pixied_run mktemp -d "${destination%/*}/.pixied-backup.XXXXXX")
    pixied_register_temp "$backup_dir"

    pixied_step "Staging PixiEden deployment under $stage_dir"
    pixied_run mkdir -p "$stage_dir/bin" "$stage_dir/lib" "$stage_dir/lib/templates"
    pixied_run cp "$source_root/$deploy_bin" "$stage_dir/$deploy_bin"
    for file in "${deploy_libs[@]}" "${deploy_templates[@]}"; do
        pixied_run mkdir -p -- "$stage_dir/$(dirname "$file")"
        pixied_run cp "$source_root/$file" "$stage_dir/$file"
    done
    pixied_run chmod 0755 "$stage_dir/$deploy_bin"
    for file in "${deploy_libs[@]}" "${deploy_templates[@]}"; do
        pixied_run chmod 0644 "$stage_dir/$file"
    done
    if [ ! -f "$stage_dir/$deploy_bin" ] || [ -L "$stage_dir/$deploy_bin" ]; then
        pixied_die "staged CLI is not a regular file: $stage_dir/$deploy_bin"
    fi
    for file in "${deploy_libs[@]}" "${deploy_templates[@]}"; do
        if [ ! -f "$stage_dir/$file" ] || [ -L "$stage_dir/$file" ]; then
            pixied_die "staged library is not a regular file: $stage_dir/$file"
        fi
    done

    for file in "$deploy_bin" "${deploy_libs[@]}" "${deploy_templates[@]}"; do
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
    # @exitcode 0 When all prior files are restored.
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

    # @description Reject destination symlinks before promotion.
    # @exitcode 0 When all destination boundaries are regular paths.
    pixied_install_validate_destination_boundaries() {
        local dir
        for dir in "$destination" "$destination/bin" "$destination/lib" \
            "$destination/lib/templates" "$destination/lib/templates/direnv" \
            "$destination/lib/templates/devcontainer" "$destination/lib/templates/dockerfile"; do
            if [ -L "$dir" ]; then
                pixied_die "deployment destination path is a symlink and escapes its boundary: $dir"
            fi
        done
    }

    # @description Roll back and re-raise an interrupt received during promotion.
    # @arg $1 string Signal name.
    # @arg $2 integer Signal exit status.
    # @exitcode The supplied signal status.
    pixied_install_promote_interrupt() {
        local sig=$1 rc=$2
        pixied_install_rollback
        trap - INT TERM 2>/dev/null || true
        eval "$pixied_prev_int_trap" 2>/dev/null || true
        eval "$pixied_prev_term_trap" 2>/dev/null || true
        kill -"$sig" "$$"
        exit "$rc"
    }

    # @description Promote staged files with rollback on the first failed move.
    # @exitcode 0 When every staged file is promoted.
    # @exitcode 1 When a move fails.
    pixied_install_promote() {
        (
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

    pixied_install_validate_destination_boundaries
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
    local destination state_exists
    local bootstrap_home_mode bootstrap_local_home bootstrap_machine_id
    local bootstrap_wizard_completed bootstrap_skip_wizard
    local release_stage="" release_version="" release_manifest_hash="" nfs_release=0
    local pixied_opt_var
    local -A pixied_orig_opt=()
    local -a delegate_args=()
    # Capture the user-supplied option overrides (original environment) before any
    # resolve runs. The resolve below exports derived values such as PIXIED_HOME_MODE
    # into this process; those must not leak into the delegated CLI as if they were
    # explicit user overrides, or pixied_options_apply_state would skip restoring the
    # saved home mode from an existing installation.
    for pixied_opt_var in PIXIED_HOME_MODE PIXIED_LOCAL_HOME PIXIED_MACHINE_ID PIXIED_PIXI_HOME; do
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

    # Resolve side-effect-free paths first so the state identity and the NFS
    # local-home candidate are known before the wizard or deployment runs.
    pixied_resolve_paths 0
    state_exists=0
    if [ -e "$PIXIED_STATE_FILE" ] || [ -L "$PIXIED_STATE_FILE" ]; then
        pixied_state_load "$PIXIED_STATE_FILE"
        state_exists=1
        pixied_options_validate_state_transition
        pixied_options_apply_state
        pixied_resolve_paths 0
    else
        pixied_options_apply_peer_defaults
    fi
    pixied_options_wizard "$state_exists"
    bootstrap_wizard_completed=${PIXIED_OPTIONS_WIZARD_COMPLETED:-0}
    pixied_options_validate_state_transition
    pixied_options_preflight_nfs_local_home "$state_exists"
    # The preflight is the only operation allowed to create a missing NFS local
    # home. All deployment paths are validated again immediately afterward.
    pixied_resolve_paths 1
    bootstrap_home_mode=$PIXIED_HOME_MODE
    bootstrap_local_home=$PIXIED_LOCAL_HOME
    bootstrap_machine_id=$PIXIED_MACHINE_ID
    bootstrap_skip_wizard=$bootstrap_wizard_completed

    destination=$PIXIED_DATA_DIR
    if [ "$PIXIED_HOME_MODE" = nfs ]; then
        nfs_release=1
        pixied_release_store_prepare
        pixied_release_publish_lock_acquire
        release_stage=$(pixied_release_run mktemp -d "$PIXIED_RELEASE_STORE_DIR/.stage.XXXXXX")
        pixied_register_temp "$release_stage"
        pixied_release_stage_source "$PIXIED_SOURCE_DIR" "$release_stage"
        release_version=$PIXIED_RELEASE_VERSION
        release_manifest_hash=$PIXIED_RELEASE_MANIFEST_HASH
        pixied_release_stage_validate "$release_stage" "$release_version" "$release_manifest_hash"
        pixied_install_deploy_source "$release_stage" "$destination"
    else
        pixied_install_deploy_source "$PIXIED_SOURCE_DIR" "$destination"
    fi
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
    for pixied_opt_var in PIXIED_HOME_MODE PIXIED_LOCAL_HOME PIXIED_MACHINE_ID PIXIED_PIXI_HOME; do
        if [ -n "${pixied_orig_opt[$pixied_opt_var]:-}" ]; then
            export "$pixied_opt_var=${pixied_orig_opt[$pixied_opt_var]}"
        else
            unset "$pixied_opt_var"
        fi
    done
    if [ "$nfs_release" -eq 1 ]; then
        export PIXIED_HOME_MODE=$bootstrap_home_mode
        export PIXIED_MACHINE_ID=$bootstrap_machine_id
    fi
    # Delegate to the now-promoted CLI. Delegation failures are intentionally not
    # turned into a deployment rollback. When bootstrap already ran the wizard,
    # pass only its selected values so the deployed CLI does not ask again.
    delegate_args=("$@")
    if [ "$bootstrap_skip_wizard" -eq 1 ]; then
        delegate_args+=(
            --home-mode "$bootstrap_home_mode"
            --machine-id "$bootstrap_machine_id"
        )
        if [ "$bootstrap_home_mode" = nfs ]; then
            delegate_args+=(--local-home "$bootstrap_local_home")
        fi
        export PIXIED_INSTALL_BOOTSTRAP_CONFIRMED=1
    fi
    "$destination/bin/pixied" install "${delegate_args[@]}"

    if [ "$nfs_release" -eq 1 ]; then
        pixied_release_promote_stage "$release_stage" "$release_version" "$release_manifest_hash"
        pixied_state_lock_acquire "$PIXIED_STATE_DIR/.lock"
        pixied_state_load "$PIXIED_STATE_FILE"
        pixied_state_set payload_release_version "$release_version"
        pixied_state_set payload_release_manifest_hash "$release_manifest_hash"
        pixied_state_write "$PIXIED_STATE_FILE"
        pixied_state_lock_release
        pixied_release_select_current "$release_version" "$release_manifest_hash"
        pixied_release_publish_lock_release
        pixied_success "Shared release $release_version is current for this host"
    fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    if [ "$#" -eq 1 ] && [ "$1" = '--help' ]; then
        pixied_install_help
        exit 0
    fi

    pixied_install_local "$@"
fi
