#!/usr/bin/env bash
# @brief Library responsible for PixiEden installation option handling.
# @description
# Parses CLI options, validates environment overrides, and applies saved state
# values only when neither the CLI nor the environment supplied a value.

if [ -n "${PIXIED_OPTIONS_LOADED:-}" ]; then
    # shellcheck disable=SC2317 # Sourced by both the source and deployed CLI.
    return 0 2>/dev/null || exit 0
fi
PIXIED_OPTIONS_LOADED=1

declare -gA PIXIED_OPTION_CLI_SET=()
declare -gA PIXIED_OPTION_ENV_SET=()

# @description Record whether an option was supplied by the environment.
# @exitcode 0 Always.
pixied_options_capture_environment() {
    local option variable
    for option in home_mode local_home session_manager use_sudo machine_id pixi_home; do
        variable=PIXIED_${option^^}
        if [ -n "${!variable:-}" ]; then
            PIXIED_OPTION_ENV_SET["$option"]=1
        else
            PIXIED_OPTION_ENV_SET["$option"]=0
        fi
    done
}

# @description Validate and normalize option values supplied through the environment.
# @exitcode 0 When all environment values are valid.
# @exitcode 2 When an environment value is invalid.
pixied_options_validate_environment() {
    local value
    if [ "${PIXIED_OPTION_ENV_SET[home_mode]:-0}" -eq 1 ] &&
        [ "${PIXIED_OPTION_CLI_SET[home_mode]:-0}" -eq 0 ]; then
        case "$PIXIED_HOME_MODE" in
        local | nfs) ;;
        *) pixied_die "invalid home mode: $PIXIED_HOME_MODE" "$PIXIED_EXIT_USAGE" ;;
        esac
    fi
    if [ "${PIXIED_OPTION_ENV_SET[session_manager]:-0}" -eq 1 ] &&
        [ "${PIXIED_OPTION_CLI_SET[session_manager]:-0}" -eq 0 ]; then
        case "$PIXIED_SESSION_MANAGER" in
        none | zellij) ;;
        *) pixied_die "invalid session manager: $PIXIED_SESSION_MANAGER" "$PIXIED_EXIT_USAGE" ;;
        esac
    fi
    if [ "${PIXIED_OPTION_ENV_SET[local_home]:-0}" -eq 1 ] &&
        [ "${PIXIED_OPTION_CLI_SET[local_home]:-0}" -eq 0 ]; then
        pixied_require_absolute_path "$PIXIED_LOCAL_HOME"
    fi
    if [ "${PIXIED_OPTION_ENV_SET[pixi_home]:-0}" -eq 1 ] &&
        [ "${PIXIED_OPTION_CLI_SET[pixi_home]:-0}" -eq 0 ]; then
        pixied_require_absolute_path "$PIXIED_PIXI_HOME"
    fi
    if [ "${PIXIED_OPTION_ENV_SET[machine_id]:-0}" -eq 1 ] &&
        [ "${PIXIED_OPTION_CLI_SET[machine_id]:-0}" -eq 0 ]; then
        pixied_machine_id_is_safe "$PIXIED_MACHINE_ID" ||
            pixied_die "unsafe machine id: $PIXIED_MACHINE_ID" "$PIXIED_EXIT_USAGE"
    fi
    if [ "${PIXIED_OPTION_ENV_SET[use_sudo]:-0}" -eq 1 ] &&
        [ "${PIXIED_OPTION_CLI_SET[use_sudo]:-0}" -eq 0 ]; then
        value=${PIXIED_USE_SUDO,,}
        case "$value" in
        1 | y | yes | true) export PIXIED_USE_SUDO=1 ;;
        0 | n | no | false) export PIXIED_USE_SUDO=0 ;;
        *) pixied_die "invalid use-sudo value: $PIXIED_USE_SUDO (expected yes or no)" "$PIXIED_EXIT_USAGE" ;;
        esac
    fi
}

# @description Validate and set a normalized boolean option value.
# @arg $1 string The option name.
# @arg $2 string The supplied value.
# @exitcode 0 When the value is valid.
# @exitcode 2 When the value is invalid.
pixied_options_set_boolean() {
    local option=$1 value=${2,,}
    case "$value" in
    1 | y | yes | true) value=1 ;;
    0 | n | no | false) value=0 ;;
    *) pixied_die "invalid $option value: $2 (expected yes or no)" "$PIXIED_EXIT_USAGE" ;;
    esac
    case "$option" in
    use_sudo) export PIXIED_USE_SUDO=$value ;;
    *) pixied_die "unknown boolean option: $option" "$PIXIED_EXIT_USAGE" ;;
    esac
    PIXIED_OPTION_CLI_SET["$option"]=1
}

# @description Parse and validate install options.
# Supports the option values used by install-local.sh and pixied install.
#
# @arg $@ string The install options.
# @set PIXIED_HOME_MODE string The requested home mode.
# @set PIXIED_LOCAL_HOME string The requested local home.
# @set PIXIED_SESSION_MANAGER string The requested session manager.
# @set PIXIED_USE_SUDO integer Whether sudo may be used.
# @set PIXIED_MACHINE_ID string The requested machine ID.
# @set PIXIED_INSTALL_ASSUME_YES integer Whether prompts are skipped.
# @exitcode 0 When parsing succeeds.
# @exitcode 2 When an option is invalid.
pixied_options_parse() {
    local option value
    pixied_options_capture_environment
    PIXIED_INSTALL_ASSUME_YES=${PIXIED_INSTALL_ASSUME_YES:-0}
    while [ "$#" -gt 0 ]; do
        option=$1
        case "$option" in
        --help)
            [ "$#" -eq 1 ] || pixied_die "--help must be used alone" "$PIXIED_EXIT_USAGE"
            export PIXIED_OPTIONS_HELP=1
            ;;
        --yes)
            PIXIED_INSTALL_ASSUME_YES=1
            ;;
        --home-mode)
            [ "$#" -ge 2 ] || pixied_die "missing value for --home-mode" "$PIXIED_EXIT_USAGE"
            value=$2
            case "$value" in
            local | nfs) export PIXIED_HOME_MODE=$value ;;
            *) pixied_die "invalid home mode: $value" "$PIXIED_EXIT_USAGE" ;;
            esac
            PIXIED_OPTION_CLI_SET[home_mode]=1
            shift
            ;;
        --home-mode=*)
            pixied_options_parse --home-mode "${option#*=}"
            ;;
        --local-home)
            [ "$#" -ge 2 ] || pixied_die "missing value for --local-home" "$PIXIED_EXIT_USAGE"
            export PIXIED_LOCAL_HOME=$2
            PIXIED_OPTION_CLI_SET[local_home]=1
            shift
            ;;
        --local-home=*)
            pixied_options_parse --local-home "${option#*=}"
            ;;
        --session-manager)
            [ "$#" -ge 2 ] || pixied_die "missing value for --session-manager" "$PIXIED_EXIT_USAGE"
            value=$2
            case "$value" in
            none | zellij) export PIXIED_SESSION_MANAGER=$value ;;
            *) pixied_die "invalid session manager: $value" "$PIXIED_EXIT_USAGE" ;;
            esac
            PIXIED_OPTION_CLI_SET[session_manager]=1
            shift
            ;;
        --session-manager=*)
            pixied_options_parse --session-manager "${option#*=}"
            ;;
        --use-sudo)
            [ "$#" -ge 2 ] || pixied_die "missing value for --use-sudo" "$PIXIED_EXIT_USAGE"
            pixied_options_set_boolean use_sudo "$2"
            shift
            ;;
        --use-sudo=*)
            pixied_options_parse --use-sudo "${option#*=}"
            ;;
        --machine-id)
            [ "$#" -ge 2 ] || pixied_die "missing value for --machine-id" "$PIXIED_EXIT_USAGE"
            pixied_machine_id_is_safe "$2" ||
                pixied_die "unsafe machine id: $2" "$PIXIED_EXIT_USAGE"
            export PIXIED_MACHINE_ID=$2
            PIXIED_OPTION_CLI_SET[machine_id]=1
            shift
            ;;
        --machine-id=*)
            pixied_options_parse --machine-id "${option#*=}"
            ;;
        --*) pixied_die "unknown install option: $option" "$PIXIED_EXIT_USAGE" ;;
        *) pixied_die "unexpected install argument: $option" "$PIXIED_EXIT_USAGE" ;;
        esac
        shift
    done

    pixied_options_validate_environment

    case "${PIXIED_INSTALL_ASSUME_YES}" in
    0 | 1) ;;
    *) pixied_die "invalid --yes setting" "$PIXIED_EXIT_USAGE" ;;
    esac
    export PIXIED_INSTALL_ASSUME_YES
}

# @description Return whether an option was explicitly supplied by CLI or environment.
# @arg $1 string The option name.
# @exitcode 0 When the option has an explicit value.
# @exitcode 1 When it does not.
pixied_options_is_explicit() {
    [ "${PIXIED_OPTION_CLI_SET[$1]:-0}" -eq 1 ] ||
        [ "${PIXIED_OPTION_ENV_SET[$1]:-0}" -eq 1 ]
}

# @description Reject reinstall attempts that change the session manager.
# The existing installation must be uninstalled before changing this setting.
#
# @exitcode 0 When the requested session manager is compatible with state.
# @exitcode 1 When the session manager change is not allowed.
pixied_options_validate_state_transition() {
    [ "${PIXIED_STATE[state_version]+present}" = present ] || return 0
    if pixied_options_is_explicit session_manager &&
        [ "${PIXIED_STATE[session_manager]}" != "$PIXIED_SESSION_MANAGER" ]; then
        pixied_die "cannot change session manager during reinstall; run uninstall first"
    fi
}

# @description Apply option values from a validated existing state.
# Explicit CLI and environment values remain higher priority than state values.
#
# @exitcode 0 When state values are applied or no state is available.
# @exitcode 1 When a required state value is missing.
pixied_options_apply_state() {
    [ "${PIXIED_STATE[state_version]+present}" = present ] || return 0
    if ! pixied_options_is_explicit home_mode; then
        export PIXIED_HOME_MODE=${PIXIED_STATE[home_mode]}
    fi
    if ! pixied_options_is_explicit local_home; then
        export PIXIED_LOCAL_HOME=${PIXIED_STATE[local_home]}
    fi
    if ! pixied_options_is_explicit session_manager; then
        export PIXIED_SESSION_MANAGER=${PIXIED_STATE[session_manager]}
    fi
    if ! pixied_options_is_explicit use_sudo && [ -n "${PIXIED_STATE[use_sudo]:-}" ]; then
        export PIXIED_USE_SUDO=${PIXIED_STATE[use_sudo]}
    fi
    if ! pixied_options_is_explicit machine_id; then
        export PIXIED_MACHINE_ID=${PIXIED_STATE[machine_id]}
    fi
    if ! pixied_options_is_explicit pixi_home && [ -n "${PIXIED_STATE[pixi_home]:-}" ]; then
        export PIXIED_PIXI_HOME=${PIXIED_STATE[pixi_home]}
    fi
    export PIXIED_DATA_DIR=${PIXIED_STATE[data_dir]}
    export PIXIED_CONFIG_DIR=${PIXIED_STATE[config_dir]}
    export PIXIED_STATE_DIR=${PIXIED_STATE[state_dir]}
    export PIXIED_SYSTEMD_USER_DIR=${PIXIED_STATE[systemd_user_dir]}
    export PIXIED_COMMAND_BIN=${PIXIED_STATE[command_bin]}
}

# @description Apply fixed defaults for options not supplied by any source.
# @exitcode 0 Always.
pixied_options_apply_defaults() {
    if ! pixied_options_is_explicit session_manager; then
        export PIXIED_SESSION_MANAGER=${PIXIED_SESSION_MANAGER:-zellij}
    fi
    if ! pixied_options_is_explicit use_sudo; then
        export PIXIED_USE_SUDO=${PIXIED_USE_SUDO:-0}
    fi
}
