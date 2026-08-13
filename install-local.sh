#!/usr/bin/env bash

PIXIED_SOURCE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly PIXIED_SOURCE_DIR

# shellcheck source=lib/common.sh
. "$PIXIED_SOURCE_DIR/lib/common.sh"
# shellcheck source=lib/paths.sh
. "$PIXIED_SOURCE_DIR/lib/paths.sh"
pixied_enable_strict_mode

pixied_install_local() {
    local destination file created_data
    local deploy_bin="bin/pixied"
    local deploy_libs=(
        lib/common.sh
        lib/paths.sh
        lib/state.sh
        lib/options.sh
        lib/pixi.sh
        lib/sync.sh
        lib/session.sh
        lib/hook.sh
        lib/generate.sh
        lib/uninstall.sh
    )
    pixied_resolve_paths
    destination=$PIXIED_DATA_DIR
    if [ -e "$destination" ] || [ -L "$destination" ]; then
        created_data=0
    else
        created_data=1
    fi
    export PIXIED_DEPLOY_CREATED_DATA=$created_data
    [ -f "$PIXIED_SOURCE_DIR/$deploy_bin" ] || pixied_die "source file is missing: $deploy_bin"
    for file in "${deploy_libs[@]}"; do
        [ -f "$PIXIED_SOURCE_DIR/$file" ] || pixied_die "source file is missing: $file"
    done

    pixied_step "Deploying PixiEden to $destination"
    pixied_run mkdir -p "$destination/bin" "$destination/lib"
    pixied_run cp "$PIXIED_SOURCE_DIR/$deploy_bin" "$destination/$deploy_bin"
    for file in "${deploy_libs[@]}"; do
        pixied_run cp "$PIXIED_SOURCE_DIR/$file" "$destination/$file"
    done
    pixied_run chmod 0755 "$destination/$deploy_bin"
    for file in "${deploy_libs[@]}"; do
        pixied_run chmod 0644 "$destination/$file"
    done
    pixied_success "PixiEden CLI deployed to $destination/bin/pixied"
    "$destination/bin/pixied" install "$@"
}

pixied_install_local "$@"
