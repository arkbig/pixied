# PixiEden

| 🌐Language: | **English** ｜ [日本語](./README.ja.md) |

> [!WARNING]
> This document is an AI-generated translation. The original Japanese version is human-reviewed.

PixiEden is a [Pixi](https://github.com/prefix-dev/pixi/)-based development environment provisioning tool. Its command name is `pixied`.

PixiEden can rebuild a Pixi development runtime from the same definition, from local environments such as WSL2 to unprivileged (without root privileges) servers whose home directories are shared over NFS.
It combines Pixi, direnv, and Zellij, and offloads data to machine-local storage to avoid network homes with heavy I/O load.

It targets the following two cases.

- Local environments (including WSL2)
- Unprivileged hosts whose home directories are on shared storage such as NFS

## Good Use Cases

- Rebuilding the same configuration on a laptop, WSL, and remote Linux
- `$HOME` is on NFS, and development tools are slow or fragile
- Returning to a Zellij session left on the same machine after reconnecting or restarting

## Key Features

- Build a global development runtime
  + Reconnect to a Zellij session left on the same machine
- Build a per-project Pixi environment
  + Layer a project Pixi environment on top of the global Pixi environment
  + Generate definitions for DevContainer or Docker

## Quick Start

Install from the latest Release.

```bash
curl -fsSL https://raw.githubusercontent.com/arkbig/pixied/main/install.sh | bash
```

Install from a cloned repository.

```bash
./install-local.sh
```

PixiEden does not edit shell configuration automatically. Follow the steps shown by the installer, and add the hook at the very top of `~/.bashrc`. For zsh, add it to `~/.zshrc` with `hook zsh`.

```bash
if [ -x "${XDG_BIN_HOME:-$HOME/.local/bin}/pixied" ]; then
    eval "$(${XDG_BIN_HOME:-$HOME/.local/bin}/pixied hook bash)"
fi
```

Opening a new terminal or SSH session enables the dedicated runtime. When Zellij is enabled, it attaches to or creates the dedicated `pixied` session.

When using it with an NFS-shared home, use a machine-local directory that you can create and own. In an interactive install, PixiEden reports a missing directory and can create the selected path only after you confirm it, before deployment. With `--yes`, or when standard input or output is not a TTY such as a `curl | bash` install, it never prompts or creates the directory, so create it in advance.

```bash
mkdir -p /scratch/$USER
./install-local.sh --home-mode nfs --local-home /scratch/$USER
```

`/scratch` is an example; replace it with a path on a local filesystem that the user can create and own. To install from the public Release, run:

```bash
curl -fsSL https://raw.githubusercontent.com/arkbig/pixied/main/install.sh |
  bash -s -- --home-mode nfs --local-home "/scratch/$USER" --yes
```

To use the interactive wizard from a remote host, download the installer and run it from a TTY instead of piping it to Bash:

```bash
curl -fsSL https://raw.githubusercontent.com/arkbig/pixied/main/install.sh \
  -o /tmp/pixied-install.sh
bash /tmp/pixied-install.sh --home-mode nfs
```

Settings are confirmed with an interactive wizard. Use `--yes` to proceed non-interactively. See the option list with `pixied install --help`.

## Commands

```text
pixied                       Alias to shell
pixied shell                 Connect to the session
pixied run <command...>      Run a command in the dedicated environment
pixied hook <bash|zsh>       Print shell initialization code
pixied install               Install or repair the environment
pixied uninstall             Clean up PixiEden-managed resources
pixied generate <format>     Generate project integration files
pixied help                  Show help
pixied version               Show the version
```

See detailed options with `pixied --help` and `pixied <command> --help`. `install-local.sh --help` accepts the same options as `pixied install`.

Run the following at the project root to generate files for using the project Pixi environment.

```bash
pixied generate direnv
pixied generate devcontainer
pixied generate dockerfile
```

`direnv` enables the project Pixi environment only when entering the project directory. DevContainer and Dockerfile build a development environment inside the container based on the project's `pixi.toml` (assuming a volume mount).

## Notes on NFS-Shared Homes

For an interactive `nfs` install, PixiEden can create a missing selected local home after an explicit confirmation, then validates its existence, owner, write permission, separation from the account home, and local filesystem conditions before deployment. With `--yes` or a non-TTY input such as `curl | bash`, it never prompts or creates a directory; create the local home before installation instead. A reinstall validates the saved identity before any creation confirmation.

In NFS mode, only the 8 files directly under the home (`.bashrc`, `.bash_profile`, `.profile`, `.bash_logout`, `.zshrc`, `.zprofile`, `.zlogin`, `.zlogout`) are synchronized between the account home and the local home. The account home is treated as canonical, and files are copied one-way `account→local` to the local home at startup of `pixied shell` or `pixied run`. They are not written back to the account home on exit.

## Uninstallation

Run the following.

```bash
pixied uninstall
```

Finally, manually remove the PixiEden hook block from the added shell configuration (such as `~/.bashrc`).

## Requirements

- Ubuntu or compatible `Linux` with `bash`, `curl` or `wget`, and `tar` available.

## Documentation

[Developer documentation](docs/README.md)

## Similar Software

- [Duetbox](https://github.com/arkbig/duetbox): Devbox (Nix)-based development environment provisioning tool. It has more packages than Pixi.
