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
  + Build an environment for an unprivileged user connecting over SSH with an NFS-shared home directory
  + Automatically enter the runtime and restore a Zellij session that remains on the same machine
- Build a project-specific Pixi environment
  + Layer a project Pixi environment on top of the global Pixi environment
  + Generate definitions for DevContainer or Docker

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

When you open a new terminal or SSH session, PixiEden switches to the local home when needed and enables Pixi Global. When Zellij is enabled, it launches or attaches directly to the dedicated `pixied` Zellij session from inside the PixiEden runtime. The parent shell environment, including `SSH_AUTH_SOCK`, is inherited naturally.

## Installation Settings

Settings are resolved in this order: CLI arguments, supported environment variables, saved state for the current machine, automatic detection, and fixed defaults.

- Home mode: `local` if `df -l` confirms a local filesystem; otherwise `nfs`.
- Local home: A pre-created machine-local path used at runtime in `nfs` mode.
- Session manager: The default is `zellij`. Selecting `none` starts a dedicated interactive Bash inside the PixiEden runtime. Selecting `zellij` directly attaches to the dedicated `pixied` session.

PixiEden may ask for confirmation when it continues using a dedicated non-local Pixi home or uninstalls managed resources. `--yes` skips only these confirmations; it does not skip path, owner, hash, or machine-id validation.

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
  --yes
```

Use `PIXIED_HOME_MODE`, `PIXIED_LOCAL_HOME`, and `PIXIED_SESSION_MANAGER` to provide settings through environment variables. `PIXIED_SESSION_MANAGER` accepts `zellij` or `none`. Add `--yes` to skip confirmation.

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

Run the following from a project root to generate files for using a project Pixi environment on top of the global PixiEden environment:

```bash
pixied generate direnv
pixied generate devcontainer
pixied generate dockerfile
```

The `direnv` output enables the project Pixi environment only after entering the project directory. The DevContainer and Dockerfile outputs build a project Pixi environment inside the container based on the project's `pixi.toml` (assuming a volume mount).

## What Is Reproduced

The following are reproduced between machines: PixiEden settings, the pinned Pixi version, project definitions, and generated project integration files. In `nfs` mode, some shell configuration files are also synchronized according to the allowlist. Pixi cache, resolved binaries, machine-local `PIXI_HOME`, running Zellij sessions, and machine-specific state are not shared between machines. Zellij reconnection works only when the session remains on the same machine.

## Operating Modes and Permissions

| home mode | session manager | Guaranteed features | Required conditions and permissions |
| --- | --- | --- | --- |
| `local` | `none` | Dedicated runtime on the normal home, direnv, project Pixi, DevContainer/Docker generation | |
| `local` | `zellij` | The above, plus reconnection to a Zellij session on the same machine | Direct attach from the PixiEden runtime. |
| `nfs` | `none` | Dedicated runtime on the machine-local home, file synchronization, direnv, project Pixi, DevContainer/Docker generation | A pre-created local home with the correct owner, write permission, and local filesystem conditions. |
| `nfs` | `zellij` | The above, plus reconnection to a Zellij session on the same machine | Write permission for the local home. Direct attach from the PixiEden runtime. |

With `none`, PixiEden starts a dedicated interactive Bash and does not start Zellij. With `zellij`, `pixied shell` and the generated hook directly run `zellij attach --create pixied` inside the runtime. An active managed Zellij session prevents uninstall until it exits. PixiEden does not provide a way to move a Zellij screen or unsynchronized work state to another machine.

Create `PIXIED_LOCAL_HOME` in the environment before installing when using `nfs` mode. The specified path must be an existing directory owned and writable by the current user, separate from the account home, and verifiable as a canonical path on a local filesystem. PixiEden does not create the default candidate `/local/$USER` automatically. The `install` only validates the local home; it does not provide a subcommand for creating one.

Creating the local home in advance does not disable NFS synchronization. In `nfs` mode, only `.bashrc`, `.bash_profile`, `.profile`, `.bash_logout`, `.zshrc`, `.zprofile`, `.zlogin`, and `.zlogout` directly under the home directory are synchronized between the account home and the local home.

NFS mode synchronizes only `.bashrc`, `.bash_profile`, `.profile`, `.bash_logout`, `.zshrc`, `.zprofile`, `.zlogin`, and `.zlogout` directly under the home directory. The account home is treated as the source of truth: when an account file has no local copy, PixiEden copies the local home before `pixied shell` or `pixied run` launches.

### Recovering from Synchronization Errors

Locks are not deleted automatically. After confirming that the relevant `pixied` process has stopped, delete only the empty lock directory as follows:

```bash
rmdir -- "$PIXIED_STATE_DIR/.lock"
```

Do not delete the lock while a process is running, and do not run `rm -rf` on the lock.

## Requirements

- Ubuntu or a compatible `Linux` environment with `bash`, `curl` or `wget`, and `tar` available.
- Zellij is required only when the session manager is `zellij`; it is launched directly inside the PixiEden runtime.

## Uninstallation

Run:

```bash
pixied uninstall
```

Uninstallation uses the dedicated `PIXI_HOME` recorded in the current state as its management boundary. A dedicated `PIXI_HOME` newly created by PixiEden and not shared with other machines can be cleaned up directory-wide after validating its path, owner, and state. For an existing path or a path shared with another machine, PixiEden cleans up only executables whose recorded hashes match the state, so shared Pixi metadata, manifests, `envs/`, and other files may remain. PixiEden does not determine ownership at the package level and does not guarantee removal of only the Global packages added by the current installation.

If the target managed Zellij session remains, uninstallation stops. End or detach the session and rerun `pixied uninstall`. If the session list cannot be retrieved, uninstallation also stops as a precaution.

Finally, manually remove the PixiEden hook block from the shell configuration file where it was added, such as `~/.bashrc` or `~/.zshrc`. If the process is interrupted, rerun `pixied uninstall` as long as the launcher or deployed CLI remains available.

## Paths and XDG Support

The `PIXIED_*` names shown here describe resolved paths; they are not supported as installation input overrides. Use the corresponding XDG environment variable to change a documented path location.

- `PIXIED_DATA_DIR` (data, CLI, and Pixi binary): `${XDG_DATA_HOME:-$HOME/.local/share}/pixied`
- `PIXIED_CONFIG_DIR` (configuration and generated runtime hook): `${XDG_CONFIG_HOME:-$HOME/.config}/pixied`
- `PIXIED_STATE_DIR` (state and machine-specific runtime synchronization state): `${XDG_STATE_HOME:-$HOME/.local/state}/pixied`
- CLI launcher: `${XDG_BIN_HOME:-$HOME/.local/bin}/pixied`
- Machine-local tools and Pixi Global data: `$PIXIED_LOCAL_HOME`

## Documentation

[Developer documentation](docs/README.ja.md) (Japanese)

## Similar Software

- [Duetbox](https://github.com/arkbig/duetbox): A Devbox (Nix) based development environment provisioning tool. It has more packages than Pixi.
