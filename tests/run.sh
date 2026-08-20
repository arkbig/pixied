#!/usr/bin/env bash

set -Eeuo pipefail

PIXIED_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly PIXIED_ROOT

if ! command -v bats >/dev/null 2>&1; then
    printf 'ERROR: bats-core is required to run the PixiEden test suite.\n' >&2
    exit 127
fi

# Keep the test runner from inheriting a host PixiEden installation.
test_env_root=$(mktemp -d "${TMPDIR:-/tmp}/pixied-test-env.XXXXXX")
trap 'rm -rf -- "$test_env_root"' EXIT
export HOME="$test_env_root/home"
export XDG_DATA_HOME="$test_env_root/xdg-data"
export XDG_CONFIG_HOME="$test_env_root/xdg-config"
export XDG_STATE_HOME="$test_env_root/xdg-state"
unset XDG_BIN_HOME
export PIXIED_MACHINE_ID=test-runner
unset PIXIED_ACCOUNT_HOME PIXIED_LOCAL_HOME PIXIED_RUNTIME_STATE_FILE
unset PIXIED_DATA_DIR PIXIED_CONFIG_DIR PIXIED_STATE_DIR PIXIED_COMMAND_BIN
unset PIXIED_STATE_FILE PIXIED_PIXI_BINARY_PATH PIXIED_PIXI_HOME
unset PIXIED_SESSION_MANAGER PIXIED_HOME_MODE
unset PIXIED_RUNTIME_HOOK_ACTIVE PIXIED_RUNTIME_HOOK_PATH
unset PIXI_HOME PIXI_CACHE_DIR PIXI_NO_PATH_UPDATE
mkdir -p "$HOME" "$XDG_DATA_HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME"

filtered_args=()
verbose=0
test_suite=integration
suite_selected=0
while [ "$#" -gt 0 ]; do
    case "$1" in
    --verbose)
        verbose=1
        ;;
    all)
        if [ "$suite_selected" -eq 1 ]; then
            printf 'ERROR: choose either generate or all, not both.\n' >&2
            exit 2
        fi
        test_suite=all
        suite_selected=1
        ;;
    generate)
        if [ "$suite_selected" -eq 1 ]; then
            printf 'ERROR: choose either generate or all, not both.\n' >&2
            exit 2
        fi
        test_suite=generate
        suite_selected=1
        ;;
    --filter)
        filtered_args+=("$1")
        shift
        if [ "$#" -eq 0 ]; then
            printf 'ERROR: --filter requires a value.\n' >&2
            exit 2
        fi
        filtered_args+=("$1")
        ;;
    *)
        filtered_args+=("$1")
        ;;
    esac
    shift
done

bats_args=(--print-output-on-failure)
if [ "$verbose" -eq 1 ] || [ -n "${PIXIED_TEST_VERBOSE:-}" ]; then
    bats_args+=(--verbose-run --show-output-of-passing-tests)
fi
if [ -n "${PIXIED_TEST_OUTPUT_DIR:-}" ]; then
    test_output_dir=$PIXIED_TEST_OUTPUT_DIR
    mkdir -p "$test_output_dir"
    if [ -n "$(find "$test_output_dir" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
        printf 'ERROR: PIXIED_TEST_OUTPUT_DIR must be empty: %s\n' "$test_output_dir" >&2
        exit 2
    fi
    bats_args+=(--gather-test-outputs-in "$test_output_dir")
fi

case "$test_suite" in
integration)
    test_files=("$PIXIED_ROOT/tests/integration.bats")
    ;;
generate)
    test_files=("$PIXIED_ROOT/tests/generate-docker.bats")
    ;;
all)
    test_files=(
        "$PIXIED_ROOT/tests/integration.bats"
        "$PIXIED_ROOT/tests/generate-docker.bats"
    )
    ;;
esac

exec bats "${bats_args[@]}" "${filtered_args[@]}" "${test_files[@]}"
