# PixiEden

| 🌐Language: | **English** ｜ [日本語](./README.ja.md) |
| ---------- | --------------------------------------- |

> [!WARNING]
> This document is an AI-generated translation. The original Japanese version is human-reviewed.

PixiEden is a [Pixi](https://github.com/prefix-dev/pixi/) based development environment provisioning tool. Its command is `pixied`.

PixiEden provides a Pixi development runtime that can be rebuilt from the same definition in environments ranging from local systems such as WSL2 to unprivileged servers (without root access) whose home directories are shared over NFS.
It combines Pixi, direnv, and Zellij, and moves data to machine-local storage to avoid the high I/O load of network-mounted home directories. This removes the latency that can make everyday shell operations unpleasant on remote environments without administrator privileges, providing a comfortable development experience.

It targets two types of environments:

- Local environments, including WSL2
- Unprivileged hosts whose home directories are on shared storage such as NFS

## Good Use Cases

- Rebuilding the same environment from one configuration on a laptop, WSL, and remote Linux
- Managing the tools to install as a list
- Using development tools that are slow or unreliable because `$HOME` is on NFS
- Returning to a Zellij session that remains on the same machine after reconnecting or restarting

## Key Features

- Build a global development runtime
  - Build an environment for an unprivileged user connecting over SSH with an NFS-shared home directory
  - Automatically enter the runtime and restore a Zellij session that remains on the same machine
- Build a project-specific Pixi environment
  - Layer a project Pixi environment on top of the global Pixi environment
  - Generate definitions for DevContainer or Docker

## Quick Start

Install from the latest release:

```bash
curl -fsSL https://raw.githubusercontent.com/arkbig/pixied/main/install.sh | bash
```

The remote installer temporarily extracts `pixied.tar.gz` from GitHub Releases and runs `install-local.sh` from the archive. Set `PIXIED_RELEASE_URL` to change the release source.

Install from a cloned repository:

```bash
./install-local.sh
```

During installation, PixiEden does not edit your shell configuration automatically. Use the full CLI path displayed by the installer and add the following three lines at the very beginning of `~/.bashrc` for Bash, or to `~/.zshrc` with `hook zsh` for zsh (where they are processed for non-interactive shells). With the XDG defaults, the path is `${XDG_BIN_HOME:-$HOME/.local/bin}/pixied`.

```bash
if command -v "${XDG_BIN_HOME:-$HOME/.local/bin}/pixied" >/dev/null 2>&1; then
    eval "$(${XDG_BIN_HOME:-$HOME/.local/bin}/pixied hook bash)"
fi
```

For zsh, add the same block to `~/.zshrc` and replace `hook bash` with `hook zsh`.

When you open a new terminal or SSH session, PixiEden switches to the local home when needed and enables Pixi Global. When Zellij is enabled, it connects to a persistent Zellij session managed by a machine-id-specific unit if a systemd user manager is available; otherwise, it falls back to direct attach.

## Installation Settings

Settings are resolved in this order: CLI arguments, supported environment variables, saved state for the current machine, automatic detection, and fixed defaults.

- Home mode: `local` if `df -l` confirms a local filesystem; otherwise `nfs`.
- Local home: A pre-created machine-local path used at runtime in `nfs` mode.
- Session manager installation: The default is `zellij`. Selecting `none` skips Zellij, the systemd user service, and linger configuration. Environments without a systemd user manager fall back to direct attach.
- Sudo usage: WSL systemd settings or linger configuration may require sudo. PixiEden displays the proposed changes and asks for explicit confirmation; it does not run sudo if confirmation is denied. These are confirmations immediately before actual changes, not settings selections.

PixiEden may ask for confirmation when it continues using a dedicated non-local Pixi home, makes WSL or linger changes with sudo, or uninstalls managed resources. `--yes` skips only these confirmations; it does not skip path, owner, hash, or machine-id validation.

When the session manager is disabled, a normal shell starts after the environment is installed. Reinstall with the following command when you need automatic attachment and persistent terminal work:

```bash
pixied install --session-manager zellij
```

To provide settings in advance and skip confirmation, run:

```bash
./install-local.sh \
  --home-mode nfs \
  --local-home /scratch/$USER \
  --session-manager none \
  --use-sudo no \
  --yes
```

Use `PIXIED_HOME_MODE`, `PIXIED_LOCAL_HOME`, `PIXIED_SESSION_MANAGER`, and `PIXIED_USE_SUDO` to provide settings through environment variables. `PIXIED_SESSION_MANAGER` accepts `zellij` or `none`. Add `--yes` to skip confirmation.

Use `PIXIED_PIXI_VERSION` to specify the Pixi version. When it is not set, PixiEden uses a pinned version and verifies it with a built-in digest. When a version or `latest` is specified, PixiEden uses the Release selected by the user and uses the official checksum from that same Release to detect download corruption or mix-ups. Set `PIXIED_PIXI_SHA256` to override the checksum when you need to pin it explicitly.

Use `PIXIED_MACHINE_ID` for advanced configurations that explicitly identify state across multiple machines. Set a unique value per machine that is safe to use as part of a path. If omitted, PixiEden uses `/etc/machine-id` or a fallback detection value.

## Commands

```text
pixied                         Alias for the shell subcommand
pixied shell                   Perform NFS sync when needed, then attach to a session
pixied run <command...>        Perform NFS sync when needed, then run a command
pixied hook <bash|zsh>         Output shell initialization code
pixied install [...]           Install or repair the environment
pixied uninstall               Clean up verified PixiEden-managed resources
pixied generate direnv         Generate an .envrc for a project Pixi environment
pixied generate devcontainer   Generate a DevContainer definition
pixied generate dockerfile     Generate a Dockerfile
pixied help                    Show help
pixied version                 Show the version
```

Run the following from a project root to generate files for using a project Pixi environment on top of the global PixiEden environment. Existing files in the destination are not overwritten without explicit confirmation.

```bash
pixied generate direnv
pixied generate devcontainer
pixied generate dockerfile
```

The `direnv` output enables the project Pixi environment only after entering the project directory. The DevContainer and Dockerfile outputs build a project Pixi environment inside the container based on the project's `pixi.toml` or `pyproject.toml`.

## What Is Reproduced

The following are reproduced between machines: PixiEden settings, the pinned Pixi version, project definitions, and generated project integration files. In `nfs` mode, some shell configuration files are also synchronized according to the allowlist. Pixi cache, resolved binaries, machine-local `PIXI_HOME`, running Zellij sessions, and machine-specific state are not shared between machines. Zellij reconnection works only when the session remains on the same machine.

## Operating Modes and Permissions

| home mode | session manager | Guaranteed features | Required conditions and permissions |
| --- | --- | --- | --- |
| `local` | `none` | Dedicated runtime on the normal home, direnv, project Pixi, DevContainer/Docker generation | No systemd or sudo required |
| `local` | `zellij` | The above, plus reconnection to a Zellij session on the same machine | Uses a persistent unit and linger when a systemd user manager and `loginctl` are available. Explicit confirmation is required if sudo is needed to change linger or WSL settings. Falls back to direct attach when unavailable |
| `nfs` | `none` | Dedicated runtime on the machine-local home, file synchronization, direnv, project Pixi, DevContainer/Docker generation | A pre-created local home with the correct owner, write permission, and local filesystem conditions. No systemd or sudo required |
| `nfs` | `zellij` | The above, plus reconnection to a Zellij session on the same machine | Write permission for the local home. Uses a persistent unit and linger when a systemd user manager and `loginctl` are available. Falls back to direct attach when unavailable. Explicit confirmation is required if sudo is needed to change WSL settings or linger |

With `none`, PixiEden does not detect, change, or start Zellij, systemd, `loginctl`, or linger. Even with `zellij`, it falls back to direct attach when systemd is unavailable. It does not provide a way to move a Zellij screen or unsynchronized work state to another machine.

Create `PIXIED_LOCAL_HOME` in the environment before installing when using `nfs` mode. The specified path must be an existing directory owned and writable by the current user, separate from the account home, and verifiable as a canonical path on a local filesystem. PixiEden does not create the default candidate `/local/$USER` automatically. The `install` only validates the local home; it does not provide a subcommand for creating one.

Creating the local home in advance does not disable NFS synchronization. In `nfs` mode, only `.bashrc`, `.bash_profile`, `.profile`, `.bash_logout`, `.zshrc`, `.zprofile`, `.zlogin`, and `.zlogout` directly under the home directory are synchronized between the account home and the local home.

NFS mode synchronizes only `.bashrc`, `.bash_profile`, `.profile`, `.bash_logout`, `.zshrc`, `.zprofile`, `.zlogin`, and `.zlogout` directly under the home directory. The allowlist is pulled before `pixied shell` or `pixied run` launches, and pushed only when the child command or session exits with status 0. If both the account side and the local side contain different changes, PixiEden does not overwrite either side; it saves conflict artifacts under `PIXIED_STATE_DIR` and stops.

### Recovering from Synchronization Errors

When a conflict occurs, PixiEden permanently saves the following information under `$PIXIED_STATE_DIR/conflicts/<artifact>/`:

- `account/`: A copy from the account home
- `local/`: A copy from the local home
- `meta/metadata`: The target item, the hash or `missing` value for each side, and the baseline value

Review the contents, decide which side to keep, make the account and local copies of the allowlisted item identical, and rerun `pixied shell` or `pixied run`. When both sides match, synchronization regenerates the baseline. Artifacts are not deleted automatically, so keep them as long as needed after confirming recovery and then clean them up manually.

If the baseline is corrupted, first confirm that no `pixied` process is running and move the relevant `sync-baseline` aside within the same directory. Then make both allowlisted sides identical and run `pixied shell` or `pixied run` to regenerate the baseline from an uninitialized state. If the two sides still differ, it stops as a conflict as usual.

Locks are not deleted automatically either. After confirming that the relevant `pixied` process has stopped, delete only the empty lock directory as follows:

```bash
rmdir -- "$PIXIED_STATE_DIR/.lock"
```

Do not delete the lock while a process is running, and do not run `rm -rf` on the lock.

## Requirements

- Ubuntu or a compatible `Linux` environment with `bash`, `curl` or `wget`, and `tar` available.
- When the session manager is enabled on WSL2, systemd must be enabled. When it is disabled, PixiEden displays a proposed change to `/etc/wsl.conf` and, with explicit confirmation and sudo permission, merges `[boot] systemd=true`. It does not start a session in the same run; manually run `wsl --shutdown` and rerun `pixied install`.
- When the session manager is enabled, PixiEden prepares a machine-id-specific user unit and linger when a systemd user manager and `loginctl` are available. When they are unavailable, it displays diagnostics and falls back to direct attach. When the session manager is disabled, it does not detect, change, or start any of them.

## Uninstallation

Run:

```bash
pixied uninstall
```

When the session manager was enabled, PixiEden displays the systemd user service it created and the linger setting it enabled, then asks for confirmation before disabling them. Use `--yes` to approve the confirmation automatically.

Uninstallation uses the dedicated `PIXI_HOME` recorded in the current state as its management boundary. A dedicated `PIXI_HOME` newly created by PixiEden and not shared with other machines can be cleaned up directory-wide after validating its path, owner, and state. For an existing path or a path shared with another machine, PixiEden cleans up only executables whose recorded hashes match the state, so shared Pixi metadata, manifests, `envs/`, and other files may remain. PixiEden does not determine ownership at the package level and does not guarantee removal of only the Global packages added by the current installation.

If the target Zellij session remains, uninstallation stops whether it is running through systemd or direct attach. End or detach the session and rerun `pixied uninstall`. If the session list cannot be retrieved, uninstallation also stops as a precaution.

Finally, manually remove the PixiEden hook block from the shell configuration file where it was added, such as `~/.bashrc` or `~/.zshrc`. If the process is interrupted, rerun `pixied uninstall` as long as the launcher or deployed CLI remains available.

## Paths and XDG Support

The `PIXIED_*` names shown here describe resolved paths; they are not supported as installation input overrides. Use the corresponding XDG environment variable to change a documented path location.

- `PIXIED_DATA_DIR` (data, CLI, and Pixi binary): `${XDG_DATA_HOME:-$HOME/.local/share}/pixied`
- `PIXIED_CONFIG_DIR` (configuration and generated runtime hook): `${XDG_CONFIG_HOME:-$HOME/.config}/pixied`
- `PIXIED_STATE_DIR` (state, machine-specific settings, synchronization baseline, and conflict information): `${XDG_STATE_HOME:-$HOME/.local/state}/pixied`
- CLI launcher: `${XDG_BIN_HOME:-$HOME/.local/bin}/pixied`
- Machine-local tools and Pixi Global data: `$PIXIED_LOCAL_HOME`

## Documentation

[Developer documentation](docs/README.ja.md) (Japanese)
