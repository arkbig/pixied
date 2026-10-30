#!/usr/bin/env bash
# @brief Expose Pixi Global commands outside the runtime.
# shellcheck disable=SC2015

if [ -n "${PIXIED_EXPOSE_LOADED:-}" ]; then
    # shellcheck disable=SC2317
    return 0 2>/dev/null || exit 0
fi
PIXIED_EXPOSE_LOADED=1

# @description Print exposure command usage.
# @stdout The command help.
pixied_expose_usage() {
    cat <<'USAGE'
Usage: pixied expose COMMAND [--to ABSOLUTE_PATH] [OPTIONS]
       pixied unexpose ABSOLUTE_PATH

Expose a Pixi Global command as a symlink, or as a version-aware wrapper.
Existing files are never replaced.

Options:
    --to PATH              Absolute destination file path (required without --docker).
    --docker               Expose a Docker CLI plugin with automatic version handling.
    --version-arg ARG      Replace a single-argument version query.
    --version-format TEXT  Output containing {version} (with --version-arg).
    --environment NAME     Pixi Global environment (default: COMMAND).
    --package NAME         Installed dependency name (default: environment).
    --help                 Show this help.

Use --docker for a Docker CLI plugin such as docker-buildx. It automatically
reports the installed Pixi version to Docker and handles version commands such
as `docker buildx version`. Docker also asks plugins for information such as
their vendor, description, and version; the wrapper replaces only the version.
Do not combine --docker with --version-arg or --version-format.
Without --to, --docker uses $DOCKER_CONFIG/cli-plugins/COMMAND, or
$HOME/.docker/cli-plugins/COMMAND when DOCKER_CONFIG is unset or empty, and
creates the directory if needed. For an explicit --to, the directory must exist.

For other tools, use both --version-arg and --version-format to replace an
exact single-argument version query. Without either mode, expose creates a
symlink. Version-aware wrappers query the installed Pixi version at runtime.

Example:
    pixied expose docker-buildx --docker
USAGE
}

# @description Normalize an exposure destination without following the final component.
# @arg $1 string Absolute destination.
# @stdout The normalized destination path.
# @exitcode 1 When the destination is invalid.
pixied_expose_destination() {
    local path=$1 dir base
    [[ "$path" = /* && "$path" != *$'\n'* ]] ||
        pixied_die 'destination must be an absolute path without newlines' "$PIXIED_EXIT_USAGE"
    dir=${path%/*}
    base=${path##*/}
    [ -n "$dir" ] || dir=/
    [ -n "$base" ] && [ "$base" != . ] && [ "$base" != .. ] ||
        pixied_die 'invalid destination name' "$PIXIED_EXIT_USAGE"
    [ -d "$dir" ] || pixied_die "destination directory does not exist: $dir"
    dir=$(cd -P -- "$dir" && pwd -P)
    printf '%s/%s' "${dir%/}" "$base"
}

# @description Compute the digest of an exposed file or symlink.
# @arg $1 string The destination path.
# @arg $2 string The expected type: link or file.
# @stdout The SHA-256 digest.
# @exitcode 1 When the destination type is invalid.
pixied_expose_digest() {
    local path=$1 kind=$2 digest mode
    case "$kind" in
    link)
        [ -L "$path" ] || pixied_die "exposure is not a symlink: $path"
        digest=$(readlink -- "$path" | sha256sum)
        ;;
    file)
        [ -f "$path" ] && [ ! -L "$path" ] && [ -O "$path" ] ||
            pixied_die "exposure is not an owned regular file: $path"
        mode=$(stat -c '%a' -- "$path")
        digest=$({
            printf '%s\n' "$mode"
            sha256sum -- "$path" | cut -d ' ' -f 1
        } | sha256sum)
        ;;
    *) pixied_die 'invalid exposure record type' ;;
    esac
    printf '%s' "${digest%% *}"
}

# @description Write a self-contained version-aware wrapper.
# @arg $1 string Output file.
# @arg $2 string Pixi Global command path.
# @arg $3 string Wrapper mode.
# @arg $4 string Pixi environment.
# @arg $5 string Pixi package.
# @arg $6 string Version query argument.
# @arg $7 string Version output format.
# @exitcode 0 When the wrapper is written.
pixied_expose_write_wrapper() {
    local output=$1 target=$2 mode=$3 environment=$4 package=$5 version_arg=$6 format=$7
    {
        printf '#!/usr/bin/env bash\n'
        printf 'target=%q\nmode=%q\nenvironment=%q\npackage=%q\n' "$target" "$mode" "$environment" "$package"
        printf 'version_arg=%q\nformat=%q\n' "$version_arg" "$format"
        printf 'pixi=%q\npixi_home=%q\nlocal_home=%q\n' \
            "$PIXIED_PIXI_BINARY_PATH" "$PIXIED_PIXI_HOME" "$PIXIED_LOCAL_HOME"
        printf '%s\n' '# @description Validate and query Pixi JSON or update Docker plugin metadata.' \
            '# @arg $1 string The JSON operation.' \
            '# @stdout The result of the operation.' \
            '# @stderr An error when the input or metadata is invalid.' \
            '# @exitcode 0 When the operation succeeds.' \
            '# @exitcode 1 When the operation fails.'
        declare -f pixied_expose_json
        cat <<'WRAPPER'
set -euo pipefail

# @description Read the installed package version from the Pixi Global environment.
# @stdout The installed version.
# @exitcode 1 When Pixi or the package metadata is unavailable.
installed_version() {
    local data version
    data=$(env HOME="$local_home" PIXI_HOME="$pixi_home" PIXI_CACHE_DIR="$pixi_home/cache" \
        PIXI_NO_PATH_UPDATE=1 "$pixi" global list --json) || {
        echo 'pixied exposure: failed to query Pixi Global metadata' >&2
        return 1
    }
    version=$(PIXIED_JSON_ENV="$environment" PIXIED_JSON_PACKAGE="$package" \
        pixied_expose_json version <<<"$data") || return
    printf '%s' "$version"
}

if [ "$mode" = docker ] && [ "$#" -eq 1 ] && [ "$1" = docker-cli-plugin-metadata ]; then
    if metadata=$("$target" "$@"); then
        :
    else
        status=$?
        echo 'pixied exposure: failed to query Docker plugin metadata' >&2
        exit "$status"
    fi
    version=$(installed_version)
    PIXIED_JSON_VERSION="v${version#v}" pixied_expose_json metadata <<<"$metadata"
    exit
fi

if [ "$mode" = docker ]; then
    plugin=${target##*/docker-}
    args=("$@")
    version_query=0
    version_format=pretty
    short=0
    for ((i = $# - 2; i >= 0; i--)); do
        if [ "${args[i]}" = "$plugin" ] &&
            { [ "${args[i+1]}" = version ] || [ "${args[i+1]}" = --version ]; }; then
            version_query=1
            for ((j = i + 2; j < $#; j++)); do
                case "${args[j]}" in
                --short) [ "$plugin" = compose ] && short=1 || version_query=0 ;;
                --format=*) [ "$plugin" = compose ] || version_query=0; version_format=${args[j]#*=} ;;
                --format | -f)
                    [ "$plugin" = compose ] || version_query=0
                    ((j += 1))
                    if [ "$j" -lt "$#" ]; then version_format=${args[j]}; else version_query=0; fi
                    ;;
                *) version_query=0 ;;
                esac
            done
            break
        fi
    done
    if [ "$#" -eq 1 ] && { [ "$1" = --version ] || [ "$1" = version ]; }; then
        version_query=1
    fi
    case "$version_format" in pretty | json) ;; *) version_query=0 ;; esac
    if [ "$version_query" -eq 1 ]; then
        version=$(installed_version)
        case "$plugin" in
        buildx) printf 'github.com/docker/buildx v%s\n' "${version#v}" ;;
        compose)
            if [ "$short" -eq 1 ]; then
                printf '%s\n' "${version#v}"
            elif [ "$version_format" = json ]; then
                encoded=$(PIXIED_JSON_VERSION="v${version#v}" pixied_expose_json quote)
                printf '{"version":%s}\n' "$encoded"
            else
                printf 'Docker Compose version v%s\n' "${version#v}"
            fi
            ;;
        *) printf 'docker-%s version v%s\n' "$plugin" "${version#v}" ;;
        esac
        exit
    fi
elif [ "$#" -eq 1 ] && [ "$1" = "$version_arg" ]; then
    version=$(installed_version)
    printf '%s\n' "${format//\{version\}/$version}"
    exit
fi
exec "$target" "$@"
WRAPPER
    } >"$output"
}

# @description Create a managed exposure of a dedicated Pixi Global command.
# @arg $@ string Command name and exposure options.
# @exitcode 0 When the exposure is created.
# @exitcode 1 When validation or creation fails.
# @exitcode 2 When usage is invalid.
pixied_expose() {
    local command="" destination="" mode=link environment="" package="" version_arg="" format=""
    local target dir base record stage temporary marker digest metadata path_digest config_dir
    local to_supplied=0 default_dir=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
        --help | -h)
            [ "$#" -eq 1 ] && [ -z "$command$destination" ] ||
                pixied_die '--help must be used alone' "$PIXIED_EXIT_USAGE"
            pixied_expose_usage
            return
            ;;
        --to | --environment | --package | --version-arg | --version-format)
            [ "$#" -ge 2 ] || pixied_die "missing value for $1" "$PIXIED_EXIT_USAGE"
            case "$1" in
            --to)
                destination=$2
                to_supplied=1
                ;;
            --environment) environment=$2 ;;
            --package) package=$2 ;;
            --version-arg) version_arg=$2 ;;
            --version-format) format=$2 ;;
            esac
            shift
            ;;
        --docker) mode=docker ;;
        --*) pixied_die "unknown expose option: $1" "$PIXIED_EXIT_USAGE" ;;
        *)
            [ -z "$command" ] || pixied_die 'only one command may be exposed' "$PIXIED_EXIT_USAGE"
            command=$1
            ;;
        esac
        shift
    done
    [[ "$command" =~ ^[a-zA-Z0-9][a-zA-Z0-9._+-]*$ ]] ||
        pixied_die 'invalid or missing Pixi Global command name' "$PIXIED_EXIT_USAGE"
    if [ -n "$version_arg$format" ]; then
        [ "$mode" = link ] && [ -n "$version_arg" ] && [[ "$format" = *'{version}'* ]] ||
            pixied_die '--version-arg and --version-format containing {version} must be used together, without --docker' "$PIXIED_EXIT_USAGE"
        mode=version
    fi
    if [ "$to_supplied" -eq 0 ]; then
        [ "$mode" = docker ] || pixied_die '--to is required without --docker' "$PIXIED_EXIT_USAGE"
        [[ "$command" = docker-* ]] ||
            pixied_die 'Docker command must have a docker-<name> name' "$PIXIED_EXIT_USAGE"
        if [ -n "${DOCKER_CONFIG:-}" ]; then
            config_dir=$DOCKER_CONFIG
            case "$config_dir" in
            /*) ;;
            *) config_dir="$(pwd -P)/$config_dir" ;;
            esac
        else
            [[ "${HOME:-}" = /* ]] || pixied_die 'HOME must be an absolute path for the Docker default'
            config_dir="$HOME/.docker"
        fi
        [[ "$config_dir" != *$'\n'* ]] ||
            pixied_die 'Docker config path must not contain newlines' "$PIXIED_EXIT_USAGE"
        destination="$config_dir/cli-plugins/$command"
        default_dir=1
    fi
    [ -n "$destination" ] || pixied_die '--to must not be empty' "$PIXIED_EXIT_USAGE"
    [[ "$destination" = /* && "$destination" != *$'\n'* ]] ||
        pixied_die 'destination must be an absolute path without newlines' "$PIXIED_EXIT_USAGE"
    base=${destination##*/}
    if [ "$mode" = docker ]; then
        [[ "$command" = docker-* && "$base" = "$command" ]] ||
            pixied_die 'Docker command and destination must have the same docker-<name> name' "$PIXIED_EXIT_USAGE"
    fi
    environment=${environment:-$command}
    package=${package:-$environment}
    pixied_runtime_load_state
    target="$PIXIED_PIXI_HOME/bin/$command"
    [ -f "$target" ] && [ -x "$target" ] ||
        pixied_die "Pixi Global command is not executable: $target"
    if [ "$mode" != link ]; then
        metadata=$(pixied_pixi_run global list --json)
        PIXIED_JSON_ENV="$environment" PIXIED_JSON_PACKAGE="$package" PIXIED_JSON_COMMAND="$command" \
            pixied_expose_json validate <<<"$metadata" ||
            pixied_die "command and package not found together in Pixi Global environment: $environment"
    fi
    if [ "$default_dir" -eq 1 ]; then
        pixied_run mkdir -p -- "${destination%/*}"
    fi
    destination=$(pixied_expose_destination "$destination")
    dir=${destination%/*}
    base=${destination##*/}
    record="$dir/.$base.pixied-exposure"
    [ ! -e "$destination" ] && [ ! -L "$destination" ] ||
        pixied_die "destination already exists: $destination"
    [ ! -e "$record" ] && [ ! -L "$record" ] ||
        pixied_die "exposure record already exists: $record"
    stage=$(mktemp -d "$dir/.pixied-expose.XXXXXX")
    pixied_register_temp "$stage"
    temporary="$stage/entry"
    if [ "$mode" = link ]; then
        ln -s -- "$target" "$temporary"
        digest=$(pixied_expose_digest "$temporary" link)
        mode="link"
    else
        pixied_expose_write_wrapper "$temporary" "$target" "$mode" "$environment" "$package" "$version_arg" "$format"
        chmod 0755 "$temporary"
        digest=$(pixied_expose_digest "$temporary" file)
        mode="file"
    fi
    marker="$stage/record"
    path_digest=$(printf '%s' "$destination" | sha256sum)
    printf 'pixied-exposure-v1\n%s\n%s\n%s\n' "$mode" "$digest" "${path_digest%% *}" >"$marker"
    chmod 0600 "$marker"
    ln -P -- "$temporary" "$destination" || pixied_die "could not create exposure: $destination"
    if ! ln -- "$marker" "$record"; then
        rm -- "$destination"
        pixied_die "could not create exposure record: $record"
    fi
    pixied_success "Exposed $command at $destination"
}

# @description Remove an unchanged exposure and its ownership record.
# @arg $@ string Absolute destination or --help.
# @exitcode 0 When the exposure is removed.
# @exitcode 1 When the record or exposure cannot be verified.
# @exitcode 2 When usage is invalid.
pixied_unexpose() {
    local destination dir base record digest path_digest
    local -a lines=()
    [ "$#" -eq 1 ] || pixied_die 'usage: pixied unexpose ABSOLUTE_PATH' "$PIXIED_EXIT_USAGE"
    if [ "$1" = --help ] || [ "$1" = -h ]; then
        pixied_expose_usage
        return
    fi
    destination=$(pixied_expose_destination "$1")
    dir=${destination%/*}
    base=${destination##*/}
    record="$dir/.$base.pixied-exposure"
    [ -f "$record" ] && [ ! -L "$record" ] && [ -O "$record" ] ||
        pixied_die "owned exposure record not found: $record"
    mapfile -t lines <"$record"
    [ "${#lines[@]}" -eq 4 ] && [ "${lines[0]}" = pixied-exposure-v1 ] &&
        [[ "${lines[2]}" =~ ^[0-9a-f]{64}$ ]] &&
        [[ "${lines[3]}" =~ ^[0-9a-f]{64}$ ]] ||
        pixied_die "invalid exposure record: $record"
    path_digest=$(printf '%s' "$destination" | sha256sum)
    [ "${path_digest%% *}" = "${lines[3]}" ] ||
        pixied_die "exposure record belongs to a different path: $record"
    digest=$(pixied_expose_digest "$destination" "${lines[1]}")
    [ "$digest" = "${lines[2]}" ] || pixied_die "exposure has changed; refusing to remove: $destination"
    rm -- "$destination" "$record"
    pixied_success "Removed exposure $destination"
}
