#!/usr/bin/env bash
# Download the latest PixiEden release and delegate deployment to its installer.

set -Eeuo pipefail

readonly PIXIED_RELEASE_URL="${PIXIED_RELEASE_URL:-https://github.com/arkbig/pixied/releases/latest/download/pixied.tar.gz}"
PIXIED_INSTALL_TEMPORARY_DIR=""

# @description Print the release installer usage and available installation options.
# @stdout The installer help message.
# @exitcode 0 Always.
print_help() {
    cat <<'USAGE'
Usage: install.sh [OPTIONS]

Download the latest PixiEden release and install it locally.

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

# @description Print an installer error and terminate.
# @arg $@ string The error message.
# @stderr The error message.
# @exitcode 1 Always.
fail() {
    printf '[pixied/install] ERROR: %s\n' "$*" >&2
    exit 1
}

# @description Download the configured PixiEden release archive.
# @arg $1 string The destination archive path.
# @exitcode 0 When the archive is downloaded.
# @exitcode 1 When no supported downloader is available or the download fails.
download_release() {
    local destination=$1 url=${2:-$PIXIED_RELEASE_URL}
    if command -v curl >/dev/null 2>&1; then
        curl --fail --silent --show-error --location \
            --proto '=https' --tlsv1.2 \
            --output "$destination" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget --quiet --https-only --output-document="$destination" \
            "$url"
    else
        fail 'curl or wget is required'
    fi
}

# @description Verify a downloaded release archive against its checksum asset.
# @arg $1 string The downloaded archive path.
# @arg $2 string The downloaded checksum path.
# @exitcode 0 When the checksum is valid and matches the archive.
# @exitcode 1 When the checksum is malformed or does not match.
verify_release_checksum() {
    local archive=$1 checksum_file=$2 expected_name expected_digest checksum_line checksum_line_count
    expected_name=${PIXIED_RELEASE_URL##*/}
    checksum_line_count=$(awk 'END { print NR }' "$checksum_file")
    [ "$checksum_line_count" -eq 1 ] || fail 'release checksum is malformed'
    checksum_line=$(sed -n \
        's/^\([0-9a-fA-F]\{64\}\)[[:space:]][[:space:]]*\([^[:space:]]*\)$/\1 \2/p' \
        "$checksum_file")
    [ -n "$checksum_line" ] ||
        fail 'release checksum is malformed'
    expected_digest=${checksum_line%% *}
    checksum_name=${checksum_line#* }
    [ "$checksum_name" = "$expected_name" ] ||
        fail 'release checksum names a different archive'
    actual_digest=$(sha256sum "$archive" | sed -n 's/^\([0-9a-fA-F]\{64\}\).*/\1/p')
    [ "${actual_digest,,}" = "${expected_digest,,}" ] ||
        fail 'release archive checksum mismatch'
}

# @description Locate the local installer inside an extracted release archive.
# @arg $1 string The extraction directory.
# @stdout The absolute path to install-local.sh.
# @exitcode 0 When the installer is found.
# @exitcode 1 When the archive does not contain the installer.
find_release_installer() {
    local extraction_dir=$1
    local installer="$extraction_dir/pixied/install-local.sh"
    [ -f "$installer" ] || fail 'release archive does not contain pixied/install-local.sh'
    printf '%s\n' "$installer"
}

# @description Remove the temporary release extraction directory.
# @exitcode 0 Always.
cleanup() {
    [ -n "$PIXIED_INSTALL_TEMPORARY_DIR" ] || return 0
    rm -rf -- "$PIXIED_INSTALL_TEMPORARY_DIR"
}

# @description Download, extract, and run the PixiEden release installer.
# @arg $@ string Installation options forwarded to install-local.sh.
# @exitcode The release installer status.
main() {
    if [ "$#" -eq 1 ] && [ "$1" = '--help' ]; then
        print_help
        return 0
    fi

    local archive checksum_file extraction_dir installer
    command -v mktemp >/dev/null 2>&1 || fail 'mktemp is required'
    command -v tar >/dev/null 2>&1 || fail 'tar is required'

    PIXIED_INSTALL_TEMPORARY_DIR=$(mktemp -d)
    trap cleanup EXIT

    archive="$PIXIED_INSTALL_TEMPORARY_DIR/pixied.tar.gz"
    checksum_file="$PIXIED_INSTALL_TEMPORARY_DIR/pixied.tar.gz.sha256"
    extraction_dir="$PIXIED_INSTALL_TEMPORARY_DIR/extracted"
    mkdir -p "$extraction_dir"
    printf '[pixied/install] Downloading release\n' >&2
    download_release "$archive"
    download_release "$checksum_file" "$PIXIED_RELEASE_URL.sha256"
    verify_release_checksum "$archive" "$checksum_file"
    tar -xzf "$archive" -C "$extraction_dir"
    installer=$(find_release_installer "$extraction_dir")
    bash "$installer" "$@"
}

main "$@"
