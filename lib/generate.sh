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
# @arg $1 string The directory from which to search.
# @arg $2 boolean Use the starting directory when no definition is found.
# @stdout The canonical project root.
# @exitcode 0 When a project root is found.
# @exitcode 1 When no project root is found.
pixied_generate_find_root() {
    local directory=${1:-} parent allow_missing=${2:-0} start_directory
    if [ -z "$directory" ]; then
        directory=$(pixied_run pwd -P)
    fi
    directory=$(pixied_canonical_path "$directory")
    [ -d "$directory" ] || pixied_die "project directory is not a directory: $directory"
    start_directory=$directory

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

    if [ "$allow_missing" -eq 1 ]; then
        printf '%s' "$start_directory"
        return 0
    fi
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

# @description Resolve the project inputs used by Dockerfile generation.
# A real pixi.toml takes precedence over pyproject.toml. A missing definition is
# retained as an expected pixi.toml for the Dev Container fallback instead of
# being passed through definition validation.
#
# @arg $1 string The project root.
# @set PIXIED_GENERATE_DEFINITION_NAME string Selected definition filename or pixi.toml.
# @set PIXIED_GENERATE_DEFINITION_EXISTS boolean Whether the selected definition exists.
# @set PIXIED_GENERATE_LOCK_EXISTS boolean Whether a regular pixi.lock exists.
# @exitcode 0 When the available project inputs are valid.
# @exitcode 1 When an available definition or lockfile is invalid.
pixied_generate_resolve_docker_inputs() {
    local root=$1 definition lockfile="$1/pixi.lock"
    PIXIED_GENERATE_DEFINITION_NAME=pixi.toml
    PIXIED_GENERATE_DEFINITION_EXISTS=0
    PIXIED_GENERATE_LOCK_EXISTS=0

    if [ -e "$root/pixi.toml" ] || [ -L "$root/pixi.toml" ] ||
        [ -e "$root/pyproject.toml" ] || [ -L "$root/pyproject.toml" ]; then
        definition=$(pixied_generate_definition "$root")
        pixied_generate_validate_definition "$definition"
        PIXIED_GENERATE_DEFINITION_NAME=${definition##*/}
        PIXIED_GENERATE_DEFINITION_EXISTS=1
    fi

    if [ -e "$lockfile" ] || [ -L "$lockfile" ]; then
        [ ! -L "$lockfile" ] ||
            pixied_die "Pixi lock file must not be a symlink: $lockfile"
        [ -f "$lockfile" ] ||
            pixied_die "Pixi lock file is not a regular file: $lockfile"
        [ -r "$lockfile" ] ||
            pixied_die "Pixi lock file is not readable: $lockfile"
        PIXIED_GENERATE_LOCK_EXISTS=1
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
    if [ "${PIXIED_HOME_MODE:-local}" = nfs ]; then
        cli_path=$(pixied_validate_canonical_path "$PIXIED_COMMAND_BIN/pixied")
    else
        cli_path=$(pixied_validate_canonical_path "$PIXIED_BIN_DIR/pixied")
    fi
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
    # Export the runtime PATH so the evaluated hook seeds both the
    # account-side and local-side ~/.local/bin in NFS mode. The export runs in
    # the subshell, so this printf is the only path where it reaches the shell.
    printf 'export PATH=%q\n' "$PATH"
    pixied_pixi_run shell-hook "$@"
}

# @description Resolve the Pixi version used to tag the generated images.
# Prefers PIXIED_PIXI_VERSION when set, otherwise the pinned default. The
# resolved value is either a concrete semver (without a leading v) or the
# literal "latest" marker.
#
# @stdout The resolved Pixi version.
# @exitcode 0 When a supported version is resolved.
# @exitcode 1 When the version cannot be resolved.
# @see PIXIED_PIXI_VERSION_DEFAULT
pixied_generate_resolve_pixi_version() {
    local version="${PIXIED_PIXI_VERSION:-$PIXIED_PIXI_VERSION_DEFAULT}"
    case "$version" in
    latest) printf 'latest' ;;
    "")
        pixied_die "could not resolve a Pixi version; set PIXIED_PIXI_VERSION to a concrete version (e.g. ${PIXIED_PIXI_VERSION_DEFAULT}) or 'latest' and rerun" \
            "$PIXIED_EXIT_FAILURE"
        ;;
    *)
        if ! printf '%s' "$version" | grep -Eq '^v?[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$'; then
            pixied_die "unsupported Pixi version for generation: $version; set PIXIED_PIXI_VERSION to a concrete version (e.g. ${PIXIED_PIXI_VERSION_DEFAULT}) or 'latest'" \
                "$PIXIED_EXIT_FAILURE"
        fi
        printf '%s' "${version#v}"
        ;;
    esac
}

# @description Build the ghcr.io/prefix-dev/pixi base image reference.
# A concrete version yields "<version>-<variant>" while the "latest" marker
# yields the bare variant tag.
#
# @arg $1 string The resolved Pixi version or "latest".
# @arg $2 string The variant (trixie, trixie-slim, plucky).
# @stdout The fully qualified base image reference.
# @exitcode 0 Always.
pixied_generate_base_image() {
    local version=$1 variant=$2
    if [ "$version" = latest ]; then
        printf 'ghcr.io/prefix-dev/pixi:%s' "$variant"
    else
        printf 'ghcr.io/prefix-dev/pixi:%s-%s' "$version" "$variant"
    fi
}

# @description Write generated content to a temporary file beside the target.
# The temporary file lives on the same filesystem so the final move is atomic.
#
# @arg $1 string The target output path.
# @arg $2 string The content to write.
# @arg $3 string The file mode (default 0644).
# @stdout The temporary file path.
# @exitcode 0 When the temporary file is written.
# @exitcode 1 When writing fails.
pixied_generate_make_temp() {
    local target=$1 content=$2 mode=${3:-0644} directory base_name temporary
    directory=${target%/*}
    [ -d "$directory" ] || pixied_die "output directory is missing: $directory"
    base_name=${target##*/}
    temporary=$(pixied_run mktemp --tmpdir="$directory" ".${base_name}.pixied.XXXXXX")
    pixied_register_temp "$temporary"
    printf '%s\n' "$content" >"$temporary"
    pixied_run chmod "$mode" -- "$temporary"
    printf '%s' "$temporary"
}

# @description Atomically commit generated files, backing up existing targets.
# In force mode each existing target is first moved to a single-generation ".bak"
# backup. All generated temps are then moved into place; if any move fails, the
# already-committed targets are rolled back to their ".bak" originals (or removed
# when no original existed) so a failed commit never leaves a partial update.
#
# @arg $1 integer Enable force mode (1) or not (0).
# @arg $@ string Alternating target and temporary file paths.
# @exitcode 0 When all files are committed.
# @exitcode 1 When a verification or commit step fails.
pixied_generate_commit_files() {
    local force=$1
    shift
    local -a targets=() temps=()
    local target temp i
    while [ "$#" -ge 2 ]; do
        targets+=("$1")
        temps+=("$2")
        shift 2
    done

    # Pre-commit verification: every temp exists and every target dir is writable.
    for temp in "${temps[@]}"; do
        [ -f "$temp" ] || pixied_die "generated content is missing; cannot commit: $temp"
    done
    for target in "${targets[@]}"; do
        [ -d "${target%/*}" ] || pixied_die "output directory is missing: ${target%/*}"
        [ -w "${target%/*}" ] || pixied_die "output directory is not writable: ${target%/*}"
    done

    # Backup phase (force): move every existing target aside before any change.
    if [ "$force" -eq 1 ]; then
        for target in "${targets[@]}"; do
            if [ -e "$target" ] || [ -L "$target" ]; then
                pixied_run rm -f -- "$target.bak"
                pixied_run mv -f -- "$target" "$target.bak" ||
                    pixied_die "failed to back up existing file; aborted before changes: $target"
            fi
        done
    fi

    # Commit phase: move each temp to its target, rolling back on the first error.
    local -a committed=()
    for i in "${!targets[@]}"; do
        target=${targets[$i]}
        temp=${temps[$i]}
        if pixied_run mv -f -- "$temp" "$target"; then
            committed+=("$i")
        else
            for j in "${committed[@]}"; do
                if [ -e "${targets[$j]}.bak" ]; then
                    pixied_run mv -f -- "${targets[$j]}.bak" "${targets[$j]}"
                else
                    pixied_run rm -f -- "${targets[$j]}"
                fi
            done
            pixied_run rm -f -- "$temp"
            pixied_die "failed to commit generated file; rolled back partial changes. Original files are preserved in .bak backups where they existed: $target"
        fi
    done
}

# @description Return the multi-stage Dockerfile used by CI.
# The builder installs the project environment and the slim runner copies it
# into /opt/pixi. The source is never copied; the caller mounts it at /workspace
# at runtime. The runner creates the "app" identity with the configured
# APP_UID/APP_GID without remapping existing system users or groups.
#
# @arg $1 string The resolved Pixi version.
# @arg $2 string The selected Pixi definition filename.
# @arg $3 boolean Whether a regular pixi.lock exists.
# @stdout The generated Dockerfile content.
# @exitcode 0 Always.
pixied_generate_dockerfile_content() {
    local pixi_version=$1 definition_name=$2 lock_exists=$3
    local install_command='pixi install'
    [ "$lock_exists" -eq 1 ] && install_command='pixi install --locked'
    cat <<'DOCKERFILE'
# Build context: the project root containing the Pixi definition.
# The source is not copied into the image; mount it at /workspace:
#   docker build -t my-ci -f Dockerfile .
#   docker run --rm -v "$PWD":/workspace --user "$(id -u):$(id -g)" my-ci run-tests-command

# Override the Pixi version: --build-args PIXI_VERSION=<version>
DOCKERFILE
    if [ "$pixi_version" = latest ]; then
        printf 'ARG PIXI_VERSION=latest\n\n'
    else
        printf 'ARG PIXI_VERSION=%s\n\n' "$pixi_version"
    fi
    cat <<'DOCKERFILE'
# -----------------------------------------------------------------------------
# Builder stage: install the project environment
# -----------------------------------------------------------------------------
DOCKERFILE
    if [ "$pixi_version" = latest ]; then
        printf 'FROM %s AS builder\n' "$(pixied_generate_base_image "$pixi_version" trixie)"
    else
        printf 'FROM ghcr.io/prefix-dev/pixi:${PIXI_VERSION}-trixie AS builder\n'
    fi
    cat <<'DOCKERFILE'

ARG PIXI_ENVIRONMENT_NAME=default

ENV PIXI_HOME=/opt/pixi
ENV PIXI_ENVIRONMENT_NAME=${PIXI_ENVIRONMENT_NAME}

WORKDIR /workspace

# Add necessary sources for pixi install
DOCKERFILE
    if [ "$lock_exists" -eq 1 ]; then
        printf 'COPY %s pixi.lock README* LICENSE* ./\n' "$definition_name"
    else
        printf 'COPY %s pixi.loc[k] README* LICENSE* ./\n' "$definition_name"
    fi
    cat <<'DOCKERFILE'

RUN mkdir -p "$PIXI_HOME" && \
    pixi config set --global detached-environments "$PIXI_HOME/envs" && \
DOCKERFILE
    printf '    %s && \\\n' "$install_command"
    cat <<'DOCKERFILE'
    environment_bin=$(find "$PIXI_HOME/envs" -mindepth 4 -maxdepth 4 -type d -path "*/envs/$PIXI_ENVIRONMENT_NAME/bin" -print -quit) && \
    : "${environment_bin:?Pixi $PIXI_ENVIRONMENT_NAME environment was not installed}" && \
    rm -rf "$PIXI_HOME/envs/bin" && \
    ln -s -- "$environment_bin" "$PIXI_HOME/envs/bin"
DOCKERFILE
    cat <<'DOCKERFILE'

# -----------------------------------------------------------------------------
# Runtime stage: run the project as the configured non-root user
# -----------------------------------------------------------------------------
DOCKERFILE
    if [ "$pixi_version" = latest ]; then
        printf 'FROM %s AS runner\n' "$(pixied_generate_base_image "$pixi_version" trixie-slim)"
    else
        printf 'FROM ghcr.io/prefix-dev/pixi:${PIXI_VERSION}-trixie-slim AS runner\n'
    fi
    cat <<'DOCKERFILE'

ARG PIXI_ENVIRONMENT_NAME=default
ARG APP_UID=1000
ARG APP_GID=1000

ENV PIXI_HOME=/opt/pixi
ENV PIXI_ENVIRONMENT_NAME=${PIXI_ENVIRONMENT_NAME}
ENV PATH=${PIXI_HOME}/envs/bin:${PIXI_HOME}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

RUN if ! getent group "${APP_GID}" >/dev/null; then \
        groupadd --gid "${APP_GID}" app; \
    fi && \
    if ! getent passwd "${APP_UID}" >/dev/null; then \
        useradd --uid "${APP_UID}" --gid "${APP_GID}" --create-home app; \
    fi
WORKDIR /workspace
COPY --from=builder ${PIXI_HOME} ${PIXI_HOME}
USER ${APP_UID}:${APP_GID}
DOCKERFILE
}

# @description Return the simple Dev Container Dockerfile content.
# The image provides the pinned Pixi binary and isolates detached environments
# from the host. The project Pixi directory is declared as a volume so it never
# resolves through the host bind mount. Project installation is deferred until
# the workspace is mounted and the Dev Container post-create command runs.
#
# @arg $1 string The resolved Pixi version.
# @stdout The generated Dockerfile content.
# @exitcode 0 Always.
pixied_generate_devcontainer_dockerfile_content() {
    local pixi_version=$1
    cat <<'DOCKERFILE'
# Build context: the project root.

# Copy the Pixi binary from the specified Pixi version image.
# Override the Pixi version: build.args PIXI_VERSION=<version>
DOCKERFILE
    if [ "$pixi_version" = latest ]; then
        printf 'ARG PIXI_VERSION=latest\n\n'
        printf 'FROM ghcr.io/prefix-dev/pixi:noble AS pixi-provider\n\n'
    else
        printf 'ARG PIXI_VERSION=%s\n\n' "$pixi_version"
        printf 'FROM ghcr.io/prefix-dev/pixi:${PIXI_VERSION}-noble AS pixi-provider\n\n'
    fi
    cat <<'DOCKERFILE'
FROM mcr.microsoft.com/devcontainers/base:noble

COPY --from=pixi-provider /usr/local/bin/pixi /usr/local/bin/

# Isolate container environment to prevent path conflicts with host
ENV PIXI_HOME=/opt/pixi
RUN mkdir -p /opt/pixi/envs && \
    pixi config set --global detached-environments /opt/pixi/envs && \
    chown -R vscode:vscode /opt/pixi

# Isolate container environment to prevent path conflicts with host.
VOLUME /workspace/.pixi

# Install additional packages if needed.
# RUN apt-get update && apt-get install -y --no-install-recommends \
#         listing-additional-packages && \
#     rm -rf /var/lib/apt/lists/*
DOCKERFILE
}

# @description Return the Dev Container definition content.
# The workspace is bind-mounted from the host while the project Pixi directory
# is kept on a per-user named volume, and the post-create work is delegated to
# the generated postCreateCommand.sh script.
#
# @stdout The generated devcontainer.json content.
# @exitcode 0 Always.
pixied_generate_devcontainer_json_content() {
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
        // To remove the volume:
        // 1. `docker volume ls` - Find the volume name ($USER-$DirectoryName-pixi).
        // 2. `docker volume rm <target>` - Delete the target volume.
        "source=${localEnv:USER}-${localWorkspaceFolderBasename}-pixi,target=${containerWorkspaceFolder}/.pixi,type=volume"
        // Optional: Mount .pixi/config.toml to share with the DevContainer.
        // "source=${localWorkspaceFolder}/.pixi/config.toml,target=${containerWorkspaceFolder}/.pixi/config.toml,type=bind"
    ],
    "postCreateCommand": "bash ${containerWorkspaceFolder}/.devcontainer/postCreateCommand.sh"
}
DEVCONTAINER
}

# @description Return the Dev Container post-create script content.
# The script installs the project Pixi environment once the workspace is
# mounted, appends the Pixi shell hook of the detected manifest to the container
# ~/.bashrc, and finally runs an optional postCreateCommand.local.sh so project
# setup survives regeneration of this file.
#
# @stdout The generated postCreateCommand.sh content.
# @exitcode 0 Always.
pixied_generate_devcontainer_post_create_content() {
    cat <<'POSTCREATE'
#!/usr/bin/env bash
#
# Post-create command script for the DevContainer.

set -Eeuo pipefail
umask 022

workspace_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
local_script="$(dirname -- "${BASH_SOURCE[0]}")/postCreateCommand.local.sh"
if [ -f "$workspace_dir/pixi.toml" ]; then
    manifest_path="$workspace_dir/pixi.toml"
elif [ -f "$workspace_dir/pyproject.toml" ]; then
    manifest_path="$workspace_dir/pyproject.toml"
else
    manifest_path="$workspace_dir/pixi.toml"
fi

install_pixi() {
    local pixi_shell_hook
    pixi_shell_hook="eval \"\$(pixi shell-hook --manifest-path $manifest_path 2>/dev/null)\""

    sudo chown -R vscode:vscode "$workspace_dir/.pixi"
    pixi install

    touch "$HOME/.bashrc"
    if ! grep -Fqx "$pixi_shell_hook" "$HOME/.bashrc"; then
        printf '%s\n' "$pixi_shell_hook" >>"$HOME/.bashrc"
    fi
}

run_local_script() {
    if [ -f "$local_script" ]; then
        /usr/bin/env bash "$local_script"
    fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    install_pixi
    run_local_script
    echo "Post-create commands completed. You may need to reload window for changes to take effect."
fi
POSTCREATE
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

# @description Print the usage for regular project integration generation.
# @stdout The generate command usage.
# @exitcode 0 Always.
pixied_generate_usage() {
    cat <<'USAGE'
Usage: pixied generate <direnv|devcontainer|dockerfile> [OPTIONS]

Generate a project integration file.

Formats:
    direnv        Append the activation block to .envrc.
    devcontainer  Generate .devcontainer files.
    dockerfile    Generate a Dockerfile.

Options:
    --print-envrc   (direnv only) Print activation code instead of writing .envrc.
    --force         (devcontainer, dockerfile only) Back up existing files
                    as <name>.bak before replacing them.
USAGE
}

# @description Print the usage for force-enabled project integration generation.
# @stdout The force-enabled generate command usage.
# @exitcode 0 Always.
pixied_generate_force_usage() {
    printf '%s\n' "usage: pixied generate <devcontainer|dockerfile> --force"
}

# @description Generate a project integration file or print direnv activation code.
# Supported formats are direnv, devcontainer, and dockerfile. Normal file
# generation reads only the nearest project definition and never loads PixiEden
# state or runs Pixi. `direnv --print-envrc` is the activation output mode.
# The --force flag is accepted for dockerfile and devcontainer, which use it to
# back up existing generated files before replacing them.
#
# @arg $1 string The output format.
# @arg $@ string Optional --print-envrc (direnv) or --force (dockerfile, devcontainer).
# @exitcode 0 When the requested files are generated.
# @exitcode 1 When the project or output is invalid.
# @exitcode 2 When the format or arguments are invalid.
pixied_generate() {
    local format=${1:-}
    local force=0 print_envrc=0 arg
    local usage
    usage=$(pixied_generate_usage)
    if [ "$#" -eq 0 ]; then
        pixied_die "$usage" "$PIXIED_EXIT_USAGE"
    fi
    case "$format" in
    --help | -h | -help)
        [ "$#" -eq 1 ] || pixied_die "$usage" "$PIXIED_EXIT_USAGE"
        printf '%s\n' "$usage"
        return "$PIXIED_EXIT_OK"
        ;;
    direnv | devcontainer | dockerfile) ;;
    *) pixied_die "$usage" "$PIXIED_EXIT_USAGE" ;;
    esac
    shift
    for arg in "$@"; do
        case "$arg" in
        --help | -h | -help) pixied_die "$usage" "$PIXIED_EXIT_USAGE" ;;
        --force)
            [ "$format" = direnv ] || force=1
            ;;
        --print-envrc)
            [ "$format" = direnv ] || pixied_die "$usage" "$PIXIED_EXIT_USAGE"
            print_envrc=1
            ;;
        *) pixied_die "$usage" "$PIXIED_EXIT_USAGE" ;;
        esac
    done

    if [ "$print_envrc" -eq 1 ]; then
        pixied_generate_direnv_print_envrc
        return 0
    fi

    if [ "$format" = direnv ]; then
        pixied_generate_direnv
        return 0
    fi

    local root pixi_version
    root=$(pixied_generate_find_root "$(pixied_run pwd -P)" 1)
    pixi_version=$(pixied_generate_resolve_pixi_version)

    case "$format" in
    direnv) pixied_generate_direnv "$root" "$definition" ;;
    devcontainer)
        pixied_generate_devcontainer "$force" "$root" "$pixi_version"
        ;;
    dockerfile)
        pixied_generate_resolve_docker_inputs "$root"
        pixied_generate_dockerfile "$force" "$root" "$pixi_version" \
            "$PIXIED_GENERATE_DEFINITION_NAME" "$PIXIED_GENERATE_DEFINITION_EXISTS" \
            "$PIXIED_GENERATE_LOCK_EXISTS"
        ;;
    esac
}

# @description Generate the project .envrc by appending the activation block.
# The direnv output always appends rather than overwriting, so no force flag is
# needed for this format.
#
# @exitcode 0 When the .envrc is written.
# @exitcode 1 When writing fails.
pixied_generate_direnv() {
    local root definition pixied_cli_command direnv_content output
    root=$(pixied_generate_find_root "$(pixied_run pwd -P)")
    definition=$(pixied_generate_definition "$root")
    pixied_generate_validate_definition "$definition"
    output="$root/.envrc"
    pixied_cli_command=$(pixied_generate_cli_command || true)
    direnv_content=$(pixied_generate_direnv_content "${definition##*/}" "$pixied_cli_command")
    pixied_generate_direnv_write "$output" "$direnv_content"
    pixied_success "Generated $output"
}

# @description Generate the CI Dockerfile.
# The image is multi-stage and never copies the project source. Existing files
# are refused unless --force backs them up first.
#
# @arg $1 integer Enable force mode (1) or not (0).
# @arg $2 string The project root.
# @arg $3 string The resolved Pixi version.
# @arg $4 string The selected definition filename or pixi.toml.
# @arg $5 boolean Whether the selected definition exists.
# @arg $6 boolean Whether a regular pixi.lock exists.
# @exitcode 0 When the Dockerfile is generated.
# @exitcode 1 When the project or output is invalid.
pixied_generate_dockerfile() {
    local force=$1 root=$2 pixi_version=$3 definition_name=$4
    local definition_exists=$5 lock_exists=$6
    local target="$root/Dockerfile" content temp
    if [ "$definition_exists" -eq 0 ]; then
        pixied_die "pixied generate dockerfile requires pixi.toml or pyproject.toml; lockfile-only and manifest-free projects are supported only by generate devcontainer" \
            "$PIXIED_EXIT_FAILURE"
    fi
    if [ "$force" -eq 0 ]; then
        pixied_generate_require_new_path "$target"
    fi
    content=$(pixied_generate_dockerfile_content "$pixi_version" "$definition_name" "$lock_exists")
    temp=$(pixied_generate_make_temp "$target" "$content" 0644)
    pixied_generate_commit_files "$force" "$target" "$temp"
    pixied_success "Generated $target"
}

# @description Generate the Dev Container files.
# Writes Dockerfile, devcontainer.json, and the post-create script into
# .devcontainer. The post-create script is executable and is never confused with
# the optional project-local postCreateCommand.local.sh, which is left untouched.
#
# @arg $1 integer Enable force mode (1) or not (0).
# @arg $2 string The project root.
# @arg $3 string The resolved Pixi version.
# @exitcode 0 When all files are generated.
# @exitcode 1 When the project or output is invalid.
pixied_generate_devcontainer() {
    local force=$1 root=$2 pixi_version=$3
    local dir="$root/.devcontainer"
    local dockerfile="$dir/Dockerfile" json="$dir/devcontainer.json"
    local post_create="$dir/postCreateCommand.sh"
    local content
    local df_temp json_temp script_temp
    pixied_run mkdir -p -- "$dir"
    if [ "$force" -eq 0 ]; then
        pixied_generate_require_new_path "$dockerfile"
        pixied_generate_require_new_path "$json"
        pixied_generate_require_new_path "$post_create"
    fi
    content=$(pixied_generate_devcontainer_dockerfile_content "$pixi_version")
    df_temp=$(pixied_generate_make_temp "$dockerfile" "$content" 0644)
    content=$(pixied_generate_devcontainer_json_content)
    json_temp=$(pixied_generate_make_temp "$json" "$content" 0644)
    content=$(pixied_generate_devcontainer_post_create_content)
    script_temp=$(pixied_generate_make_temp "$post_create" "$content" 0755)
    pixied_generate_commit_files "$force" \
        "$dockerfile" "$df_temp" \
        "$json" "$json_temp" \
        "$post_create" "$script_temp"
    pixied_success "Generated files in $dir:"
    pixied_success "  ${dockerfile##*/}"
    pixied_success "  ${json##*/}"
    pixied_success "  ${post_create##*/}"
}
