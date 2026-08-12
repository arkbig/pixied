#!/usr/bin/env bash
# Create the release git tag from the PixiEden version in the CLI source.
# The tag name is derived from PIXIED_VERSION in bin/pixied so that the git
# tag and the packaged version cannot drift.

set -Eeuo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly REPO_ROOT
readonly VERSION_SOURCE="$REPO_ROOT/bin/pixied"
readonly VERSION_RE='^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$'

DRY_RUN=0
PUSH=0

# @description Print a tagging error and terminate.
# @arg $@ string The error message.
# @stderr The error message.
# @exitcode 1 Always.
fail() {
    printf '[tag-release] ERROR: %s\n' "$*" >&2
    exit 1
}

# @description Print an informational message.
# @arg $@ string The message.
# @stdout The message.
info() {
    printf '[tag-release] %s\n' "$*"
}

# @description Print the usage to standard output.
# @stdout The usage message.
usage() {
    cat <<'USAGE'
Usage: scripts/tag-release.sh [--dry-run] [--push]

Create the annotated release tag v<version> from PIXIED_VERSION in bin/pixied.
Fails when the working tree has uncommitted changes or the derived tag already
exists, so an already released version is never re-tagged.

Options:
    --dry-run  Validate the version, the working tree, and the tag only.
    --push     Push the tag to origin after creating it.
    --help     Show this help.
USAGE
}

# @description Resolve the version from the CLI entry point.
# @stdout The version string.
# @exitcode 1 When the version cannot be resolved to a semantic version.
get_version() {
    local version
    version=$(awk -F'"' '/^PIXIED_VERSION=/{print $2; exit}' "$VERSION_SOURCE")
    if [[ "$version" =~ $VERSION_RE ]]; then
        printf '%s\n' "$version"
    else
        fail "invalid version in $VERSION_SOURCE: '$version'"
    fi
}

# @description Verify that no tracked files have uncommitted changes.
# Untracked files are ignored because release inputs such as plan.md and
# tasks.md are intentionally not managed by git.
# @exitcode 1 When tracked files are modified, staged, or deleted.
assert_clean_tree() {
    local status
    status=$(git -C "$REPO_ROOT" status --porcelain --untracked-files=no)
    if [ -n "$status" ]; then
        fail "the working tree has uncommitted changes; commit them before tagging"
    fi
}

# @description Verify that the derived tag does not exist locally or on origin.
# @arg $1 string The tag name to verify.
# @exitcode 1 When the tag already exists locally.
# @exitcode 1 When the tag already exists on origin and push was requested.
assert_tag_absent() {
    local tag=$1 remote
    if git -C "$REPO_ROOT" rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
        fail "tag $tag already exists locally; bump PIXIED_VERSION in bin/pixied"
    fi
    if [ "$PUSH" -eq 1 ]; then
        if ! remote=$(git -C "$REPO_ROOT" ls-remote --tags origin "$tag" 2>&1); then
            fail "could not query origin for tag $tag: $remote"
        fi
        if [ -n "$remote" ]; then
            fail "tag $tag already exists on origin; bump PIXIED_VERSION in bin/pixied"
        fi
    fi
}

# @description Create the release tag or validate the release state.
# @arg $@ string Optional flags: --dry-run, --push, --help.
# @stdout Progress and result messages.
# @exitcode 0 When the tag is created or the dry run succeeds.
# @exitcode 1 When validation fails or tagging fails.
main() {
    local arg version tag head
    for arg in "$@"; do
        case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --push) PUSH=1 ;;
        --help | -h)
            usage
            exit 0
            ;;
        *) fail "unknown option: $arg" ;;
        esac
    done

    version=$(get_version)
    tag="v$version"
    assert_clean_tree
    assert_tag_absent "$tag"

    if [ "$DRY_RUN" -eq 1 ]; then
        info "tag $tag is ready for creation at HEAD"
        [ "$PUSH" -eq 1 ] && info "would push $tag to origin after creation"
        exit 0
    fi

    head=$(git -C "$REPO_ROOT" rev-parse --short HEAD)
    git -C "$REPO_ROOT" tag -a "$tag" -m "PixiEden $version"
    info "created annotated tag $tag at $head"
    if [ "$PUSH" -eq 1 ]; then
        git -C "$REPO_ROOT" push origin "$tag"
        info "pushed $tag to origin"
    else
        info "tag not pushed; run with --push or: git push origin $tag"
    fi
}

main "$@"
