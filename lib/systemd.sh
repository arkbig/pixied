#!/usr/bin/env bash
# @brief Systemd user-session support for PixiEden.
# @description
# Generates the machine-specific Zellij unit, checks whether a user manager is
# reachable, and provides explicit gates for lingering and WSL configuration.

if [ -n "${PIXIED_SYSTEMD_LOADED:-}" ]; then
    # shellcheck disable=SC2317 # Sourced by both the source and deployed CLI.
    return 0 2>/dev/null || exit 0
fi
PIXIED_SYSTEMD_LOADED=1

# @description Detect whether the current environment is WSL.
# An explicit PIXIED_WSL value is available for isolated tests and containers.
#
# @exitcode 0 When WSL is detected.
# @exitcode 1 When WSL is not detected.
pixied_systemd_is_wsl() {
    case "${PIXIED_WSL:-}" in
    1 | yes | true) return 0 ;;
    0 | no | false) return 1 ;;
    "") ;;
    *) pixied_die "invalid PIXIED_WSL value: $PIXIED_WSL" "$PIXIED_EXIT_USAGE" ;;
    esac

    if [ -e /.dockerenv ] || [ -e /run/.containerenv ]; then
        return 1
    fi
    if [ -r /proc/sys/kernel/osrelease ] &&
        grep -qiE 'microsoft|wsl' /proc/sys/kernel/osrelease; then
        return 0
    fi
    if [ -r /proc/version ] && grep -qiE 'microsoft|wsl' /proc/version; then
        return 0
    fi
    return 1
}

# @description Return whether WSL's systemd option is enabled in wsl.conf.
# Only the [boot] systemd setting is interpreted; all other configuration is
# treated as opaque text.
#
# @arg $1 string The wsl.conf path.
# @exitcode 0 When [boot] systemd is enabled.
# @exitcode 1 When it is absent or disabled.
pixied_systemd_wsl_systemd_enabled() {
    local config_path=$1 line section candidate value in_boot=0
    [ -r "$config_path" ] || return 1

    while IFS= read -r line || [ -n "$line" ]; do
        candidate=${line%%[#;]*}
        if [[ "$candidate" =~ ^[[:space:]]*\[([^]]+)\][[:space:]]*$ ]]; then
            section=${BASH_REMATCH[1],,}
            if [ "$section" = boot ]; then
                in_boot=1
            else
                in_boot=0
            fi
            continue
        fi
        [ "$in_boot" -eq 1 ] || continue
        if [[ "$candidate" =~ ^[[:space:]]*systemd[[:space:]]*=[[:space:]]*([^[:space:]]+)[[:space:]]*$ ]]; then
            value=${BASH_REMATCH[1],,}
            case "$value" in
            1 | yes | true) return 0 ;;
            *) return 1 ;;
            esac
        fi
    done <"$config_path"
    return 1
}

# @description Render wsl.conf with [boot] systemd=true while preserving other settings.
# Existing systemd assignments in the [boot] section are replaced in place.
#
# @arg $1 string The source wsl.conf path.
# @stdout The merged configuration.
# @exitcode 0 Always.
pixied_systemd_wsl_merge() {
    local config_path=$1 line section candidate value content=""
    local in_boot=0 found=0 saw_boot=0

    if [ -e "$config_path" ]; then
        [ -f "$config_path" ] || pixied_die "WSL configuration is not a regular file: $config_path"
        [ ! -L "$config_path" ] || pixied_die "WSL configuration is a symlink: $config_path"
        while IFS= read -r line || [ -n "$line" ]; do
            candidate=${line%%[#;]*}
            if [[ "$candidate" =~ ^[[:space:]]*\[([^]]+)\][[:space:]]*$ ]]; then
                if [ "$in_boot" -eq 1 ] && [ "$found" -eq 0 ]; then
                    content+=$'systemd=true\n'
                    found=1
                fi
                section=${BASH_REMATCH[1],,}
                if [ "$section" = boot ]; then
                    in_boot=1
                    saw_boot=1
                else
                    in_boot=0
                fi
            fi

            if [ "$in_boot" -eq 1 ] &&
                [[ "$candidate" =~ ^[[:space:]]*systemd[[:space:]]*=[[:space:]]*([^[:space:]]+)[[:space:]]*$ ]]; then
                value=${BASH_REMATCH[1],,}
                case "$value" in
                1 | yes | true | 0 | no | false) ;;
                *) ;;
                esac
                if [ "$found" -eq 0 ]; then
                    content+=$'systemd=true\n'
                    found=1
                fi
                continue
            fi
            content+="$line"$'\n'
        done <"$config_path"
    fi

    if [ "$in_boot" -eq 1 ] && [ "$found" -eq 0 ]; then
        content+=$'systemd=true\n'
        found=1
    fi
    if [ "$saw_boot" -eq 0 ]; then
        content+=$'[boot]\nsystemd=true\n'
    fi
    printf '%s' "$content"
}

# @description Ask once before a sudo-backed system configuration change.
# --yes is the only non-interactive confirmation path; no sudo command is run
# when the gate is denied or when no terminal is available.
#
# @arg $1 string The change to describe.
# @exitcode 0 When the change is approved.
# @exitcode 1 When the change is denied.
pixied_systemd_confirm_sudo() {
    local message=$1 answer
    if [ "${PIXIED_INSTALL_ASSUME_YES:-0}" -eq 1 ]; then
        return 0
    fi
    if ! [ -t 0 ] || ! [ -t 1 ]; then
        pixied_warn "cannot request sudo confirmation without an interactive TTY"
        pixied_warn "rerun with --yes after reviewing: $message"
        return 1
    fi
    printf '%sApply privileged change: %s [y/N] %s' \
        "$PIXIED_COLOR_YELLOW" "$message" "$PIXIED_COLOR_RESET" >&2
    IFS= read -r answer
    case "$answer" in
    [yY] | [yY][eE][sS]) return 0 ;;
    *)
        pixied_warn "privileged change was declined: $message"
        return 1
        ;;
    esac
}

# @description Check whether the systemd user manager can be reached.
# PIXIED_SYSTEMD_USER_AVAILABLE can force the result for isolated tests.
#
# @exitcode 0 When the user manager is reachable.
# @exitcode 1 When it is unavailable.
pixied_systemd_user_manager_available() {
    case "${PIXIED_SYSTEMD_USER_AVAILABLE:-}" in
    1 | yes | true) return 0 ;;
    0 | no | false) return 1 ;;
    "") ;;
    *) pixied_die "invalid PIXIED_SYSTEMD_USER_AVAILABLE value: $PIXIED_SYSTEMD_USER_AVAILABLE" "$PIXIED_EXIT_USAGE" ;;
    esac
    pixied_have_cmd systemctl || return 1
    pixied_run systemctl --user show-environment >/dev/null 2>&1
}

# @description Escape a value for a systemd command-line or environment assignment.
#
# @arg $1 string The value to escape.
# @stdout The escaped value.
# @exitcode 0 Always.
pixied_systemd_escape_value() {
    local value=$1
    value=${value//\\/\\x5c}
    value=${value//$'\x22'/\\x22}
    value=${value//$' '/\\x20}
    value=${value//$'\t'/\\x09}
    value=${value//\$/\$\$}
    value=${value//%/%%}
    printf '%s' "$value"
}

# @description Print the machine-specific Zellij systemd unit.
#
# @stdout The unit file content.
# @exitcode 0 Always.
pixied_systemd_unit_content() {
    local unit_home unit_pixi unit_cache unit_path unit_bin unit_state unit_path_env
    unit_home=$(pixied_systemd_escape_value "$PIXIED_LOCAL_HOME")
    unit_pixi=$(pixied_systemd_escape_value "$PIXIED_PIXI_HOME")
    unit_cache=$(pixied_systemd_escape_value "$PIXIED_PIXI_HOME/cache")
    unit_path=$(pixied_systemd_escape_value \
        "$PIXIED_COMMAND_BIN:$PIXIED_DATA_DIR/bin:$PIXIED_PIXI_HOME/bin")
    unit_bin=$(pixied_systemd_escape_value "$PIXIED_ZELLIJ_PATH")
    unit_state=$(pixied_systemd_escape_value "$PIXIED_STATE_FILE")
    unit_path_env=$(pixied_systemd_escape_value "$PIXIED_SYSTEMD_UNIT_PATH")
    cat <<UNIT
[Unit]
Description=PixiEden Zellij session for $PIXIED_MACHINE_ID
After=default.target

[Service]
Type=oneshot
RemainAfterExit=yes
Environment=HOME=$unit_home
Environment=PIXI_HOME=$unit_pixi
Environment=PIXI_CACHE_DIR=$unit_cache
Environment=PIXI_NO_PATH_UPDATE=1
Environment=PATH=$unit_path
Environment=PIXIED_RUNTIME_STATE_FILE=$unit_state
Environment=PIXIED_SYSTEMD_UNIT_PATH=$unit_path_env
ExecStart=$unit_bin attach --create-background pixied-$PIXIED_MACHINE_ID
ExecStop=-$unit_bin delete-session pixied-$PIXIED_MACHINE_ID

[Install]
WantedBy=default.target
UNIT
}

# @description Write the generated unit only when an existing copy is owned by this state.
#
# @arg $1 string The target unit path.
# @arg $2 string The unit content.
# @exitcode 0 When the unit is written.
# @exitcode 1 When an existing unit cannot be verified.
pixied_systemd_write_unit() {
    local unit_path=$1 content=$2
    if [ -e "$unit_path" ] || [ -L "$unit_path" ]; then
        if ! pixied_state_has unit_path || ! pixied_state_has unit_hash ||
            [ "${PIXIED_STATE[unit_path]}" != "$unit_path" ] ||
            [ -z "${PIXIED_STATE[unit_hash]}" ] ||
            ! pixied_hash_matches "$unit_path" "${PIXIED_STATE[unit_hash]}"; then
            pixied_die "existing systemd unit is not managed by PixiEden: $unit_path"
        fi
        pixied_validate_owned_path "$unit_path" "${PIXIED_STATE[unit_hash]}"
    fi
    pixied_atomic_write "$unit_path" "$content"
}

# @description Apply the WSL systemd setting when it is missing.
# A successful change sets restart-required state and deliberately skips all
# systemd and loginctl calls in the current run.
#
# @exitcode 0 When systemd is already enabled or the configuration was changed.
# @exitcode 1 When the change cannot be applied.
pixied_systemd_prepare_wsl() {
    local config_path=${PIXIED_WSL_CONF_PATH:-/etc/wsl.conf}
    local content temporary
    PIXIED_SYSTEMD_RESTART_REQUIRED=0
    case "$config_path" in
    /*) ;;
    *) pixied_die "WSL configuration path must be absolute: $config_path" "$PIXIED_EXIT_USAGE" ;;
    esac

    pixied_systemd_wsl_systemd_enabled "$config_path" && return 0
    content=$(pixied_systemd_wsl_merge "$config_path")
    pixied_warn "WSL systemd is disabled; proposed $config_path contents:"
    printf '%s' "$content" >&2
    if [ "${PIXIED_USE_SUDO:-0}" -ne 1 ]; then
        pixied_warn "not changing $config_path without --use-sudo yes; using direct Zellij attach"
        return 1
    fi
    if ! pixied_systemd_confirm_sudo "write systemd=true to $config_path"; then
        return 1
    fi
    pixied_temp_dir
    temporary=$(pixied_run mktemp --tmpdir="$PIXIED_TEMP_DIR" pixied-wsl.XXXXXX)
    pixied_register_temp "$temporary"
    printf '%s' "$content" >"$temporary"
    pixied_run sudo install -m 0644 -- "$temporary" "$config_path"
    PIXIED_SYSTEMD_RESTART_REQUIRED=1
    pixied_warn "WSL systemd configuration changed; run wsl --shutdown, then rerun pixied install"
}

# @description Enable user lingering through one explicit sudo operation when needed.
#
# @exitcode 0 When lingering is enabled or already active.
# @exitcode 1 When the state is unknown or enabling it was declined or failed.
pixied_systemd_prepare_linger() {
    local user_name=${USER:-} linger_state
    export PIXIED_SYSTEMD_LINGER_ENABLED=0
    export PIXIED_SYSTEMD_CREATED_LINGER=0
    [ -n "$user_name" ] || user_name=$(pixied_run id -un)
    pixied_have_cmd loginctl || {
        pixied_warn "loginctl is unavailable; user lingering was not configured"
        return 1
    }
    linger_state=$(pixied_run loginctl show-user "$user_name" \
        --property=Linger --value 2>/dev/null || true)
    case "${linger_state,,}" in
    yes | 1 | true)
        export PIXIED_SYSTEMD_LINGER_ENABLED=1
        return 0
        ;;
    no | 0 | false) ;;
    *)
        if [ "${PIXIED_USE_SUDO:-0}" -ne 1 ]; then
            pixied_warn "could not determine user lingering state for $user_name"
            return 1
        fi
        pixied_warn "could not determine user lingering state for $user_name; attempting approved enable"
        ;;
    esac

    if [ "${PIXIED_USE_SUDO:-0}" -ne 1 ]; then
        pixied_warn "user lingering is disabled; using direct Zellij attach unless --use-sudo yes is approved"
        return 1
    fi
    if ! pixied_systemd_confirm_sudo "enable user lingering for $user_name"; then
        return 1
    fi
    if pixied_run sudo loginctl enable-linger "$user_name"; then
        export PIXIED_SYSTEMD_LINGER_ENABLED=1
        export PIXIED_SYSTEMD_CREATED_LINGER=1
        return 0
    fi
    pixied_warn "could not enable user lingering; using direct Zellij attach"
    return 1
}

# @description Reload and enable a generated unit in the user manager.
#
# @arg $1 string The unit name.
# @exitcode 0 When both operations succeed.
# @exitcode 1 When the user manager rejects an operation.
pixied_systemd_activate_unit() {
    local unit_name=$1
    pixied_run systemctl --user daemon-reload || return 1
    pixied_run systemctl --user enable "$unit_name" || return 1
}

# @description Prepare the optional persistent Zellij session support.
# Session-manager none returns before probing any session-related command.
#
# @set PIXIED_SYSTEMD_UNIT_PATH string The generated unit path.
# @set PIXIED_SYSTEMD_UNIT_HASH string The generated unit hash.
# @set PIXIED_SYSTEMD_AVAILABLE integer Whether the user manager is usable.
# @set PIXIED_SYSTEMD_LINGER_ENABLED integer Whether user lingering is active.
# @set PIXIED_SYSTEMD_CREATED_LINGER integer Whether this run enabled lingering.
# @exitcode 0 Always unless a validation or ownership check fails.
pixied_systemd_prepare() {
    local unit_name content
    export PIXIED_SYSTEMD_UNIT_PATH=""
    export PIXIED_SYSTEMD_UNIT_HASH=""
    export PIXIED_SYSTEMD_AVAILABLE=0
    export PIXIED_SYSTEMD_LINGER_ENABLED=0
    export PIXIED_SYSTEMD_CREATED_LINGER=0
    export PIXIED_SYSTEMD_RESTART_REQUIRED=0

    [ "$PIXIED_SESSION_MANAGER" = zellij ] || return 0
    [ -x "${PIXIED_ZELLIJ_PATH:-}" ] || pixied_die "dedicated Zellij is not executable"

    unit_name="pixied-$PIXIED_MACHINE_ID.service"
    PIXIED_SYSTEMD_UNIT_PATH=$(pixied_validate_canonical_path \
        "$PIXIED_SYSTEMD_USER_DIR/$unit_name")
    pixied_run mkdir -p -- "$PIXIED_SYSTEMD_USER_DIR"
    content=$(pixied_systemd_unit_content)
    pixied_systemd_write_unit "$PIXIED_SYSTEMD_UNIT_PATH" "$content"
    PIXIED_SYSTEMD_UNIT_HASH=$(pixied_sha256_file "$PIXIED_SYSTEMD_UNIT_PATH")
    export PIXIED_SYSTEMD_UNIT_HASH

    if pixied_systemd_is_wsl && ! pixied_systemd_wsl_systemd_enabled "${PIXIED_WSL_CONF_PATH:-/etc/wsl.conf}"; then
        pixied_systemd_prepare_wsl || return 0
        [ "$PIXIED_SYSTEMD_RESTART_REQUIRED" -eq 0 ] || return 0
    fi
    if ! pixied_systemd_user_manager_available; then
        pixied_warn "systemd user manager is unavailable; using direct Zellij attach"
        return 0
    fi
    if ! pixied_systemd_activate_unit "$unit_name"; then
        pixied_warn "could not activate $unit_name; using direct Zellij attach"
        return 0
    fi
    export PIXIED_SYSTEMD_AVAILABLE=1
    pixied_systemd_prepare_linger || true
}

# @description Start the persistent unit for a runtime session.
# The caller attaches directly when this function reports unavailable or failed.
#
# @arg $1 string The Zellij session name.
# @exitcode 0 When systemd started the unit.
# @exitcode 1 When direct attach should be used.
pixied_systemd_runtime_start() {
    local session_name=$1 unit_name expected
    [ "${PIXIED_SESSION_MANAGER:-none}" = zellij ] || return 1
    pixied_state_has unit_path || return 1
    pixied_state_has unit_hash || pixied_die "runtime systemd unit hash is missing"
    pixied_state_has systemd_user_dir || pixied_die "runtime systemd user directory is missing"
    unit_name="pixied-${PIXIED_MACHINE_ID}.service"
    expected=$(pixied_canonical_path "${PIXIED_STATE[systemd_user_dir]}/$unit_name")
    [ "${PIXIED_STATE[unit_path]}" = "$expected" ] ||
        pixied_die "runtime systemd unit path is outside the user unit directory"
    pixied_validate_owned_path "${PIXIED_STATE[unit_path]}" "${PIXIED_STATE[unit_hash]}"
    [ "${PIXIED_STATE[systemd_available]:-0}" -eq 1 ] || return 1
    pixied_systemd_user_manager_available || return 1
    pixied_run systemctl --user start "$unit_name" || return 1
    pixied_info "started persistent Zellij session: $session_name"
}
