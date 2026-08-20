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
# @stdout The generated Dockerfile content.
# @exitcode 0 Always.
pixied_generate_dockerfile_content() {
    local pixi_version=$1
    cat <<'DOCKERFILE'
# Generated by `pixied generate dockerfile`.
#
# Build context: the project root containing pixi.toml and pixi.lock.
# The source is not copied into the image; mount it at /workspace:
#   docker build -t my-ci -f Dockerfile .
#   docker run --rm -v "$PWD":/workspace --user "$(id -u):$(id -g)" my-ci
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
ENV PIXI_HOME=/opt/pixi
WORKDIR /workspace
COPY pixi.toml pixi.lock ./
RUN mkdir -p "$PIXI_HOME" && \
    printf 'detached-environments = "%s/projects"\n' "$PIXI_HOME" > "$PIXI_HOME/config.toml" && \
    pixi install --locked && \
    environment_bin=$(find "$PIXI_HOME/projects" -mindepth 4 -maxdepth 4 -type d -path '*/envs/default/bin' -print -quit) && \
    test -n "$environment_bin" || { echo 'Pixi default environment was not installed' >&2; exit 1; }; \
    rm -rf "$PIXI_HOME/projects/bin" && \
    ln -s -- "$environment_bin" "$PIXI_HOME/projects/bin"
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
ARG APP_UID=1000
ARG APP_GID=1000
ENV PIXI_HOME=/opt/pixi
ENV PATH=${PIXI_HOME}/projects/bin:${PIXI_HOME}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
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

# @description Return the single-stage Dev Container Dockerfile content.
# .env is sourced as a shell environment file, so arbitrary exported settings
# can be added alongside CONTAINER_UID/GID. The container IDs are still
# validated as decimal integers, and the configured identity is exposed as
# the app user. Pixi installs after initializing a missing project manifest.
#
# @arg $1 string The resolved Pixi version.
# @stdout The generated Dockerfile content.
# @exitcode 0 Always.
pixied_generate_devcontainer_dockerfile_content() {
    local pixi_version=$1
    cat <<'DOCKERFILE'
# Generated by `pixied generate dockerfile`.
#
# Build context: the project root. Ensure .devcontainer/.env exists.
# Override the Pixi version: docker build --build-arg PIXI_VERSION=<version> .
DOCKERFILE
    if [ "$pixi_version" = latest ]; then
        printf 'ARG PIXI_VERSION=latest\n\n'
        printf 'FROM %s\n' "$(pixied_generate_base_image "$pixi_version" plucky)"
    else
        printf 'ARG PIXI_VERSION=%s\n\n' "$pixi_version"
        printf 'FROM ghcr.io/prefix-dev/pixi:${PIXI_VERSION}-plucky\n'
    fi
    cat <<'DOCKERFILE'
ENV PIXI_HOME=/opt/pixi
ENV PATH=${PIXI_HOME}/projects/bin:${PIXI_HOME}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

WORKDIR /workspace
COPY pixi.tom[l] pixi.loc[k] .devcontainer/.env ./
COPY .devcontainer/.env .devcontainer/.env
COPY .devcontainer/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

RUN set -a && \
    . /workspace/.devcontainer/.env && \
    set +a && \
    CONTAINER_UID=${CONTAINER_UID:-1000} && \
    CONTAINER_GID=${CONTAINER_GID:-1000} && \
    validate_id() { \
        id_val="$1"; name="$2"; \
        case "$id_val" in ''|*[!0-9]*) \
            echo "invalid $name: must be a decimal integer" >&2; exit 1 ;; \
        esac; \
        if [ "$id_val" -lt 0 ] || [ "$id_val" -gt 2147483647 ]; then \
            echo "invalid $name: out of range [0,2147483647]" >&2; exit 1; \
        fi; \
    } && \
    validate_id "$CONTAINER_UID" CONTAINER_UID && \
    validate_id "$CONTAINER_GID" CONTAINER_GID && \
    if getent group app >/dev/null; then \
        [ "$(getent group app | cut -d: -f3)" = "$CONTAINER_GID" ] || { \
            echo "app group does not have CONTAINER_GID=$CONTAINER_GID" >&2; exit 1; \
        }; \
    else \
        existing_group=$(getent group "$CONTAINER_GID" | cut -d: -f1) && \
        if [ -n "$existing_group" ]; then \
            groupmod --new-name app "$existing_group"; \
        else \
            groupadd --gid "$CONTAINER_GID" app; \
        fi; \
    fi && \
    if getent passwd app >/dev/null; then \
        [ "$(id -u app)" = "$CONTAINER_UID" ] || { \
            echo "app user does not have CONTAINER_UID=$CONTAINER_UID" >&2; exit 1; \
        }; \
    else \
        existing_user=$(getent passwd "$CONTAINER_UID" | cut -d: -f1) && \
        if [ -n "$existing_user" ]; then \
            [ "$existing_user" != root ] || { \
                echo 'CONTAINER_UID=0 cannot provide a non-root app user' >&2; exit 1; \
            }; \
            usermod --login app --home /home/app --move-home "$existing_user"; \
        else \
            useradd --uid "$CONTAINER_UID" --gid "$CONTAINER_GID" --create-home app; \
        fi; \
    fi && \
    chown "$CONTAINER_UID:$CONTAINER_GID" /workspace && \
    install -d -o "$CONTAINER_UID" -g "$CONTAINER_GID" "$PIXI_HOME" && \
    printf 'detached-environments = "%s/projects"\n' "$PIXI_HOME" > "$PIXI_HOME/config.toml" && \
    apt-get update && apt-get install -y --no-install-recommends gosu && \
    rm -rf /var/lib/apt/lists/*

RUN set -a && \
    . /workspace/.devcontainer/.env && \
    set +a && \
    CONTAINER_UID=${CONTAINER_UID:-1000} && \
    CONTAINER_GID=${CONTAINER_GID:-1000} && \
    app_user=app && \
    if [ ! -f pixi.toml ]; then \
        rm -f -- pixi.lock && \
        su "$app_user" -c "PIXI_HOME=$PIXI_HOME pixi init"; \
    fi && \
    if [ -f pixi.lock ]; then \
        su "$app_user" -c "PIXI_HOME=$PIXI_HOME pixi install --locked"; \
    else \
        su "$app_user" -c "PIXI_HOME=$PIXI_HOME pixi install"; \
    fi && \
    environment_dir=$(find "$PIXI_HOME/projects" -mindepth 3 -maxdepth 3 -type d -path '*/envs/default' -print -quit) && \
    test -n "$environment_dir" || { echo 'Pixi default environment was not installed' >&2; exit 1; }; \
    environment_bin="$environment_dir/bin" && \
    install -d -o "$CONTAINER_UID" -g "$CONTAINER_GID" -- "$environment_bin" && \
    rm -rf "$PIXI_HOME/projects/bin" && \
    ln -s -- "$environment_bin" "$PIXI_HOME/projects/bin"

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
DOCKERFILE
}

# @description Return the Dev Container ENTRYPOINT script content.
# The script sources .env as a shell environment file for CONTAINER_UID/GID and
# any additional exported settings, corrects ownership of app HOME and
# /opt/pixi, and runs the command as app unless a privilege switcher leads.
#
# @stdout The generated entrypoint script content.
# @exitcode 0 Always.
pixied_generate_entrypoint_content() {
    cat <<'ENTRYPOINT'
#!/usr/bin/env bash
# Generated by pixied generate.
set -euo pipefail

ENV_FILE="/workspace/.devcontainer/.env"
if [ ! -f "$ENV_FILE" ]; then
    echo "pixied entrypoint: $ENV_FILE is missing; mount .devcontainer/.env or regenerate with 'pixied generate devcontainer'" >&2
    exit 1
fi

# Source the mounted .env so arbitrary settings can be exported to the
# container command. This intentionally executes shell code from the file.
CONTAINER_UID="1000"
CONTAINER_GID="1000"
set -a
source "$ENV_FILE"
set +a
CONTAINER_UID=${CONTAINER_UID:-1000}
CONTAINER_GID=${CONTAINER_GID:-1000}

validate_id() {
    local id_val=$1 name=$2
    [[ "$id_val" =~ ^[0-9]+$ ]] || {
        echo "pixied entrypoint: invalid $name: $id_val (must be a decimal integer)" >&2
        exit 1
    }
    [ "$id_val" -ge 0 ] && [ "$id_val" -le 2147483647 ] || {
        echo "pixied entrypoint: invalid $name: $id_val (out of range [0,2147483647])" >&2
        exit 1
    }
}
validate_id "$CONTAINER_UID" CONTAINER_UID
validate_id "$CONTAINER_GID" CONTAINER_GID

chown_if_needed() {
    local path=$1 owner group
    [ -e "$path" ] || return 0
    owner=$(stat -c %u -- "$path" 2>/dev/null || true)
    group=$(stat -c %g -- "$path" 2>/dev/null || true)
    [ "$owner" = "$CONTAINER_UID" ] && [ "$group" = "$CONTAINER_GID" ] && return 0
    chown -R "${CONTAINER_UID}:${CONTAINER_GID}" "$path"
}

app_user=app
if ! getent passwd "$app_user" >/dev/null; then
    app_user=$(getent passwd "${CONTAINER_UID:-1000}" | cut -d: -f1)
fi
[ -n "$app_user" ] || app_user=app

chown_if_needed "/home/${app_user}"
chown_if_needed /opt/pixi

first_arg=${1:-}
case "$(basename -- "${first_arg%% *}")" in
gosu) exec "$@" ;;
esac

if [ "$(id -u)" = 0 ]; then
    exec gosu "$app_user" "$@"
fi
exec "$@"
ENTRYPOINT
}

# @description Return the Dev Container definition content.
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
    "remoteUser": "app"
}
DEVCONTAINER
}

# @description Return the Dev Container .env content with the host UID/GID.
# @arg $1 string The host UID.
# @arg $2 string The host GID.
# @stdout The generated .env content.
# @exitcode 0 Always.
pixied_generate_devcontainer_env_content() {
    local uid=$1 gid=$2
    printf 'CONTAINER_UID=%s\n' "$uid"
    printf 'CONTAINER_GID=%s\n' "$gid"
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
    printf '%s\n' "usage: pixied generate <direnv|devcontainer|dockerfile> [--print-envrc]"
    pixied_generate_force_usage
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
    [ "$#" -ge 1 ] || pixied_die "$usage" "$PIXIED_EXIT_USAGE"
    case "$format" in
    direnv | devcontainer | dockerfile) ;;
    *) pixied_die "$usage" "$PIXIED_EXIT_USAGE" ;;
    esac
    shift
    for arg in "$@"; do
        case "$arg" in
        --force) force=1 ;;
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

    local root definition pixi_version
    root=$(pixied_generate_find_root "$(pixied_run pwd -P)")
    definition=$(pixied_generate_definition "$root")
    pixied_generate_validate_definition "$definition"
    pixi_version=$(pixied_generate_resolve_pixi_version)

    case "$format" in
    dockerfile) pixied_generate_dockerfile "$force" "$root" "$pixi_version" "$definition" ;;
    devcontainer) pixied_generate_devcontainer "$force" "$root" "$pixi_version" ;;
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
# @arg $4 string The definition file path.
# @exitcode 0 When the Dockerfile is generated.
# @exitcode 1 When the project or output is invalid.
pixied_generate_dockerfile() {
    local force=$1 root=$2 pixi_version=$3 definition=$4
    local target="$root/Dockerfile" content temp
    local definition_name=${definition##*/}
    if [ "$definition_name" != pixi.toml ] && [ ! -e "$root/pixi.toml" ]; then
        pixied_die "pixied generate dockerfile requires a pixi.toml; pyproject.toml-only projects are not supported for CI images" \
            "$PIXIED_EXIT_FAILURE"
    fi
    if [ "$force" -eq 0 ]; then
        pixied_generate_require_new_path "$target"
    fi
    content=$(pixied_generate_dockerfile_content "$pixi_version")
    temp=$(pixied_generate_make_temp "$target" "$content" 0644)
    pixied_generate_commit_files "$force" "$target" "$temp"
    pixied_success "Generated $target"
}

# @description Generate the Dev Container files.
# Writes Dockerfile, devcontainer.json, entrypoint.sh, and .env into
# .devcontainer. Existing files are refused unless --force backs them up first.
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
    local entry="$dir/entrypoint.sh" env="$dir/.env"
    local host_uid host_gid content
    local df_temp json_temp entry_temp env_temp
    pixied_run mkdir -p -- "$dir"
    if [ "$force" -eq 0 ]; then
        pixied_generate_require_new_path "$dockerfile"
        pixied_generate_require_new_path "$json"
        pixied_generate_require_new_path "$entry"
        pixied_generate_require_new_path "$env"
    fi
    host_uid=$(pixied_run id -u)
    host_gid=$(pixied_run id -g)
    content=$(pixied_generate_devcontainer_dockerfile_content "$pixi_version")
    df_temp=$(pixied_generate_make_temp "$dockerfile" "$content" 0644)
    content=$(pixied_generate_devcontainer_json_content)
    json_temp=$(pixied_generate_make_temp "$json" "$content" 0644)
    content=$(pixied_generate_entrypoint_content)
    entry_temp=$(pixied_generate_make_temp "$entry" "$content" 0755)
    content=$(pixied_generate_devcontainer_env_content "$host_uid" "$host_gid")
    env_temp=$(pixied_generate_make_temp "$env" "$content" 0644)
    pixied_generate_commit_files "$force" \
        "$dockerfile" "$df_temp" \
        "$json" "$json_temp" \
        "$entry" "$entry_temp" \
        "$env" "$env_temp"
    pixied_success "Generated files in $dir:"
    pixied_success "  ${dockerfile##*/}"
    pixied_success "  ${json##*/}"
    pixied_success "  ${entry##*/}"
    pixied_success "  ${env##*/}"
}
