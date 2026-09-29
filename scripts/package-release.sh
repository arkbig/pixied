#!/usr/bin/env bash
# Build the deployable PixiEden release archive.

set -Eeuo pipefail
umask 022

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly REPO_ROOT
readonly RELEASE_ROOT=pixied
PACKAGE_STAGE_DIR=""

# shellcheck disable=SC1091
. "$REPO_ROOT/lib/release.sh"

# @description Print a packaging error and terminate.
# @arg $@ string The error message.
# @stderr The error message.
# @exitcode 1 Always.
fail() {
    printf '[pixied/package-release] ERROR: %s\n' "$*" >&2
    exit 1
}

# @description Remove the temporary package manifest directory.
# @exitcode 0 Always.
cleanup() {
    [ -n "$PACKAGE_STAGE_DIR" ] || return 0
    rm -rf -- "$PACKAGE_STAGE_DIR"
}

# @description Verify that every required release path exists.
# @arg $@ string Release-relative paths.
# @exitcode 0 When all paths are present.
# @exitcode 1 When a required path is missing.
validate_release_paths() {
    local path
    for path in "$@"; do
        [ -e "$REPO_ROOT/$path" ] || fail "required release path is missing: $path"
    done
}

# @description Create a deployable archive from the repository release inputs.
# @arg $1 string Optional output archive path.
# @stdout The created archive path.
# @exitcode 0 When packaging succeeds.
# @exitcode 1 When a required release path or archive operation fails.
main() {
    local output=${1:-$REPO_ROOT/dist/pixied.tar.gz}
    local output_dir checksum_file
    local -a release_paths=(
        README.md
        README.ja.md
        docs
    )

    output_dir=$(dirname "$output")
    mkdir -p "$output_dir"
    pixied_release_payload_paths "$REPO_ROOT"
    release_paths=("${PIXIED_RELEASE_PAYLOAD_PATHS[@]}" "${release_paths[@]}")
    validate_release_paths "${release_paths[@]}"
    PACKAGE_STAGE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/pixied-package.XXXXXX")
    trap cleanup EXIT
    pixied_release_generate_manifest "$REPO_ROOT" "$PACKAGE_STAGE_DIR/release-manifest"
    tar -czf "$output" \
        --sort=name \
        --mtime=@0 \
        --owner=0 \
        --group=0 \
        --numeric-owner \
        --transform="s,^,$RELEASE_ROOT/," \
        -C "$REPO_ROOT" \
        "${release_paths[@]}" \
        -C "$PACKAGE_STAGE_DIR" release-manifest
    checksum_file="$output.sha256"
    sha256sum "$output" |
        awk -v name="$(basename "$output")" '{print $1 "  " name}' >"$checksum_file"
    printf '%s\n' "$output"
}

main "$@"
