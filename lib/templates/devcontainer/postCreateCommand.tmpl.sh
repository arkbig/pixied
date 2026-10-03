#!/usr/bin/env bash
#
# Post-create command script for the DevContainer.

set -Eeuo pipefail
umask 022

workspace_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
local_script="$(dirname -- "${BASH_SOURCE[0]}")/postCreateCommand.local.sh"
if [ -f "$workspace_dir/pixi.toml" ]; then
    manifest_path="$workspace_dir/pixi.toml"
elif [ -f "$workspace_dir/pyproject.toml" ]; then
    manifest_path="$workspace_dir/pyproject.toml"
else
    manifest_path="$workspace_dir/pixi.toml"
fi

install_pixi() {
    local pixi_shell_hook
    pixi_shell_hook="eval \"\$(pixi shell-hook --manifest-path $manifest_path 2>/dev/null)\""

    sudo chown -R vscode:vscode "$workspace_dir/.pixi"
    pixi install

    touch "$HOME/.bashrc"
    if ! grep -Fqx "$pixi_shell_hook" "$HOME/.bashrc"; then
        printf '%s\n' "$pixi_shell_hook" >>"$HOME/.bashrc"
    fi
}

run_local_script() {
    if [ -f "$local_script" ]; then
        /usr/bin/env bash "$local_script"
    fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    install_pixi
    run_local_script
    echo "Post-create commands completed. You may need to reload window for changes to take effect."
fi
