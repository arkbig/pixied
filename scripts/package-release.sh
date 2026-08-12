#!/usr/bin/env bash
# Build the deployable PixiEden release archive.

set -Eeuo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly REPO_ROOT
readonly RELEASE_ROOT=pixied

# @description Print a packaging error and terminate.
# @arg $@ string The error message.
# @stderr The error message.
# @exitcode 1 Always.
fail() {
    printf '[pixied/package-release] ERROR: %s\n' "$*" >&2
    exit 1
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
        install-local.sh
        bin
        lib
        README.md
        README.ja.md
        docs
    )

    output_dir=$(dirname "$output")
    mkdir -p "$output_dir"
    validate_release_paths "${release_paths[@]}"
    tar -czf "$output" \
        --sort=name \
        --mtime=@0 \
        --owner=0 \
        --group=0 \
        --numeric-owner \
        --transform="s,^,$RELEASE_ROOT/," \
        -C "$REPO_ROOT" \
        "${release_paths[@]}"
    checksum_file="$output.sha256"
    sha256sum "$output" |
        awk -v name="$(basename "$output")" '{print $1 "  " name}' >"$checksum_file"
    printf '%s\n' "$output"
}

main "$@"
