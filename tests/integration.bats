#!/usr/bin/env bats

# @description Initialize repository and isolated default environment for this test file.
# @set PIXIED_REPO_ROOT string Absolute path to the repository root.
# @set PIXIED_TEST_ROOT string Shared temporary directory for the test file.
setup_file() {
    export PIXIED_REPO_ROOT
    PIXIED_REPO_ROOT=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
    export PIXIED_TEST_ROOT="$BATS_FILE_TMPDIR"

    # WSL-specific behavior is disabled because PixiEden does not manage system services.
    export PIXIED_WSL=0
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

# @description Assert that two strings are equal.
# @arg $1 string Expected value.
# @arg $2 string Actual value.
# @exitcode 0 When the values are equal.
# @exitcode 1 When the values differ.
assert_equal() {
    local expected=$1 actual=$2
    [ "$expected" = "$actual" ] ||
        pixied_test_fail "expected '$expected', got '$actual'"
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
        assert_equal "${1:-}" "${output:-}"
    fi
}

# @description Create fake external commands used by observability tests.
# @arg $1 string Directory in which to create fake command links.
setup_fake_commands() {
    local fake_bin=$1 command_name
    mkdir -p "$fake_bin"
    for command_name in pixi zellij; do
        ln -s "$PIXIED_REPO_ROOT/tests/fakes/external-command" "$fake_bin/$command_name"
    done
}

# @description Extract the version assignment from a pixied script.
# @arg $1 string Path to the pixied script.
# @stdout The version value.
pixied_version_from_source() {
    sed -n 's/^PIXIED_VERSION="\([^"]*\)"/\1/p' "$1" | head -n 1
}

# @description Assert that a version string follows semantic versioning.
# @arg $1 string Version string without the command name.
# @exitcode 0 When the version is valid.
# @exitcode 1 When the version is invalid.
assert_semver() {
    local version=$1
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
        pixied_test_fail "unexpected version format: $version"
}

@test "static analysis passes" {
    local -a scripts
    mapfile -t scripts < <(find "$PIXIED_REPO_ROOT" -type f -name '*.sh' -print | sort)

    run bash -n "${scripts[@]}"
    assert_success
    if command -v shellcheck >/dev/null 2>&1; then
        run shellcheck -x "${scripts[@]}"
        assert_success
    else
        printf 'SKIP: shellcheck is not installed\n'
    fi
    if command -v shfmt >/dev/null 2>&1; then
        run shfmt -f "${scripts[@]}"
        assert_success
    else
        printf 'SKIP: shfmt is not installed\n'
    fi
}

@test "CLI contract is stable" {
    local cli="$PIXIED_REPO_ROOT/bin/pixied"
    local home="$PIXIED_TEST_ROOT/cli-home"
    local data="$PIXIED_TEST_ROOT/cli-data"
    local config="$PIXIED_TEST_ROOT/cli-config"
    local state="$PIXIED_TEST_ROOT/cli-state"
    local expected_version
    mkdir -p "$home"
    expected_version="pixied $(pixied_version_from_source "$cli")"
    assert_semver "${expected_version#pixied }"

    run bash "$cli" version
    assert_success
    assert_equal "$expected_version" "$output"

    run bash "$cli" help
    assert_success
    assert_output --partial 'Runtime activation uses the dedicated Pixi environment and starts an isolated child process.'

    run bash "$cli" unknown
    assert_failure 2
    assert_output --partial 'unknown command: unknown'

    run env HOME="$home" XDG_DATA_HOME="$data" XDG_CONFIG_HOME="$config" \
        XDG_STATE_HOME="$state" PIXIED_HOME_MODE=local PIXIED_MACHINE_ID=phase3-cli \
        bash "$cli" shell
    assert_failure 1
    assert_output --partial 'PixiEden is not installed; run `pixied install` first'

    run env HOME="$home" XDG_DATA_HOME="$data" XDG_CONFIG_HOME="$config" \
        XDG_STATE_HOME="$state" PIXIED_HOME_MODE=local PIXIED_MACHINE_ID=phase3-cli \
        bash "$cli"
    assert_failure 1
    assert_output --partial 'PixiEden is not installed; run `pixied install` first'

    run bash "$cli" start
    assert_failure 2
    assert_output --partial 'unknown command: start'

    run bash "$cli" run
    assert_failure 2
    assert_output --partial 'usage: pixied run <command> [args...]'
}

@test "project integration generation is isolated and protects existing files" {
    local cli="$PIXIED_REPO_ROOT/bin/pixied"
    local home="$PIXIED_TEST_ROOT/generate-home"
    local host_pixi_home="$PIXIED_TEST_ROOT/host-pixi-home"
    local project="$PIXIED_TEST_ROOT/project/subdir"
    local protected="$PIXIED_TEST_ROOT/protected"
    local no_cli_project="$PIXIED_TEST_ROOT/no-cli-project"
    local before_pixi_home
    local expected_pixi_version
    local expected_envrc_line
    mkdir -p "$home" "$host_pixi_home" "$project" "$protected" "$no_cli_project"
    printf '[workspace]\nname = "sample"\n' >"$PIXIED_TEST_ROOT/project/pixi.toml"
    printf 'version = 1\n' >"$PIXIED_TEST_ROOT/project/pixi.lock"
    printf '[workspace]\nname = "protected"\n' >"$protected/pixi.toml"
    printf 'keep this file\n' >"$protected/.envrc"
    printf '[workspace]\nname = "no-cli"\n' >"$no_cli_project/pixi.toml"
    before_pixi_home=$host_pixi_home
    expected_pixi_version=$(sed -n \
        's/^readonly PIXIED_PIXI_VERSION_DEFAULT="\([^"]*\)"/\1/p' \
        "$PIXIED_REPO_ROOT/lib/pixi.sh")
    expected_envrc_line='eval "$('"$cli"' generate direnv --print-envrc)"'

    run env PATH=/usr/bin:/bin HOME="$home" PIXI_HOME="$host_pixi_home" bash -c \
        'cd -- "$1" && bash "$2" generate direnv' bash "$project" "$cli"
    assert_success
    [ -f "$PIXIED_TEST_ROOT/project/.envrc" ] || pixied_test_fail ".envrc was not generated"
    run bash -n "$PIXIED_TEST_ROOT/project/.envrc"
    assert_success
    grep -Fq -- "if [ -x $cli ]; then" \
        "$PIXIED_TEST_ROOT/project/.envrc" ||
        pixied_test_fail ".envrc does not guard the absolute pixied command"
    grep -Fq -- "$expected_envrc_line" \
        "$PIXIED_TEST_ROOT/project/.envrc" ||
        pixied_test_fail ".envrc does not use the public direnv print command"
    grep -Fq -- 'watch_file pixi.toml' "$PIXIED_TEST_ROOT/project/.envrc" ||
        pixied_test_fail ".envrc does not watch the project definition"
    assert_equal "$before_pixi_home" "$host_pixi_home"

    run env PATH=/usr/bin:/bin HOME="$home" bash -c \
        'cd -- "$1" && bash "$2" generate direnv' bash "$no_cli_project" "$cli"
    assert_success
    grep -Fq -- "if [ -x $cli ]; then" "$no_cli_project/.envrc" ||
        pixied_test_fail "generation without pixied on PATH did not embed the CLI path"
    grep -Fq -- "$cli generate direnv --print-envrc" "$no_cli_project/.envrc" ||
        pixied_test_fail "absolute CLI fallback does not use the public direnv print command"

    run env HOME="$home" PIXI_HOME="$host_pixi_home" bash -c \
        'cd -- "$1" && bash "$2" generate devcontainer' bash "$project" "$cli"
    assert_success
    [ -f "$PIXIED_TEST_ROOT/project/.devcontainer/devcontainer.json" ] ||
        pixied_test_fail "devcontainer.json was not generated"
    [ -f "$PIXIED_TEST_ROOT/project/.devcontainer/Dockerfile" ] ||
        pixied_test_fail "DevContainer Dockerfile was not generated"
    grep -Fq -- 'COPY --exclude=.pixi . .' "$PIXIED_TEST_ROOT/project/.devcontainer/Dockerfile" ||
        pixied_test_fail "DevContainer Dockerfile does not copy the project source"
    grep -Fq -- "ARG PIXI_VERSION=$expected_pixi_version" \
        "$PIXIED_TEST_ROOT/project/.devcontainer/Dockerfile" ||
        pixied_test_fail "DevContainer Dockerfile does not use the pinned Pixi version"
    if grep -Fq -- 'RUN rm -rf -- .pixi && pixi install' \
        "$PIXIED_TEST_ROOT/project/.devcontainer/Dockerfile"; then
        pixied_test_fail "DevContainer Dockerfile duplicates post-create installation"
    fi
    grep -Fq -- 'postCreateCommand installs into that volume' \
        "$PIXIED_TEST_ROOT/project/.devcontainer/Dockerfile" ||
        pixied_test_fail "DevContainer Dockerfile does not explain volume installation"
    grep -Fq -- '"type=volume,target=/workspace/.pixi"' \
        "$PIXIED_TEST_ROOT/project/.devcontainer/devcontainer.json" ||
        pixied_test_fail "DevContainer does not isolate the project environment"

    run env HOME="$home" PIXI_HOME="$host_pixi_home" bash -c \
        'cd -- "$1" && bash "$2" generate dockerfile' bash "$project" "$cli"
    assert_success
    [ -f "$PIXIED_TEST_ROOT/project/Dockerfile" ] || pixied_test_fail "Dockerfile was not generated"
    grep -Fq -- 'COPY --exclude=.pixi . .' "$PIXIED_TEST_ROOT/project/Dockerfile" ||
        pixied_test_fail "Dockerfile does not copy the project source before install"
    grep -Fq -- 'RUN rm -rf -- .pixi && pixi install --locked' \
        "$PIXIED_TEST_ROOT/project/Dockerfile" ||
        pixied_test_fail "Dockerfile does not install from the lock file"
    grep -Fq -- "ARG PIXI_VERSION=$expected_pixi_version" \
        "$PIXIED_TEST_ROOT/project/Dockerfile" ||
        pixied_test_fail "Dockerfile does not use the pinned Pixi version"
    if grep -Fq -- "$host_pixi_home" "$PIXIED_TEST_ROOT/project"/.envrc \
        "$PIXIED_TEST_ROOT/project"/Dockerfile \
        "$PIXIED_TEST_ROOT/project"/.devcontainer/Dockerfile; then
        pixied_test_fail "generated files contain the host PIXI_HOME"
    fi

    run env PATH=/usr/bin:/bin HOME="$home" PIXI_HOME="$host_pixi_home" bash -c \
        'cd -- "$1" && bash "$2" generate direnv' bash "$protected" "$cli"
    assert_failure 1
    assert_output --partial 'refusing to overwrite existing generated file'
    assert_equal 'keep this file' "$(<"$protected/.envrc")"

    run env PATH=/usr/bin:/bin HOME="$home" PIXI_HOME="$host_pixi_home" bash -c \
        'cd -- "$1" && bash "$2" generate direnv' bash "$PIXIED_TEST_ROOT" "$cli"
    assert_failure 1
    assert_output --partial 'could not find a Pixi project root'
}

@test "project integration generation validates Pixi pyproject definitions" {
    local cli="$PIXIED_REPO_ROOT/bin/pixied"
    local home="$PIXIED_TEST_ROOT/pyproject-home"
    local valid_project="$PIXIED_TEST_ROOT/pyproject-valid"
    local invalid_project="$PIXIED_TEST_ROOT/pyproject-invalid"
    mkdir -p "$home" "$valid_project" "$invalid_project"
    cat >"$valid_project/pyproject.toml" <<'PYPROJECT'
[project]
name = "sample"
[tool.pixi.workspace]
channels = ["conda-forge"]
platforms = ["linux-64"]
PYPROJECT
    cat >"$invalid_project/pyproject.toml" <<'PYPROJECT'
[project]
name = "python-only"
version = "0.1.0"
PYPROJECT

    run env HOME="$home" bash -c \
        'cd -- "$1" && bash "$2" generate dockerfile' bash "$valid_project" "$cli"
    assert_success
    grep -Fq -- 'COPY --exclude=.pixi . .' "$valid_project/Dockerfile" ||
        pixied_test_fail "Dockerfile does not copy the project source"

    run env HOME="$home" bash -c \
        'cd -- "$1" && bash "$2" generate dockerfile' bash "$invalid_project" "$cli"
    assert_failure 1
    assert_output --partial 'has no supported Pixi section'
}

@test "generated project shell hook keeps Pixi variables isolated" {
    local home="$PIXIED_TEST_ROOT/project-hook-home"
    local data="$PIXIED_TEST_ROOT/project-hook-data"
    local config="$PIXIED_TEST_ROOT/project-hook-config"
    local state="$PIXIED_TEST_ROOT/project-hook-state"
    local project="$PIXIED_TEST_ROOT/project-hook-project"
    local host_pixi_home="$PIXIED_TEST_ROOT/project-hook-host-pixi"
    mkdir -p "$home" "$project"
    printf '[workspace]\nchannels = ["conda-forge"]\nplatforms = ["linux-64"]\n' >"$project/pixi.toml"

    run env -u PIXI_HOME HOME="$home" XDG_DATA_HOME="$data" XDG_CONFIG_HOME="$config" \
        XDG_STATE_HOME="$state" PIXIED_MACHINE_ID=project-hook \
        PIXIED_SESSION_MANAGER=none PIXIED_PIXI_BINARY_SOURCE="$PIXIED_REPO_ROOT/tests/fakes/pixi" \
        bash "$PIXIED_REPO_ROOT/install-local.sh" --yes
    assert_success

    run env HOME="$home" XDG_DATA_HOME="$data" XDG_CONFIG_HOME="$config" \
        XDG_STATE_HOME="$state" PIXIED_MACHINE_ID=project-hook \
        PIXI_HOME="$host_pixi_home" PIXI_CACHE_DIR="$host_pixi_home/cache" \
        PIXI_NO_PATH_UPDATE=0 bash -c '
        cd -- "$1"
        bash "$2" generate direnv --print-envrc
    ' bash "$project" "$data/pixied/bin/pixied"
    assert_success
    assert_output --partial 'export PIXIED_FAKE_PROJECT_HOOK=1'
    [ ! -e "$project/.envrc" ] || pixied_test_fail "print-envrc unexpectedly created .envrc"

    run env HOME="$home" XDG_DATA_HOME="$data" XDG_CONFIG_HOME="$config" \
        XDG_STATE_HOME="$state" PIXIED_MACHINE_ID=project-hook \
        PIXI_HOME="$host_pixi_home" PIXI_CACHE_DIR="$host_pixi_home/cache" \
        PIXI_NO_PATH_UPDATE=0 bash -c '
        cd -- "$1"
        eval "$(bash "$2" generate direnv --print-envrc)"
        printf "home=%s\n" "$HOME"
        printf "pixi=%s\n" "$PIXI_HOME"
        printf "cache=%s\n" "$PIXI_CACHE_DIR"
        printf "no_update=%s\n" "$PIXI_NO_PATH_UPDATE"
        printf "hook=%s\n" "$PIXIED_FAKE_PROJECT_HOOK"
    ' bash "$project" "$data/pixied/bin/pixied"
    assert_success
    assert_output --partial "home=$home"
    assert_output --partial "pixi=$data/pixied/pixi"
    assert_output --partial "cache=$data/pixied/pixi/cache"
    assert_output --partial 'no_update=1'
    assert_output --partial 'hook=1'
}

@test "generated project shell hook preserves account HOME in NFS mode" {
    local account_home="$PIXIED_TEST_ROOT/project-hook-nfs-account"
    local local_home="$PIXIED_TEST_ROOT/project-hook-nfs-local"
    local data="$PIXIED_TEST_ROOT/project-hook-nfs-data"
    local config="$PIXIED_TEST_ROOT/project-hook-nfs-config"
    local state="$PIXIED_TEST_ROOT/project-hook-nfs-state"
    local project="$PIXIED_TEST_ROOT/project-hook-nfs-project"
    mkdir -p "$account_home" "$local_home" "$project"
    printf '[workspace]\nchannels = ["conda-forge"]\nplatforms = ["linux-64"]\n' \
        >"$project/pixi.toml"

    run env -u PIXI_HOME HOME="$account_home" XDG_DATA_HOME="$data" \
        XDG_CONFIG_HOME="$config" XDG_STATE_HOME="$state" \
        PIXIED_MACHINE_ID=project-hook-nfs PIXIED_SESSION_MANAGER=none \
        PIXIED_PIXI_BINARY_SOURCE="$PIXIED_REPO_ROOT/tests/fakes/pixi" \
        bash "$PIXIED_REPO_ROOT/install-local.sh" --home-mode nfs \
        --local-home "$local_home" --yes
    assert_success

    run env HOME="$account_home" XDG_DATA_HOME="$data" \
        XDG_CONFIG_HOME="$config" XDG_STATE_HOME="$state" PIXIED_HOME_MODE=nfs \
        PIXIED_LOCAL_HOME="$local_home" PIXIED_MACHINE_ID=project-hook-nfs \
        bash -c '
        cd -- "$1"
        eval "$(bash "$2" generate direnv --print-envrc)"
        printf "home=%s\n" "$HOME"
    ' bash "$project" "$data/pixied/bin/pixied"
    assert_success
    assert_output --partial "home=$account_home"
}

@test "command execution is observable" {
    local fake_bin="$PIXIED_TEST_ROOT/fake-bin"
    local log="$PIXIED_TEST_ROOT/commands.log"
    local command_name
    setup_fake_commands "$fake_bin"
    : >"$log"

    run env PATH="$fake_bin:/usr/bin:/bin" PIXIED_COMMAND_LOG="$log" \
        bash -c '. "$1/lib/common.sh"; pixied_run pixi --version' bash "$PIXIED_REPO_ROOT"
    assert_success
    assert_equal 'pixi 0.0.0-fake' "$output"

    run env PATH="$fake_bin:/usr/bin:/bin" PIXIED_COMMAND_LOG="$log" \
        bash -c '. "$1/lib/common.sh"; pixied_run zellij' bash "$PIXIED_REPO_ROOT"
    assert_success
    grep -Fq -- 'pixi --version' "$log" || pixied_test_fail "missing pixi command log"
    grep -Fq -- 'zellij' "$log" || pixied_test_fail "missing zellij command log"
    if command grep -Eq -- '^(systemctl|loginctl|sudo) ' "$log"; then
        pixied_test_fail "system service commands were unexpectedly logged"
    fi
}

@test "temporary paths are cleaned up" {
    local marker="$PIXIED_TEST_ROOT/temp-marker"

    run env PIXIED_MARKER="$marker" PIXIED_REPO_ROOT="$PIXIED_REPO_ROOT" bash -c '
        . "$PIXIED_REPO_ROOT/lib/common.sh"
        pixied_enable_strict_mode
        pixied_temp_dir
        : >"$PIXIED_TEMP_DIR/marker"
        printf "%s\n" "$PIXIED_TEMP_DIR" >"$PIXIED_MARKER"
    '
    assert_success
    [ ! -e "$(<"$marker")" ] || pixied_test_fail "temporary directory was not cleaned"
}

# US-101-1
# US-101-2
@test "local installation is networkless and complete" {
    local home="$PIXIED_TEST_ROOT/home"
    local data="$PIXIED_TEST_ROOT/data"
    local config="$PIXIED_TEST_ROOT/config"
    local state="$PIXIED_TEST_ROOT/state"
    local machine_id=phase1-install
    local existing_pixi="$PIXIED_TEST_ROOT/existing-pixi"
    local config_target="$PIXIED_TEST_ROOT/config-target"
    local log="$PIXIED_TEST_ROOT/install.log"
    local version expected_version
    mkdir -p "$home" "$existing_pixi/bin" "$config_target"
    ln -s "$config_target" "$config"
    printf 'existing pixi environment\n' >"$existing_pixi/bin/pixi"
    : >"$log"

    run env HOME="$home" PIXI_HOME="$existing_pixi" \
        XDG_DATA_HOME="$data" XDG_CONFIG_HOME="$config" XDG_STATE_HOME="$state" \
        PIXIED_MACHINE_ID="$machine_id" PIXIED_HOME_MODE=local PIXIED_SESSION_MANAGER=none \
        PIXIED_COMMAND_LOG="$log" \
        PIXIED_SESSION_MANAGER=none PIXIED_PIXI_BINARY_SOURCE="$PIXIED_REPO_ROOT/tests/fakes/pixi" \
        bash "$PIXIED_REPO_ROOT/install-local.sh"
    assert_success
    assert_output --partial 'Runtime hook, dedicated Pixi environment, and session support are ready'
    assert_output --partial 'Option A (Start now):'
    assert_output --partial "$home/.local/bin/pixied shell"
    assert_output --partial 'Option B (Automatic - Recommended):'
    assert_output --partial "Add to ~/.bashrc, then restart your terminal:"
    assert_output --partial "$home/.local/bin/pixied hook bash"
    [[ "$output" != *'Phase 5'* ]] || pixied_test_fail "success output contains an obsolete phase number"
    [ -f "$data/pixied/bin/pixied" ] || pixied_test_fail "deployed CLI is missing"
    [ -f "$data/pixied/lib/common.sh" ] || pixied_test_fail "deployed common library is missing"
    run bash "$data/pixied/bin/pixied" version
    assert_success
    version=$output
    expected_version="pixied $(pixied_version_from_source "$data/pixied/bin/pixied")"
    assert_equal "$expected_version" "$version"
    grep -Fq -- 'bash --version' "$log" || pixied_test_fail "bash version was not logged"
    [ -x "$data/pixied/pixi/bin/direnv" ] || pixied_test_fail "dedicated direnv is missing"
    [ ! -e "$data/pixied/pixi/bin/zellij" ] || pixied_test_fail "zellij was installed in none mode"
    [ -x "$home/.local/bin/pixied" ] || pixied_test_fail "launcher is missing"
    [ -f "$config_target/pixied/runtime-hook.bash" ] || pixied_test_fail "runtime hook is missing"
    [ -f "$state/pixied/machines/$machine_id/state" ] || pixied_test_fail "state is missing"
    assert_equal 'existing pixi environment' "$(<"$existing_pixi/bin/pixi")"
    [ ! -e "$existing_pixi/bin/zellij" ] || pixied_test_fail "existing Pixi home was modified"
    if command grep -Eq -- '^(zellij|systemctl|loginctl|sudo) ' "$log"; then
        pixied_test_fail "none mode called a session-related command"
    fi
    [ ! -d "$home/.cache" ] || pixied_test_fail "unexpected cache directory: $home/.cache"
}

@test "interactive install reviews settings before provisioning" {
    command -v script >/dev/null 2>&1 || skip "script command is required for the TTY test"
    local home="$PIXIED_TEST_ROOT/wizard-home"
    local data="$PIXIED_TEST_ROOT/wizard-data"
    local config="$PIXIED_TEST_ROOT/wizard-config"
    local state="$PIXIED_TEST_ROOT/wizard-state"
    local log="$PIXIED_TEST_ROOT/wizard.log"
    local fake_bin="$PIXIED_TEST_ROOT/wizard-fake-bin"
    local machine_id=wizard-machine
    mkdir -p "$home" "$fake_bin"
    printf '#!/usr/bin/env bash\ncase "$*" in\n*%s*) exit 1 ;;\n*) exec /usr/bin/df "$@" ;;\nesac\n' \
        "$home" >"$fake_bin/df"
    chmod 0755 "$fake_bin/df"
    : >"$log"

    run env -i PATH="$fake_bin:$PATH" HOME="$home" XDG_DATA_HOME="$data" XDG_CONFIG_HOME="$config" \
        XDG_STATE_HOME="$state" PIXIED_MACHINE_ID="$machine_id" \
        PIXIED_COMMAND_LOG="$log" \
        PIXIED_PIXI_BINARY_SOURCE="$PIXIED_REPO_ROOT/tests/fakes/pixi" \
        bash -c '
        printf "%s\n" local none "$1" "" |
            script -qec "bash \"$2\" install" /dev/null
    ' bash "$machine_id" "$PIXIED_REPO_ROOT/bin/pixied"
    assert_success
    assert_output --partial 'Installation configuration wizard'
    assert_output --partial 'Review installation'
    assert_output --partial 'Home mode: local'
    assert_output --partial 'Session manager: none'
    assert_output --partial 'Proceed with installation? [Y/n]'
    assert_output --partial 'NFS synchronization is disabled'
    [ -f "$state/pixied/machines/$machine_id/state" ] ||
        pixied_test_fail "wizard installation state is missing"
    if command grep -Eq -- '^(pixi|curl|wget) ' "$log"; then
        pixied_test_fail "provisioning started before final confirmation"
    fi
}

@test "interactive NFS install keeps the selected local home when later prompts use defaults" {
    command -v script >/dev/null 2>&1 || skip "script command is required for the TTY test"
    local home="$PIXIED_TEST_ROOT/wizard-nfs-home"
    local local_home="$PIXIED_TEST_ROOT/wizard-nfs-local"
    local data="$PIXIED_TEST_ROOT/wizard-nfs-data"
    local config="$PIXIED_TEST_ROOT/wizard-nfs-config"
    local state="$PIXIED_TEST_ROOT/wizard-nfs-state"
    local machine_id=wizard-nfs-machine
    mkdir -p "$home" "$local_home"

    run env -i PATH="$PATH" HOME="$home" XDG_DATA_HOME="$data" XDG_CONFIG_HOME="$config" \
        XDG_STATE_HOME="$state" PIXIED_MACHINE_ID="$machine_id" \
        PIXIED_PIXI_BINARY_SOURCE="$PIXIED_REPO_ROOT/tests/fakes/pixi" \
        bash -c '
        printf "%s\n" nfs "$1" none "" "" |
            script -qec "bash \"$2\"" /dev/null
    ' bash "$local_home" "$PIXIED_REPO_ROOT/install-local.sh"
    assert_success
    assert_output --partial "Local home: $local_home"
    assert_output --partial "Pixi home: $local_home/.local/share/pixied/pixi"
    [ -f "$state/pixied/machines/$machine_id/state" ] ||
        pixied_test_fail "NFS wizard state is missing"
    grep -Fq -- "local_home=$local_home" "$state/pixied/machines/$machine_id/state" ||
        pixied_test_fail "selected local home was not persisted"
}

@test "release archive installs through the remote and local entrypoints" {
    local archive="$PIXIED_TEST_ROOT/pixied-release.tar.gz"
    local fake_bin="$PIXIED_TEST_ROOT/release-fake-bin"
    local home="$PIXIED_TEST_ROOT/release-home"
    local data="$PIXIED_TEST_ROOT/release-data"
    local config="$PIXIED_TEST_ROOT/release-config"
    local state="$PIXIED_TEST_ROOT/release-state"
    mkdir -p "$fake_bin" "$home"
    cat >"$fake_bin/curl" <<'CURL'
#!/usr/bin/env bash
set -Eeuo pipefail
output=""
url=""
while [ "$#" -gt 0 ]; do
    case "$1" in
    --output | -o)
        output=$2
        shift 2
        ;;
    *)
        url=$1
        shift
        ;;
    esac
done
[ -n "$output" ]
if [[ "$url" == *.sha256 ]]; then
    sha256sum "${PIXIED_TEST_RELEASE_ARCHIVE:?}" |
        sed 's#  .*#  pixied.tar.gz#' >"$output"
else
    cp "${PIXIED_TEST_RELEASE_ARCHIVE:?}" "$output"
fi
CURL
    chmod 0755 "$fake_bin/curl"

    run bash "$PIXIED_REPO_ROOT/scripts/package-release.sh" "$archive"
    assert_success
    [ -f "$archive" ] || pixied_test_fail "release archive was not created"
    [ -f "$archive.sha256" ] || pixied_test_fail "release archive checksum was not created"
    run bash -c 'cd -- "$1" && sha256sum -c -- "$2"' bash \
        "$(dirname "$archive")" "$(basename "$archive").sha256"
    assert_success
    run tar -tzf "$archive"
    assert_success
    assert_output --partial 'pixied/install-local.sh'
    assert_output --partial 'pixied/bin/pixied'
    assert_output --partial 'pixied/lib/pixi.sh'
    assert_output --partial 'pixied/README.md'
    assert_output --partial 'pixied/README.ja.md'
    if [[ "$output" == *'pixied/tests/'* ]] || [[ "$output" == *'pixied/.git/'* ]]; then
        pixied_test_fail "release archive contains checkout-only files"
    fi

    run env -u PIXI_HOME PATH="$fake_bin:/usr/bin:/bin" \
        PIXIED_TEST_RELEASE_ARCHIVE="$archive" PIXIED_RELEASE_URL=https://example.invalid/pixied.tar.gz \
        HOME="$home" XDG_DATA_HOME="$data" XDG_CONFIG_HOME="$config" \
        XDG_STATE_HOME="$state" PIXIED_MACHINE_ID=phase7-release PIXIED_HOME_MODE=local \
        PIXIED_SESSION_MANAGER=none PIXIED_PIXI_BINARY_SOURCE="$PIXIED_REPO_ROOT/tests/fakes/pixi" \
        bash "$PIXIED_REPO_ROOT/install.sh" --home-mode local --session-manager none --yes
    assert_success
    [ -x "$data/pixied/bin/pixied" ] || pixied_test_fail "remote release installer did not deploy the CLI"
    [ -f "$state/pixied/machines/phase7-release/state" ] ||
        pixied_test_fail "remote release installer did not create state"
}

@test "remote installer requires the packaged archive root" {
    local archive="$PIXIED_TEST_ROOT/pixied-invalid-release.tar.gz"
    local fake_bin="$PIXIED_TEST_ROOT/invalid-release-fake-bin"
    local archive_root="$PIXIED_TEST_ROOT/invalid-release-root"
    mkdir -p "$fake_bin" "$archive_root/other"
    printf '#!/usr/bin/env bash\nexit 0\n' >"$archive_root/other/install-local.sh"
    tar -czf "$archive" -C "$archive_root" other
    cat >"$fake_bin/curl" <<'CURL'
#!/usr/bin/env bash
set -Eeuo pipefail
output=""
url=""
while [ "$#" -gt 0 ]; do
    case "$1" in
    --output | -o)
        output=$2
        shift 2
        ;;
    *)
        url=$1
        shift
        ;;
    esac
done
[ -n "$output" ]
if [[ "$url" == *.sha256 ]]; then
    sha256sum "${PIXIED_TEST_RELEASE_ARCHIVE:?}" |
        sed 's#  .*#  pixied.tar.gz#' >"$output"
else
    cp "${PIXIED_TEST_RELEASE_ARCHIVE:?}" "$output"
fi
CURL
    chmod 0755 "$fake_bin/curl"

    run env PATH="$fake_bin:/usr/bin:/bin" \
        PIXIED_TEST_RELEASE_ARCHIVE="$archive" PIXIED_RELEASE_URL=https://example.invalid/pixied.tar.gz \
        bash "$PIXIED_REPO_ROOT/install.sh"
    assert_failure 1
    assert_output --partial 'release archive does not contain pixied/install-local.sh'
}

@test "remote installer rejects a release checksum mismatch before extraction" {
    local archive="$PIXIED_TEST_ROOT/pixied-mismatch-release.tar.gz"
    local fake_bin="$PIXIED_TEST_ROOT/mismatch-release-fake-bin"
    mkdir -p "$fake_bin"
    run bash "$PIXIED_REPO_ROOT/scripts/package-release.sh" "$archive"
    assert_success
    cat >"$fake_bin/curl" <<'CURL'
#!/usr/bin/env bash
set -Eeuo pipefail
output=""
url=""
while [ "$#" -gt 0 ]; do
    case "$1" in
    --output | -o)
        output=$2
        shift 2
        ;;
    *)
        url=$1
        shift
        ;;
    esac
done
[ -n "$output" ]
if [[ "$url" == *.sha256 ]]; then
    printf '%064d  pixied.tar.gz\n' 0 >"$output"
else
    cp "${PIXIED_TEST_RELEASE_ARCHIVE:?}" "$output"
fi
CURL
    chmod 0755 "$fake_bin/curl"

    run env PATH="$fake_bin:/usr/bin:/bin" \
        PIXIED_TEST_RELEASE_ARCHIVE="$archive" PIXIED_RELEASE_URL=https://example.invalid/pixied.tar.gz \
        bash "$PIXIED_REPO_ROOT/install.sh"
    assert_failure 1
    assert_output --partial 'release archive checksum mismatch'
}

@test "remote installer rejects a malformed release checksum" {
    local archive="$PIXIED_TEST_ROOT/pixied-malformed-release.tar.gz"
    local fake_bin="$PIXIED_TEST_ROOT/malformed-release-fake-bin"
    mkdir -p "$fake_bin"
    run bash "$PIXIED_REPO_ROOT/scripts/package-release.sh" "$archive"
    assert_success
    cat >"$fake_bin/curl" <<'CURL'
#!/usr/bin/env bash
set -Eeuo pipefail
output=""
url=""
while [ "$#" -gt 0 ]; do
    case "$1" in
    --output | -o)
        output=$2
        shift 2
        ;;
    *)
        url=$1
        shift
        ;;
    esac
done
[ -n "$output" ]
if [[ "$url" == *.sha256 ]]; then
    printf 'not-a-checksum\n' >"$output"
else
    cp "${PIXIED_TEST_RELEASE_ARCHIVE:?}" "$output"
fi
CURL
    chmod 0755 "$fake_bin/curl"

    run env PATH="$fake_bin:/usr/bin:/bin" \
        PIXIED_TEST_RELEASE_ARCHIVE="$archive" PIXIED_RELEASE_URL=https://example.invalid/pixied.tar.gz \
        bash "$PIXIED_REPO_ROOT/install.sh"
    assert_failure 1
    assert_output --partial 'release checksum is malformed'
}

# US-101-1
@test "zellij mode provisions optional Global package and isolated Pixi variables" {
    local home="$PIXIED_TEST_ROOT/phase2-zellij-home"
    local data="$PIXIED_TEST_ROOT/phase2-zellij-data"
    local log="$PIXIED_TEST_ROOT/phase2-zellij.log"
    local state_file="$PIXIED_TEST_ROOT/phase2-zellij-state/pixied/machines/phase2-zellij/state"
    mkdir -p "$home"
    : >"$log"

    run env -u PIXI_HOME HOME="$home" XDG_DATA_HOME="$data" \
        XDG_STATE_HOME="$PIXIED_TEST_ROOT/phase2-zellij-state" \
        PIXIED_MACHINE_ID=phase2-zellij PIXIED_SESSION_MANAGER=zellij \
        PIXIED_PIXI_BINARY_SOURCE="$PIXIED_REPO_ROOT/tests/fakes/pixi" \
        PIXIED_COMMAND_LOG="$log" bash "$PIXIED_REPO_ROOT/install-local.sh"
    assert_success
    [ -x "$data/pixied/pixi/bin/direnv" ] || pixied_test_fail "dedicated direnv is missing"
    [ -x "$data/pixied/pixi/bin/zellij" ] || pixied_test_fail "dedicated zellij is missing"
    grep -Fq -- 'PIXI_HOME=' "$log" || pixied_test_fail "Pixi HOME was not isolated"
    grep -Fq -- 'PIXI_CACHE_DIR=' "$log" || pixied_test_fail "Pixi cache was not isolated"
    grep -Fq -- 'PIXI_NO_PATH_UPDATE=1' "$log" || pixied_test_fail "Pixi path update was not disabled"
    grep -Fq -- 'session_manager=zellij' "$state_file" || pixied_test_fail "session manager was not persisted"
    grep -Eq -- '^pixi_binary_hash=[0-9a-f]{64}$' "$state_file" ||
        pixied_test_fail "Pixi binary hash was not persisted"
    grep -Eq -- '^direnv_hash=[0-9a-f]{64}$' "$state_file" ||
        pixied_test_fail "direnv hash was not persisted"
    grep -Eq -- '^zellij_hash=[0-9a-f]{64}$' "$state_file" ||
        pixied_test_fail "zellij hash was not persisted"
}

@test "zellij mode avoids host service commands and persists no obsolete state" {
    local home="$PIXIED_TEST_ROOT/phase5-direct-home"
    local data="$PIXIED_TEST_ROOT/phase5-direct-data"
    local config="$PIXIED_TEST_ROOT/phase5-direct-config"
    local state="$PIXIED_TEST_ROOT/phase5-direct-state"
    local fake_bin="$PIXIED_TEST_ROOT/phase5-direct-bin"
    local log="$PIXIED_TEST_ROOT/phase5-direct.log"
    local state_file="$state/pixied/machines/phase5-direct/state"
    mkdir -p "$home"
    setup_fake_commands "$fake_bin"
    : >"$log"

    run env -u PIXI_HOME HOME="$home" XDG_DATA_HOME="$data" \
        XDG_CONFIG_HOME="$config" XDG_STATE_HOME="$state" \
        PATH="$fake_bin:/usr/bin:/bin" PIXIED_COMMAND_LOG="$log" \
        PIXIED_MACHINE_ID=phase5-direct PIXIED_SESSION_MANAGER=zellij \
        PIXIED_PIXI_BINARY_SOURCE="$PIXIED_REPO_ROOT/tests/fakes/pixi" \
        bash "$PIXIED_REPO_ROOT/install-local.sh"
    assert_success
    [ ! -e "$config/systemd" ] || pixied_test_fail "host service files were created"
    for obsolete_key in systemd_user_dir unit_path unit_hash systemd_available linger_enabled created_linger; do
        if grep -Fq -- "$obsolete_key=" "$state_file"; then
            pixied_test_fail "obsolete state key was persisted: $obsolete_key"
        fi
    done
    if command grep -Eq -- '^(systemctl|loginctl|sudo) ' "$log"; then
        pixied_test_fail "host service commands were unexpectedly called"
    fi
}

@test "direct shell attaches to the dedicated Zellij session" {
    local home="$PIXIED_TEST_ROOT/phase5-shell-home"
    local data="$PIXIED_TEST_ROOT/phase5-shell-data"
    local config="$PIXIED_TEST_ROOT/phase5-shell-config"
    local state="$PIXIED_TEST_ROOT/phase5-shell-state"
    local fake_bin="$PIXIED_TEST_ROOT/phase5-shell-bin"
    local log="$PIXIED_TEST_ROOT/phase5-shell.log"
    mkdir -p "$home"
    setup_fake_commands "$fake_bin"
    : >"$log"

    run env -u PIXI_HOME HOME="$home" XDG_DATA_HOME="$data" \
        XDG_CONFIG_HOME="$config" XDG_STATE_HOME="$state" \
        PATH="$fake_bin:/usr/bin:/bin" PIXIED_COMMAND_LOG="$log" \
        PIXIED_MACHINE_ID=phase5-shell PIXIED_SESSION_MANAGER=zellij \
        PIXIED_PIXI_BINARY_SOURCE="$PIXIED_REPO_ROOT/tests/fakes/pixi" \
        bash "$PIXIED_REPO_ROOT/install-local.sh"
    assert_success

    run env HOME="$home" XDG_DATA_HOME="$data" XDG_CONFIG_HOME="$config" \
        XDG_STATE_HOME="$state" PATH="$fake_bin:/usr/bin:/bin" \
        PIXIED_COMMAND_LOG="$log" PIXIED_MACHINE_ID=phase5-shell \
        bash -c '
        printf "exit\\n" | script -qec "bash \"$0/pixied/bin/pixied\" shell" /dev/null
    ' "$data"
    assert_success
    grep -Fq -- "zellij attach --create pixied" "$log" ||
        pixied_test_fail "shell did not directly attach to the dedicated session"
    if command grep -Eq -- '^(systemctl|loginctl|sudo) ' "$log"; then
        pixied_test_fail "shell invoked a host service command"
    fi
}

# US-102-2
# US-103-1
@test "generated hook activates only the isolated runtime environment" {
    local home="$PIXIED_TEST_ROOT/phase3-hook-home"
    local data="$PIXIED_TEST_ROOT/phase3-hook-data"
    local config="$PIXIED_TEST_ROOT/phase3-hook-config"
    local state="$PIXIED_TEST_ROOT/phase3-hook-state"
    local cli="$PIXIED_REPO_ROOT/bin/pixied"
    mkdir -p "$home"

    run env -u PIXI_HOME HOME="$home" XDG_DATA_HOME="$data" XDG_CONFIG_HOME="$config" \
        XDG_STATE_HOME="$state" PIXIED_MACHINE_ID=phase3-hook PIXIED_SESSION_MANAGER=none \
        PIXIED_PIXI_BINARY_SOURCE="$PIXIED_REPO_ROOT/tests/fakes/pixi" \
        bash "$PIXIED_REPO_ROOT/install-local.sh"
    assert_success

    run env -u PIXI_HOME HOME="$home" XDG_DATA_HOME="$data" XDG_CONFIG_HOME="$config" \
        XDG_STATE_HOME="$state" PIXIED_MACHINE_ID=phase3-hook \
        PATH="/usr/bin:/bin:/usr/bin" bash -c '
        eval "$($1 hook bash)"
        printf "home=%s\n" "$HOME"
        printf "pixi=%s\n" "$PIXI_HOME"
        printf "cache=%s\n" "$PIXI_CACHE_DIR"
        printf "no_update=%s\n" "$PIXI_NO_PATH_UPDATE"
        printf "active=%s\n" "$PIXIED_RUNTIME_HOOK_ACTIVE"
        printf "pixied=%s\n" "$(command -v pixied)"
        count=0
        IFS=: read -r -a entries <<<"$PATH"
        for entry in "${entries[@]}"; do
            [ "$entry" = "$2/pixied/pixi/bin" ] && count=$((count + 1))
        done
        printf "pixi_bin_count=%s\n" "$count"
    ' bash "$data/pixied/bin/pixied" "$data"
    assert_success
    assert_output --partial "home=$home"
    assert_output --partial "pixi=$data/pixied/pixi"
    assert_output --partial "cache=$data/pixied/pixi/cache"
    assert_output --partial 'no_update=1'
    assert_output --partial 'active=1'
    assert_output --partial "pixied=$home/.local/bin/pixied"
    assert_output --partial 'pixi_bin_count=1'
    [ "$HOME" != "$home" ] || pixied_test_fail "test shell HOME was changed"
    [ ! -e "$home/.cache" ] || pixied_test_fail "runtime hook created a host cache"
}

# US-102-1
# US-102-3
@test "hook output sources the generated runtime hook and records its hash" {
    local home="$PIXIED_TEST_ROOT/phase3-hook-output-home"
    local data="$PIXIED_TEST_ROOT/phase3-hook-output-data"
    local config="$PIXIED_TEST_ROOT/phase3-hook-output-config"
    local state="$PIXIED_TEST_ROOT/phase3-hook-output-state"
    local state_file="$state/pixied/machines/phase3-hook-output/state"
    local expected_hook="$config/pixied/runtime-hook.bash"
    mkdir -p "$home"
    printf 'user-managed shell configuration\n' >"$home/.bashrc"

    run env -u PIXI_HOME HOME="$home" XDG_DATA_HOME="$data" XDG_CONFIG_HOME="$config" \
        XDG_STATE_HOME="$state" PIXIED_MACHINE_ID=phase3-hook-output PIXIED_SESSION_MANAGER=none \
        PIXIED_PIXI_BINARY_SOURCE="$PIXIED_REPO_ROOT/tests/fakes/pixi" \
        bash "$PIXIED_REPO_ROOT/install-local.sh"
    assert_success

    run env -u PIXI_HOME HOME="$home" XDG_DATA_HOME="$data" XDG_CONFIG_HOME="$config" \
        XDG_STATE_HOME="$state" PIXIED_MACHINE_ID=phase3-hook-output \
        bash "$data/pixied/bin/pixied" hook bash
    assert_success
    assert_equal ". $expected_hook" "$output"
    [ -f "$expected_hook" ] || pixied_test_fail "generated runtime hook is missing"
    grep -Eq -- '^runtime_hook_hash=[0-9a-f]{64}$' "$state_file" ||
        pixied_test_fail "runtime hook hash was not persisted"
    assert_equal 'user-managed shell configuration' "$(<"$home/.bashrc")"
}

@test "zsh hook sources the generated runtime hook" {
    command -v zsh >/dev/null 2>&1 || skip "zsh is required"
    local home="$PIXIED_TEST_ROOT/phase3-zsh-hook-home"
    local data="$PIXIED_TEST_ROOT/phase3-zsh-hook-data"
    local config="$PIXIED_TEST_ROOT/phase3-zsh-hook-config"
    local state="$PIXIED_TEST_ROOT/phase3-zsh-hook-state"
    local direnv_log="$PIXIED_TEST_ROOT/phase3-zsh-hook-direnv.log"
    local runtime_hook="$config/pixied/runtime-hook.bash"
    mkdir -p "$home"
    : >"$direnv_log"

    run env -u PIXI_HOME HOME="$home" XDG_DATA_HOME="$data" XDG_CONFIG_HOME="$config" \
        XDG_STATE_HOME="$state" PIXIED_MACHINE_ID=phase3-zsh-hook PIXIED_SESSION_MANAGER=none \
        PIXIED_FAKE_DIRENV_LOG="$direnv_log" \
        PIXIED_PIXI_BINARY_SOURCE="$PIXIED_REPO_ROOT/tests/fakes/pixi" \
        bash "$PIXIED_REPO_ROOT/install-local.sh"
    assert_success

    run zsh -n "$runtime_hook"
    assert_success

    run env -u PIXI_HOME HOME="$home" XDG_DATA_HOME="$data" XDG_CONFIG_HOME="$config" \
        XDG_STATE_HOME="$state" PIXIED_MACHINE_ID=phase3-zsh-hook \
        zsh -c 'eval "$(bash "$1" hook zsh)"; printf "home=%s\npixi=%s\ncache=%s\nactive=%s\npixied=%s\n" "$HOME" "$PIXI_HOME" "$PIXI_CACHE_DIR" "$PIXIED_RUNTIME_HOOK_ACTIVE" "$(command -v pixied)"' \
        zsh "$data/pixied/bin/pixied"
    assert_success
    assert_output --partial "home=$home"
    assert_output --partial "pixi=$data/pixied/pixi"
    assert_output --partial "cache=$data/pixied/pixi/cache"
    assert_output --partial 'active=1'
    assert_output --partial "pixied=$home/.local/bin/pixied"
    [ "$HOME" != "$home" ] || pixied_test_fail "test shell HOME was changed"
    [ ! -e "$home/.cache" ] || pixied_test_fail "runtime hook created a host cache"

    run env -u PIXI_HOME HOME="$home" XDG_DATA_HOME="$data" XDG_CONFIG_HOME="$config" \
        XDG_STATE_HOME="$state" PIXIED_MACHINE_ID=phase3-zsh-hook \
        zsh -c 'eval "$(bash "$1" hook zsh)"; eval "$(bash "$1" hook zsh)"; printf "second-hook-finished\n"' \
        zsh "$data/pixied/bin/pixied"
    assert_success
    assert_output --partial 'second-hook-finished'

    run env -u PIXI_HOME HOME="$home" XDG_DATA_HOME="$data" XDG_CONFIG_HOME="$config" \
        XDG_STATE_HOME="$state" PIXIED_MACHINE_ID=phase3-zsh-hook \
        PIXIED_FAKE_DIRENV_LOG="$direnv_log" \
        zsh -ic 'eval "$(bash "$1" hook zsh)"; printf "interactive-hook-finished\n"' \
        zsh "$data/pixied/bin/pixied"
    assert_success
    assert_output --partial 'interactive-hook-finished'
    grep -Fq -- 'hook zsh' "$direnv_log" ||
        pixied_test_fail "zsh hook did not request the zsh direnv hook"
}

# US-103-2
@test "interactive hook starts Zellij only under the approved conditions" {
    command -v script >/dev/null 2>&1 || skip "script command is required for the TTY test"
    local home="$PIXIED_TEST_ROOT/phase3-hook-autostart-home"
    local data="$PIXIED_TEST_ROOT/phase3-hook-autostart-data"
    local config="$PIXIED_TEST_ROOT/phase3-hook-autostart-config"
    local state="$PIXIED_TEST_ROOT/phase3-hook-autostart-state"
    local fake_bin="$PIXIED_TEST_ROOT/phase3-hook-autostart-bin"
    local log="$PIXIED_TEST_ROOT/phase3-hook-autostart.log"
    local machine_id=phase3-hook-autostart
    mkdir -p "$home"
    setup_fake_commands "$fake_bin"
    : >"$log"

    run env -u PIXI_HOME HOME="$home" XDG_DATA_HOME="$data" XDG_CONFIG_HOME="$config" \
        XDG_STATE_HOME="$state" PIXIED_MACHINE_ID="$machine_id" \
        PIXIED_SESSION_MANAGER=zellij \
        PATH="$fake_bin:/usr/bin:/bin" PIXIED_COMMAND_LOG="$log" \
        PIXIED_PIXI_BINARY_SOURCE="$PIXIED_REPO_ROOT/tests/fakes/pixi" \
        bash "$PIXIED_REPO_ROOT/install-local.sh"
    assert_success

    run env -u CI -u ZELLIJ -u PIXI_HOME -u PIXIED_RUNTIME_HOOK_ACTIVE -u PIXIED_STATE_DIR \
        -u PIXIED_RUNTIME_STATE_FILE -u PIXIED_STATE_FILE -u PIXIED_DATA_DIR \
        -u PIXIED_CONFIG_DIR -u PIXIED_PIXI_HOME HOME="$home" \
        XDG_DATA_HOME="$data" XDG_CONFIG_HOME="$config" XDG_STATE_HOME="$state" \
        PIXIED_MACHINE_ID="$machine_id" PATH="$data/pixied/bin:$data/pixied/pixi/bin:/usr/bin:/bin" \
        PIXIED_COMMAND_LOG="$log" TERM=xterm-256color \
        script -qec "bash -ic 'eval \"\$(bash \"$data/pixied/bin/pixied\" hook bash)\"; printf \"hook-finished\\n\"'" \
        /dev/null
    assert_success
    assert_output --partial 'hook-finished'
    grep -Fq -- "$data/pixied/pixi/bin/zellij attach --create pixied" "$log" ||
        pixied_test_fail "interactive hook did not start the dedicated Zellij session"

    : >"$log"
    run env -u ZELLIJ -u PIXI_HOME CI=1 HOME="$home" \
        XDG_DATA_HOME="$data" XDG_CONFIG_HOME="$config" XDG_STATE_HOME="$state" \
        PIXIED_MACHINE_ID="$machine_id" PATH="$data/pixied/bin:$data/pixied/pixi/bin:/usr/bin:/bin" \
        PIXIED_COMMAND_LOG="$log" TERM=xterm-256color \
        script -qec "bash -ic 'eval \"\$(bash \"$data/pixied/bin/pixied\" hook bash)\"; printf \"hook-finished\\n\"'" \
        /dev/null
    assert_success
    assert_output --partial 'hook-finished'
    if grep -Fq -- 'zellij attach --create' "$log"; then
        pixied_test_fail "CI hook unexpectedly started Zellij"
    fi

    : >"$log"
    run env -u CI -u PIXI_HOME ZELLIJ=1 HOME="$home" \
        XDG_DATA_HOME="$data" XDG_CONFIG_HOME="$config" XDG_STATE_HOME="$state" \
        PIXIED_MACHINE_ID="$machine_id" PATH="$data/pixied/bin:$data/pixied/pixi/bin:/usr/bin:/bin" \
        PIXIED_COMMAND_LOG="$log" TERM=xterm-256color \
        script -qec "bash -ic 'eval \"\$(bash \"$data/pixied/bin/pixied\" hook bash)\"; printf \"hook-finished\\n\"'" \
        /dev/null
    assert_success
    assert_output --partial 'hook-finished'
    if grep -Fq -- 'zellij attach --create' "$log"; then
        pixied_test_fail "nested Zellij hook unexpectedly started another session"
    fi

    : >"$log"
    run env -u CI -u ZELLIJ -u PIXI_HOME HOME="$home" \
        XDG_DATA_HOME="$data" XDG_CONFIG_HOME="$config" XDG_STATE_HOME="$state" \
        PIXIED_MACHINE_ID="$machine_id" PATH="$data/pixied/bin:$data/pixied/pixi/bin:/usr/bin:/bin" \
        PIXIED_COMMAND_LOG="$log" \
        bash -c 'eval "$(bash "$1/pixied/bin/pixied" hook bash)"; printf "hook-finished\n"' \
        bash "$data"
    assert_success
    assert_output --partial 'hook-finished'
    if grep -Fq -- 'zellij attach --create' "$log"; then
        pixied_test_fail "non-interactive hook unexpectedly started Zellij"
    fi
}

# US-103-3
@test "modified runtime hook leaves the sourcing shell unchanged" {
    local home="$PIXIED_TEST_ROOT/phase3-hook-invalid-home"
    local parent_home="$PIXIED_TEST_ROOT/phase3-hook-invalid-parent"
    local data="$PIXIED_TEST_ROOT/phase3-hook-invalid-data"
    local config="$PIXIED_TEST_ROOT/phase3-hook-invalid-config"
    local state="$PIXIED_TEST_ROOT/phase3-hook-invalid-state"
    local runtime_hook="$config/pixied/runtime-hook.bash"
    mkdir -p "$home" "$parent_home"

    run env -u PIXI_HOME HOME="$home" XDG_DATA_HOME="$data" XDG_CONFIG_HOME="$config" \
        XDG_STATE_HOME="$state" PIXIED_MACHINE_ID=phase3-hook-invalid PIXIED_SESSION_MANAGER=none \
        PIXIED_PIXI_BINARY_SOURCE="$PIXIED_REPO_ROOT/tests/fakes/pixi" \
        bash "$PIXIED_REPO_ROOT/install-local.sh"
    assert_success
    printf '\n# invalidated by the test\n' >>"$runtime_hook"

    run env -u PIXI_HOME HOME="$parent_home" PIXI_HOME=host-pixi \
        PIXIED_RUNTIME_STATE_FILE="$state/pixied/machines/phase3-hook-invalid/state" \
        bash -c '. "$1"; printf "home=%s\npixi=%s\nactive=%s\n" "$HOME" "${PIXI_HOME:-unset}" "${PIXIED_RUNTIME_HOOK_ACTIVE:-unset}"' \
        bash "$runtime_hook"
    assert_success
    assert_output --partial "home=$parent_home"
    assert_output --partial 'pixi=host-pixi'
    assert_output --partial 'active=unset'
    assert_output --partial 'runtime state is unavailable'
}

# US-104-1
# US-104-2
# US-104-3
@test "run command bypasses Zellij and returns the child status" {
    local home="$PIXIED_TEST_ROOT/phase3-command-home"
    local data="$PIXIED_TEST_ROOT/phase3-command-data"
    local config="$PIXIED_TEST_ROOT/phase3-command-config"
    local state="$PIXIED_TEST_ROOT/phase3-command-state"
    local log="$PIXIED_TEST_ROOT/phase3-command.log"
    mkdir -p "$home"
    : >"$log"

    run env -u PIXI_HOME HOME="$home" XDG_DATA_HOME="$data" XDG_CONFIG_HOME="$config" \
        XDG_STATE_HOME="$state" PIXIED_MACHINE_ID=phase3-command PIXIED_SESSION_MANAGER=zellij \
        PIXIED_PIXI_BINARY_SOURCE="$PIXIED_REPO_ROOT/tests/fakes/pixi" \
        bash "$PIXIED_REPO_ROOT/install-local.sh"
    assert_success

    run env -u PIXI_HOME HOME="$home" XDG_DATA_HOME="$data" XDG_CONFIG_HOME="$config" \
        XDG_STATE_HOME="$state" PIXIED_MACHINE_ID=phase3-command PIXIED_SESSION_MANAGER=zellij \
        PIXIED_COMMAND_LOG="$log" bash "$data/pixied/bin/pixied" run bash -c \
        'printf "child_home=%s\nchild_pixi=%s\nchild_pixied=%s\n" "$HOME" "$PIXI_HOME" "$(command -v pixied)"; exit 0'
    assert_success
    assert_output --partial "child_home=$home"
    assert_output --partial "child_pixi=$data/pixied/pixi"
    assert_output --partial "child_pixied=$home/.local/bin/pixied"

    run env -u PIXI_HOME HOME="$home" XDG_DATA_HOME="$data" XDG_CONFIG_HOME="$config" \
        XDG_STATE_HOME="$state" PIXIED_MACHINE_ID=phase3-command PIXIED_SESSION_MANAGER=zellij \
        PIXIED_COMMAND_LOG="$log" bash "$data/pixied/bin/pixied" run bash -c \
        'printf "child_home=%s\nchild_pixi=%s\n" "$HOME" "$PIXI_HOME"; exit 7'
    assert_failure 7
    assert_output --partial "child_home=$home"
    assert_output --partial "child_pixi=$data/pixied/pixi"

    run env -u PIXI_HOME HOME="$home" XDG_DATA_HOME="$data" XDG_CONFIG_HOME="$config" \
        XDG_STATE_HOME="$state" PIXIED_MACHINE_ID=phase3-command PIXIED_SESSION_MANAGER=zellij \
        PIXIED_COMMAND_LOG="$log" bash "$data/pixied/bin/pixied" run bash -c \
        'kill -TERM "$$"'
    assert_failure 143
    ! grep -Fq -- 'attach --create' "$log" ||
        pixied_test_fail "explicit command unexpectedly attached to Zellij"
}

# US-105-1
@test "none session starts an interactive dedicated Bash" {
    command -v script >/dev/null 2>&1 || skip "script command is required for the TTY test"
    local home="$PIXIED_TEST_ROOT/phase3-none-session-home"
    local data="$PIXIED_TEST_ROOT/phase3-none-session-data"
    local config="$PIXIED_TEST_ROOT/phase3-none-session-config"
    local state="$PIXIED_TEST_ROOT/phase3-none-session-state"
    mkdir -p "$home"

    run env -u PIXI_HOME HOME="$home" XDG_DATA_HOME="$data" XDG_CONFIG_HOME="$config" \
        XDG_STATE_HOME="$state" PIXIED_MACHINE_ID=phase3-none-session \
        PIXIED_SESSION_MANAGER=none PIXIED_PIXI_BINARY_SOURCE="$PIXIED_REPO_ROOT/tests/fakes/pixi" \
        bash "$PIXIED_REPO_ROOT/install-local.sh"
    assert_success

    run env -u PIXI_HOME HOME="$home" XDG_DATA_HOME="$data" XDG_CONFIG_HOME="$config" \
        XDG_STATE_HOME="$state" PIXIED_MACHINE_ID=phase3-none-session \
        bash -c '
        printf "%s\n" '\''printf none-session >"$HOME/none-session"'\'' exit |
            script -qec "bash \"$1/pixied/bin/pixied\" shell" /dev/null
    ' bash "$data"
    assert_success
    assert_equal 'none-session' "$(<"$home/none-session")"
}

# US-101-3
@test "session manager changes require uninstall" {
    local home="$PIXIED_TEST_ROOT/phase2-options-home"
    local data="$PIXIED_TEST_ROOT/phase2-options-data"
    local state="$PIXIED_TEST_ROOT/phase2-options-state"
    local fake_source="$PIXIED_REPO_ROOT/tests/fakes/pixi"
    local cli="$PIXIED_REPO_ROOT/bin/pixied"
    local state_file="$state/pixied/machines/phase2-options/state"
    mkdir -p "$home"

    run env -u PIXI_HOME HOME="$home" XDG_DATA_HOME="$data" XDG_STATE_HOME="$state" \
        PIXIED_MACHINE_ID=phase2-options PIXIED_SESSION_MANAGER=none \
        PIXIED_PIXI_BINARY_SOURCE="$fake_source" bash "$cli" install
    assert_success

    run env -u PIXI_HOME HOME="$home" XDG_DATA_HOME="$data" XDG_STATE_HOME="$state" \
        PIXIED_MACHINE_ID=phase2-options PIXIED_SESSION_MANAGER=none \
        PIXIED_PIXI_BINARY_SOURCE="$fake_source" bash "$cli" install --session-manager zellij
    assert_failure 1
    assert_output --partial 'cannot change session manager during reinstall'
    grep -Fq -- 'session_manager=none' "$state_file" ||
        pixied_test_fail "session manager state was changed unexpectedly"
    [ ! -e "$data/pixied/pixi/bin/zellij" ] ||
        pixied_test_fail "CLI-selected zellij was installed before uninstall"
}

# US-101-3
@test "interrupted Pixi provisioning can resume" {
    local home="$PIXIED_TEST_ROOT/phase2-recovery-home"
    local data="$PIXIED_TEST_ROOT/phase2-recovery-data"
    local state="$PIXIED_TEST_ROOT/phase2-recovery-state"
    local fake_source="$PIXIED_REPO_ROOT/tests/fakes/pixi"
    local state_file="$state/pixied/machines/phase2-recovery/state"
    mkdir -p "$home"

    run env -u PIXI_HOME HOME="$home" XDG_DATA_HOME="$data" XDG_STATE_HOME="$state" \
        PIXIED_MACHINE_ID=phase2-recovery PIXIED_SESSION_MANAGER=none \
        PIXIED_PIXI_BINARY_SOURCE="$fake_source" PIXIED_FAKE_PIXI_FAIL_VERSION=1 \
        bash "$PIXIED_REPO_ROOT/bin/pixied" install
    assert_failure 1
    [ -f "$state_file" ] || pixied_test_fail "checkpoint state was not written"
    grep -Eq -- '^pixi_binary_hash=[0-9a-f]{64}$' "$state_file" ||
        pixied_test_fail "checkpoint Pixi hash was not persisted"

    run env -u PIXI_HOME HOME="$home" XDG_DATA_HOME="$data" XDG_CONFIG_HOME="$config" \
        XDG_STATE_HOME="$state" PIXIED_MACHINE_ID=phase2-recovery PIXIED_SESSION_MANAGER=none \
        PIXIED_PIXI_BINARY_SOURCE="$fake_source" bash "$PIXIED_REPO_ROOT/bin/pixied" install
    assert_success
}

# US-107-3
@test "uninstall removes an owned local installation without removing the home parent" {
    local home="$PIXIED_TEST_ROOT/phase6-local-home"
    local data="$PIXIED_TEST_ROOT/phase6-local-data"
    local config="$PIXIED_TEST_ROOT/phase6-local-config"
    local state="$PIXIED_TEST_ROOT/phase6-local-state"
    local log="$PIXIED_TEST_ROOT/phase6-local.log"
    local existing_pixi="$home/existing-pixi"
    mkdir -p "$home" "$existing_pixi/bin"
    printf 'pre-existing Pixi\n' >"$existing_pixi/bin/pixi"

    run env HOME="$home" PIXI_HOME="$existing_pixi" XDG_DATA_HOME="$data" XDG_CONFIG_HOME="$config" \
        XDG_STATE_HOME="$state" PIXIED_COMMAND_LOG="$log" \
        PIXIED_MACHINE_ID=phase6-local PIXIED_HOME_MODE=local PIXIED_SESSION_MANAGER=none \
        PIXIED_PIXI_BINARY_SOURCE="$PIXIED_REPO_ROOT/tests/fakes/pixi" \
        bash "$PIXIED_REPO_ROOT/install-local.sh" --yes
    assert_success
    [ -x "$home/.local/bin/pixied" ] || pixied_test_fail "launcher was not created"

    run env HOME="$home" PIXI_HOME="$existing_pixi" XDG_DATA_HOME="$data" XDG_CONFIG_HOME="$config" \
        XDG_STATE_HOME="$state" PIXIED_COMMAND_LOG="$log" \
        PIXIED_MACHINE_ID=phase6-local PIXIED_HOME_MODE=local \
        bash "$data/pixied/bin/pixied" uninstall --yes
    assert_success
    [ ! -e "$data/pixied" ] || pixied_test_fail "owned data directory remains"
    [ ! -e "$home/.local/bin/pixied" ] || pixied_test_fail "owned launcher remains"
    [ ! -e "$state/pixied/machines/phase6-local/state" ] ||
        pixied_test_fail "current state remains"
    [ -d "$home" ] || pixied_test_fail "account home was removed"
    assert_equal 'pre-existing Pixi' "$(<"$existing_pixi/bin/pixi")"
    if command grep -Eq -- '^(zellij|systemctl|loginctl|sudo) ' "$log"; then
        pixied_test_fail "none-mode uninstall called a session-related command"
    fi
}

# US-106-1
# US-107-3
@test "uninstall removes an NFS Pixi home but preserves PIXIED_LOCAL_HOME" {
    local home="$PIXIED_TEST_ROOT/phase6-nfs-home"
    local local_home="$PIXIED_TEST_ROOT/phase6-nfs-local-home"
    local data="$PIXIED_TEST_ROOT/phase6-nfs-data"
    local config="$PIXIED_TEST_ROOT/phase6-nfs-config"
    local state="$PIXIED_TEST_ROOT/phase6-nfs-state"
    mkdir -p "$home" "$local_home"

    run env -u PIXI_HOME HOME="$home" XDG_DATA_HOME="$data" XDG_CONFIG_HOME="$config" \
        XDG_STATE_HOME="$state" PIXIED_HOME_MODE=nfs PIXIED_LOCAL_HOME="$local_home" \
        PIXIED_MACHINE_ID=phase6-nfs PIXIED_SESSION_MANAGER=none \
        PIXIED_PIXI_BINARY_SOURCE="$PIXIED_REPO_ROOT/tests/fakes/pixi" \
        bash "$PIXIED_REPO_ROOT/install-local.sh" --yes
    assert_success

    run env -u PIXI_HOME HOME="$home" XDG_DATA_HOME="$data" XDG_CONFIG_HOME="$config" \
        XDG_STATE_HOME="$state" PIXIED_HOME_MODE=nfs PIXIED_LOCAL_HOME="$local_home" \
        PIXIED_MACHINE_ID=phase6-nfs \
        bash "$data/pixied/bin/pixied" uninstall --yes
    assert_success
    [ ! -e "$data/pixied" ] || pixied_test_fail "NFS data directory remains"
    [ ! -e "$local_home/.local/share/pixied/pixi" ] ||
        pixied_test_fail "dedicated NFS Pixi home remains"
    [ -d "$local_home" ] || pixied_test_fail "PIXIED_LOCAL_HOME was removed"
}

# US-107-2
# US-107-3
@test "uninstall keeps shared resources until the last machine" {
    local home="$PIXIED_TEST_ROOT/phase6-shared-home"
    local data="$PIXIED_TEST_ROOT/phase6-shared-data"
    local config="$PIXIED_TEST_ROOT/phase6-shared-config"
    local state="$PIXIED_TEST_ROOT/phase6-shared-state"
    local log="$PIXIED_TEST_ROOT/phase6-shared.log"
    mkdir -p "$home"

    run env -u PIXI_HOME HOME="$home" XDG_DATA_HOME="$data" XDG_CONFIG_HOME="$config" \
        XDG_STATE_HOME="$state" PIXIED_COMMAND_LOG="$log" \
        PIXIED_MACHINE_ID=phase6-shared-one PIXIED_HOME_MODE=local PIXIED_SESSION_MANAGER=none \
        PIXIED_PIXI_BINARY_SOURCE="$PIXIED_REPO_ROOT/tests/fakes/pixi" \
        bash "$PIXIED_REPO_ROOT/install-local.sh" --yes
    assert_success

    run env -u PIXI_HOME HOME="$home" XDG_DATA_HOME="$data" XDG_CONFIG_HOME="$config" \
        XDG_STATE_HOME="$state" PIXIED_COMMAND_LOG="$log" \
        PIXIED_MACHINE_ID=phase6-shared-two PIXIED_HOME_MODE=local PIXIED_SESSION_MANAGER=none \
        PIXIED_PIXI_BINARY_SOURCE="$PIXIED_REPO_ROOT/tests/fakes/pixi" \
        bash "$data/pixied/bin/pixied" install --yes
    assert_success

    run env -u PIXI_HOME HOME="$home" XDG_DATA_HOME="$data" XDG_CONFIG_HOME="$config" \
        XDG_STATE_HOME="$state" PIXIED_COMMAND_LOG="$log" \
        PIXIED_MACHINE_ID=phase6-shared-one PIXIED_HOME_MODE=local \
        bash "$data/pixied/bin/pixied" uninstall --yes
    assert_success
    [ ! -e "$state/pixied/machines/phase6-shared-one/state" ] ||
        pixied_test_fail "first machine state remains"
    [ -f "$state/pixied/machines/phase6-shared-two/state" ] ||
        pixied_test_fail "second machine state was removed"
    [ -x "$data/pixied/bin/pixi" ] || pixied_test_fail "shared Pixi binary was removed"
    [ -f "$config/pixied/runtime-hook.bash" ] || pixied_test_fail "shared runtime hook was removed"
    [ -x "$home/.local/bin/pixied" ] || pixied_test_fail "shared launcher was removed"

    run env -u PIXI_HOME HOME="$home" XDG_DATA_HOME="$data" XDG_CONFIG_HOME="$config" \
        XDG_STATE_HOME="$state" PIXIED_COMMAND_LOG="$log" \
        PIXIED_MACHINE_ID=phase6-shared-two PIXIED_HOME_MODE=local \
        bash "$data/pixied/bin/pixied" uninstall --yes
    assert_success
    [ ! -e "$data/pixied" ] || pixied_test_fail "last machine left shared data"
    [ ! -e "$config/pixied/runtime-hook.bash" ] || pixied_test_fail "last machine left runtime hook"
    [ ! -e "$home/.local/bin/pixied" ] || pixied_test_fail "last machine left launcher"
    [ ! -e "$state/pixied/machines/phase6-shared-two/state" ] ||
        pixied_test_fail "last machine state remains"
    [ -d "$home" ] || pixied_test_fail "shared account home was removed"
}

# US-107-1
@test "uninstall stops when a managed artifact hash does not match" {
    local home="$PIXIED_TEST_ROOT/phase6-hash-home"
    local data="$PIXIED_TEST_ROOT/phase6-hash-data"
    local config="$PIXIED_TEST_ROOT/phase6-hash-config"
    local state="$PIXIED_TEST_ROOT/phase6-hash-state"
    local runtime_hook="$config/pixied/runtime-hook.bash"
    mkdir -p "$home"

    run env -u PIXI_HOME HOME="$home" XDG_DATA_HOME="$data" XDG_CONFIG_HOME="$config" \
        XDG_STATE_HOME="$state" PIXIED_MACHINE_ID=phase6-hash \
        PIXIED_HOME_MODE=local PIXIED_SESSION_MANAGER=none \
        PIXIED_PIXI_BINARY_SOURCE="$PIXIED_REPO_ROOT/tests/fakes/pixi" \
        bash "$PIXIED_REPO_ROOT/install-local.sh" --yes
    assert_success
    printf '\nmodified by test\n' >>"$runtime_hook"

    run env -u PIXI_HOME HOME="$home" XDG_DATA_HOME="$data" XDG_CONFIG_HOME="$config" \
        XDG_STATE_HOME="$state" PIXIED_MACHINE_ID=phase6-hash PIXIED_HOME_MODE=local \
        bash "$data/pixied/bin/pixied" uninstall --yes
    assert_failure 1
    assert_output --partial 'managed path hash does not match'
    [ -f "$state/pixied/machines/phase6-hash/state" ] || pixied_test_fail "state was removed after hash mismatch"
    [ -d "$data/pixied" ] || pixied_test_fail "data was removed after hash mismatch"
    [ ! -e "$state/pixied/.lock" ] || pixied_test_fail "state lock was left behind"
}

# US-107-1
@test "uninstall rejects a managed path outside its boundary" {
    local home="$PIXIED_TEST_ROOT/phase6-path-home"
    local data="$PIXIED_TEST_ROOT/phase6-path-data"
    local config="$PIXIED_TEST_ROOT/phase6-path-config"
    local state="$PIXIED_TEST_ROOT/phase6-path-state"
    local state_file="$state/pixied/machines/phase6-path/state"
    local foreign_path="$PIXIED_TEST_ROOT/foreign-runtime-hook"
    mkdir -p "$home"

    run env -u PIXI_HOME HOME="$home" XDG_DATA_HOME="$data" XDG_CONFIG_HOME="$config" \
        XDG_STATE_HOME="$state" PIXIED_MACHINE_ID=phase6-path \
        PIXIED_HOME_MODE=local PIXIED_SESSION_MANAGER=none \
        PIXIED_PIXI_BINARY_SOURCE="$PIXIED_REPO_ROOT/tests/fakes/pixi" \
        bash "$PIXIED_REPO_ROOT/install-local.sh" --yes
    assert_success
    sed -i "s#^runtime_hook_path=.*#runtime_hook_path=$foreign_path#" "$state_file"

    run env -u PIXI_HOME HOME="$home" XDG_DATA_HOME="$data" XDG_CONFIG_HOME="$config" \
        XDG_STATE_HOME="$state" PIXIED_MACHINE_ID=phase6-path PIXIED_HOME_MODE=local \
        bash "$data/pixied/bin/pixied" uninstall --yes
    assert_failure 1
    assert_output --partial 'uninstall state runtime_hook_path is outside its managed boundary'
    [ -f "$state_file" ] || pixied_test_fail "state was removed after path mismatch"
    [ -d "$data/pixied" ] || pixied_test_fail "data was removed after path mismatch"
}

# US-107-4
@test "interrupted install can be resumed and then uninstalled" {
    local home="$PIXIED_TEST_ROOT/phase6-recovery-home"
    local data="$PIXIED_TEST_ROOT/phase6-recovery-data"
    local config="$PIXIED_TEST_ROOT/phase6-recovery-config"
    local state="$PIXIED_TEST_ROOT/phase6-recovery-state"
    local state_file="$state/pixied/machines/phase6-recovery/state"
    mkdir -p "$home"

    run env -u PIXI_HOME HOME="$home" XDG_DATA_HOME="$data" XDG_CONFIG_HOME="$config" \
        XDG_STATE_HOME="$state" PIXIED_MACHINE_ID=phase6-recovery \
        PIXIED_HOME_MODE=local PIXIED_SESSION_MANAGER=none \
        PIXIED_PIXI_BINARY_SOURCE="$PIXIED_REPO_ROOT/tests/fakes/pixi" \
        PIXIED_FAKE_PIXI_FAIL_VERSION=1 bash "$PIXIED_REPO_ROOT/bin/pixied" install
    assert_failure 1
    [ -f "$state_file" ] || pixied_test_fail "interrupted install left no checkpoint state"

    run env -u PIXI_HOME HOME="$home" XDG_DATA_HOME="$data" XDG_CONFIG_HOME="$config" \
        XDG_STATE_HOME="$state" PIXIED_MACHINE_ID=phase6-recovery \
        PIXIED_HOME_MODE=local PIXIED_SESSION_MANAGER=none \
        PIXIED_PIXI_BINARY_SOURCE="$PIXIED_REPO_ROOT/tests/fakes/pixi" \
        bash "$PIXIED_REPO_ROOT/bin/pixied" install --yes
    assert_success

    run env -u PIXI_HOME HOME="$home" XDG_DATA_HOME="$data" XDG_CONFIG_HOME="$config" \
        XDG_STATE_HOME="$state" PIXIED_MACHINE_ID=phase6-recovery PIXIED_HOME_MODE=local \
        bash "$PIXIED_REPO_ROOT/bin/pixied" uninstall --yes
    assert_success
    [ ! -e "$data/pixied" ] || pixied_test_fail "resumed installation data remains"
    [ ! -e "$state_file" ] || pixied_test_fail "resumed installation state remains"
}

# US-107-4
@test "uninstall restores a state left in quarantine by an interruption" {
    local home="$PIXIED_TEST_ROOT/phase6-pending-home"
    local data="$PIXIED_TEST_ROOT/phase6-pending-data"
    local config="$PIXIED_TEST_ROOT/phase6-pending-config"
    local state="$PIXIED_TEST_ROOT/phase6-pending-state"
    local state_file="$state/pixied/machines/phase6-pending/state"
    local pending_state="$state/pixied/machines/phase6-pending/.pixied-quarantine-phase6-pending-123-state"
    local pending_data="$data/.pixied-quarantine-phase6-pending-123-pixied"
    mkdir -p "$home"

    run env -u PIXI_HOME HOME="$home" XDG_DATA_HOME="$data" XDG_CONFIG_HOME="$config" \
        XDG_STATE_HOME="$state" PIXIED_MACHINE_ID=phase6-pending \
        PIXIED_HOME_MODE=local PIXIED_SESSION_MANAGER=none \
        PIXIED_PIXI_BINARY_SOURCE="$PIXIED_REPO_ROOT/tests/fakes/pixi" \
        bash "$PIXIED_REPO_ROOT/install-local.sh" --yes
    assert_success
    mv "$data/pixied" "$pending_data"
    mv "$state_file" "$pending_state"

    run env -u PIXI_HOME HOME="$home" XDG_DATA_HOME="$data" XDG_CONFIG_HOME="$config" \
        XDG_STATE_HOME="$state" PIXIED_MACHINE_ID=phase6-pending PIXIED_HOME_MODE=local \
        bash "$PIXIED_REPO_ROOT/bin/pixied" uninstall --yes
    assert_success
    [ ! -e "$data/pixied" ] || pixied_test_fail "pending installation data remains"
    [ ! -e "$pending_data" ] || pixied_test_fail "stale data quarantine remains"
    [ ! -e "$state_file" ] || pixied_test_fail "restored state remains"
    [ ! -e "$pending_state" ] || pixied_test_fail "pending state quarantine remains"
}

@test "uninstall refuses an active direct-attach Zellij session" {
    local home="$PIXIED_TEST_ROOT/phase6-active-session-home"
    local data="$PIXIED_TEST_ROOT/phase6-active-session-data"
    local config="$PIXIED_TEST_ROOT/phase6-active-session-config"
    local state="$PIXIED_TEST_ROOT/phase6-active-session-state"
    mkdir -p "$home"

    run env -u PIXI_HOME HOME="$home" XDG_DATA_HOME="$data" XDG_CONFIG_HOME="$config" \
        XDG_STATE_HOME="$state" PIXIED_MACHINE_ID=phase6-active-session \
        PIXIED_HOME_MODE=local PIXIED_SESSION_MANAGER=zellij \
        PIXIED_PIXI_BINARY_SOURCE="$PIXIED_REPO_ROOT/tests/fakes/pixi" \
        bash "$PIXIED_REPO_ROOT/install-local.sh" --yes
    assert_success

    run env -u PIXI_HOME HOME="$home" XDG_DATA_HOME="$data" XDG_CONFIG_HOME="$config" \
        XDG_STATE_HOME="$state" PIXIED_MACHINE_ID=phase6-active-session \
        PIXIED_FAKE_ZELLIJ_REMAINS=1 \
        PIXIED_FAKE_ZELLIJ_SESSION_NAME=pixied \
        bash "$data/pixied/bin/pixied" uninstall --yes
    assert_failure 1
    assert_output --partial 'managed Zellij session is active'
    [ -f "$state/pixied/machines/phase6-active-session/state" ] ||
        pixied_test_fail "state was removed while the Zellij session was active"
    [ -d "$data/pixied" ] ||
        pixied_test_fail "data was removed while the Zellij session was active"
}

@test "uninstall warns and continues when the managed Zellij session cannot be inspected" {
    local home="$PIXIED_TEST_ROOT/phase6-session-list-failure-home"
    local data="$PIXIED_TEST_ROOT/phase6-session-list-failure-data"
    local config="$PIXIED_TEST_ROOT/phase6-session-list-failure-config"
    local state="$PIXIED_TEST_ROOT/phase6-session-list-failure-state"
    mkdir -p "$home"

    run env -u PIXI_HOME HOME="$home" XDG_DATA_HOME="$data" XDG_CONFIG_HOME="$config" \
        XDG_STATE_HOME="$state" PIXIED_MACHINE_ID=phase6-session-list-failure \
        PIXIED_HOME_MODE=local PIXIED_SESSION_MANAGER=zellij \
        PIXIED_PIXI_BINARY_SOURCE="$PIXIED_REPO_ROOT/tests/fakes/pixi" \
        bash "$PIXIED_REPO_ROOT/install-local.sh" --yes
    assert_success

    run env -u PIXI_HOME HOME="$home" XDG_DATA_HOME="$data" XDG_CONFIG_HOME="$config" \
        XDG_STATE_HOME="$state" PIXIED_MACHINE_ID=phase6-session-list-failure \
        PIXIED_FAKE_ZELLIJ_LIST_FAIL=1 \
        bash "$data/pixied/bin/pixied" uninstall --yes
    assert_success
    assert_output --partial 'could not inspect the managed Zellij session'
    [ ! -e "$state/pixied/machines/phase6-session-list-failure/state" ] ||
        pixied_test_fail "state remains when the Zellij session list failed"
    [ ! -e "$data/pixied" ] ||
        pixied_test_fail "data remains when the Zellij session list failed"
}

# US-101-3
@test "saved installation paths are restored on reinstall" {
    local home="$PIXIED_TEST_ROOT/phase2-path-home"
    local data_one="$PIXIED_TEST_ROOT/phase2-path-data-one"
    local data_two="$PIXIED_TEST_ROOT/phase2-path-data-two"
    local config_one="$PIXIED_TEST_ROOT/phase2-path-config-one"
    local state="$PIXIED_TEST_ROOT/phase2-path-state"
    local fake_source="$PIXIED_REPO_ROOT/tests/fakes/pixi"
    mkdir -p "$home"

    run env -u PIXI_HOME HOME="$home" XDG_DATA_HOME="$data_one" \
        XDG_CONFIG_HOME="$config_one" XDG_STATE_HOME="$state" \
        PIXIED_MACHINE_ID=phase2-path PIXIED_SESSION_MANAGER=none \
        PIXIED_PIXI_BINARY_SOURCE="$fake_source" bash "$PIXIED_REPO_ROOT/bin/pixied" install
    assert_success

    run env -u PIXI_HOME HOME="$home" XDG_DATA_HOME="$data_two" \
        XDG_CONFIG_HOME="$PIXIED_TEST_ROOT/phase2-path-config-two" XDG_STATE_HOME="$state" \
        PIXIED_MACHINE_ID=phase2-path PIXIED_SESSION_MANAGER=none \
        PIXIED_PIXI_BINARY_SOURCE="$fake_source" bash "$PIXIED_REPO_ROOT/bin/pixied" install
    assert_success
    [ -x "$data_one/pixied/bin/pixi" ] || pixied_test_fail "saved data path was not reused"
    [ ! -e "$data_two/pixied/bin/pixi" ] || pixied_test_fail "new data path was used"
}

@test "creation flags reflect pre-existing managed directories" {
    local home="$PIXIED_TEST_ROOT/phase2-created-home"
    local data="$PIXIED_TEST_ROOT/phase2-created-data"
    local state="$PIXIED_TEST_ROOT/phase2-created-state"
    local state_file="$state/pixied/machines/phase2-created/state"
    mkdir -p "$home" "$data/pixied"

    run env -u PIXI_HOME HOME="$home" XDG_DATA_HOME="$data" XDG_STATE_HOME="$state" \
        PIXIED_MACHINE_ID=phase2-created PIXIED_SESSION_MANAGER=none \
        PIXIED_PIXI_BINARY_SOURCE="$PIXIED_REPO_ROOT/tests/fakes/pixi" \
        bash "$PIXIED_REPO_ROOT/bin/pixied" install
    assert_success
    grep -Fq -- 'created_data=0' "$state_file" || pixied_test_fail "existing data was marked as created"
    grep -Fq -- 'created_pixi_home=1' "$state_file" || pixied_test_fail "new Pixi home was not marked as created"
}

@test "install refuses an unverified existing Pixi home before Global provision" {
    local home="$PIXIED_TEST_ROOT/phase2-unmanaged-pixi-home"
    local data="$PIXIED_TEST_ROOT/phase2-unmanaged-pixi-data"
    local state="$PIXIED_TEST_ROOT/phase2-unmanaged-pixi-state"
    local existing_pixi="$PIXIED_TEST_ROOT/phase2-unmanaged-pixi-existing"
    local log="$PIXIED_TEST_ROOT/phase2-unmanaged-pixi.log"
    mkdir -p "$home" "$existing_pixi"
    printf '%s\n' 'keep this Pixi home' >"$existing_pixi/marker"
    : >"$log"

    run env -u PIXI_HOME HOME="$home" XDG_DATA_HOME="$data" XDG_STATE_HOME="$state" \
        PIXIED_PIXI_HOME="$existing_pixi" PIXIED_COMMAND_LOG="$log" \
        PIXIED_MACHINE_ID=phase2-unmanaged-pixi PIXIED_SESSION_MANAGER=none \
        PIXIED_PIXI_BINARY_SOURCE="$PIXIED_REPO_ROOT/tests/fakes/pixi" \
        bash "$PIXIED_REPO_ROOT/install-local.sh" --yes
    assert_failure
    assert_output --partial 'refusing to use an unverified existing Pixi home'
    assert_equal 'keep this Pixi home' "$(<"$existing_pixi/marker")"
    [ ! -e "$existing_pixi/bin/direnv" ] ||
        pixied_test_fail "unverified Pixi home received direnv"
    [ ! -e "$existing_pixi/bin/zellij" ] ||
        pixied_test_fail "unverified Pixi home received zellij"
    if grep -Fq -- 'global install' "$log"; then
        pixied_test_fail "Global provision ran for an unverified Pixi home"
    fi
}

@test "Pixi checksum mismatch stops before binary installation" {
    local home="$PIXIED_TEST_ROOT/phase2-checksum-home"
    local data="$PIXIED_TEST_ROOT/phase2-checksum-data"
    local state="$PIXIED_TEST_ROOT/phase2-checksum-state"
    mkdir -p "$home"

    run env -u PIXI_HOME HOME="$home" XDG_DATA_HOME="$data" XDG_STATE_HOME="$state" \
        PIXIED_MACHINE_ID=phase2-checksum PIXIED_SESSION_MANAGER=none \
        PIXIED_PIXI_BINARY_SOURCE="$PIXIED_REPO_ROOT/tests/fakes/pixi" \
        PIXIED_PIXI_SHA256=0000000000000000000000000000000000000000000000000000000000000000 \
        bash "$PIXIED_REPO_ROOT/bin/pixied" install
    assert_failure 1
    assert_output --partial 'Pixi asset checksum mismatch'
    [ ! -e "$data/pixied/bin/pixi" ] || pixied_test_fail "unverified Pixi binary was installed"
}

@test "command log refuses an existing symlink" {
    local home="$PIXIED_TEST_ROOT/command-log-home"
    local data="$PIXIED_TEST_ROOT/command-log-data"
    local state="$PIXIED_TEST_ROOT/command-log-state"
    local log="$PIXIED_TEST_ROOT/command-log"
    local target="$PIXIED_TEST_ROOT/command-log-target"
    mkdir -p "$home"
    printf 'keep\n' >"$target"
    ln -s "$target" "$log"

    run env -u PIXI_HOME HOME="$home" XDG_DATA_HOME="$data" XDG_STATE_HOME="$state" \
        PIXIED_MACHINE_ID=command-log PIXIED_SESSION_MANAGER=none \
        PIXIED_PIXI_BINARY_SOURCE="$PIXIED_REPO_ROOT/tests/fakes/pixi" \
        PIXIED_COMMAND_LOG="$log" bash "$PIXIED_REPO_ROOT/bin/pixied" install
    assert_failure 1
    assert_output --partial 'command log must not be a symlink'
    assert_equal 'keep' "$(<"$target")"
}

@test "custom Pixi version verifies the official checksum asset" {
    local home="$PIXIED_TEST_ROOT/version-official-home"
    local data="$PIXIED_TEST_ROOT/version-official-data"
    local state="$PIXIED_TEST_ROOT/version-official-state"
    local fake_bin="$PIXIED_TEST_ROOT/version-official-bin"
    local log="$PIXIED_TEST_ROOT/version-official.log"
    local asset="$PIXIED_REPO_ROOT/tests/fakes/pixi"
    mkdir -p "$home" "$fake_bin"
    ln -s "$PIXIED_REPO_ROOT/tests/fakes/curl" "$fake_bin/curl"

    run env -u PIXI_HOME HOME="$home" XDG_DATA_HOME="$data" XDG_STATE_HOME="$state" \
        PATH="$fake_bin:$PATH" \
        PIXIED_MACHINE_ID=version-official PIXIED_SESSION_MANAGER=none \
        PIXIED_PIXI_VERSION=0.99.0 PIXIED_PIXI_ASSET_PATH="$asset" \
        PIXIED_FAKE_SHA256="$(sha256sum "$asset" | cut -d' ' -f1)" \
        PIXIED_COMMAND_LOG="$log" \
        bash "$PIXIED_REPO_ROOT/bin/pixied" install
    assert_success
    grep -Fq -- 'v0.99.0' "$log" || pixied_test_fail "release tag v0.99.0 was not requested"
    grep -Fq -- '--proto' "$log" || pixied_test_fail "Pixi curl download did not require HTTPS"
    grep -Fq -- '--tlsv1.2' "$log" || pixied_test_fail "Pixi curl download did not require TLS 1.2"
    [ -x "$data/pixied/bin/pixi" ] || pixied_test_fail "verified Pixi binary was not installed"
}

@test "Pixi wget downloads require HTTPS and TLS 1.2" {
    run bash -c '
        source "$1/lib/common.sh"
        source "$1/lib/pixi.sh"
        pixied_have_cmd() { [ "$1" = wget ]; }
        pixied_run() { printf "%q " "$@"; }
        pixied_pixi_download https://example.invalid/pixi.tar.gz /tmp/pixi.tar.gz
    ' bash "$PIXIED_REPO_ROOT"
    assert_success
    assert_output --partial '--https-only'
    assert_output --partial '--secure-protocol=TLSv1_2'
}

@test "latest Pixi version resolves the release tag and verifies the checksum" {
    local home="$PIXIED_TEST_ROOT/latest-version-home"
    local data="$PIXIED_TEST_ROOT/latest-version-data"
    local state="$PIXIED_TEST_ROOT/latest-version-state"
    local fake_bin="$PIXIED_TEST_ROOT/latest-version-bin"
    local log="$PIXIED_TEST_ROOT/latest-version.log"
    local asset="$PIXIED_REPO_ROOT/tests/fakes/pixi"
    mkdir -p "$home" "$fake_bin"
    ln -s "$PIXIED_REPO_ROOT/tests/fakes/curl" "$fake_bin/curl"

    run env -u PIXI_HOME HOME="$home" XDG_DATA_HOME="$data" XDG_STATE_HOME="$state" \
        PATH="$fake_bin:$PATH" \
        PIXIED_MACHINE_ID=latest-version PIXIED_SESSION_MANAGER=none \
        PIXIED_PIXI_VERSION=latest PIXIED_PIXI_LATEST_TAG=v0.99.0 \
        PIXIED_PIXI_ASSET_PATH="$asset" \
        PIXIED_FAKE_SHA256="$(sha256sum "$asset" | cut -d' ' -f1)" \
        PIXIED_COMMAND_LOG="$log" \
        bash "$PIXIED_REPO_ROOT/bin/pixied" install
    assert_success
    grep -Fq -- 'v0.99.0' "$log" || pixied_test_fail "latest release tag was not resolved"
    [ -x "$data/pixied/bin/pixi" ] || pixied_test_fail "verified Pixi binary was not installed"
}

@test "latest Pixi version resolves the GitHub API response" {
    local home="$PIXIED_TEST_ROOT/latest-api-home"
    local data="$PIXIED_TEST_ROOT/latest-api-data"
    local state="$PIXIED_TEST_ROOT/latest-api-state"
    local fake_bin="$PIXIED_TEST_ROOT/latest-api-bin"
    local log="$PIXIED_TEST_ROOT/latest-api.log"
    local asset="$PIXIED_REPO_ROOT/tests/fakes/pixi"
    mkdir -p "$home" "$fake_bin"
    ln -s "$PIXIED_REPO_ROOT/tests/fakes/curl" "$fake_bin/curl"

    run env -u PIXI_HOME HOME="$home" XDG_DATA_HOME="$data" XDG_STATE_HOME="$state" \
        PATH="$fake_bin:$PATH" \
        PIXIED_MACHINE_ID=latest-api PIXIED_SESSION_MANAGER=none \
        PIXIED_PIXI_VERSION=latest PIXIED_FAKE_LATEST_RESPONSE='{"tag_name":"v0.99.0"}' \
        PIXIED_PIXI_ASSET_PATH="$asset" \
        PIXIED_FAKE_SHA256="$(sha256sum "$asset" | cut -d' ' -f1)" \
        PIXIED_COMMAND_LOG="$log" bash "$PIXIED_REPO_ROOT/bin/pixied" install
    assert_success
    grep -Fq -- 'v0.99.0' "$log" || pixied_test_fail "API release tag was not used"
}

@test "latest Pixi version rejects malformed GitHub API responses" {
    local fake_bin="$PIXIED_TEST_ROOT/latest-api-invalid-bin"
    local response expected index=0 home data state
    mkdir -p "$fake_bin"
    ln -s "$PIXIED_REPO_ROOT/tests/fakes/curl" "$fake_bin/curl"

    while IFS='|' read -r response expected; do
        home="$PIXIED_TEST_ROOT/latest-api-invalid-home-$index"
        data="$PIXIED_TEST_ROOT/latest-api-invalid-data-$index"
        state="$PIXIED_TEST_ROOT/latest-api-invalid-state-$index"
        mkdir -p "$home"
        run env -u PIXI_HOME HOME="$home" XDG_DATA_HOME="$data" XDG_STATE_HOME="$state" \
            PATH="$fake_bin:$PATH" \
            PIXIED_MACHINE_ID="latest-api-invalid-$index" PIXIED_SESSION_MANAGER=none \
            PIXIED_PIXI_VERSION=latest PIXIED_FAKE_LATEST_RESPONSE="$response" \
            bash "$PIXIED_REPO_ROOT/bin/pixied" install
        assert_failure 1
        assert_output --partial "$expected"
        index=$((index + 1))
    done <<'CASES'
{}|could not resolve the latest Pixi release tag
{"message":"API rate limit exceeded"}|could not resolve the latest Pixi release tag
{"tag_name":"0.99.0"}|invalid Pixi release tag
{"tag_name":"v0.99.0","other":{"tag_name":"v0.98.0"}}|multiple latest Pixi release tags found
CASES
}

@test "official checksum mismatch for a custom version stops before installation" {
    local home="$PIXIED_TEST_ROOT/version-mismatch-home"
    local data="$PIXIED_TEST_ROOT/version-mismatch-data"
    local state="$PIXIED_TEST_ROOT/version-mismatch-state"
    local fake_bin="$PIXIED_TEST_ROOT/version-mismatch-bin"
    mkdir -p "$home" "$fake_bin"
    ln -s "$PIXIED_REPO_ROOT/tests/fakes/curl" "$fake_bin/curl"

    run env -u PIXI_HOME HOME="$home" XDG_DATA_HOME="$data" XDG_STATE_HOME="$state" \
        PATH="$fake_bin:$PATH" \
        PIXIED_MACHINE_ID=version-mismatch PIXIED_SESSION_MANAGER=none \
        PIXIED_PIXI_VERSION=0.99.0 \
        PIXIED_PIXI_ASSET_PATH="$PIXIED_REPO_ROOT/tests/fakes/pixi" \
        PIXIED_FAKE_SHA256=0000000000000000000000000000000000000000000000000000000000000000 \
        bash "$PIXIED_REPO_ROOT/bin/pixied" install
    assert_failure 1
    assert_output --partial 'Pixi asset checksum mismatch'
    [ ! -e "$data/pixied/bin/pixi" ] || pixied_test_fail "unverified Pixi binary was installed"
}

@test "unsafe Pixi archive members are rejected before extraction" {
    local home="$PIXIED_TEST_ROOT/archive-safety-home"
    local data="$PIXIED_TEST_ROOT/archive-safety-data"
    local state="$PIXIED_TEST_ROOT/archive-safety-state"
    local archive="$PIXIED_TEST_ROOT/unsafe-pixi.tar.gz"
    local archive_root="$PIXIED_TEST_ROOT/unsafe-pixi-root"
    local outside="$PIXIED_TEST_ROOT/archive-escape"
    mkdir -p "$home" "$archive_root/pixi"
    cp "$PIXIED_REPO_ROOT/tests/fakes/pixi" "$archive_root/pixi/pixi"
    chmod 0755 "$archive_root/pixi/pixi"
    ln -s "$outside" "$archive_root/pixi/escape"
    tar -czf "$archive" -C "$archive_root" pixi

    run env -u PIXI_HOME HOME="$home" XDG_DATA_HOME="$data" XDG_STATE_HOME="$state" \
        PIXIED_MACHINE_ID=archive-safety PIXIED_SESSION_MANAGER=none \
        PIXIED_PIXI_VERSION=0.99.0 PIXIED_PIXI_ASSET_PATH="$archive" \
        PIXIED_PIXI_SHA256="$(sha256sum "$archive" | cut -d' ' -f1)" \
        bash "$PIXIED_REPO_ROOT/bin/pixied" install
    assert_failure 1
    assert_output --partial 'unsupported Pixi archive member type'
    [ ! -e "$data/pixied/bin/pixi" ] || pixied_test_fail "unsafe Pixi archive was extracted"
    [ ! -e "$outside" ] || pixied_test_fail "unsafe Pixi archive wrote outside extraction directory"
}

@test "local paths and state are resolved and persisted" {
    local home="$PIXIED_TEST_ROOT/phase1-home"
    local data="$PIXIED_TEST_ROOT/phase1-data"
    local config="$PIXIED_TEST_ROOT/phase1-config"
    local state="$PIXIED_TEST_ROOT/phase1-state"
    local bin="$PIXIED_TEST_ROOT/phase1-bin"
    local state_file
    mkdir -p "$home" "$data" "$config" "$state" "$bin"

    run env HOME="$home" XDG_DATA_HOME="$data" XDG_CONFIG_HOME="$config" \
        XDG_STATE_HOME="$state" XDG_BIN_HOME="$bin" PIXIED_HOME_MODE=local \
        PIXIED_MACHINE_ID=phase1-local bash -c '
        set -e
        . "$1/lib/common.sh"
        . "$1/lib/paths.sh"
        . "$1/lib/state.sh"
        pixied_resolve_paths
        test "$PIXIED_ACCOUNT_HOME" = "$HOME"
        test "$PIXIED_LOCAL_HOME" = "$HOME"
        test "$PIXIED_PIXI_HOME" = "$2/pixied/pixi"
        mkdir -p "$PIXIED_MACHINE_STATE_DIR"
        pixied_state_initialize_from_paths
        pixied_state_lock_acquire
        pixied_state_write
        pixied_state_lock_release
        pixied_state_load
        test "$(pixied_state_get machine_id)" = phase1-local
        printf "%s\n%s\n" "$PIXIED_PIXI_HOME" "$PIXIED_STATE_FILE"
    ' bash "$PIXIED_REPO_ROOT" "$data"
    assert_success
    state_file="$state/pixied/machines/phase1-local/state"
    [ -f "$state_file" ] || pixied_test_fail "expected state file: $state_file"
    grep -Fq -- "account_home=$home" "$state_file" || pixied_test_fail "account home is missing"
    grep -Fq -- 'state_version=1' "$state_file" || pixied_test_fail "state version is missing"
    ! grep -Fq -- 'eval ' "$state_file" || pixied_test_fail "state contains executable code"
    [[ "$output" == *"$data/pixied/pixi"* ]] ||
        pixied_test_fail "local PIXI_HOME was not derived from local data path"
}

@test "explicit local mode continues on an NFS account home with a warning" {
    local home="$PIXIED_TEST_ROOT/explicit-local-nfs-home"
    local data="$PIXIED_TEST_ROOT/explicit-local-nfs-data"
    local config="$PIXIED_TEST_ROOT/explicit-local-nfs-config"
    local state="$PIXIED_TEST_ROOT/explicit-local-nfs-state"
    local bin="$PIXIED_TEST_ROOT/explicit-local-nfs-bin"
    local fake_bin="$PIXIED_TEST_ROOT/explicit-local-nfs-fake-bin"
    mkdir -p "$home" "$data" "$config" "$state" "$bin" "$fake_bin"
    printf '#!/usr/bin/env bash\ncase "$*" in\n*%s*) exit 1 ;;\n*) exec /usr/bin/df "$@" ;;\nesac\n' \
        "$home" >"$fake_bin/df"
    chmod 0755 "$fake_bin/df"

    run env PATH="$fake_bin:/usr/bin:/bin" HOME="$home" \
        XDG_DATA_HOME="$data" XDG_CONFIG_HOME="$config" XDG_STATE_HOME="$state" \
        XDG_BIN_HOME="$bin" PIXIED_HOME_MODE=local PIXIED_MACHINE_ID=explicit-local-nfs \
        bash -c '
        . "$1/lib/common.sh"
        . "$1/lib/paths.sh"
        pixied_resolve_paths
        printf "%s\n" "$PIXIED_HOME_MODE" "$PIXIED_LOCAL_HOME"
    ' bash "$PIXIED_REPO_ROOT"
    assert_success
    assert_output --partial "account home is not on a local filesystem"
    assert_output --partial "NFS synchronization is disabled"
    [[ "$output" == *$'local\n'$home* ]] ||
        pixied_test_fail "explicit local mode did not continue with the account home"
}

# US-106-1
@test "NFS paths use a separate local home" {
    local home="$PIXIED_TEST_ROOT/nfs-account"
    local local_home="$PIXIED_TEST_ROOT/nfs-local"
    local data="$PIXIED_TEST_ROOT/nfs-data"
    local config="$PIXIED_TEST_ROOT/nfs-config"
    local state="$PIXIED_TEST_ROOT/nfs-state"
    local bin="$PIXIED_TEST_ROOT/nfs-bin"
    local fake_bin="$PIXIED_TEST_ROOT/nfs-fake-bin"
    mkdir -p "$home" "$local_home" "$data" "$config" "$state" "$bin" "$fake_bin"
    printf '#!/usr/bin/env bash\ncase "$*" in\n*%s*|*%s*) exit 1 ;;\n*) exec /usr/bin/df "$@" ;;\nesac\n' \
        "$home" "$data" >"$fake_bin/df"
    chmod 0755 "$fake_bin/df"

    run env PATH="$fake_bin:/usr/bin:/bin" HOME="$home" \
        PIXIED_LOCAL_HOME="$local_home" XDG_DATA_HOME="$data" \
        XDG_CONFIG_HOME="$config" XDG_STATE_HOME="$state" XDG_BIN_HOME="$bin" \
        PIXIED_HOME_MODE=nfs PIXIED_MACHINE_ID=phase1-nfs bash -c '
        set -e
        . "$1/lib/common.sh"
        . "$1/lib/paths.sh"
        pixied_resolve_paths
        test "$PIXIED_ACCOUNT_HOME" = "$2"
        test "$PIXIED_LOCAL_HOME" = "$3"
        test "$PIXIED_ACCOUNT_HOME" != "$PIXIED_LOCAL_HOME"
        test "$PIXIED_PIXI_HOME" = "$3/.local/share/pixied/pixi"
        printf "%s\n" "$PIXIED_ACCOUNT_HOME" "$PIXIED_PIXI_HOME"
    ' bash "$PIXIED_REPO_ROOT" "$home" "$local_home"
    assert_success
    [[ "$output" == *"$home"*"$local_home/.local/share/pixied/pixi"* ]] ||
        pixied_test_fail "NFS path resolution changed account home or PIXI_HOME"
}

# US-106-1
# US-106-2
# US-106-3
# US-106-4
@test "NFS allowlist uses three-way sync and records conflicts" {
    local home="$PIXIED_TEST_ROOT/phase4-sync-home"
    local local_home="$PIXIED_TEST_ROOT/phase4-sync-local"
    local data="$PIXIED_TEST_ROOT/phase4-sync-data"
    local config="$PIXIED_TEST_ROOT/phase4-sync-config"
    local state="$PIXIED_TEST_ROOT/phase4-sync-state"
    local state_file="$state/pixied/machines/phase4-sync/state"
    local baseline="$state/pixied/machines/phase4-sync/sync-baseline"
    local artifact legacy_baseline
    mkdir -p "$home" "$local_home"
    printf 'account bashrc v1\n' >"$home/.bashrc"
    printf 'account bash profile v1\n' >"$home/.bash_profile"
    printf 'account zshrc v1\n' >"$home/.zshrc"
    printf 'account zprofile v1\n' >"$home/.zprofile"
    printf 'local zlogin v1\n' >"$local_home/.zlogin"
    printf 'local zlogout v1\n' >"$local_home/.zlogout"
    printf 'local profile v1\n' >"$local_home/.profile"
    printf 'local bash logout v1\n' >"$local_home/.bash_logout"
    printf 'account outside\n' >"$home/not-allowlisted"
    printf 'local outside\n' >"$local_home/not-allowlisted"
    printf 'account zshenv\n' >"$home/.zshenv"
    printf 'local zshenv\n' >"$local_home/.zshenv"

    run env -u PIXI_HOME HOME="$home" XDG_DATA_HOME="$data" \
        XDG_CONFIG_HOME="$config" XDG_STATE_HOME="$state" \
        PIXIED_HOME_MODE=nfs PIXIED_LOCAL_HOME="$local_home" \
        PIXIED_MACHINE_ID=phase4-sync PIXIED_SESSION_MANAGER=none \
        PIXIED_PIXI_BINARY_SOURCE="$PIXIED_REPO_ROOT/tests/fakes/pixi" \
        bash "$PIXIED_REPO_ROOT/install-local.sh"
    assert_success
    [ -x "$local_home/.local/share/pixied/pixi/bin/direnv" ] ||
        pixied_test_fail "NFS Pixi home was not placed on the local home"
    grep -Fq -- "pixi_home=$local_home/.local/share/pixied/pixi" \
        "$state/pixied/machines/phase4-sync/state" ||
        pixied_test_fail "NFS Pixi home was not persisted as a local path"

    run env -u PIXI_HOME HOME="$home" XDG_DATA_HOME="$data" \
        XDG_CONFIG_HOME="$config" XDG_STATE_HOME="$state" \
        PIXIED_HOME_MODE=nfs PIXIED_LOCAL_HOME="$local_home" \
        PIXIED_MACHINE_ID=phase4-sync \
        bash "$data/pixied/bin/pixied" run bash -c 'exit 0'
    assert_success
    assert_equal 'account bashrc v1' "$(<"$home/.bashrc")"
    assert_equal 'account bashrc v1' "$(<"$local_home/.bashrc")"
    assert_equal 'account bash profile v1' "$(<"$home/.bash_profile")"
    assert_equal 'account bash profile v1' "$(<"$local_home/.bash_profile")"
    assert_equal 'account zshrc v1' "$(<"$home/.zshrc")"
    assert_equal 'account zshrc v1' "$(<"$local_home/.zshrc")"
    assert_equal 'account zprofile v1' "$(<"$home/.zprofile")"
    assert_equal 'account zprofile v1' "$(<"$local_home/.zprofile")"
    assert_equal 'local zlogin v1' "$(<"$home/.zlogin")"
    assert_equal 'local zlogin v1' "$(<"$local_home/.zlogin")"
    assert_equal 'local zlogout v1' "$(<"$home/.zlogout")"
    assert_equal 'local zlogout v1' "$(<"$local_home/.zlogout")"
    assert_equal 'local profile v1' "$(<"$home/.profile")"
    assert_equal 'local profile v1' "$(<"$local_home/.profile")"
    assert_equal 'local bash logout v1' "$(<"$home/.bash_logout")"
    assert_equal 'local bash logout v1' "$(<"$local_home/.bash_logout")"
    assert_equal 'account outside' "$(<"$home/not-allowlisted")"
    assert_equal 'local outside' "$(<"$local_home/not-allowlisted")"
    assert_equal 'account zshenv' "$(<"$home/.zshenv")"
    assert_equal 'local zshenv' "$(<"$local_home/.zshenv")"
    [ -f "$baseline" ] || pixied_test_fail "sync baseline was not created"
    grep -Fq -- '.bashrc=' "$baseline" || pixied_test_fail "baseline has no bashrc entry"
    grep -Fq -- '.zshrc=' "$baseline" || pixied_test_fail "baseline has no zshrc entry"
    [ -f "$state_file" ] || pixied_test_fail "state file was not retained"

    legacy_baseline="$baseline.legacy"
    grep -E '^\.(bashrc|bash_profile|profile|bash_logout)=' "$baseline" >"$legacy_baseline"
    mv -f "$legacy_baseline" "$baseline"
    run env -u PIXI_HOME HOME="$home" XDG_DATA_HOME="$data" \
        XDG_CONFIG_HOME="$config" XDG_STATE_HOME="$state" \
        PIXIED_HOME_MODE=nfs PIXIED_LOCAL_HOME="$local_home" \
        PIXIED_MACHINE_ID=phase4-sync \
        bash "$data/pixied/bin/pixied" run bash -c 'exit 0'
    assert_success
    grep -Fq -- '.zshrc=' "$baseline" ||
        pixied_test_fail "legacy baseline was not upgraded"

    printf 'account bashrc v2\n' >"$home/.bashrc"
    run env -u PIXI_HOME HOME="$home" XDG_DATA_HOME="$data" \
        XDG_CONFIG_HOME="$config" XDG_STATE_HOME="$state" \
        PIXIED_HOME_MODE=nfs PIXIED_LOCAL_HOME="$local_home" \
        PIXIED_MACHINE_ID=phase4-sync \
        bash "$data/pixied/bin/pixied" run bash -c 'exit 0'
    assert_success
    assert_equal 'account bashrc v2' "$(<"$local_home/.bashrc")"

    printf 'local profile v2\n' >"$local_home/.profile"
    run env -u PIXI_HOME HOME="$home" XDG_DATA_HOME="$data" \
        XDG_CONFIG_HOME="$config" XDG_STATE_HOME="$state" \
        PIXIED_HOME_MODE=nfs PIXIED_LOCAL_HOME="$local_home" \
        PIXIED_MACHINE_ID=phase4-sync \
        bash "$data/pixied/bin/pixied" run bash -c 'exit 0'
    assert_success
    assert_equal 'local profile v2' "$(<"$home/.profile")"

    printf 'account bashrc conflict\n' >"$home/.bashrc"
    printf 'local bashrc conflict\n' >"$local_home/.bashrc"
    run env -u PIXI_HOME HOME="$home" XDG_DATA_HOME="$data" \
        XDG_CONFIG_HOME="$config" XDG_STATE_HOME="$state" \
        PIXIED_HOME_MODE=nfs PIXIED_LOCAL_HOME="$local_home" \
        PIXIED_MACHINE_ID=phase4-sync \
        bash "$data/pixied/bin/pixied" run bash -c 'printf child-ran >"$HOME/child-ran"'
    assert_failure 1
    assert_output --partial 'sync conflict detected'
    [ ! -e "$local_home/child-ran" ] || pixied_test_fail "child ran after sync conflict"
    assert_equal 'account bashrc conflict' "$(<"$home/.bashrc")"
    assert_equal 'local bashrc conflict' "$(<"$local_home/.bashrc")"
    artifact=$(find "$state/pixied/conflicts" -mindepth 1 -maxdepth 1 -type d -print -quit)
    [ -n "$artifact" ] || pixied_test_fail "sync conflict artifact was not created"
    [ -f "$artifact/account/.bashrc" ] || pixied_test_fail "account conflict copy is missing"
    [ -f "$artifact/local/.bashrc" ] || pixied_test_fail "local conflict copy is missing"
    grep -Fq -- 'item=.bashrc' "$artifact/meta/metadata" ||
        pixied_test_fail "conflict metadata is missing"
}

@test "atomic sync copy rejects a symlink source" {
    local root="$PIXIED_TEST_ROOT/phase4-copy-source"
    mkdir -p "$root/destination"
    printf 'source\n' >"$root/real-source"
    ln -s "$root/real-source" "$root/source-link"

    run bash -c '
        . "$1/lib/common.sh"
        . "$1/lib/paths.sh"
        . "$1/lib/state.sh"
        . "$1/lib/sync.sh"
        pixied_enable_strict_mode
        pixied_sync_copy_atomic "$2/source-link" "$2/destination/copied"
    ' bash "$PIXIED_REPO_ROOT" "$root"
    assert_failure 1
    assert_output --partial 'sync source is not a regular file'
    [ ! -e "$root/destination/copied" ] ||
        pixied_test_fail "symlink source was copied"
}

# US-106-3
@test "NFS sync skips push after child failure or signal" {
    local home="$PIXIED_TEST_ROOT/phase4-status-home"
    local local_home="$PIXIED_TEST_ROOT/phase4-status-local"
    local data="$PIXIED_TEST_ROOT/phase4-status-data"
    local config="$PIXIED_TEST_ROOT/phase4-status-config"
    local state="$PIXIED_TEST_ROOT/phase4-status-state"
    mkdir -p "$home" "$local_home"
    printf 'stable\n' >"$home/.bashrc"

    run env -u PIXI_HOME HOME="$home" XDG_DATA_HOME="$data" \
        XDG_CONFIG_HOME="$config" XDG_STATE_HOME="$state" \
        PIXIED_HOME_MODE=nfs PIXIED_LOCAL_HOME="$local_home" \
        PIXIED_MACHINE_ID=phase4-status PIXIED_SESSION_MANAGER=none \
        PIXIED_PIXI_BINARY_SOURCE="$PIXIED_REPO_ROOT/tests/fakes/pixi" \
        bash "$PIXIED_REPO_ROOT/install-local.sh"
    assert_success
    run env -u PIXI_HOME HOME="$home" XDG_DATA_HOME="$data" \
        XDG_CONFIG_HOME="$config" XDG_STATE_HOME="$state" \
        PIXIED_HOME_MODE=nfs PIXIED_LOCAL_HOME="$local_home" \
        PIXIED_MACHINE_ID=phase4-status \
        bash "$data/pixied/bin/pixied" run bash -c 'exit 0'
    assert_success

    run env -u PIXI_HOME HOME="$home" XDG_DATA_HOME="$data" \
        XDG_CONFIG_HOME="$config" XDG_STATE_HOME="$state" \
        PIXIED_HOME_MODE=nfs PIXIED_LOCAL_HOME="$local_home" \
        PIXIED_MACHINE_ID=phase4-status \
        bash "$data/pixied/bin/pixied" run bash -c \
        'printf "failed-child\n" >"$HOME/.bashrc"; exit 7'
    assert_failure 7
    assert_equal 'stable' "$(<"$home/.bashrc")"
    assert_equal 'failed-child' "$(<"$local_home/.bashrc")"

    run env -u PIXI_HOME HOME="$home" XDG_DATA_HOME="$data" \
        XDG_CONFIG_HOME="$config" XDG_STATE_HOME="$state" \
        PIXIED_HOME_MODE=nfs PIXIED_LOCAL_HOME="$local_home" \
        PIXIED_MACHINE_ID=phase4-status \
        bash "$data/pixied/bin/pixied" run bash -c \
        'printf "signal-child\n" >"$HOME/.bashrc"; kill -TERM "$$"'
    assert_failure 143
    assert_equal 'failed-child' "$(<"$home/.bashrc")"
    assert_equal 'signal-child' "$(<"$local_home/.bashrc")"
}

@test "NFS sync refuses an existing lock and invalid baseline" {
    local home="$PIXIED_TEST_ROOT/phase4-lock-home"
    local local_home="$PIXIED_TEST_ROOT/phase4-lock-local"
    local data="$PIXIED_TEST_ROOT/phase4-lock-data"
    local config="$PIXIED_TEST_ROOT/phase4-lock-config"
    local state="$PIXIED_TEST_ROOT/phase4-lock-state"
    local baseline="$state/pixied/machines/phase4-lock/sync-baseline"
    mkdir -p "$home" "$local_home"
    printf 'stable\n' >"$home/.bashrc"

    run env -u PIXI_HOME HOME="$home" XDG_DATA_HOME="$data" \
        XDG_CONFIG_HOME="$config" XDG_STATE_HOME="$state" \
        PIXIED_HOME_MODE=nfs PIXIED_LOCAL_HOME="$local_home" \
        PIXIED_MACHINE_ID=phase4-lock PIXIED_SESSION_MANAGER=none \
        PIXIED_PIXI_BINARY_SOURCE="$PIXIED_REPO_ROOT/tests/fakes/pixi" \
        bash "$PIXIED_REPO_ROOT/install-local.sh"
    assert_success
    run env -u PIXI_HOME HOME="$home" XDG_DATA_HOME="$data" \
        XDG_CONFIG_HOME="$config" XDG_STATE_HOME="$state" \
        PIXIED_HOME_MODE=nfs PIXIED_LOCAL_HOME="$local_home" \
        PIXIED_MACHINE_ID=phase4-lock \
        bash "$data/pixied/bin/pixied" run bash -c 'exit 0'
    assert_success

    mkdir "$state/pixied/.lock"
    run env -u PIXI_HOME HOME="$home" XDG_DATA_HOME="$data" \
        XDG_CONFIG_HOME="$config" XDG_STATE_HOME="$state" \
        PIXIED_HOME_MODE=nfs PIXIED_LOCAL_HOME="$local_home" \
        PIXIED_MACHINE_ID=phase4-lock \
        bash "$data/pixied/bin/pixied" run bash -c \
        'printf lock-child >"$HOME/lock-child"'
    assert_failure 1
    assert_output --partial 'state lock already exists'
    [ ! -e "$local_home/lock-child" ] || pixied_test_fail "child ran while sync lock existed"
    [ -d "$state/pixied/.lock" ] || pixied_test_fail "existing sync lock was removed"
    rmdir "$state/pixied/.lock"

    sed -i 's/^\.bashrc=.*/.bashrc=invalid/' "$baseline"
    run env -u PIXI_HOME HOME="$home" XDG_DATA_HOME="$data" \
        XDG_CONFIG_HOME="$config" XDG_STATE_HOME="$state" \
        PIXIED_HOME_MODE=nfs PIXIED_LOCAL_HOME="$local_home" \
        PIXIED_MACHINE_ID=phase4-lock \
        bash "$data/pixied/bin/pixied" run bash -c 'exit 0'
    assert_failure 1
    assert_output --partial 'invalid sync baseline hash'
}

@test "Zellij session residue prevents the clean-exit push" {
    command -v script >/dev/null 2>&1 || skip "script command is required for the TTY test"
    local home="$PIXIED_TEST_ROOT/phase4-detach-home"
    local local_home="$PIXIED_TEST_ROOT/phase4-detach-local"
    local data="$PIXIED_TEST_ROOT/phase4-detach-data"
    local config="$PIXIED_TEST_ROOT/phase4-detach-config"
    local state="$PIXIED_TEST_ROOT/phase4-detach-state"
    mkdir -p "$home" "$local_home"
    printf 'stable\n' >"$home/.bashrc"

    run env -u PIXI_HOME HOME="$home" XDG_DATA_HOME="$data" \
        XDG_CONFIG_HOME="$config" XDG_STATE_HOME="$state" \
        PIXIED_HOME_MODE=nfs PIXIED_LOCAL_HOME="$local_home" \
        PIXIED_MACHINE_ID=phase4-detach PIXIED_SESSION_MANAGER=zellij \
        PIXIED_PIXI_BINARY_SOURCE="$PIXIED_REPO_ROOT/tests/fakes/pixi" \
        bash "$PIXIED_REPO_ROOT/install-local.sh"
    assert_success
    run env -u PIXI_HOME HOME="$home" XDG_DATA_HOME="$data" \
        XDG_CONFIG_HOME="$config" XDG_STATE_HOME="$state" \
        PIXIED_HOME_MODE=nfs PIXIED_LOCAL_HOME="$local_home" \
        PIXIED_MACHINE_ID=phase4-detach \
        PIXIED_FAKE_ZELLIJ_REMAINS=1 \
        PIXIED_FAKE_ZELLIJ_SESSION_NAME=pixied \
        PIXIED_FAKE_ZELLIJ_TOUCH="$local_home/.bashrc" \
        PIXIED_FAKE_ZELLIJ_CONTENT='detached-local' \
        script -qec "bash '$data/pixied/bin/pixied' shell" /dev/null
    assert_success
    assert_equal 'stable' "$(<"$home/.bashrc")"
    assert_equal 'detached-local' "$(<"$local_home/.bashrc")"
}

@test "local run honors the runtime lock" {
    local home="$PIXIED_TEST_ROOT/phase4-local-lock-home"
    local data="$PIXIED_TEST_ROOT/phase4-local-lock-data"
    local config="$PIXIED_TEST_ROOT/phase4-local-lock-config"
    local state="$PIXIED_TEST_ROOT/phase4-local-lock-state"
    local marker="$home/local-lock-child"
    mkdir -p "$home"

    run env -u PIXI_HOME HOME="$home" XDG_DATA_HOME="$data" XDG_CONFIG_HOME="$config" \
        XDG_STATE_HOME="$state" PIXIED_HOME_MODE=local \
        PIXIED_MACHINE_ID=phase4-local-lock PIXIED_SESSION_MANAGER=none \
        PIXIED_PIXI_BINARY_SOURCE="$PIXIED_REPO_ROOT/tests/fakes/pixi" \
        bash "$PIXIED_REPO_ROOT/install-local.sh" --yes
    assert_success

    mkdir "$state/pixied/.lock"
    run env -u PIXI_HOME HOME="$home" XDG_DATA_HOME="$data" XDG_CONFIG_HOME="$config" \
        XDG_STATE_HOME="$state" PIXIED_HOME_MODE=local \
        PIXIED_MACHINE_ID=phase4-local-lock \
        bash "$data/pixied/bin/pixied" run bash -c 'printf child >"$HOME/local-lock-child"'
    assert_failure 1
    assert_output --partial 'state lock already exists'
    [ ! -e "$marker" ] || pixied_test_fail "local child ran while the runtime lock existed"
    [ -d "$state/pixied/.lock" ] || pixied_test_fail "existing runtime lock was removed"
    rmdir "$state/pixied/.lock"
}

@test "missing NFS local home explains how to prepare it" {
    local home="$PIXIED_TEST_ROOT/missing-local-home-account"
    local local_home="$PIXIED_TEST_ROOT/missing-local-home"
    local data="$PIXIED_TEST_ROOT/missing-local-home-data"
    local config="$PIXIED_TEST_ROOT/missing-local-home-config"
    local state="$PIXIED_TEST_ROOT/missing-local-home-state"
    local bin="$PIXIED_TEST_ROOT/missing-local-home-bin"
    mkdir -p "$home" "$data" "$config" "$state" "$bin"

    run env HOME="$home" PIXIED_LOCAL_HOME="$local_home" XDG_DATA_HOME="$data" \
        XDG_CONFIG_HOME="$config" XDG_STATE_HOME="$state" XDG_BIN_HOME="$bin" \
        PIXIED_HOME_MODE=nfs PIXIED_MACHINE_ID=missing-local-home bash -c '
        . "$1/lib/common.sh"
        . "$1/lib/paths.sh"
        pixied_resolve_paths
    ' bash "$PIXIED_REPO_ROOT"
    assert_failure 1
    assert_output --partial "selected NFS mode requires a local home"
    assert_output --partial "mkdir -p -- '$local_home'"
    assert_output --partial "--local-home PATH"
}

@test "filesystem detection failures are reported" {
    local home="$PIXIED_TEST_ROOT/detection-failure-home"
    local fake_bin="$PIXIED_TEST_ROOT/detection-failure-bin"
    mkdir -p "$home" "$fake_bin"
    printf '#!/usr/bin/env bash\nexit 2\n' >"$fake_bin/df"
    chmod 0755 "$fake_bin/df"

    run env PATH="$fake_bin:/usr/bin:/bin" HOME="$home" bash -c '
        . "$1/lib/common.sh"
        . "$1/lib/paths.sh"
        pixied_enable_strict_mode
        pixied_resolve_paths
    ' bash "$PIXIED_REPO_ROOT"
    assert_failure 1
    assert_output --partial 'could not determine filesystem type'
}

@test "empty successful filesystem detection is treated as non-local" {
    local home="$PIXIED_TEST_ROOT/empty-detection-home"
    local fake_bin="$PIXIED_TEST_ROOT/empty-detection-bin"
    mkdir -p "$home" "$fake_bin"
    printf '#!/usr/bin/env bash\nexit 0\n' >"$fake_bin/df"
    chmod 0755 "$fake_bin/df"

    run env PATH="$fake_bin:/usr/bin:/bin" HOME="$home" bash -c '
        . "$1/lib/common.sh"
        . "$1/lib/paths.sh"
        pixied_is_local_filesystem "$HOME"
    ' bash "$PIXIED_REPO_ROOT"
    assert_failure 1
}

@test "XDG base directories may be symlinks" {
    local home="$PIXIED_TEST_ROOT/xdg-symlink-home"
    local config_target="$PIXIED_TEST_ROOT/xdg-symlink-config-target"
    local config="$PIXIED_TEST_ROOT/xdg-symlink-config"
    local data="$PIXIED_TEST_ROOT/xdg-symlink-data"
    local state="$PIXIED_TEST_ROOT/xdg-symlink-state"
    local bin="$PIXIED_TEST_ROOT/xdg-symlink-bin"
    mkdir -p "$home" "$config_target" "$data" "$state" "$bin"
    ln -s "$config_target" "$config"

    run env HOME="$home" XDG_DATA_HOME="$data" XDG_CONFIG_HOME="$config" \
        XDG_STATE_HOME="$state" XDG_BIN_HOME="$bin" PIXIED_HOME_MODE=local \
        PIXIED_MACHINE_ID=xdg-symlink bash -c '
        . "$1/lib/common.sh"
        . "$1/lib/paths.sh"
        pixied_resolve_paths
        printf "%s\n" "$PIXIED_CONFIG_DIR"
    ' bash "$PIXIED_REPO_ROOT"
    assert_success
    assert_output --partial "XDG base path is not canonical or contains a symlink; using canonical path: $config -> $config_target"
    assert_output --partial "$config_target/pixied"
}

@test "invalid state data is rejected" {
    local home="$PIXIED_TEST_ROOT/reject-home"
    local data="$PIXIED_TEST_ROOT/reject-data"
    local config="$PIXIED_TEST_ROOT/reject-config"
    local state="$PIXIED_TEST_ROOT/reject-state"
    local bin="$PIXIED_TEST_ROOT/reject-bin"
    local state_file lock_dir
    mkdir -p "$home" "$data" "$config" "$state" "$bin"

    run env HOME="$home" XDG_DATA_HOME="$data" XDG_CONFIG_HOME="$config" \
        XDG_STATE_HOME="$state" XDG_BIN_HOME="$bin" PIXIED_HOME_MODE=local \
        PIXIED_MACHINE_ID=phase1-reject bash -c '
        set -e
        . "$1/lib/common.sh"
        . "$1/lib/paths.sh"
        . "$1/lib/state.sh"
        pixied_resolve_paths
        mkdir -p "$PIXIED_MACHINE_STATE_DIR"
        pixied_state_initialize_from_paths
        pixied_state_set pixi_binary_hash ""
        pixied_state_lock_acquire
        pixied_state_write
        pixied_state_lock_release
        pixied_state_load
    ' bash "$PIXIED_REPO_ROOT"
    assert_success
    state_file="$state/pixied/machines/phase1-reject/state"

    printf 'unknown=value\n' >>"$state_file"
    run env HOME="$home" XDG_DATA_HOME="$data" XDG_CONFIG_HOME="$config" \
        XDG_STATE_HOME="$state" XDG_BIN_HOME="$bin" PIXIED_HOME_MODE=local \
        PIXIED_MACHINE_ID=phase1-reject bash -c '
        . "$1/lib/common.sh"
        . "$1/lib/paths.sh"
        . "$1/lib/state.sh"
        pixied_resolve_paths
        pixied_state_load
    ' bash "$PIXIED_REPO_ROOT"
    assert_failure 1
    assert_output --partial 'unknown state key: unknown'

    sed -i '/^unknown=value$/d' "$state_file"
    printf 'unit_path=/run/user/1000/pixied.service\n' >>"$state_file"
    run env HOME="$home" XDG_DATA_HOME="$data" XDG_CONFIG_HOME="$config" \
        XDG_STATE_HOME="$state" XDG_BIN_HOME="$bin" PIXIED_HOME_MODE=local \
        PIXIED_MACHINE_ID=phase1-reject bash -c '
        . "$1/lib/common.sh"
        . "$1/lib/paths.sh"
        . "$1/lib/state.sh"
        pixied_resolve_paths
        pixied_state_load
    ' bash "$PIXIED_REPO_ROOT"
    assert_failure 1
    assert_output --partial 'obsolete state key: unit_path; reinstall PixiEden before continuing'

    sed -i '/^unit_path=/d' "$state_file"
    mv "$state_file" "$state_file.real"
    ln -s "$state_file.real" "$state_file"
    run env HOME="$home" XDG_DATA_HOME="$data" XDG_CONFIG_HOME="$config" \
        XDG_STATE_HOME="$state" XDG_BIN_HOME="$bin" PIXIED_HOME_MODE=local \
        PIXIED_MACHINE_ID=phase1-reject bash -c '
        . "$1/lib/common.sh"
        . "$1/lib/paths.sh"
        . "$1/lib/state.sh"
        pixied_resolve_paths
        pixied_state_load
    ' bash "$PIXIED_REPO_ROOT"
    assert_failure 1
    assert_output --partial 'path is not canonical or contains a symlink'

    rm "$state_file"
    lock_dir="$state/pixied/.lock"
    chmod 0775 "$state/pixied"
    run env HOME="$home" XDG_DATA_HOME="$data" XDG_CONFIG_HOME="$config" \
        XDG_STATE_HOME="$state" XDG_BIN_HOME="$bin" PIXIED_HOME_MODE=local \
        PIXIED_MACHINE_ID=phase1-reject bash -c '
        . "$1/lib/common.sh"
        . "$1/lib/paths.sh"
        . "$1/lib/state.sh"
        pixied_resolve_paths
        pixied_state_lock_acquire
    ' bash "$PIXIED_REPO_ROOT"
    assert_failure 1
    assert_output --partial 'managed path is writable by group or others'
    chmod 0755 "$state/pixied"

    mkdir "$lock_dir"
    run env HOME="$home" XDG_DATA_HOME="$data" XDG_CONFIG_HOME="$config" \
        XDG_STATE_HOME="$state" XDG_BIN_HOME="$bin" PIXIED_HOME_MODE=local \
        PIXIED_MACHINE_ID=phase1-reject bash -c '
        . "$1/lib/common.sh"
        . "$1/lib/paths.sh"
        . "$1/lib/state.sh"
        pixied_resolve_paths
        pixied_state_lock_acquire
    ' bash "$PIXIED_REPO_ROOT"
    assert_failure 1
    assert_output --partial 'state lock already exists'
    [ -d "$lock_dir" ] || pixied_test_fail "existing state lock was removed"
}

@test "state writes require a lock" {
    local home="$PIXIED_TEST_ROOT/write-lock-home"
    local data="$PIXIED_TEST_ROOT/write-lock-data"
    local config="$PIXIED_TEST_ROOT/write-lock-config"
    local state="$PIXIED_TEST_ROOT/write-lock-state"
    local bin="$PIXIED_TEST_ROOT/write-lock-bin"
    mkdir -p "$home" "$data" "$config" "$state" "$bin"

    run env HOME="$home" XDG_DATA_HOME="$data" XDG_CONFIG_HOME="$config" \
        XDG_STATE_HOME="$state" XDG_BIN_HOME="$bin" PIXIED_HOME_MODE=local \
        PIXIED_MACHINE_ID=phase1-write-lock bash -c '
        . "$1/lib/common.sh"
        . "$1/lib/paths.sh"
        . "$1/lib/state.sh"
        pixied_resolve_paths
        mkdir -p "$PIXIED_MACHINE_STATE_DIR"
        pixied_state_initialize_from_paths
        pixied_state_write
    ' bash "$PIXIED_REPO_ROOT"
    assert_failure 1
    assert_output --partial 'state lock is required before writing state'
}

@test "TTY validation rejects non-interactive input" {
    run bash -c '. "$1/lib/common.sh"; pixied_require_tty' bash "$PIXIED_REPO_ROOT" </dev/null
    assert_failure 1
    assert_output --partial 'an interactive TTY is required'
}

@test "signal handlers preserve conventional signal statuses" {
    run bash -c '. "$1/lib/common.sh"; pixied_enable_strict_mode; kill -INT "$$"' \
        bash "$PIXIED_REPO_ROOT"
    assert_failure 130

    run bash -c '. "$1/lib/common.sh"; pixied_enable_strict_mode; kill -TERM "$$"' \
        bash "$PIXIED_REPO_ROOT"
    assert_failure 143
}

# Re-entering from a generated hook must explain that the runtime is already active.
@test "shell reports when PixiEden is already active" {
    local cli="$PIXIED_REPO_ROOT/bin/pixied"

    run env PIXIED_RUNTIME_HOOK_ACTIVE=1 bash "$cli" shell
    assert_failure
    assert_output --partial 'PixiEden is already active in this shell; use exit to leave it'
}

# An existing lock must not be removed automatically, but should explain both
# an active runtime and a stale lock as possible causes.
@test "existing runtime lock explains active or stale state" {
    local home="$PIXIED_TEST_ROOT/phase-lock-message-home"
    local data="$PIXIED_TEST_ROOT/phase-lock-message-data"
    local config="$PIXIED_TEST_ROOT/phase-lock-message-config"
    local state="$PIXIED_TEST_ROOT/phase-lock-message-state"
    local lock="$state/pixied/.lock"

    mkdir -p "$home" "$lock"
    run env HOME="$home" XDG_DATA_HOME="$data" XDG_CONFIG_HOME="$config" \
        XDG_STATE_HOME="$state" PIXIED_STATE_DIR="$state/pixied" \
        bash -c '\
        . "$1/lib/common.sh"; \
        . "$1/lib/paths.sh"; \
        . "$1/lib/state.sh"; \
        pixied_resolve_paths; \
        pixied_state_lock_acquire "$2"' \
        bash "$PIXIED_REPO_ROOT" "$lock"
    assert_failure
    assert_output --partial 'state lock already exists'
    assert_output --partial 'PixiEden may already be active or the lock may be stale'
    [ -d "$lock" ] || pixied_test_fail "existing lock was removed"
}
