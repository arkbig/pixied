#!/usr/bin/env bats

# Docker-dependent tests for generated Dev Container artifacts. These require a
# working Docker runtime with network access and are intentionally separated from
# tests/integration.bats so the fast, hermetic suite can run without Docker. The
# release gate runs this file (e.g. `bats tests/generate-docker.bats`).

# @description Initialize repository and isolated default environment for this test file.
# @set PIXIED_REPO_ROOT string Absolute path to the repository root.
# @set PIXIED_TEST_ROOT string Shared temporary directory for the test file.
setup_file() {
    export PIXIED_REPO_ROOT
    PIXIED_REPO_ROOT=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
    export PIXIED_TEST_ROOT="$BATS_FILE_TMPDIR"

    # WSL-specific behavior is disabled because PixiEden does not manage system services.
    export PIXIED_WSL=0

    if ! command -v docker >/dev/null 2>&1; then
        skip "docker is not available"
    fi
}

# @description Print a diagnostic and fail the current test.
# @arg $@ string The failure message.
# @stderr The failure message.
# @exitcode 1 Always.
pixied_test_fail() {
    printf 'FAIL: %s\n' "$*" >&2
    return 1
}

# @description Assert that the most recent Bats command succeeded.
# @arg $1 string Optional context for the failure message.
# @exitcode 0 When the command returned zero.
# @exitcode 1 When the command returned a non-zero status.
assert_success() {
    local context=${1:-command}
    [ "${status:-}" -eq 0 ] ||
        pixied_test_fail "expected successful $context, got status ${status:-unset}: ${output:-}"
}

# @description Assert that the most recent Bats command returned a failure status.
# @arg $1 integer Expected failure status.
# @exitcode 0 When the command returned the expected failure status.
# @exitcode 1 When the command returned another status.
assert_failure() {
    local expected=${1:-1}
    [ "${status:-}" -eq "$expected" ] ||
        pixied_test_fail "expected status $expected, got ${status:-unset}: ${output:-}"
}

# @description Assert that the most recent Bats command produced expected output.
# @arg $1 string The '--partial' option or an exact expected value.
# @arg $2 string Expected output when '--partial' is used.
# @exitcode 0 When output matches.
# @exitcode 1 When output differs.
assert_output() {
    if [ "${1:-}" = --partial ]; then
        local expected=${2:-}
        [[ "${output:-}" == *"$expected"* ]] ||
            pixied_test_fail "expected output to contain '$expected', got '${output:-}'"
    else
        [ "${1:-}" = "${output:-}" ] ||
            pixied_test_fail "expected '${1:-}', got '${output:-}'"
    fi
}

# @description Generate a devcontainer and return the project path plus a unique tag.
# @arg $1 string Test name used to derive unique directories and image tag.
# @stdout "project tag" on success (caller reads via $output or inline).
generate_devcontainer_for_test() {
    local name=$1
    local cli="$PIXIED_REPO_ROOT/bin/pixied"
    local home="$PIXIED_TEST_ROOT/${name}-home"
    local project="$PIXIED_TEST_ROOT/${name}-project"
    local tag="pixied-test-${name}"
    mkdir -p "$home" "$project"
    printf '[workspace]\nname = "sample"\nchannels = ["conda-forge"]\nplatforms = ["linux-64"]\n' >"$project/pixi.toml"
    env HOME="$home" bash -c \
        'cd -- "$1" && bash "$2" generate devcontainer' bash "$project" "$cli"
    printf '%s\n%s\n' "$project" "$tag"
}

@test "generate devcontainer builds and runs with a mounted workspace" {
    command -v docker >/dev/null 2>&1 || skip "docker is not available"
    local project tag
    project=$(generate_devcontainer_for_test dcbuild | sed -n '1p')
    tag=pixied-test-dcbuild
    trap 'docker rmi -f "$tag" >/dev/null 2>&1 || true' EXIT
    printf '[workspace]\nname = "sample"\nchannels = ["conda-forge"]\nplatforms = ["linux-64"]\n' >"$project/pixi.toml"
    # Override the host-derived uid/gid so the build is deterministic regardless of
    # the test runner's own uid (a root runner would break useradd --uid 0).
    printf 'CONTAINER_UID=1000\nCONTAINER_GID=1000\n' >"$project/.devcontainer/.env"

    run docker build -f "$project/.devcontainer/Dockerfile" -t "$tag" "$project"
    assert_success

    run docker run --rm -v "$project":/workspace -w /workspace "$tag" id -u
    assert_success
    [ "$output" = "1000" ] || pixied_test_fail "container UID did not match the configured UID"

    run docker run --rm -v "$project":/workspace -w /workspace "$tag" id -g
    assert_success
    [ "$output" = "1000" ] || pixied_test_fail "container GID did not match the configured GID"

    run docker run --rm -v "$project":/workspace -w /workspace "$tag" bash -c 'echo "$PIXI_HOME"'
    assert_success
    [ "$output" = "/opt/pixi" ] || pixied_test_fail "container did not forward PIXI_HOME=/opt/pixi"

    run docker run --rm -v "$project":/workspace -w /workspace "$tag" bash -c 'echo "$PATH"'
    assert_success
    printf '%s\n' "$output" | grep -q -- '/opt/pixi/bin' ||
        pixied_test_fail "container PATH did not include /opt/pixi/bin"
}

@test "generate devcontainer entrypoint fails when .env is missing" {
    command -v docker >/dev/null 2>&1 || skip "docker is not available"
    local project tag empty
    project=$(generate_devcontainer_for_test dcenv | sed -n '1p')
    tag=pixied-test-dcenv
    empty="$PIXIED_TEST_ROOT/dcenv-empty"
    mkdir -p "$empty"
    trap 'docker rmi -f "$tag" >/dev/null 2>&1 || true' EXIT
    printf '[workspace]\nname = "sample"\nchannels = ["conda-forge"]\nplatforms = ["linux-64"]\n' >"$project/pixi.toml"
    printf 'CONTAINER_UID=1000\nCONTAINER_GID=1000\n' >"$project/.devcontainer/.env"

    run docker build -f "$project/.devcontainer/Dockerfile" -t "$tag" "$project"
    assert_success

    run docker run --rm -v "$empty":/workspace "$tag"
    assert_failure
    assert_output --partial 'is missing'
}

# PXD-010: the Dev Container Dockerfile must build whether or not pixi.toml /
# pixi.lock are present, because the COPY uses wildcards (pixi.tom[l] pixi.loc[k]).
@test "generate devcontainer builds with only pixi.toml (no lock)" {
    command -v docker >/dev/null 2>&1 || skip "docker is not available"
    local project tag
    project=$(generate_devcontainer_for_test tomlonly | sed -n '1p')
    tag=pixied-test-tomlonly
    trap 'docker rmi -f "$tag" >/dev/null 2>&1 || true' EXIT
    printf '[workspace]\nname = "sample"\nchannels = ["conda-forge"]\nplatforms = ["linux-64"]\n' >"$project/pixi.toml"
    printf 'CONTAINER_UID=1000\nCONTAINER_GID=1000\n' >"$project/.devcontainer/.env"

    run docker build -f "$project/.devcontainer/Dockerfile" -t "$tag" "$project"
    assert_success
}

@test "generate devcontainer builds with only pixi.lock (no toml)" {
    command -v docker >/dev/null 2>&1 || skip "docker is not available"
    local project tag
    project=$(generate_devcontainer_for_test lockonly | sed -n '1p')
    tag=pixied-test-lockonly
    trap 'docker rmi -f "$tag" >/dev/null 2>&1 || true' EXIT
    printf 'version\n1.2.3\n' >"$project/pixi.lock"
    rm -f -- "$project/pixi.toml"
    printf 'CONTAINER_UID=1000\nCONTAINER_GID=1000\n' >"$project/.devcontainer/.env"

    run docker build -f "$project/.devcontainer/Dockerfile" -t "$tag" "$project"
    assert_success
}

@test "generate devcontainer builds with neither pixi.toml nor pixi.lock" {
    command -v docker >/dev/null 2>&1 || skip "docker is not available"
    local project tag
    project=$(generate_devcontainer_for_test neither | sed -n '1p')
    tag=pixied-test-neither
    trap 'docker rmi -f "$tag" >/dev/null 2>&1 || true' EXIT
    rm -f -- "$project/pixi.toml" "$project/pixi.lock"
    printf 'CONTAINER_UID=1000\nCONTAINER_GID=1000\n' >"$project/.devcontainer/.env"

    run docker build -f "$project/.devcontainer/Dockerfile" -t "$tag" "$project"
    assert_success
}
