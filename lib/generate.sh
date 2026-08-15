#!/usr/bin/env bash
# @brief Project integration file generation for PixiEden.
# @description
# Finds and validates a Pixi project definition, then writes direnv,
# DevContainer, or Docker integration files without touching PixiEden state.

if [ -n "${PIXIED_GENERATE_LOADED:-}" ]; then
    # shellcheck disable=SC2317 # Sourced by both the source and deployed CLI.
    return 0 2>/dev/null || exit 0
fi
PIXIED_GENERATE_LOADED=1

# @description Find the nearest directory containing a Pixi project definition.
# A pixi.toml takes precedence when both supported definition files are present.
#
# @stdout The canonical project root.
# @exitcode 0 When a project root is found.
# @exitcode 1 When no project root is found.
pixied_generate_find_root() {
    local directory=${1:-} parent
    if [ -z "$directory" ]; then
        directory=$(pixied_run pwd -P)
    fi
    directory=$(pixied_canonical_path "$directory")
    [ -d "$directory" ] || pixied_die "project directory is not a directory: $directory"

    while :; do
        if [ -e "$directory/pixi.toml" ] || [ -L "$directory/pixi.toml" ] ||
            [ -e "$directory/pyproject.toml" ] || [ -L "$directory/pyproject.toml" ]; then
            printf '%s' "$directory"
            return 0
        fi
        [ "$directory" != / ] || break
        parent=${directory%/*}
        [ -n "$parent" ] || parent=/
        directory=$parent
    done

    pixied_die "could not find a Pixi project root (pixi.toml or pyproject.toml) from: ${1:-$(pixied_run pwd -P)}; run 'pixi init' to create a project first"
}

# @description Return and validate the Pixi definition selected for a project.
# Rejects symlinks and non-regular files so generation cannot follow a project
# definition outside the detected project root.
#
# @arg $1 string The project root.
# @stdout The absolute project definition path.
# @exitcode 0 When a supported definition is valid as a file.
# @exitcode 1 When the definition is absent or invalid.
pixied_generate_definition() {
    local root=$1 candidate name
    for name in pixi.toml pyproject.toml; do
        candidate="$root/$name"
        if [ -e "$candidate" ] || [ -L "$candidate" ]; then
            [ ! -L "$candidate" ] ||
                pixied_die "Pixi project definition must not be a symlink: $candidate"
            [ -f "$candidate" ] ||
                pixied_die "Pixi project definition is not a regular file: $candidate"
            [ -r "$candidate" ] ||
                pixied_die "Pixi project definition is not readable: $candidate"
            printf '%s' "$candidate"
            return 0
        fi
    done
    pixied_die "Pixi project definition (pixi.toml or pyproject.toml) is missing from: $root; run 'pixi init' to create one first"
}

# @description Validate the minimum TOML section that identifies a Pixi project.
# This checks the supported manifest marker only; TOML parsing and dependency
# resolution are left to Pixi when the generated integration file is used.
#
# @arg $1 string The project definition path.
# @exitcode 0 When the definition has a supported Pixi section.
# @exitcode 1 When the definition does not identify a Pixi project.
pixied_generate_validate_definition() {
    local definition=$1 name=${1##*/} pattern
    [ -s "$definition" ] ||
        pixied_die "Pixi project definition is empty: $definition"
    case "$name" in
    pixi.toml)
        pattern='^[[:space:]]*\[(workspace|project)\]([[:space:]]*(#.*)?)?$'
        if ! pixied_run grep -Eq -- "$pattern" "$definition"; then
            pixied_die "Pixi project definition has no supported Pixi section: $definition"
        fi
        ;;
    pyproject.toml)
        pattern='^[[:space:]]*\[tool\.pixi\.workspace\]([[:space:]]*(#.*)?)?$'
        if ! pixied_run grep -Eq -- "$pattern" "$definition"; then
            pixied_die "Pixi project definition has no supported Pixi section: $definition"
        fi
        ;;
    *)
        pixied_die "unsupported Pixi project definition: $definition"
        ;;
    esac
}

# @description Validate an optional project lock file and report whether it exists.
# @arg $1 string The project root.
# @stdout 1 when pixi.lock exists, otherwise 0.
# @exitcode 0 Always when the optional file is valid or absent.
pixied_generate_lock_present() {
    local lock_file="$1/pixi.lock"
    if [ -e "$lock_file" ] || [ -L "$lock_file" ]; then
        [ ! -L "$lock_file" ] ||
            pixied_die "Pixi lock file must not be a symlink: $lock_file"
        [ -f "$lock_file" ] ||
            pixied_die "Pixi lock file is not a regular file: $lock_file"
        printf '1'
    else
        printf '0'
    fi
}

# @description Return the absolute PixiEden CLI path to embed during generation.
# The generated file must not resolve a different pixied executable from PATH
# when it is evaluated later.
#
# @stdout A shell-quoted absolute executable path.
# @exitcode 0 When a usable CLI path is available.
# @exitcode 1 When the current CLI path is unavailable.
pixied_generate_cli_command() {
    local cli_path
    cli_path=$(pixied_validate_canonical_path "$PIXIED_BIN_DIR/pixied")
    [ -x "$cli_path" ] || return 1
    printf '%q' "$cli_path"
}

# @description Return the direnv integration file content.
# The command uses a side-effect-free PixiEden runtime path so evaluating the
# hook does not start NFS synchronization or a session. The block is wrapped in
# sentinel markers so pixied generate direnv can update an existing .envrc
# without leaving stale or duplicate blocks.
#
# @arg $1 string The project definition filename.
# @arg $2 string The PixiEden CLI command to use.
# @stdout The generated .envrc content.
# @exitcode 0 Always.
pixied_generate_direnv_content() {
    local definition_name=$1 pixied_cli_command=${2:-}
    cat <<'ENVRC'
# >>> pixied direnv integration (generated by pixied generate) >>>
ENVRC
    printf 'watch_file %s\n' "$definition_name"
    cat <<'ENVRC'
watch_file pixi.lock
ENVRC
    if [ -n "$pixied_cli_command" ]; then
        printf 'if [ -x %s ]; then\n' "$pixied_cli_command"
        printf '    eval "$(%s generate direnv --print-envrc)"\n' "$pixied_cli_command"
        printf 'fi\n'
    else
        printf '%s\n' '# pixied was not found during generation; skipping activation.'
    fi
    cat <<'ENVRC'
# <<< pixied direnv integration <<<
ENVRC
}

# @description Print a .envrc file with any previous pixied block removed.
# Lines between the pixied sentinel markers are skipped while everything else is
# printed unchanged. This keeps repeated generation idempotent.
#
# @arg $1 string The .envrc path to read.
# @stdout The .envrc content with any pixied block removed.
# @exitcode 0 Always.
pixied_generate_direnv_strip() {
    local path=$1
    pixied_run awk '
        /^# >>> pixied direnv integration/ { skip=1; next }
        /^# <<< pixied direnv integration/ { skip=0; next }
        skip { next }
        { print }
    ' "$path"
}

# @description Atomically write content to a path, replacing any existing file.
# The temp file is created beside the target so the final rename stays on the
# same filesystem. Used to update an existing generated file in place.
#
# @arg $1 string The target path.
# @arg $2 string The file content.
# @exitcode 0 When the file is written.
# @exitcode 1 When writing fails.
pixied_generate_write_inplace() {
    local path=$1 content=$2 directory base_name temporary
    directory=${path%/*}
    base_name=${path##*/}
    pixied_run mkdir -p -- "$directory"
    temporary=$(pixied_run mktemp --tmpdir="$directory" ".${base_name}.pixied.XXXXXX")
    pixied_register_temp "$temporary"
    printf '%s\n' "$content" >"$temporary"
    pixied_run chmod 0644 -- "$temporary"
    pixied_run mv -f -- "$temporary" "$path"
}

# @description Write or update the pixied direnv block in a .envrc file.
# When no .envrc exists, the block is written as a new file. When .envrc exists,
# any previous pixied block is stripped first, then a single new block is
# appended at the end so the generated activation does not disturb user content.
#
# @arg $1 string The .envrc path.
# @arg $2 string The generated direnv block (with sentinel markers).
# @exitcode 0 When the file is written.
# @exitcode 1 When writing or validation fails.
pixied_generate_direnv_write() {
    local path=$1 content=$2 existing
    if [ -e "$path" ] || [ -L "$path" ]; then
        [ ! -L "$path" ] || pixied_die "refusing to update a symlinked .envrc: $path"
        [ -f "$path" ] || pixied_die "refusing to update a non-regular .envrc: $path"
        existing=$(pixied_generate_direnv_strip "$path")
        case "$existing" in
        *$'\n') ;;
        *) existing=${existing}$'\n' ;;
        esac
        pixied_generate_write_inplace "$path" "${existing}${content}"
    else
        pixied_generate_write_file "$path" "$content"
    fi
}

# @description Print the project activation shell code for direnv.
# This is the implementation behind `generate direnv --print-envrc`.
#
# @stdout Shell code that activates the nearest Pixi project.
# @exitcode 0 When the project hook is printed.
# @exitcode 1 When PixiEden state or the project definition is invalid.
pixied_generate_direnv_print_envrc() {
    local root definition
    root=$(pixied_generate_find_root "$(pixied_run pwd -P)")
    definition=$(pixied_generate_definition "$root")
    pixied_generate_validate_definition "$definition"
    pixied_generate_project_shell_hook --manifest-path "$definition"
}

# @description Print a project shell hook from the dedicated Pixi runtime.
# Unlike pixied shell or pixied run, this does not begin or finish synchronization and does
# not attach to a session. It is used while direnv evaluates a generated file.
#
# @arg $@ string Arguments passed to Pixi shell-hook.
# @stdout The Pixi shell activation script.
# @exitcode The dedicated Pixi command exit status.
pixied_generate_project_shell_hook() {
    pixied_runtime_load_state
    pixied_runtime_export_environment
    printf 'export PIXI_HOME=%q\n' "$PIXI_HOME"
    printf 'export PIXI_CACHE_DIR=%q\n' "$PIXI_CACHE_DIR"
    printf 'export PIXI_NO_PATH_UPDATE=%q\n' "$PIXI_NO_PATH_UPDATE"
    printf 'export PIXIED_RUNTIME_STATE_FILE=%q\n' "$PIXIED_RUNTIME_STATE_FILE"
    pixied_pixi_run shell-hook "$@"
}

# @description Return the Dockerfile content for a Pixi project.
# @arg $1 integer Whether pixi.lock is present.
# @arg $2 string The pinned Pixi version.
# @arg $3 integer Whether to install during the image build.
# @stdout The generated Dockerfile content.
# @exitcode 0 Always.
pixied_generate_dockerfile_content() {
    local lock_present=$1 pixi_version=$2 install_during_build=${3:-1}
    cat <<'DOCKERFILE'
# syntax=docker/dockerfile:1.19
# Generated by pixied generate. Do not edit.
DOCKERFILE
    printf 'ARG PIXI_VERSION=%s\n' "$pixi_version"
    cat <<'DOCKERFILE'
FROM ghcr.io/prefix-dev/pixi:${PIXI_VERSION}

WORKDIR /workspace

COPY --exclude=.pixi . .
DOCKERFILE
    if [ "$install_during_build" -eq 1 ]; then
        if [ "$lock_present" -eq 1 ]; then
            printf 'RUN rm -rf -- .pixi && pixi install --locked\n'
        else
            printf 'RUN rm -rf -- .pixi && pixi install\n'
        fi
    else
        printf '# The Dev Container mounts .pixi as a volume; postCreateCommand installs into that volume.\n'
    fi
    cat <<'DOCKERFILE'

ENV PATH="/workspace/.pixi/envs/default/bin:${PATH}"
DOCKERFILE
}

# @description Return the DevContainer definition content.
# @arg $1 integer Whether pixi.lock is present.
# @stdout The generated devcontainer.json content.
# @exitcode 0 Always.
pixied_generate_devcontainer_content() {
    local lock_present=$1 install_command
    if [ "$lock_present" -eq 1 ]; then
        install_command='pixi install --locked'
    else
        install_command='pixi install'
    fi
    cat <<'DEVCONTAINER'
{
    "name": "Pixi project",
    "build": {
        "dockerfile": "Dockerfile",
        "context": ".."
    },
    "workspaceFolder": "/workspace",
    "workspaceMount": "source=${localWorkspaceFolder},target=/workspace,type=bind",
    "mounts": [
        "type=volume,target=/workspace/.pixi"
    ],
DEVCONTAINER
    printf '  "postCreateCommand": "%s"\n' "$install_command"
    cat <<'DEVCONTAINER'
}
DEVCONTAINER
}

# @description Check that a generated output path is not already present.
# @arg $1 string The output path.
# @exitcode 0 When the path is available.
# @exitcode 1 When the path already exists.
pixied_generate_require_new_path() {
    local path=$1
    if [ -e "$path" ] || [ -L "$path" ]; then
        pixied_die "refusing to overwrite existing generated file: $path; remove it and rerun"
    fi
}

# @description Atomically write a new generated output file.
# The temporary file is created beside the target so the final link stays on the
# same filesystem. A hard link creates the target without replacing a file that
# appeared after the initial existence check.
#
# @arg $1 string The output path.
# @arg $2 string The file content.
# @exitcode 0 When the file is created.
# @exitcode 1 When writing or validation fails.
pixied_generate_write_file() {
    local path=$1 content=$2 directory temporary base_name
    pixied_generate_require_new_path "$path"
    directory=${path%/*}
    base_name=${path##*/}
    pixied_run mkdir -p -- "$directory"
    temporary=$(pixied_run mktemp --tmpdir="$directory" ".${base_name}.pixied.XXXXXX")
    pixied_register_temp "$temporary"
    printf '%s\n' "$content" >"$temporary"
    pixied_run chmod 0644 -- "$temporary"
    pixied_generate_require_new_path "$path"
    if pixied_run ln -- "$temporary" "$path"; then
        pixied_run rm -f -- "$temporary"
    else
        pixied_die "refusing to overwrite existing generated file: $path; remove it and rerun"
    fi
}

# @description Generate a project integration file or print direnv activation code.
# Supported formats are direnv, devcontainer, and dockerfile. Normal file
# generation reads only the nearest project definition and never loads PixiEden
# state or runs Pixi. `direnv --print-envrc` is the activation output mode.
#
# @arg $1 string The output format.
# @arg $2 string Optional --print-envrc flag for the direnv format.
# @exitcode 0 When the requested files are generated.
# @exitcode 1 When the project or output is invalid.
# @exitcode 2 When the format or arguments are invalid.
pixied_generate() {
    local format=${1:-} root definition definition_name lock_present
    local pixied_cli_command print_envrc=0
    local output dockerfile_content devcontainer_content direnv_content
    [ "$#" -ge 1 ] ||
        pixied_die "usage: pixied generate <direnv|devcontainer|dockerfile> [--print-envrc]" \
            "$PIXIED_EXIT_USAGE"
    case "$format" in
    direnv | devcontainer | dockerfile) ;;
    *) pixied_die "unknown generate format: $format" "$PIXIED_EXIT_USAGE" ;;
    esac
    shift
    if [ "$format" = direnv ] && [ "$#" -eq 1 ] && [ "$1" = --print-envrc ]; then
        print_envrc=1
    elif [ "$#" -ne 0 ]; then
        pixied_die "usage: pixied generate <direnv|devcontainer|dockerfile> [--print-envrc]" \
            "$PIXIED_EXIT_USAGE"
    fi

    if [ "$print_envrc" -eq 1 ]; then
        pixied_generate_direnv_print_envrc
        return 0
    fi

    root=$(pixied_generate_find_root "$(pixied_run pwd -P)")
    definition=$(pixied_generate_definition "$root")
    pixied_generate_validate_definition "$definition"
    definition_name=${definition##*/}
    lock_present=$(pixied_generate_lock_present "$root")

    case "$format" in
    direnv)
        output="$root/.envrc"
        pixied_cli_command=$(pixied_generate_cli_command || true)
        direnv_content=$(pixied_generate_direnv_content "$definition_name" "$pixied_cli_command")
        pixied_generate_direnv_write "$output" "$direnv_content"
        pixied_success "Generated $output"
        ;;
    devcontainer)
        output="$root/.devcontainer"
        if [ -e "$output" ] || [ -L "$output" ]; then
            [ ! -L "$output" ] || pixied_die "DevContainer directory must not be a symlink: $output"
            [ -d "$output" ] || pixied_die "DevContainer path is not a directory: $output"
        fi
        pixied_generate_require_new_path "$output/devcontainer.json"
        pixied_generate_require_new_path "$output/Dockerfile"
        dockerfile_content=$(pixied_generate_dockerfile_content \
            "$lock_present" "$PIXIED_PIXI_VERSION_DEFAULT" 0)
        devcontainer_content=$(pixied_generate_devcontainer_content "$lock_present")
        pixied_generate_write_file "$output/Dockerfile" "$dockerfile_content"
        pixied_generate_write_file "$output/devcontainer.json" "$devcontainer_content"
        pixied_success "Generated $output/devcontainer.json and $output/Dockerfile"
        ;;
    dockerfile)
        output="$root/Dockerfile"
        dockerfile_content=$(pixied_generate_dockerfile_content \
            "$lock_present" "$PIXIED_PIXI_VERSION_DEFAULT")
        pixied_generate_write_file "$output" "$dockerfile_content"
        pixied_success "Generated $output"
        ;;
    esac
}
