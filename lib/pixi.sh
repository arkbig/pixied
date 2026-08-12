#!/usr/bin/env bash
# @brief Library responsible for PixiEden's dedicated Pixi environment.
# @description
# Selects a Linux Pixi release asset, verifies its SHA-256 digest, installs the
# binary inside PIXIED_DATA_DIR, and runs all Pixi commands with a dedicated
# PIXI_HOME and PIXI_NO_PATH_UPDATE setting.

if [ -n "${PIXIED_PIXI_LOADED:-}" ]; then
    # shellcheck disable=SC2317 # Sourced by both the source and deployed CLI.
    return 0 2>/dev/null || exit 0
fi
PIXIED_PIXI_LOADED=1

readonly PIXIED_PIXI_VERSION_DEFAULT="0.76.1"
# SHA-256 digests for the default Pixi release assets, matching
# PIXIED_PIXI_VERSION_DEFAULT. Update them together when bumping the pin.
readonly PIXIED_PIXI_SHA256_X86_64_DEFAULT="8e2ab7630f5bc1e8aa38d236842e20f565f7aa0834687e53670b7c86ba54c90f"
readonly PIXIED_PIXI_SHA256_AARCH64_DEFAULT="e7c9d7f128fe02d20b212c0ba9b8ab445907b415155b72ca93f3120e63a8fbb3"
readonly PIXIED_PIXI_RELEASE_BASE="https://github.com/prefix-dev/pixi/releases/download"

# @description Return the supported Linux Pixi platform identifier.
# @stdout The Pixi platform identifier.
# @exitcode 0 When the host architecture is supported.
# @exitcode 2 When the host is not a supported Linux architecture.
pixied_pixi_platform() {
    local operating_system architecture
    operating_system=$(pixied_run uname -s)
    architecture=$(pixied_run uname -m)
    [ "$operating_system" = Linux ] ||
        pixied_die "unsupported operating system for Pixi: $operating_system" "$PIXIED_EXIT_USAGE"
    case "$architecture" in
    x86_64 | amd64) printf 'x86_64-unknown-linux-musl' ;;
    aarch64 | arm64) printf 'aarch64-unknown-linux-musl' ;;
    *) pixied_die "unsupported Linux architecture for Pixi: $architecture" "$PIXIED_EXIT_USAGE" ;;
    esac
}

# @description Return the default SHA-256 digest for a Pixi release asset.
# The digests are declared next to PIXIED_PIXI_VERSION_DEFAULT at the top.
#
# @arg $1 string The platform identifier.
# @stdout The expected SHA-256 digest.
# @exitcode 0 When a digest is known.
# @exitcode 1 When no digest is known.
pixied_pixi_default_sha256() {
    case "$1" in
    x86_64-unknown-linux-musl)
        printf '%s' "$PIXIED_PIXI_SHA256_X86_64_DEFAULT"
        ;;
    aarch64-unknown-linux-musl)
        printf '%s' "$PIXIED_PIXI_SHA256_AARCH64_DEFAULT"
        ;;
    *) return 1 ;;
    esac
}

# @description Validate a Pixi release tag.
# @arg $1 string The release tag.
# @stdout The validated release tag.
# @exitcode 0 When the tag uses the supported release format.
# @exitcode 1 When the tag is invalid.
pixied_pixi_validate_release_tag() {
    local tag=$1
    [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
        pixied_die "invalid Pixi release tag: $tag"
    printf '%s' "$tag"
}

# @description Return the tag of the latest Pixi release.
# Uses PIXIED_PIXI_LATEST_TAG when set, otherwise resolves the tag from the
# GitHub latest release API.
#
# @stdout The latest release tag.
# @exitcode 0 When the tag is resolved.
# @exitcode 1 When the latest release cannot be resolved.
pixied_pixi_latest_tag() {
    local file tag tag_entries second_tag
    if [ -n "${PIXIED_PIXI_LATEST_TAG:-}" ]; then
        pixied_pixi_validate_release_tag "$PIXIED_PIXI_LATEST_TAG"
        return 0
    fi
    pixied_temp_dir
    file="$PIXIED_TEMP_DIR/pixi.latest.json"
    pixied_pixi_download "https://api.github.com/repos/prefix-dev/pixi/releases/latest" "$file"
    tag_entries=$(
        { command grep -Eo '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' "$file" || :; } |
            sed -n 's/^"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)"$/\1/p'
    )
    [ -n "$tag_entries" ] || pixied_die "could not resolve the latest Pixi release tag"
    second_tag=$(printf '%s\n' "$tag_entries" | sed -n '2p')
    [ -z "$second_tag" ] || pixied_die "multiple latest Pixi release tags found"
    tag=$(printf '%s' "$tag_entries")
    pixied_pixi_validate_release_tag "$tag"
}

# @description Normalize a Pixi release version to a GitHub release tag.
# latest resolves to the current latest tag, and other versions gain the
# required v prefix.
#
# @arg $1 string The version, latest, or tag.
# @stdout The release tag.
# @exitcode 0 When the tag is resolved.
# @exitcode 1 When the tag cannot be resolved.
pixied_pixi_release_tag() {
    local version=$1 tag
    case "$version" in
    latest) tag=$(pixied_pixi_latest_tag) ;;
    v*) tag=$version ;;
    *) tag="v$version" ;;
    esac
    pixied_pixi_validate_release_tag "$tag"
}

# @description Return the Pixi release asset URL for a release tag.
# @arg $1 string The release tag.
# @arg $2 string The platform identifier.
# @stdout The asset URL.
# @exitcode 0 Always.
pixied_pixi_asset_url() {
    printf '%s/%s/pixi-%s.tar.gz' "$PIXIED_PIXI_RELEASE_BASE" "$1" "$2"
}

# @description Fetch the official SHA-256 digest for a Pixi release asset.
# Downloads the per-asset .sha256 file published with the release.
#
# @arg $1 string The release tag.
# @arg $2 string The platform identifier.
# @stdout The expected SHA-256 digest.
# @exitcode 0 When the digest is fetched.
# @exitcode 1 When the digest cannot be fetched.
pixied_pixi_fetch_sha256() {
    local tag=$1 platform=$2 file expected_name digest
    pixied_temp_dir
    file="$PIXIED_TEMP_DIR/pixi.sha256"
    expected_name="pixi-$platform.tar.gz"
    pixied_pixi_download "$PIXIED_PIXI_RELEASE_BASE/$tag/$expected_name.sha256" "$file"
    digest=$(sed -n 's/^\([0-9a-fA-F]\{64\}\).*/\1/p' "$file" | head -n 1)
    [ -n "$digest" ] || pixied_die "no SHA-256 digest in the official Pixi checksum for $tag"
    printf '%s' "$digest"
}

# @description Resolve the expected SHA-256 digest for the selected Pixi release asset.
# Prefers an explicit PIXIED_PIXI_SHA256, then the official per-release checksum
# when PIXIED_PIXI_VERSION is set, and finally the pinned default digest.
#
# @arg $1 string The platform identifier.
# @arg $2 string The release tag.
# @stdout The expected SHA-256 digest.
# @exitcode 0 When a digest is resolved.
# @exitcode 1 When no digest is known.
pixied_pixi_resolve_sha256() {
    local platform=$1 tag=$2
    if [ -n "${PIXIED_PIXI_SHA256:-}" ]; then
        printf '%s' "$PIXIED_PIXI_SHA256"
        return 0
    fi
    if [ -n "${PIXIED_PIXI_VERSION:-}" ]; then
        pixied_pixi_fetch_sha256 "$tag" "$platform"
        return 0
    fi
    pixied_pixi_default_sha256 "$platform"
}

# @description Verify a file against a SHA-256 digest.
# @arg $1 string The file path.
# @arg $2 string The expected digest.
# @exitcode 0 When the digest matches.
# @exitcode 1 When the digest differs.
pixied_pixi_verify_sha256() {
    local file=$1 expected=$2 actual
    [[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] ||
        pixied_die "invalid Pixi asset SHA-256 digest"
    actual=$(pixied_sha256_file "$file")
    [ "${actual,,}" = "${expected,,}" ] ||
        pixied_die "Pixi asset checksum mismatch"
}

# @description Download a Pixi asset to a temporary file.
# @arg $1 string The asset URL.
# @arg $2 string The output file.
# @exitcode 0 When the download succeeds.
# @exitcode 1 When no supported downloader is available or download fails.
pixied_pixi_download() {
    local url=$1 output=$2
    [[ "$url" == https://* ]] || pixied_die "Pixi download URL must use HTTPS"
    if pixied_have_cmd curl; then
        pixied_run curl -fsSL --proto '=https' --tlsv1.2 -o "$output" -- "$url"
    elif pixied_have_cmd wget; then
        pixied_run wget -qO "$output" --https-only --secure-protocol=TLSv1_2 -- "$url"
    else
        pixied_die "required command not found: curl or wget"
    fi
}

# @description Validate the members of a Pixi release archive.
# @arg $1 string The archive path.
# @exitcode 0 When all archive members are safe regular files or directories.
# @exitcode 1 When the archive contains an unsafe member.
pixied_pixi_validate_archive() {
    local archive=$1 listing metadata member metadata_line file_type
    listing=$(pixied_run tar -tzf "$archive")
    while IFS= read -r member; do
        case "$member" in
        "" | . | ./* | .. | ../* | */../* | */.. | /*)
            pixied_die "unsafe Pixi archive member: $member"
            ;;
        esac
    done <<<"$listing"

    metadata=$(pixied_run tar -tvzf "$archive")
    while IFS= read -r metadata_line; do
        [ -n "$metadata_line" ] || continue
        file_type=${metadata_line:0:1}
        case "$file_type" in
        - | d) ;;
        *) pixied_die "unsupported Pixi archive member type: $metadata_line" ;;
        esac
    done <<<"$metadata"
}

# @description Extract the pixi executable from a release archive.
# @arg $1 string The archive path.
# @arg $2 string The extraction directory.
# @stdout The extracted executable path.
# @exitcode 0 When the archive contains a regular pixi executable.
# @exitcode 1 When extraction fails or the executable is absent.
pixied_pixi_extract_binary() {
    local archive=$1 extraction_dir member binary
    extraction_dir=$2
    pixied_require_cmd tar
    pixied_pixi_validate_archive "$archive"
    pixied_run mkdir -p -- "$extraction_dir"
    pixied_run tar -xzf "$archive" --no-same-owner --no-same-permissions -C "$extraction_dir"
    binary=$(find "$extraction_dir" -type f -name pixi -print -quit)
    [ -n "$binary" ] || pixied_die "Pixi asset does not contain a pixi executable"
    [ ! -L "$binary" ] || pixied_die "Pixi asset contains a symlink executable"
    member=$(pixied_run realpath -m -- "$binary")
    case "$member" in
    "$extraction_dir"/*) printf '%s' "$binary" ;;
    *) pixied_die "Pixi executable escaped the extraction directory" ;;
    esac
}

# @description Check whether another machine state records the current Pixi home.
# Scans only validated state files under the current state directory and leaves
# the caller's in-memory state unchanged.
#
# @exitcode 0 When another machine records the current Pixi home.
# @exitcode 1 When no other machine records the current Pixi home.
pixied_pixi_home_is_recorded_by_other_state() {
    local machines_dir machine_dir candidate candidate_name expected key found=1
    local -A saved_state=()
    for key in "${PIXIED_STATE_KEY_ORDER[@]}"; do
        if pixied_state_has "$key"; then
            saved_state["$key"]=${PIXIED_STATE[$key]}
        fi
    done
    machines_dir="${PIXIED_STATE_DIR}/machines"
    [ -d "$machines_dir" ] || return 1
    pixied_validate_owned_path "$machines_dir"

    for machine_dir in "$machines_dir"/*; do
        [ -e "$machine_dir" ] || [ -L "$machine_dir" ] || continue
        [ ! -L "$machine_dir" ] || pixied_die "machine state directory is a symlink: $machine_dir"
        [ -d "$machine_dir" ] || pixied_die "machine state entry is not a directory: $machine_dir"
        candidate="$machine_dir/state"
        if [ ! -e "$candidate" ] && [ ! -L "$candidate" ]; then
            continue
        fi
        [ ! -L "$candidate" ] || pixied_die "machine state file is a symlink: $candidate"
        candidate_name=${machine_dir##*/}
        [ "$candidate_name" != "$PIXIED_MACHINE_ID" ] || continue
        pixied_machine_id_is_safe "$candidate_name" ||
            pixied_die "unsafe machine state directory name: $candidate_name"
        expected=$(pixied_canonical_path "$candidate")
        [ "$candidate" = "$expected" ] || pixied_die "machine state path is not canonical: $candidate"
        pixied_state_load_external "$candidate"
        [ "${PIXIED_STATE[machine_id]}" = "$candidate_name" ] ||
            pixied_die "machine state ID does not match its directory: $candidate"
        [ "${PIXIED_STATE[state_dir]}" = "$PIXIED_STATE_DIR" ] ||
            pixied_die "machine state uses a different state directory: $candidate"
        if [ "${PIXIED_STATE[pixi_home]:-}" = "$PIXIED_PIXI_HOME" ]; then
            found=0
            break
        fi
    done

    PIXIED_STATE=()
    for key in "${PIXIED_STATE_KEY_ORDER[@]}"; do
        if [ "${saved_state[$key]+present}" = present ]; then
            pixied_state_set "$key" "${saved_state[$key]}"
        fi
    done
    return "$found"
}

# @description Validate the ownership boundary of an existing Pixi home.
# A new path, the current installation's recorded path, or a path recorded by
# another validated machine state may be used. Other existing paths are never
# provisioned with PixiEden Global packages.
#
# @arg $1 integer Whether the current installation created the path.
# @exitcode 0 When the Pixi home is safe to use.
# @exitcode 1 When an existing Pixi home is unverified or unsafe.
pixied_pixi_validate_home_boundary() {
    local created=${1:-0}
    if [ -e "$PIXIED_PIXI_HOME" ] || [ -L "$PIXIED_PIXI_HOME" ]; then
        if ! [ -d "$PIXIED_PIXI_HOME" ] || [ -L "$PIXIED_PIXI_HOME" ]; then
            pixied_die "dedicated Pixi home is not a regular directory: $PIXIED_PIXI_HOME"
        fi
        pixied_validate_owned_path "$PIXIED_PIXI_HOME"
        if [ "$created" -eq 1 ] &&
            [ "${PIXIED_STATE[pixi_home]:-}" = "$PIXIED_PIXI_HOME" ]; then
            return 0
        fi
        if pixied_pixi_home_is_recorded_by_other_state; then
            return 0
        fi
        pixied_die "refusing to use an unverified existing Pixi home: $PIXIED_PIXI_HOME"
    fi
}

# @description Adopt a shared Pixi binary recorded by another machine state.
# An existing binary is reusable only when an independently parsed state file
# records the exact path and matching hash. The current in-memory state is
# restored before returning so the caller can continue its own install.
#
# @arg $1 string The expected shared Pixi binary path.
# @exitcode 0 When a trusted shared binary was adopted.
# @exitcode 1 When no trusted state records the binary.
pixied_pixi_adopt_shared_binary() {
    local target=$1 machines_dir machine_dir candidate candidate_name expected actual key
    local shared_created_data shared_created_pixi_home shared_pixi_home
    local -A saved_state=()
    for key in "${PIXIED_STATE_KEY_ORDER[@]}"; do
        if pixied_state_has "$key"; then
            saved_state["$key"]=${PIXIED_STATE[$key]}
        fi
    done
    target=$(pixied_validate_canonical_path "$target")
    machines_dir="${PIXIED_STATE_DIR}/machines"
    [ -d "$machines_dir" ] || return 1
    pixied_validate_owned_path "$machines_dir"

    for machine_dir in "$machines_dir"/*; do
        [ -e "$machine_dir" ] || [ -L "$machine_dir" ] || continue
        [ ! -L "$machine_dir" ] || pixied_die "machine state directory is a symlink: $machine_dir"
        [ -d "$machine_dir" ] || pixied_die "machine state entry is not a directory: $machine_dir"
        candidate="$machine_dir/state"
        if [ ! -e "$candidate" ] && [ ! -L "$candidate" ]; then
            continue
        fi
        [ ! -L "$candidate" ] || pixied_die "machine state file is a symlink: $candidate"
        candidate_name=${machine_dir##*/}
        pixied_machine_id_is_safe "$candidate_name" ||
            pixied_die "unsafe machine state directory name: $candidate_name"
        expected=$(pixied_canonical_path "$candidate")
        [ "$candidate" = "$expected" ] || pixied_die "machine state path is not canonical: $candidate"
        pixied_state_load_external "$candidate"
        [ "${PIXIED_STATE[machine_id]}" = "$candidate_name" ] ||
            pixied_die "machine state ID does not match its directory: $candidate"
        [ "${PIXIED_STATE[state_dir]}" = "$PIXIED_STATE_DIR" ] ||
            pixied_die "machine state uses a different state directory: $candidate"
        expected="${PIXIED_STATE[data_dir]}/bin/pixi"
        if [ "${PIXIED_STATE[pixi_binary_path]:-}" = "$target" ] &&
            [ -n "${PIXIED_STATE[pixi_binary_hash]:-}" ] &&
            pixied_hash_matches "$target" "${PIXIED_STATE[pixi_binary_hash]}"; then
            pixied_validate_owned_path "$target" "${PIXIED_STATE[pixi_binary_hash]}"
            actual=${PIXIED_STATE[pixi_binary_hash]}
            shared_created_data=${PIXIED_STATE[created_data]:-0}
            shared_created_pixi_home=${PIXIED_STATE[created_pixi_home]:-0}
            shared_pixi_home=${PIXIED_STATE[pixi_home]:-}
            PIXIED_STATE=()
            for key in "${PIXIED_STATE_KEY_ORDER[@]}"; do
                if [ "${saved_state[$key]+present}" = present ]; then
                    pixied_state_set "$key" "${saved_state[$key]}"
                fi
            done
            if [ "$shared_created_data" -eq 1 ]; then
                pixied_state_set created_data 1
            fi
            if [ "$shared_created_pixi_home" -eq 1 ] &&
                [ "$shared_pixi_home" = "$PIXIED_PIXI_HOME" ]; then
                pixied_state_set created_pixi_home 1
            fi
            PIXIED_PIXI_BINARY_HASH=$actual
            export PIXIED_PIXI_BINARY_HASH
            return 0
        fi
    done

    PIXIED_STATE=()
    for key in "${PIXIED_STATE_KEY_ORDER[@]}"; do
        if [ "${saved_state[$key]+present}" = present ]; then
            pixied_state_set "$key" "${saved_state[$key]}"
        fi
    done
    return 1
}

# @description Install the verified Pixi binary into the dedicated data directory.
# Reuses an existing binary only when the current state contains a matching hash.
#
# @set PIXIED_PIXI_BINARY_PATH string The installed Pixi binary path.
# @set PIXIED_PIXI_BINARY_HASH string The installed Pixi binary hash.
# @exitcode 0 When the binary is installed or safely reused.
# @exitcode 1 When verification or installation fails.
pixied_pixi_install_binary() {
    local target_dir archive extraction_dir source_binary expected actual temporary
    target_dir=$PIXIED_DATA_DIR/bin
    export PIXIED_PIXI_BINARY_PATH=$target_dir/pixi
    pixied_run mkdir -p -- "$target_dir" "$PIXIED_PIXI_HOME"

    if [ -e "$PIXIED_PIXI_BINARY_PATH" ] || [ -L "$PIXIED_PIXI_BINARY_PATH" ]; then
        if [ ! -L "$PIXIED_PIXI_BINARY_PATH" ] && [ -x "$PIXIED_PIXI_BINARY_PATH" ] &&
            pixied_state_has pixi_binary_path &&
            [ "${PIXIED_STATE[pixi_binary_path]}" = "$PIXIED_PIXI_BINARY_PATH" ] &&
            pixied_state_has pixi_binary_hash &&
            [ -n "${PIXIED_STATE[pixi_binary_hash]:-}" ] &&
            pixied_hash_matches "$PIXIED_PIXI_BINARY_PATH" "${PIXIED_STATE[pixi_binary_hash]}"; then
            PIXIED_PIXI_BINARY_HASH=${PIXIED_STATE[pixi_binary_hash]}
            export PIXIED_PIXI_BINARY_HASH
            return 0
        fi
        if pixied_pixi_adopt_shared_binary "$PIXIED_PIXI_BINARY_PATH"; then
            return 0
        fi
        pixied_die "refusing to adopt or replace an unverified Pixi binary: $PIXIED_PIXI_BINARY_PATH"
    fi

    pixied_temp_dir
    archive="$PIXIED_TEMP_DIR/pixi.asset"
    extraction_dir="$PIXIED_TEMP_DIR/extracted"
    if [ -n "${PIXIED_PIXI_BINARY_SOURCE:-}" ]; then
        source_binary=$PIXIED_PIXI_BINARY_SOURCE
        if ! [ -f "$source_binary" ] || [ -L "$source_binary" ] || ! [ -x "$source_binary" ]; then
            pixied_die "Pixi binary source is not an executable regular file: $source_binary"
        fi
        pixied_run cp -- "$source_binary" "$archive"
        expected=${PIXIED_PIXI_SHA256:-}
        if [ -z "$expected" ]; then
            expected=$(pixied_sha256_file "$source_binary")
        fi
        source_binary=$archive
    else
        local platform tag
        platform=$(pixied_pixi_platform)
        tag=$(pixied_pixi_release_tag "${PIXIED_PIXI_VERSION:-$PIXIED_PIXI_VERSION_DEFAULT}")
        expected=$(pixied_pixi_resolve_sha256 "$platform" "$tag")
        [ -n "$expected" ] || pixied_die "no trusted Pixi checksum is configured for $platform"
        if [ -n "${PIXIED_PIXI_ASSET_PATH:-}" ]; then
            if ! [ -f "$PIXIED_PIXI_ASSET_PATH" ] || [ -L "$PIXIED_PIXI_ASSET_PATH" ]; then
                pixied_die "Pixi asset path is not a regular file: $PIXIED_PIXI_ASSET_PATH"
            fi
            pixied_run cp -- "$PIXIED_PIXI_ASSET_PATH" "$archive"
        else
            pixied_pixi_download "${PIXIED_PIXI_ASSET_URL:-$(pixied_pixi_asset_url "$tag" "$platform")}" "$archive"
        fi
        source_binary=$archive
    fi
    pixied_pixi_verify_sha256 "$archive" "$expected"

    if pixied_run tar -tzf "$archive" >/dev/null 2>&1; then
        source_binary=$(pixied_pixi_extract_binary "$archive" "$extraction_dir")
    fi
    if ! [ -f "$source_binary" ] || [ -L "$source_binary" ] || ! [ -x "$source_binary" ]; then
        pixied_die "verified Pixi asset is not an executable regular file"
    fi
    actual=$(pixied_sha256_file "$source_binary")
    temporary=$(pixied_run mktemp --tmpdir="$target_dir" .pixi.XXXXXX)
    pixied_register_temp "$temporary"
    pixied_run cp -- "$source_binary" "$temporary"
    pixied_run chmod 0755 -- "$temporary"
    pixied_run mv -f -- "$temporary" "$PIXIED_PIXI_BINARY_PATH"
    PIXIED_PIXI_BINARY_HASH=$actual
    export PIXIED_PIXI_BINARY_HASH
}

# @description Run the dedicated Pixi binary with isolated runtime variables.
# @arg $@ string Pixi arguments.
# @stdout The Pixi command output.
# @exitcode The Pixi command exit status.
pixied_pixi_run() {
    [ -x "${PIXIED_PIXI_BINARY_PATH:-}" ] ||
        pixied_die "dedicated Pixi binary is not executable"
    pixied_run env HOME="$PIXIED_LOCAL_HOME" PIXI_HOME="$PIXIED_PIXI_HOME" \
        PIXI_CACHE_DIR="$PIXIED_PIXI_HOME/cache" PIXI_NO_PATH_UPDATE=1 \
        "$PIXIED_PIXI_BINARY_PATH" "$@"
}

# @description Return the exposed path for a Pixi Global package.
# @arg $1 string The package name.
# @stdout The expected executable path.
# @exitcode 0 Always.
pixied_pixi_global_binary_path() {
    printf '%s/bin/%s' "$PIXIED_PIXI_HOME" "$1"
}

# @description Install and verify a required Pixi Global package.
# @arg $1 string The package name.
# @exitcode 0 When the package is installed and exposed.
# @exitcode 1 When Pixi cannot install or expose the package.
pixied_pixi_global_install() {
    local package=$1 package_path
    package_path=$(pixied_pixi_global_binary_path "$package")
    pixied_step "Installing Pixi Global package: $package"
    pixied_pixi_run global install "$package"
    [ -x "$package_path" ] ||
        pixied_die "Pixi Global package was not exposed at $package_path"
    case "$package" in
    direnv) export PIXIED_DIRENV_PATH=$package_path ;;
    zellij) export PIXIED_ZELLIJ_PATH=$package_path ;;
    esac
}

# @description Install the Phase 2 Pixi Global packages.
# direnv is always installed; zellij is installed only for the zellij session mode.
#
# @set PIXIED_DIRENV_PATH string The dedicated direnv path.
# @set PIXIED_ZELLIJ_PATH string The dedicated zellij path when enabled.
# @exitcode 0 When the dedicated environment is ready.
# @exitcode 1 When provisioning fails.
pixied_pixi_provision_globals() {
    pixied_pixi_run --version >/dev/null
    pixied_pixi_global_install direnv
    if [ "$PIXIED_SESSION_MANAGER" = zellij ]; then
        pixied_pixi_global_install zellij
    fi
}

# @description Install the dedicated Pixi binary and Phase 2 Global packages.
# @exitcode 0 When the dedicated environment is ready.
# @exitcode 1 When provisioning fails.
pixied_pixi_provision() {
    pixied_pixi_install_binary
    pixied_pixi_provision_globals
}
