#!/usr/bin/env bash
# @brief Immutable release storage and validation for PixiEden.
# @description
# Defines the release payload allowlist, creates and validates release manifests,
# and publishes versioned payloads into the shared NFS release store.
# shellcheck disable=SC2015

if [ -n "${PIXIED_RELEASE_LOADED:-}" ]; then
    # shellcheck disable=SC2317 # Sourced by both the source and deployed CLI.
    return 0 2>/dev/null || exit 0
fi
PIXIED_RELEASE_LOADED=1

declare -ga PIXIED_RELEASE_PAYLOAD_PATHS=()
declare -g PIXIED_RELEASE_VERSION=""
declare -g PIXIED_RELEASE_MANIFEST_HASH=""
declare -g PIXIED_RELEASE_LOCK_DIR=""
declare -g PIXIED_RELEASE_LEASE_FILE=""
declare -g PIXIED_RELEASE_CURRENT_VERSION=""
declare -g PIXIED_RELEASE_CURRENT_MANIFEST_HASH=""
declare -g PIXIED_RELEASE_CURRENT_DIR=""
declare -g PIXIED_RELEASE_PROMOTED_DIR=""
declare -ga PIXIED_RELEASE_PRUNE_CANDIDATES=()
declare -g PIXIED_RELEASE_PRUNE_COUNTER=0

# @description Report a release validation error through the shared error path.
# Falls back to a standalone stderr error when release.sh is used by the package
# script before the main PixiEden libraries are loaded.
#
# @arg $1 string The error message.
# @arg $2 integer The exit code (defaults to 1).
# @stderr The release error message.
# @exitcode $2 Always.
pixied_release_fail() {
    local message=$1 exit_code=${2:-1}
    if declare -F pixied_die >/dev/null 2>&1; then
        pixied_die "$message" "$exit_code"
    fi
    printf '[pixied/release] ERROR: %s\n' "$message" >&2
    return "$exit_code"
}

# @description Run a command through pixied_run when available.
# Package tooling does not load common.sh, while the installed CLI uses its
# command logger; this wrapper keeps both paths on the same implementation.
#
# @arg $@ string The command and arguments.
# @stdout The command output.
# @exitcode The command exit status.
pixied_release_run() {
    if declare -F pixied_run >/dev/null 2>&1; then
        pixied_run "$@"
    else
        command "$@"
    fi
}

# @description Return the safe release version from a string.
#
# @arg $1 string The release version.
# @stdout The validated version.
# @exitcode 0 When the version is valid.
# @exitcode 2 When the version is invalid.
if ! declare -F pixied_release_version_validate >/dev/null 2>&1; then
    pixied_release_version_validate() {
        local version=${1:-}
        [[ "$version" =~ ${PIXIED_SAFE_VERSION_PATTERN:-^[0-9]+\.[0-9]+\.[0-9]+$} ]] ||
            pixied_release_fail "invalid release version: $version" "${PIXIED_EXIT_USAGE:-2}"
        printf '%s' "$version"
    }
fi

# @description Populate the canonical release payload allowlist.
# The list contains the local installer, CLI, every immediate lib/*.sh file,
# and every lib/templates/<category> template. Templates use a .tmpl infix
# before the real extension (*.tmpl.{ext}); extensionless outputs use a bare
# .tmpl suffix instead. The template categories are fixed to direnv,
# devcontainer, and dockerfile. Symlinks remain in the list so later validation
# can reject them explicitly.
#
# @arg $1 string The source tree root.
# @set PIXIED_RELEASE_PAYLOAD_PATHS array Release-relative payload paths.
# @exitcode 0 When the source tree has the expected layout.
# @exitcode 1 When the source tree is missing a required directory.
pixied_release_payload_paths() {
    local source_root=${1:-} lib_path template_path category
    [ -n "$source_root" ] || pixied_release_fail 'release source root is not set'
    [ -d "$source_root" ] || pixied_release_fail "release source root is not a directory: $source_root"
    [ ! -L "$source_root" ] || pixied_release_fail "release source root is a symlink: $source_root"
    [ -d "$source_root/bin" ] || pixied_release_fail "release source bin directory is missing: $source_root/bin"
    [ -d "$source_root/lib" ] || pixied_release_fail "release source lib directory is missing: $source_root/lib"
    [ ! -L "$source_root/bin" ] || pixied_release_fail "release source bin directory is a symlink: $source_root/bin"
    [ ! -L "$source_root/lib" ] || pixied_release_fail "release source lib directory is a symlink: $source_root/lib"

    PIXIED_RELEASE_PAYLOAD_PATHS=(install-local.sh bin/pixied)
    while IFS= read -r lib_path; do
        [ -n "$lib_path" ] || continue
        PIXIED_RELEASE_PAYLOAD_PATHS+=("lib/$lib_path")
    done < <(find "$source_root/lib" -mindepth 1 -maxdepth 1 \
        \( -type f -o -type l \) -name '*.sh' -printf '%f\n' | LC_ALL=C sort)
    if [ -d "$source_root/lib/templates" ]; then
        [ ! -L "$source_root/lib/templates" ] ||
            pixied_release_fail "release source templates directory is a symlink: $source_root/lib/templates"
        for category in direnv devcontainer dockerfile; do
            [ -d "$source_root/lib/templates/$category" ] ||
                pixied_release_fail "release source template category is missing: $source_root/lib/templates/$category"
            [ ! -L "$source_root/lib/templates/$category" ] ||
                pixied_release_fail "release source template category is a symlink: $source_root/lib/templates/$category"
        done
        while IFS= read -r template_path; do
            [ -n "$template_path" ] || continue
            PIXIED_RELEASE_PAYLOAD_PATHS+=("lib/templates/$template_path")
        done < <(find "$source_root/lib/templates" -mindepth 2 -maxdepth 2 \
            \( -type f -o -type l \) \( -name '*.tmpl' -o -name '*.tmpl.*' \) \
            -printf '%P\n' | LC_ALL=C sort)
    fi
    [ "${#PIXIED_RELEASE_PAYLOAD_PATHS[@]}" -gt 2 ] ||
        pixied_release_fail "release source has no library payload: $source_root/lib"
}

# @description Return the expected mode for a release payload path.
#
# @arg $1 string The release-relative payload path.
# @stdout The expected numeric mode.
# @exitcode 0 When the path is in the allowlist shape.
# @exitcode 1 When the path is not a payload path.
pixied_release_expected_mode() {
    case "$1" in
    install-local.sh | bin/pixied) printf '755' ;;
    lib/templates/*/*.tmpl | lib/templates/*/*.tmpl.*) printf '644' ;;
    lib/*.sh) printf '644' ;;
    *) pixied_release_fail "release path is not in the payload allowlist: $1" ;;
    esac
}

# @description Return the release version declared by a CLI source file.
#
# @arg $1 string The source tree root.
# @stdout The declared SemVer release version.
# @exitcode 0 When the version declaration is valid.
# @exitcode 1 When the declaration is absent or invalid.
pixied_release_source_version() {
    local source_root=${1:-} cli version
    cli="$source_root/bin/pixied"
    [ -f "$cli" ] && [ ! -L "$cli" ] ||
        pixied_release_fail "release CLI is not a regular file: $cli"
    version=$(sed -n \
        's/^PIXIED_VERSION="\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)"$/\1/p' \
        "$cli" | head -n 1)
    [ -n "$version" ] || pixied_release_fail "release CLI has no valid PIXIED_VERSION: $cli"
    pixied_release_version_validate "$version"
}

# @description Return a payload file's SHA-256 digest.
#
# @arg $1 string The regular payload file.
# @stdout The 64-character lowercase digest.
# @exitcode 0 When hashing succeeds.
# @exitcode 1 When the file is not a regular file.
pixied_release_file_hash() {
    local path=${1:-} hash
    [ -f "$path" ] && [ ! -L "$path" ] ||
        pixied_release_fail "release payload is not a regular file: $path"
    hash=$(sha256sum -- "$path")
    printf '%s' "${hash%% *}"
}

# @description Generate the canonical manifest content for a release tree.
# The manifest records the source version, each allowlisted path, its required
# mode, and its SHA-256 digest in deterministic order.
#
# @arg $1 string The release source or stage directory.
# @stdout The manifest content.
# @set PIXIED_RELEASE_VERSION string The version declared by the CLI.
# @exitcode 0 When all payload files pass validation.
# @exitcode 1 When a file is missing, is a symlink, or has an unsafe mode.
pixied_release_manifest_content() {
    local source_root=$1 rel path canonical mode expected hash
    source_root=$(realpath -m -- "$source_root")
    pixied_release_payload_paths "$source_root"
    PIXIED_RELEASE_VERSION=$(pixied_release_source_version "$source_root")
    printf 'version=%s\n' "$PIXIED_RELEASE_VERSION"
    for rel in "${PIXIED_RELEASE_PAYLOAD_PATHS[@]}"; do
        path="$source_root/$rel"
        canonical=$(realpath -m -- "$path")
        [ "$canonical" = "$path" ] ||
            pixied_release_fail "release payload path is not canonical: $rel"
        [ -f "$path" ] && [ ! -L "$path" ] ||
            pixied_release_fail "release payload is not a regular file: $rel"
        mode=$(stat -c %a -- "$path")
        expected=$(pixied_release_expected_mode "$rel")
        [ "$mode" = "$expected" ] ||
            pixied_release_fail "release payload has unexpected mode $mode (expected $expected): $rel"
        hash=$(pixied_release_file_hash "$path")
        printf 'file=%s|mode=%s|sha256=%s\n' "$rel" "$mode" "$hash"
    done
}

# @description Generate a release manifest at a target path.
#
# @arg $1 string The release source or stage directory.
# @arg $2 string The manifest output path.
# @set PIXIED_RELEASE_VERSION string The declared release version.
# @exitcode 0 When the manifest is written.
# @exitcode 1 When the source or output path is unsafe.
pixied_release_generate_manifest() {
    local source_root=$1 output=$2 parent
    parent=${output%/*}
    [ -d "$parent" ] || pixied_release_fail "release manifest parent is missing: $parent"
    [ ! -L "$output" ] || pixied_release_fail "release manifest target is a symlink: $output"
    umask 077
    pixied_release_manifest_content "$source_root" >"$output"
    pixied_release_run chmod 0644 -- "$output"
}

# @description Validate the exact file set and manifest of a release tree.
# Extra files, symlinks, malformed modes, and digest changes are rejected.
#
# @arg $1 string The release directory.
# @arg $2 string Optional manifest path (defaults to release-manifest in the directory).
# @arg $3 string Optional archive marker that permits packaged documentation.
# @set PIXIED_RELEASE_VERSION string The validated release version.
# @set PIXIED_RELEASE_MANIFEST_HASH string The manifest SHA-256 digest.
# @exitcode 0 When the release tree is fully verified.
# @exitcode 1 When the tree or manifest is unsafe or inconsistent.
pixied_release_validate_tree() {
    local release_dir=$1 manifest=${2:-$1/release-manifest} tree_kind=${3:-release}
    local entry rel expected actual
    release_dir=$(realpath -m -- "$release_dir")
    [ -d "$release_dir" ] && [ ! -L "$release_dir" ] ||
        pixied_release_fail "release directory is not a regular directory: $release_dir"
    [ -f "$manifest" ] && [ ! -L "$manifest" ] ||
        pixied_release_fail "release manifest is not a regular file: $manifest"
    while IFS= read -r entry; do
        rel=${entry#"$release_dir/"}
        case "$rel" in
        install-local.sh | release-manifest | bin | lib | lib/templates | bin/pixied | lib/*.sh) ;;
        lib/templates/direnv | lib/templates/devcontainer | lib/templates/dockerfile) ;;
        lib/templates/direnv/*.tmpl | lib/templates/devcontainer/*.tmpl | lib/templates/dockerfile/*.tmpl) ;;
        lib/templates/direnv/*.tmpl.* | lib/templates/devcontainer/*.tmpl.* | lib/templates/dockerfile/*.tmpl.*) ;;
        README.md | README.ja.md | docs | docs/*)
            [ "$tree_kind" = archive ] ||
                pixied_release_fail "release contains an unmanaged path: $rel"
            ;;
        *) pixied_release_fail "release contains an unmanaged path: $rel" ;;
        esac
    done < <(find "$release_dir" -mindepth 1 -print)

    pixied_release_manifest_content "$release_dir" >"${manifest}.expected"
    expected=$(<"${manifest}.expected")
    pixied_release_run rm -f -- "${manifest}.expected"
    actual=$(<"$manifest")
    [ "$actual" = "$expected" ] ||
        pixied_release_fail "release manifest does not match payload: $release_dir"
    PIXIED_RELEASE_MANIFEST_HASH=$(pixied_release_file_hash "$manifest")
    export PIXIED_RELEASE_VERSION PIXIED_RELEASE_MANIFEST_HASH
}

# @description Copy and validate a source tree into a release stage directory.
# The stage is populated only from the shared payload allowlist and receives
# normalized release permissions before its manifest is generated.
#
# @arg $1 string The source tree.
# @arg $2 string The empty stage directory.
# @set PIXIED_RELEASE_VERSION string The staged release version.
# @set PIXIED_RELEASE_MANIFEST_HASH string The staged manifest digest.
# @exitcode 0 When the stage is complete and verified.
# @exitcode 1 When the source cannot be copied or verified.
pixied_release_stage_source() {
    local source_root=$1 stage_dir=$2 rel source target mode
    source_root=$(realpath -m -- "$source_root")
    [ -d "$stage_dir" ] && [ ! -L "$stage_dir" ] ||
        pixied_release_fail "release stage is not a regular directory: $stage_dir"
    pixied_release_payload_paths "$source_root"
    if [ -f "$source_root/release-manifest" ]; then
        pixied_release_validate_tree "$source_root" "$source_root/release-manifest" archive
    fi
    pixied_release_run mkdir -p -- "$stage_dir/bin" "$stage_dir/lib"
    for rel in "${PIXIED_RELEASE_PAYLOAD_PATHS[@]}"; do
        source="$source_root/$rel"
        target="$stage_dir/$rel"
        [ -f "$source" ] && [ ! -L "$source" ] ||
            pixied_release_fail "release payload is not a regular file: $rel"
        pixied_release_run mkdir -p -- "$(dirname "$target")"
        pixied_release_run cp -- "$source" "$target"
        mode=$(pixied_release_expected_mode "$rel")
        pixied_release_run chmod "$mode" -- "$target"
    done
    pixied_release_generate_manifest "$stage_dir" "$stage_dir/release-manifest"
    pixied_release_validate_tree "$stage_dir"
}

# @description Validate a release stage against an existing immutable version.
# Existing versions are reusable only when their complete manifest matches. No
# managed release directory is changed by this preflight.
#
# @arg $1 string The stage directory under the release store.
# @arg $2 string The staged release version.
# @arg $3 string The staged manifest hash.
# @set PIXIED_RELEASE_PROMOTED_DIR string The existing or future release directory.
# @exitcode 0 When the stage is safe to promote or reuse.
# @exitcode 1 When validation or promotion fails.
pixied_release_stage_validate() {
    local stage_dir=$1 version=$2 manifest_hash=$3
    local store release_dir actual_hash
    pixied_release_require_publish_lock
    store=$(pixied_release_store_dir)
    stage_dir=$(realpath -m -- "$stage_dir")
    case "$stage_dir" in
    "$store"/.stage.*) ;;
    *) pixied_release_fail "release stage is outside the managed store: $stage_dir" ;;
    esac
    [ -d "$stage_dir" ] && [ ! -L "$stage_dir" ] ||
        pixied_release_fail "release stage is not a regular directory: $stage_dir"
    version=$(pixied_release_version_validate "$version")
    [[ "$manifest_hash" =~ ^[0-9a-f]{64}$ ]] ||
        pixied_release_fail 'invalid staged release manifest hash'
    pixied_release_validate_tree "$stage_dir"
    actual_hash=$PIXIED_RELEASE_MANIFEST_HASH
    [ "$actual_hash" = "$manifest_hash" ] ||
        pixied_release_fail "staged release manifest hash does not match: $version"
    [ "$PIXIED_RELEASE_VERSION" = "$version" ] ||
        pixied_release_fail "staged release version does not match: $version"
    release_dir=$(pixied_release_version_dir "$version")
    if [ -e "$release_dir" ] || [ -L "$release_dir" ]; then
        [ -d "$release_dir" ] && [ ! -L "$release_dir" ] ||
            pixied_release_fail "existing release path is not a directory: $release_dir"
        [ -f "$release_dir/release-manifest" ] ||
            pixied_release_fail "existing release manifest is missing: $release_dir"
        [ "$(<"$release_dir/release-manifest")" = "$(<"$stage_dir/release-manifest")" ] ||
            pixied_release_fail "release version already exists with a different manifest: $version"
        pixied_release_validate_tree "$release_dir"
    fi
    PIXIED_RELEASE_VERSION=$version
    PIXIED_RELEASE_MANIFEST_HASH=$manifest_hash
    PIXIED_RELEASE_PROMOTED_DIR=$release_dir
    export PIXIED_RELEASE_VERSION PIXIED_RELEASE_MANIFEST_HASH PIXIED_RELEASE_PROMOTED_DIR
}

# @description Promote a validated stage into its immutable version directory.
# The stage is intentionally left in place on reuse so the caller's registered
# temporary cleanup handles it without removing a managed release directory.
#
# @arg $1 string The stage directory under the release store.
# @arg $2 string The staged release version.
# @arg $3 string The staged manifest hash.
# @set PIXIED_RELEASE_PROMOTED_DIR string The existing or newly promoted directory.
# @exitcode 0 When the stage is promoted or safely reused.
# @exitcode 1 When validation or promotion fails.
pixied_release_promote_stage() {
    local stage_dir=$1 release_dir
    pixied_release_stage_validate "$@"
    release_dir=$PIXIED_RELEASE_PROMOTED_DIR
    if [ ! -e "$release_dir" ] && [ ! -L "$release_dir" ]; then
        pixied_release_run mv -- "$stage_dir" "$release_dir"
    fi
}

# @description Prepare the internal NFS release store and its managed roots.
#
# @set PIXIED_RELEASE_STORE_DIR string The prepared store path.
# @exitcode 0 When the store is available and owned by the current user.
# @exitcode 1 When a store path is a symlink, foreign-owned, or unsafe.
pixied_release_store_prepare() {
    local store releases leases path
    store=$(pixied_release_store_dir)
    releases="$store/releases"
    leases="$store/leases"
    for path in "$store" "$releases" "$leases"; do
        [ ! -L "$path" ] || pixied_release_fail "release store path is a symlink: $path"
    done
    pixied_release_run mkdir -p -- "$releases" "$leases"
    for path in "$store" "$releases" "$leases"; do
        [ -d "$path" ] && [ ! -L "$path" ] ||
            pixied_release_fail "release store path is not a directory: $path"
        pixied_release_run chmod 0700 -- "$path"
        if declare -F pixied_validate_owned_path >/dev/null 2>&1; then
            pixied_validate_owned_path "$path"
        fi
    done
    PIXIED_RELEASE_STORE_DIR=$store
    export PIXIED_RELEASE_STORE_DIR
}

# @description Acquire the shared publish lock as an owned directory.
# The lock is intentionally non-waiting so a concurrent administrator receives
# an explicit refusal instead of observing a partially published release.
#
# @set PIXIED_RELEASE_LOCK_DIR string The acquired lock directory.
# @exitcode 0 When the lock is acquired.
# @exitcode 1 When another publisher owns the lock or the path is unsafe.
pixied_release_publish_lock_acquire() {
    local lock_dir
    [ -z "${PIXIED_RELEASE_LOCK_DIR:-}" ] ||
        pixied_release_fail 'release publish lock is already held'
    pixied_release_store_prepare
    lock_dir=$(pixied_release_publish_lock_path)
    [ ! -e "$lock_dir" ] && [ ! -L "$lock_dir" ] ||
        pixied_release_fail "release publish lock already exists: $lock_dir"
    if ! pixied_release_run mkdir -- "$lock_dir"; then
        pixied_release_fail "could not acquire release publish lock: $lock_dir"
    fi
    pixied_release_run chmod 0700 -- "$lock_dir"
    if declare -F pixied_validate_owned_path >/dev/null 2>&1; then
        pixied_validate_owned_path "$lock_dir"
    fi
    PIXIED_RELEASE_LOCK_DIR=$lock_dir
}

# @description Release the shared publish lock.
# @exitcode 0 When no lock is held or the empty lock is removed.
# @exitcode 1 When the lock cannot be safely removed.
pixied_release_publish_lock_release() {
    [ -n "${PIXIED_RELEASE_LOCK_DIR:-}" ] || return 0
    pixied_release_run rmdir -- "$PIXIED_RELEASE_LOCK_DIR"
    PIXIED_RELEASE_LOCK_DIR=""
}

# @description Validate that the shared publish lock is still held.
# @exitcode 0 When the current process holds the expected lock.
# @exitcode 1 When the lock is absent or changed.
pixied_release_require_publish_lock() {
    local expected=${PIXIED_RELEASE_LOCK_DIR:-} actual
    [ -n "$expected" ] || pixied_release_fail 'release publish lock is required'
    actual=$(pixied_release_publish_lock_path)
    [ "$expected" = "$actual" ] || pixied_release_fail 'unexpected release publish lock path'
    [ -d "$expected" ] && [ ! -L "$expected" ] ||
        pixied_release_fail "release publish lock is unavailable: $expected"
    if declare -F pixied_validate_owned_path >/dev/null 2>&1; then
        pixied_validate_owned_path "$expected"
    fi
}

# @description Read and fully validate the shared current release pointer.
# The pointer, selected release directory, manifest, ownership, and containment
# are checked before any caller receives the selected version.
#
# @set PIXIED_RELEASE_CURRENT_VERSION string The verified current version.
# @set PIXIED_RELEASE_CURRENT_MANIFEST_HASH string The verified manifest hash.
# @set PIXIED_RELEASE_CURRENT_DIR string The verified current release directory.
# @exitcode 0 When current points to a verified release.
# @exitcode 1 When current is missing, malformed, corrupted, or unsafe.
pixied_release_current_read() {
    local store releases current_path release_dir line version="" manifest_hash=""
    local version_seen=0 hash_seen=0 actual_hash
    [ "${PIXIED_HOME_MODE:-local}" = nfs ] ||
        pixied_release_fail "release store is available only in NFS mode" "${PIXIED_EXIT_USAGE:-2}"
    store=$(pixied_release_store_dir)
    releases="$store/releases"
    current_path=$(pixied_release_current_path)
    [ -d "$store" ] && [ ! -L "$store" ] ||
        pixied_release_fail "release store is unavailable: $store"
    [ -d "$releases" ] && [ ! -L "$releases" ] ||
        pixied_release_fail "release directory is unavailable: $releases"
    [ -f "$current_path" ] && [ ! -L "$current_path" ] ||
        pixied_release_fail "current release pointer is missing or unsafe: $current_path"
    [ "$(realpath -m -- "$current_path")" = "$current_path" ] ||
        pixied_release_fail "current release pointer is not canonical: $current_path"
    if declare -F pixied_validate_owned_path >/dev/null 2>&1; then
        pixied_validate_owned_path "$store"
        pixied_validate_owned_path "$releases"
        pixied_validate_owned_path "$current_path"
    fi
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
        version=*)
            [ "$version_seen" -eq 0 ] || pixied_release_fail 'duplicate current release version'
            version=${line#*=}
            version_seen=1
            ;;
        manifest_hash=*)
            [ "$hash_seen" -eq 0 ] || pixied_release_fail 'duplicate current release manifest hash'
            manifest_hash=${line#*=}
            hash_seen=1
            ;;
        *) pixied_release_fail "malformed current release pointer: $current_path" ;;
        esac
    done <"$current_path"
    [ "$version_seen" -eq 1 ] && [ "$hash_seen" -eq 1 ] ||
        pixied_release_fail "current release pointer is incomplete: $current_path"
    version=$(pixied_release_version_validate "$version")
    [[ "$manifest_hash" =~ ^[0-9a-f]{64}$ ]] ||
        pixied_release_fail "current release pointer has an invalid manifest hash"
    release_dir=$(pixied_release_version_dir "$version")
    case "$release_dir/" in
    "$releases/"*) ;;
    *) pixied_release_fail "current release escapes the release store: $version" ;;
    esac
    [ -d "$release_dir" ] && [ ! -L "$release_dir" ] ||
        pixied_release_fail "current release directory is unavailable: $release_dir"
    if declare -F pixied_validate_owned_path >/dev/null 2>&1; then
        pixied_validate_owned_path "$release_dir"
    fi
    pixied_release_validate_tree "$release_dir"
    actual_hash=$PIXIED_RELEASE_MANIFEST_HASH
    [ "$actual_hash" = "$manifest_hash" ] ||
        pixied_release_fail "current release manifest hash does not match: $version"
    PIXIED_RELEASE_CURRENT_VERSION=$version
    PIXIED_RELEASE_CURRENT_MANIFEST_HASH=$manifest_hash
    PIXIED_RELEASE_CURRENT_DIR=$release_dir
    export PIXIED_RELEASE_CURRENT_VERSION PIXIED_RELEASE_CURRENT_MANIFEST_HASH \
        PIXIED_RELEASE_CURRENT_DIR
}

# @description Return the comm string for the current process.
# @stdout The process comm value.
# @exitcode 0 Always.
pixied_release_process_comm() {
    local comm=""
    if [ -r "/proc/$$/comm" ]; then
        comm=$(head -n 1 -- "/proc/$$/comm" 2>/dev/null)
    fi
    if [ -z "$comm" ] && command -v ps >/dev/null 2>&1; then
        comm=$(ps -p $$ -o comm= 2>/dev/null | head -n 1)
    fi
    printf '%s' "$comm"
}

# @description Acquire a short version-specific release source lease.
# The lease is separate from the machine runtime lease and protects a selected
# release directory while a management command reads it.
#
# @arg $1 string The release version.
# @set PIXIED_RELEASE_LEASE_FILE string The created lease file.
# @exitcode 0 When the lease is created.
# @exitcode 1 When the release or lease directory is unsafe.
pixied_release_lease_acquire() {
    local version=$1 lease_dir lease_file comm
    [ -z "${PIXIED_RELEASE_LEASE_FILE:-}" ] ||
        pixied_release_fail 'release lease is already held'
    version=$(pixied_release_version_validate "$version")
    lease_dir=$(pixied_release_lease_dir "$version")
    pixied_release_store_prepare
    [ ! -L "$lease_dir" ] || pixied_release_fail "release lease directory is a symlink: $lease_dir"
    pixied_release_run mkdir -p -- "$lease_dir"
    pixied_release_run chmod 0700 -- "$lease_dir"
    if declare -F pixied_validate_owned_path >/dev/null 2>&1; then
        pixied_validate_owned_path "$lease_dir"
    fi
    lease_file=$(pixied_release_run mktemp --tmpdir="$lease_dir" "$$-XXXXXX")
    comm=$(pixied_release_process_comm)
    {
        printf 'pid=%s\n' "$$"
        printf 'comm=%s\n' "$comm"
        printf 'version=%s\n' "$version"
    } >"$lease_file"
    pixied_release_run chmod 0600 -- "$lease_file"
    PIXIED_RELEASE_LEASE_FILE=$lease_file
    export PIXIED_RELEASE_LEASE_FILE
}

# @description Release the current version-specific release lease.
# @exitcode 0 When no lease is held or the lease file is removed.
pixied_release_lease_release() {
    [ -n "${PIXIED_RELEASE_LEASE_FILE:-}" ] || return 0
    [ -f "$PIXIED_RELEASE_LEASE_FILE" ] && [ ! -L "$PIXIED_RELEASE_LEASE_FILE" ] ||
        pixied_release_fail "release lease is not a regular file: $PIXIED_RELEASE_LEASE_FILE"
    if declare -F pixied_validate_owned_path >/dev/null 2>&1; then
        pixied_validate_owned_path "$PIXIED_RELEASE_LEASE_FILE"
    fi
    pixied_release_run rm -f -- "$PIXIED_RELEASE_LEASE_FILE"
    PIXIED_RELEASE_LEASE_FILE=""
    export PIXIED_RELEASE_LEASE_FILE
}

# @description Decide whether a release lease file is stale.
# A lease is live only when its pid and comm still identify the same process.
#
# @arg $1 string The lease file.
# @exitcode 0 When the lease is stale.
# @exitcode 1 When the lease is live.
pixied_release_lease_is_stale() {
    local lease_file=$1 pid comm actual
    pid=$(sed -n 's/^pid=//p' "$lease_file" | head -n 1)
    comm=$(sed -n 's/^comm=//p' "$lease_file" | head -n 1)
    case "$pid" in
    '' | *[!0-9]*) return 0 ;;
    esac
    [ -n "$comm" ] || return 0
    kill -0 "$pid" 2>/dev/null || return 0
    actual=""
    [ -r "/proc/$pid/comm" ] && actual=$(head -n 1 -- "/proc/$pid/comm" 2>/dev/null)
    [ "$actual" = "$comm" ] || return 0
    return 1
}

# @description Sweep stale leases under every release version.
# Live leases are recorded in PIXIED_RELEASE_LIVE_VERSIONS for prune and other
# shared-store management commands.
#
# @set PIXIED_RELEASE_LIVE_VERSIONS assoc Versions with live leases.
# @exitcode 0 When the sweep completes.
# @exitcode 1 When a lease entry is unsafe.
pixied_release_lease_sweep() {
    local leases version lease_dir lease_file recorded_version
    declare -gA PIXIED_RELEASE_LIVE_VERSIONS=()
    leases="$(pixied_release_store_dir)/leases"
    [ -d "$leases" ] || return 0
    [ ! -L "$leases" ] || pixied_release_fail "release leases directory is a symlink: $leases"
    for lease_dir in "$leases"/*; do
        [ -d "$lease_dir" ] || continue
        [ ! -L "$lease_dir" ] || pixied_release_fail "release lease directory is a symlink: $lease_dir"
        version=${lease_dir##*/}
        pixied_release_version_validate "$version" >/dev/null
        for lease_file in "$lease_dir"/*; do
            [ -e "$lease_file" ] || continue
            [ -f "$lease_file" ] && [ ! -L "$lease_file" ] ||
                pixied_release_fail "release lease entry is not a regular file: $lease_file"
            recorded_version=$(sed -n 's/^version=//p' "$lease_file" | head -n 1)
            [ "$recorded_version" = "$version" ] ||
                pixied_release_fail "release lease version does not match its directory: $lease_file"
            if pixied_release_lease_is_stale "$lease_file"; then
                if declare -F pixied_validate_owned_path >/dev/null 2>&1; then
                    pixied_validate_owned_path "$lease_file"
                fi
                pixied_release_run rm -f -- "$lease_file"
            else
                # shellcheck disable=SC2034 # The caller consumes this exported associative array.
                PIXIED_RELEASE_LIVE_VERSIONS["$version"]=1
            fi
        done
    done
}

# @description Collect immutable releases eligible for pruning.
# Current, the newest requested number of other releases, and live-leased
# releases are excluded. Every release entry is validated before candidates are
# exposed to a caller.
#
# @arg $1 integer Number of non-current releases to retain.
# @set PIXIED_RELEASE_PRUNE_CANDIDATES array Release versions to remove.
# @exitcode 0 When the release store contains only safe entries.
# @exitcode 1 When an entry is unmanaged or unsafe.
pixied_release_prune_collect() {
    local keep=$1 keep_count=0 releases release_entry version canonical
    local -a release_versions=()
    local retain_count=0
    case "$keep" in
    '' | *[!0-9]*) pixied_release_fail "invalid prune keep count: $keep" "${PIXIED_EXIT_USAGE:-2}" ;;
    esac
    keep_count=$((10#$keep))
    [ -n "${PIXIED_RELEASE_CURRENT_VERSION:-}" ] ||
        pixied_release_fail 'current release must be resolved before pruning'
    releases="$(pixied_release_store_dir)/releases"
    [ -d "$releases" ] && [ ! -L "$releases" ] ||
        pixied_release_fail "release directory is unavailable: $releases"
    PIXIED_RELEASE_PRUNE_CANDIDATES=()
    for release_entry in "$releases"/*; do
        [ -e "$release_entry" ] || [ -L "$release_entry" ] || continue
        [ -d "$release_entry" ] && [ ! -L "$release_entry" ] ||
            pixied_release_fail "release entry is not a directory: $release_entry"
        version=${release_entry##*/}
        pixied_release_version_validate "$version" >/dev/null
        canonical=$(realpath -m -- "$release_entry")
        [ "$canonical" = "$release_entry" ] ||
            pixied_release_fail "release entry is not canonical: $release_entry"
        case "$canonical/" in
        "$releases/"*) ;;
        *) pixied_release_fail "release entry escapes the release directory: $version" ;;
        esac
        if declare -F pixied_validate_owned_path >/dev/null 2>&1; then
            pixied_validate_owned_path "$canonical"
        fi
        pixied_release_validate_tree "$canonical"
        release_versions+=("$version")
    done

    while IFS= read -r version; do
        [ -n "$version" ] || continue
        [ "$version" = "$PIXIED_RELEASE_CURRENT_VERSION" ] && continue
        if declare -p PIXIED_RELEASE_LIVE_VERSIONS >/dev/null 2>&1 &&
            [ "${PIXIED_RELEASE_LIVE_VERSIONS[$version]:-0}" = 1 ]; then
            continue
        fi
        if [ "$retain_count" -lt "$keep_count" ]; then
            retain_count=$((retain_count + 1))
            continue
        fi
        PIXIED_RELEASE_PRUNE_CANDIDATES+=("$version")
    done < <(printf '%s\n' "${release_versions[@]}" | sort -V -r)
}

# @description Validate the complete shared release store before last-machine removal.
# Only the release store's managed roots may exist, and every managed object is
# checked for canonical ownership while the publish lock is held.
#
# @exitcode 0 When the store contains only owned managed objects.
# @exitcode 1 When an unmanaged, foreign, or unsafe object is found.
pixied_release_validate_store_for_cleanup() {
    local store entry name release_dir lease_dir lease_file lock_entry rel
    local version canonical current_present=0
    store=$(pixied_release_store_dir)
    pixied_release_require_publish_lock
    declare -F pixied_validate_owned_path >/dev/null 2>&1 ||
        pixied_release_fail 'ownership validator is unavailable for release cleanup'
    pixied_validate_owned_path "$store"
    for name in releases leases; do
        [ -d "$store/$name" ] && [ ! -L "$store/$name" ] ||
            pixied_release_fail "release store managed root is unsafe: $store/$name"
    done
    for entry in "$store"/* "$store"/.[!.]* "$store"/..?*; do
        [ -e "$entry" ] || [ -L "$entry" ] || continue
        name=${entry##*/}
        case "$name" in
        releases | leases)
            [ -d "$entry" ] && [ ! -L "$entry" ] ||
                pixied_release_fail "release store managed root is unsafe: $entry"
            pixied_validate_owned_path "$entry"
            ;;
        current)
            [ -f "$entry" ] && [ ! -L "$entry" ] ||
                pixied_release_fail "release store current pointer is unsafe: $entry"
            pixied_validate_owned_path "$entry"
            current_present=1
            ;;
        publish.lock)
            [ "$entry" = "${PIXIED_RELEASE_LOCK_DIR:-}" ] ||
                pixied_release_fail "release store publish lock is not held by this process: $entry"
            [ -d "$entry" ] && [ ! -L "$entry" ] ||
                pixied_release_fail "release store publish lock is unsafe: $entry"
            pixied_validate_owned_path "$entry"
            for lock_entry in "$entry"/* "$entry"/.[!.]* "$entry"/..?*; do
                [ -e "$lock_entry" ] || [ -L "$lock_entry" ] || continue
                pixied_release_fail "release store publish lock is not empty: $entry"
            done
            ;;
        *) pixied_release_fail "shared release store contains unmanaged entry: $entry" ;;
        esac
    done
    if [ "$current_present" -eq 1 ]; then
        pixied_release_current_read
    fi

    for release_dir in "$store/releases"/* "$store/releases"/.[!.]* "$store/releases"/..?*; do
        [ -e "$release_dir" ] || [ -L "$release_dir" ] || continue
        [ -d "$release_dir" ] && [ ! -L "$release_dir" ] ||
            pixied_release_fail "release entry is not a directory: $release_dir"
        version=${release_dir##*/}
        pixied_release_version_validate "$version" >/dev/null
        canonical=$(realpath -m -- "$release_dir")
        [ "$canonical" = "$release_dir" ] ||
            pixied_release_fail "release entry is not canonical: $release_dir"
        case "$canonical/" in
        "$store/releases/"*) ;;
        *) pixied_release_fail "release entry escapes the release directory: $version" ;;
        esac
        pixied_validate_owned_path "$release_dir"
        pixied_release_validate_tree "$release_dir"
        for rel in "${PIXIED_RELEASE_PAYLOAD_PATHS[@]}" release-manifest; do
            pixied_validate_owned_path "$release_dir/$rel"
        done
    done
    for lease_dir in "$store/leases"/* "$store/leases"/.[!.]* "$store/leases"/..?*; do
        [ -e "$lease_dir" ] || [ -L "$lease_dir" ] || continue
        [ -d "$lease_dir" ] && [ ! -L "$lease_dir" ] ||
            pixied_release_fail "release lease directory is unsafe: $lease_dir"
        version=${lease_dir##*/}
        pixied_release_version_validate "$version" >/dev/null
        pixied_validate_owned_path "$lease_dir"
        for lease_file in "$lease_dir"/* "$lease_dir"/.[!.]* "$lease_dir"/..?*; do
            [ -e "$lease_file" ] || [ -L "$lease_file" ] || continue
            [ -f "$lease_file" ] && [ ! -L "$lease_file" ] ||
                pixied_release_fail "release lease entry is unsafe: $lease_file"
            pixied_validate_owned_path "$lease_file"
        done
    done
}

# @description Return a same-filesystem quarantine path for a release.
# The path is constrained to the release directory's parent and is never
# returned when an existing entry would be overwritten.
#
# @arg $1 string The release directory.
# @stdout The unique quarantine sibling path.
# @exitcode 0 When a safe path is available.
# @exitcode 1 When the path cannot be made canonical.
pixied_release_prune_quarantine_path() {
    local release_dir=$1 parent version candidate canonical
    parent=${release_dir%/*}
    version=${release_dir##*/}
    while :; do
        PIXIED_RELEASE_PRUNE_COUNTER=$((PIXIED_RELEASE_PRUNE_COUNTER + 1))
        candidate="$parent/.pixied-prune-$$-$PIXIED_RELEASE_PRUNE_COUNTER-$version"
        [ ! -e "$candidate" ] && [ ! -L "$candidate" ] || continue
        canonical=$(realpath -m -- "$candidate")
        [ "$canonical" = "$candidate" ] ||
            pixied_release_fail "prune quarantine path is not canonical: $candidate"
        case "$canonical/" in
        "$parent/"*)
            printf '%s' "$canonical"
            return 0
            ;;
        *) pixied_release_fail "prune quarantine escapes the release directory: $candidate" ;;
        esac
    done
}

# @description Revalidate and quarantine all collected prune candidates.
# Current and live leases are checked again under the held publish lock before
# any move occurs, so a newly protected release aborts the whole deletion pass.
#
# @exitcode 0 When every candidate is safely removed.
# @exitcode 1 When validation, quarantine, or deletion fails.
pixied_release_prune_delete() {
    local current_version=${PIXIED_RELEASE_CURRENT_VERSION:-} version release_dir quarantine
    pixied_release_current_read
    [ "$PIXIED_RELEASE_CURRENT_VERSION" = "$current_version" ] ||
        pixied_release_fail 'current release changed while preparing prune'
    pixied_release_lease_sweep
    for version in "${PIXIED_RELEASE_PRUNE_CANDIDATES[@]}"; do
        [ "$version" != "$PIXIED_RELEASE_CURRENT_VERSION" ] ||
            pixied_release_fail "prune candidate is current: $version"
        if declare -p PIXIED_RELEASE_LIVE_VERSIONS >/dev/null 2>&1 &&
            [ "${PIXIED_RELEASE_LIVE_VERSIONS[$version]:-0}" = 1 ]; then
            pixied_release_fail "prune candidate has a live release lease: $version"
        fi
        release_dir=$(pixied_release_version_dir "$version")
        [ -d "$release_dir" ] && [ ! -L "$release_dir" ] ||
            pixied_release_fail "prune candidate is unavailable: $version"
        if declare -F pixied_validate_owned_path >/dev/null 2>&1; then
            pixied_validate_owned_path "$release_dir"
        fi
        pixied_release_validate_tree "$release_dir"
    done
    for version in "${PIXIED_RELEASE_PRUNE_CANDIDATES[@]}"; do
        release_dir=$(pixied_release_version_dir "$version")
        quarantine=$(pixied_release_prune_quarantine_path "$release_dir")
        pixied_release_run mv -- "$release_dir" "$quarantine"
        [ -d "$quarantine" ] && [ ! -L "$quarantine" ] ||
            pixied_release_fail "prune quarantine is unavailable: $version"
        if declare -F pixied_validate_owned_path >/dev/null 2>&1; then
            pixied_validate_owned_path "$quarantine"
        fi
        pixied_release_run rm -rf -- "$quarantine"
        [ ! -e "$quarantine" ] && [ ! -L "$quarantine" ] ||
            pixied_release_fail "could not purge prune quarantine: $version"
    done
}

# @description Select a verified release as the shared current release.
# The pointer is a regular file containing version and manifest hash and is
# replaced atomically only after the target release has been revalidated.
#
# @arg $1 string The release version.
# @arg $2 string The expected manifest hash.
# @set PIXIED_RELEASE_CURRENT_VERSION string The selected version.
# @set PIXIED_RELEASE_CURRENT_MANIFEST_HASH string The selected manifest hash.
# @exitcode 0 When current is atomically replaced.
# @exitcode 1 When the target release or pointer is unsafe.
pixied_release_select_current() {
    local version=$1 expected_hash=$2 release_dir current_path content actual_hash
    pixied_release_require_publish_lock
    version=$(pixied_release_version_validate "$version")
    [[ "$expected_hash" =~ ^[0-9a-f]{64}$ ]] ||
        pixied_release_fail 'invalid release manifest hash'
    release_dir=$(pixied_release_version_dir "$version")
    pixied_release_validate_tree "$release_dir"
    actual_hash=$PIXIED_RELEASE_MANIFEST_HASH
    [ "$actual_hash" = "$expected_hash" ] ||
        pixied_release_fail "release manifest hash does not match: $version"
    current_path=$(pixied_release_current_path)
    [ ! -L "$current_path" ] || pixied_release_fail "current release pointer is a symlink: $current_path"
    content="version=$version"$'\n'
    content+="manifest_hash=$expected_hash"$'\n'
    pixied_atomic_write "$current_path" "$content"
    PIXIED_RELEASE_CURRENT_VERSION=$version
    PIXIED_RELEASE_CURRENT_MANIFEST_HASH=$expected_hash
    PIXIED_RELEASE_CURRENT_DIR=$release_dir
    export PIXIED_RELEASE_CURRENT_VERSION PIXIED_RELEASE_CURRENT_MANIFEST_HASH \
        PIXIED_RELEASE_CURRENT_DIR
}

# @description Publish a source tree and select it as the shared current release.
# A stage is created beside the release store, promoted only after complete
# validation, and never overwrites a different existing release with the same
# version. The previous current pointer is untouched on any earlier failure.
#
# @arg $1 string The verified release source tree.
# @set PIXIED_RELEASE_VERSION string The published version.
# @set PIXIED_RELEASE_MANIFEST_HASH string The published manifest digest.
# @exitcode 0 When the release is published and selected.
# @exitcode 1 When validation, locking, promotion, or selection fails.
pixied_release_publish() {
    local source_root=$1 store stage_dir release_dir version manifest_hash
    source_root=$(realpath -m -- "$source_root")
    pixied_release_store_prepare
    pixied_release_publish_lock_acquire
    store=$PIXIED_RELEASE_STORE_DIR
    stage_dir=$(pixied_release_run mktemp -d "$store/.stage.XXXXXX")
    pixied_register_temp "$stage_dir"
    pixied_release_stage_source "$source_root" "$stage_dir"
    version=$PIXIED_RELEASE_VERSION
    manifest_hash=$PIXIED_RELEASE_MANIFEST_HASH
    pixied_release_promote_stage "$stage_dir" "$version" "$manifest_hash"
    release_dir=$PIXIED_RELEASE_PROMOTED_DIR
    pixied_release_select_current "$version" "$manifest_hash"
    pixied_release_publish_lock_release
}
