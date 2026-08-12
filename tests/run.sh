#!/usr/bin/env bash

set -Eeuo pipefail

PIXIED_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly PIXIED_ROOT

if ! command -v bats >/dev/null 2>&1; then
    printf 'ERROR: bats-core is required to run the PixiEden test suite.\n' >&2
    exit 127
fi

filtered_args=()
verbose=0
for arg in "$@"; do
    if [ "$arg" = --verbose ]; then
        verbose=1
    else
        filtered_args+=("$arg")
    fi
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

exec bats "${bats_args[@]}" "${filtered_args[@]}" "$PIXIED_ROOT/tests/integration.bats"
