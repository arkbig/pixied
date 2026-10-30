#!/usr/bin/env bats

# @description Install an isolated fake PixiEden runtime for each test.
setup() {
    export REPO_ROOT
    REPO_ROOT=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
    export HOME="$BATS_TEST_TMPDIR/home"
    export XDG_DATA_HOME="$BATS_TEST_TMPDIR/data"
    export XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/config"
    export XDG_STATE_HOME="$BATS_TEST_TMPDIR/state"
    export PIXIED_MACHINE_ID=exposure-test PIXIED_HOME_MODE=local PIXIED_WSL=0
    export PIXIED_PIXI_BINARY_SOURCE="$REPO_ROOT/tests/fakes/pixi"
    export PIXI_HOME="$XDG_DATA_HOME/pixied/pixi"
    unset DOCKER_CONFIG
    mkdir -p "$HOME" "$BATS_TEST_TMPDIR/dest"
    run bash "$REPO_ROOT/install-local.sh" --yes
    [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
    export CLI="$REPO_ROOT/bin/pixied"
    cat >"$PIXI_HOME/bin/docker-buildx" <<'SCRIPT'
#!/usr/bin/env bash
if [ "${1:-}" = docker-cli-plugin-metadata ]; then
    [ "${PIXIED_FAKE_PLUGIN_FAIL_METADATA:-0}" -eq 0 ] || exit 17
    printf '{"SchemaVersion":"0.1.0","Vendor":"Test","Version":"","ShortDescription":"Test plugin"}\n'
else
    printf 'delegated:'
    printf ' <%s>' "$@"
    printf '\n'
fi
SCRIPT
    chmod +x "$PIXI_HOME/bin/docker-buildx"
    write_version 1.2.3
}

# @description Set the fake installed package version.
# @arg $1 string The version to expose.
write_version() {
    printf '[{"name":"build-env","dependencies":[{"name":"build-pkg","version":"%s"}],"exposed":[{"exposed_name":"docker-buildx","executable":"docker-buildx"}]}]\n' "$1" >"$PIXI_HOME/fake-global.json"
}

@test "expose help explains Docker and generic version modes" {
    run bash "$CLI" expose --help
    [ "$status" -eq 0 ]
    [[ "$output" == *'Do not combine --docker with --version-arg or --version-format.'* ]]
    [[ "$output" == *'vendor, description, and version'* ]]
    [[ "$output" == *'pixied expose docker-buildx --docker'* ]]
    [[ "$output" == *'$DOCKER_CONFIG/cli-plugins/COMMAND'* ]]
}

@test "docker mode creates the default plugin directory and Docker finds the wrapper" {
    local dest="$HOME/.docker/cli-plugins/docker-buildx"
    run bash "$CLI" expose docker-buildx --docker --environment build-env --package build-pkg
    [ "$status" -eq 0 ]
    [ -x "$dest" ]
    if command -v docker >/dev/null; then
        run docker buildx version
        [ "$status" -eq 0 ]
        [ "$output" = 'github.com/docker/buildx v1.2.3' ]
    fi
    run bash "$CLI" unexpose "$dest"
    [ "$status" -eq 0 ]
    run env DOCKER_CONFIG= bash "$CLI" expose docker-buildx --docker \
        --environment build-env --package build-pkg
    [ "$status" -eq 0 ]
    [ -x "$dest" ]
}

@test "docker default honors absolute and relative DOCKER_CONFIG" {
    local config="$BATS_TEST_TMPDIR/custom config" dest="$BATS_TEST_TMPDIR/custom config/cli-plugins/docker-buildx"
    run env DOCKER_CONFIG="$config" bash "$CLI" expose docker-buildx --docker \
        --environment build-env --package build-pkg
    [ "$status" -eq 0 ]
    [ -x "$dest" ]
    if command -v docker >/dev/null; then
        run env DOCKER_CONFIG="$config" docker buildx version
        [ "$status" -eq 0 ]
        [ "$output" = 'github.com/docker/buildx v1.2.3' ]
    fi
    run bash "$CLI" unexpose "$dest"
    [ "$status" -eq 0 ]
    run bash -c 'cd "$1"; shift; DOCKER_CONFIG="relative config" exec bash "$@"' \
        bash "$BATS_TEST_TMPDIR" "$CLI" expose docker-buildx --docker \
        --environment build-env --package build-pkg
    [ "$status" -eq 0 ]
    [ -x "$BATS_TEST_TMPDIR/relative config/cli-plugins/docker-buildx" ]
    if command -v docker >/dev/null; then
        run bash -c 'cd "$1"; shift; DOCKER_CONFIG="relative config" exec docker "$@"' \
            bash "$BATS_TEST_TMPDIR" buildx version
        [ "$status" -eq 0 ]
        [ "$output" = 'github.com/docker/buildx v1.2.3' ]
    fi
}

@test "docker explicit destination takes precedence over DOCKER_CONFIG" {
    local dest="$BATS_TEST_TMPDIR/dest/docker-buildx" config="$BATS_TEST_TMPDIR/config-not-created"
    run env DOCKER_CONFIG="$config" bash "$CLI" expose docker-buildx --docker --to "$dest" \
        --environment build-env --package build-pkg
    [ "$status" -eq 0 ]
    [ -x "$dest" ]
    [ ! -e "$config" ]
    run bash "$CLI" expose docker-buildx --docker --to "$config/cli-plugins/docker-buildx" \
        --environment build-env --package build-pkg
    [ "$status" -ne 0 ]
    [ ! -e "$config" ]
}

@test "automatic destination preserves files and avoids directories on invalid requests" {
    local config="$BATS_TEST_TMPDIR/docker-config" dest="$BATS_TEST_TMPDIR/docker-config/cli-plugins/docker-buildx"
    run env DOCKER_CONFIG="$config" bash "$CLI" expose docker-buildx --docker \
        --environment build-env --package wrong
    [ "$status" -ne 0 ]
    [ ! -e "$config" ]
    run env DOCKER_CONFIG="$config" bash "$CLI" expose invalid --docker
    [ "$status" -eq 2 ]
    [ ! -e "$config" ]
    mkdir -p "${dest%/*}"
    printf 'user data\n' >"$dest"
    run env DOCKER_CONFIG="$config" bash "$CLI" expose docker-buildx --docker \
        --environment build-env --package build-pkg
    [ "$status" -ne 0 ]
    [ "$(cat "$dest")" = 'user data' ]
}

@test "generic exposures still require a destination" {
    run bash "$CLI" expose docker-buildx
    [ "$status" -eq 2 ]
    [[ "$output" == *'--to is required without --docker'* ]]
    run bash "$CLI" expose docker-buildx --docker --to ''
    [ "$status" -eq 2 ]
    [[ "$output" == *'--to must not be empty'* ]]
}

@test "docker mode rejects generic version options" {
    local dest="$BATS_TEST_TMPDIR/dest/docker-buildx"
    run bash "$CLI" expose docker-buildx --to "$dest" --docker \
        --version-arg --version --version-format '{version}'
    [ "$status" -eq 2 ]
    [[ "$output" == *'without --docker'* ]]
    [ ! -e "$dest" ]
}

@test "expose creates a symlink and unexpose removes only its own unchanged link" {
    local dest="$BATS_TEST_TMPDIR/dest/tool"
    run bash "$CLI" expose docker-buildx --to "$dest"
    [ "$status" -eq 0 ]
    [ -L "$dest" ]
    run "$dest" hello "two words"
    [ "$output" = 'delegated: <hello> <two words>' ]
    run bash "$CLI" unexpose "$dest"
    [ "$status" -eq 0 ]
    [ ! -e "$dest" ] && [ ! -L "$dest" ]
    [ ! -e "$BATS_TEST_TMPDIR/dest/.tool.pixied-exposure" ]
}

@test "docker wrapper updates metadata and version while forwarding other arguments" {
    local dest="$BATS_TEST_TMPDIR/dest/docker-buildx"
    run bash "$CLI" expose docker-buildx --to "$dest" --docker --environment build-env --package build-pkg
    [ "$status" -eq 0 ]
    run "$dest" docker-cli-plugin-metadata
    [ "$status" -eq 0 ]
    [ "$output" = '{"SchemaVersion":"0.1.0","Vendor":"Test","Version":"v1.2.3","ShortDescription":"Test plugin"}' ]
    run bash -n "$dest"
    [ "$status" -eq 0 ]
    if command -v shellcheck >/dev/null; then
        run shellcheck "$dest"
        [ "$status" -eq 0 ]
    fi
    run "$dest" buildx version
    [ "$output" = 'github.com/docker/buildx v1.2.3' ]
    write_version 2.4.0
    run "$dest" buildx version
    [ "$output" = 'github.com/docker/buildx v2.4.0' ]
    run "$dest" docker-cli-plugin-metadata
    [ "$output" = '{"SchemaVersion":"0.1.0","Vendor":"Test","Version":"v2.4.0","ShortDescription":"Test plugin"}' ]
    run "$dest" buildx build --tag 'two words'
    [ "$output" = 'delegated: <buildx> <build> <--tag> <two words>' ]
    run bash "$CLI" unexpose "$dest"
    [ "$status" -eq 0 ]
}

@test "docker discovers and invokes the wrapper as a real CLI plugin" {
    command -v docker >/dev/null || skip 'docker is not installed'
    local config="$BATS_TEST_TMPDIR/docker" dest
    mkdir -p "$config/cli-plugins"
    dest="$config/cli-plugins/docker-buildx"
    run bash "$CLI" expose docker-buildx --to "$dest" --docker --environment build-env --package build-pkg
    [ "$status" -eq 0 ]
    run docker --config "$config" buildx version
    [ "$status" -eq 0 ]
    [ "$output" = 'github.com/docker/buildx v1.2.3' ]
}

@test "docker compose supports short and JSON version queries" {
    command -v docker >/dev/null || skip 'docker is not installed'
    local config="$BATS_TEST_TMPDIR/docker" dest
    mkdir -p "$config/cli-plugins"
    cp "$PIXI_HOME/bin/docker-buildx" "$PIXI_HOME/bin/docker-compose"
    printf '[{"name":"compose-env","dependencies":[{"name":"compose-pkg","version":"2.30.0"}],"exposed":[{"exposed_name":"docker-compose","executable":"docker-compose"}]}]\n' >"$PIXI_HOME/fake-global.json"
    dest="$config/cli-plugins/docker-compose"
    run bash "$CLI" expose docker-compose --to "$dest" --docker --environment compose-env --package compose-pkg
    [ "$status" -eq 0 ]
    run docker --config "$config" compose version --short
    [ "$status" -eq 0 ]
    [ "$output" = 2.30.0 ]
    run docker --config "$config" compose version --format json
    [ "$status" -eq 0 ]
    [ "$output" = '{"version":"v2.30.0"}' ]
    run docker --config "$config" compose version --short --format json
    [ "$status" -eq 0 ]
    [ "$output" = 2.30.0 ]
    run docker --config "$config" compose version --help
    [[ "$output" == *'delegated:'* ]]
}

@test "generic wrapper replaces only the configured version query" {
    local dest="$BATS_TEST_TMPDIR/dest/tool"
    run bash "$CLI" expose docker-buildx --to "$dest" --version-arg=-v
    [ "$status" -eq 2 ]
    run bash "$CLI" expose docker-buildx --to "$dest" --version-arg -v \
        --version-format 'Tool {version} ({version})' --environment build-env --package build-pkg
    [ "$status" -eq 0 ]
    run "$dest" -v
    [ "$output" = 'Tool 1.2.3 (1.2.3)' ]
    run "$dest" -v extra
    [ "$output" = 'delegated: <-v> <extra>' ]
}

@test "expose refuses existing destinations and mismatched metadata" {
    local dest="$BATS_TEST_TMPDIR/dest/tool"
    printf 'user data\n' >"$dest"
    run bash "$CLI" expose docker-buildx --to "$dest"
    [ "$status" -ne 0 ]
    [ "$(cat "$dest")" = 'user data' ]
    rm "$dest"
    run bash "$CLI" expose docker-buildx --to "$dest" --version-arg -v \
        --version-format '{version}' --environment build-env --package wrong
    [ "$status" -ne 0 ]
    [ ! -e "$dest" ]
}

@test "unexpose refuses modified or unrelated files" {
    local dest="$BATS_TEST_TMPDIR/dest/tool"
    run bash "$CLI" expose docker-buildx --to "$dest" --version-arg -v \
        --version-format '{version}' --environment build-env --package build-pkg
    [ "$status" -eq 0 ]
    printf '# modified\n' >>"$dest"
    run bash "$CLI" unexpose "$dest"
    [ "$status" -ne 0 ]
    [ -f "$dest" ]
    printf 'unrelated\n' >"$BATS_TEST_TMPDIR/dest/unrelated"
    run bash "$CLI" unexpose "$BATS_TEST_TMPDIR/dest/unrelated"
    [ "$status" -ne 0 ]
    [ -f "$BATS_TEST_TMPDIR/dest/unrelated" ]
}

@test "unexpose refuses a changed symlink and preserves its new target" {
    local dest="$BATS_TEST_TMPDIR/dest/tool" other="$BATS_TEST_TMPDIR/other"
    printf 'user data\n' >"$other"
    run bash "$CLI" expose docker-buildx --to "$dest"
    [ "$status" -eq 0 ]
    rm "$dest"
    ln -s "$other" "$dest"
    run bash "$CLI" unexpose "$dest"
    [ "$status" -ne 0 ]
    [ -L "$dest" ]
    [ "$(cat "$other")" = 'user data' ]
}

@test "unexpose refuses a wrapper with changed permissions" {
    local dest="$BATS_TEST_TMPDIR/dest/tool"
    run bash "$CLI" expose docker-buildx --to "$dest" --version-arg -v \
        --version-format '{version}' --environment build-env --package build-pkg
    [ "$status" -eq 0 ]
    chmod 0700 "$dest"
    run bash "$CLI" unexpose "$dest"
    [ "$status" -ne 0 ]
    [ -f "$dest" ]
}

@test "unexpose refuses a copied record at another path" {
    local dest="$BATS_TEST_TMPDIR/dest/tool" copy="$BATS_TEST_TMPDIR/dest/copy"
    run bash "$CLI" expose docker-buildx --to "$dest" --version-arg -v \
        --version-format '{version}' --environment build-env --package build-pkg
    [ "$status" -eq 0 ]
    cp -p "$dest" "$copy"
    cp "$BATS_TEST_TMPDIR/dest/.tool.pixied-exposure" "$BATS_TEST_TMPDIR/dest/.copy.pixied-exposure"
    run bash "$CLI" unexpose "$copy"
    [ "$status" -ne 0 ]
    [ -f "$copy" ]
}

@test "wrapper reports missing or ambiguous installed versions" {
    local dest="$BATS_TEST_TMPDIR/dest/tool"
    run bash "$CLI" expose docker-buildx --to "$dest" --version-arg -v \
        --version-format '{version}' --environment build-env --package build-pkg
    [ "$status" -eq 0 ]
    printf '[]\n' >"$PIXI_HOME/fake-global.json"
    run "$dest" -v
    [ "$status" -ne 0 ]
    [[ "$output" == *'expected exactly one installed package version'* ]]
    run "$dest" other
    [ "$status" -eq 0 ]
    [ "$output" = 'delegated: <other>' ]
}

@test "docker wrapper reports and preserves metadata command failures" {
    local dest="$BATS_TEST_TMPDIR/dest/docker-buildx"
    run bash "$CLI" expose docker-buildx --to "$dest" --docker --environment build-env --package build-pkg
    [ "$status" -eq 0 ]
    run env PIXIED_FAKE_PLUGIN_FAIL_METADATA=1 "$dest" docker-cli-plugin-metadata
    [ "$status" -eq 17 ]
    [[ "$output" == *'failed to query Docker plugin metadata'* ]]
}

@test "exposure creation and version queries do not require jq" {
    local dest="$BATS_TEST_TMPDIR/dest/docker-buildx" fake_bin="$BATS_TEST_TMPDIR/no-jq"
    local name path
    mkdir "$fake_bin"
    for name in bash awk cat chmod cut date df dirname env find id ln mkdir mktemp mountpoint readlink realpath rm sha256sum sort stat tr uname; do
        path=$(command -v "$name")
        ln -s "$path" "$fake_bin/$name"
    done
    run env PATH="$fake_bin" bash "$CLI" expose docker-buildx --to "$dest" --docker \
        --environment build-env --package build-pkg
    [ "$status" -eq 0 ]
    run env PATH="$fake_bin" "$dest" docker-cli-plugin-metadata
    [ "$status" -eq 0 ]
    [ "$output" = '{"SchemaVersion":"0.1.0","Vendor":"Test","Version":"v1.2.3","ShortDescription":"Test plugin"}' ]
    run env PATH="$fake_bin" "$dest" buildx version
    [ "$status" -eq 0 ]
    [ "$output" = 'github.com/docker/buildx v1.2.3' ]
}

@test "JSON handling supports escapes, nesting, and metadata without Version" {
    local dest="$BATS_TEST_TMPDIR/dest/docker-buildx"
    cat >"$PIXI_HOME/fake-global.json" <<'JSON'
[
  {"name":"other","dependencies":[{"name":"build-pkg","version":"9.0"}],"exposed":[]},
  {"exposed":[{"exposed_name":"docker-buildx","note":"\\\" \uD83D\uDE80"}],
   "dependencies":[{"version":"1.2.3+test","name":"build\u002dpkg"}],
   "name":"build\u002denv"}
]
JSON
    cat >"$PIXI_HOME/bin/docker-buildx" <<'SCRIPT'
#!/usr/bin/env bash
printf '%s\n' '{"SchemaVersion":"0.1.0","Vendor":"Test \"vendor\"","Nested":{"Version":"keep"},"ShortDescription":"Unicode \uD83D\uDE80"}'
SCRIPT
    chmod +x "$PIXI_HOME/bin/docker-buildx"
    run bash "$CLI" expose docker-buildx --to "$dest" --docker --environment build-env --package build-pkg
    [ "$status" -eq 0 ]
    run "$dest" docker-cli-plugin-metadata
    [ "$status" -eq 0 ]
    [ "$output" = '{"SchemaVersion":"0.1.0","Vendor":"Test \"vendor\"","Nested":{"Version":"keep"},"ShortDescription":"Unicode \uD83D\uDE80","Version":"v1.2.3+test"}' ]
}

@test "compose version JSON escapes package version characters" {
    local dest="$BATS_TEST_TMPDIR/dest/docker-compose"
    cp "$PIXI_HOME/bin/docker-buildx" "$PIXI_HOME/bin/docker-compose"
    cat >"$PIXI_HOME/fake-global.json" <<'JSON'
[{"name":"compose-env","dependencies":[{"name":"compose-pkg","version":"2.3+\"quoted\\path"}],"exposed":[{"exposed_name":"docker-compose"}]}]
JSON
    run bash "$CLI" expose docker-compose --to "$dest" --docker --environment compose-env --package compose-pkg
    [ "$status" -eq 0 ]
    run "$dest" compose version --format json
    [ "$status" -eq 0 ]
    [ "$output" = '{"version":"v2.3+\"quoted\\path"}' ]
    run "$dest" docker-cli-plugin-metadata
    [ "$status" -eq 0 ]
    [ "$output" = '{"SchemaVersion":"0.1.0","Vendor":"Test","Version":"v2.3+\"quoted\\path","ShortDescription":"Test plugin"}' ]
}

@test "JSON handling rejects malformed and ambiguous metadata" {
    local dest="$BATS_TEST_TMPDIR/dest/docker-buildx"
    run bash "$CLI" expose docker-buildx --to "$dest" --docker --environment build-env --package build-pkg
    [ "$status" -eq 0 ]
    printf '[{"name":"build-env","name":"build-env"}]\n' >"$PIXI_HOME/fake-global.json"
    run "$dest" buildx version
    [ "$status" -ne 0 ]
    [[ "$output" == *'duplicate JSON object key'* ]]
    printf '[{"name":"build-env",}]\n' >"$PIXI_HOME/fake-global.json"
    run "$dest" buildx version
    [ "$status" -ne 0 ]
    [[ "$output" == *'expected JSON string'* ]]
    write_version 1.2.3
    cat >"$PIXI_HOME/bin/docker-buildx" <<'SCRIPT'
#!/usr/bin/env bash
printf '%s\n' '{"Version":"broken"'
SCRIPT
    run "$dest" docker-cli-plugin-metadata
    [ "$status" -ne 0 ]
    [[ "$output" == *'expected JSON object separator'* ]]
}
