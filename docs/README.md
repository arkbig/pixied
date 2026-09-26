# PixiEden Development Documentation

This is the developer entry point. Requirements and design decisions are separated into four layers:

```text
PRD (purpose and background)
  -> UC (system boundary and flows)
    -> US/AC (value slices and acceptance conditions)
      <-> ADR (decisions and rejected alternatives)
```

| Layer | Document | Responsibility |
|---|---|---|
| PRD | [prd.ja.md](prd.ja.md) | Purpose, background, users, scope, and success definition |
| UC | [use-cases.ja.md](use-cases.ja.md) | Actors, system boundary, goals, and normal flows |
| US/AC | [user-stories.ja.md](user-stories.ja.md) | User value and acceptance conditions |
| ADR | [adr.ja.md](adr.ja.md) | Decision reasons, alternatives, and trade-offs |

## Source of truth

State format, runtime hooks, function contracts, and detailed failure paths are defined by the corresponding `bin/`, `lib/`, and `tests/` implementations. The product documents trace requirements to verification but do not duplicate implementation details.

## Development checks

When changing `bin/pixied` or `lib/*.sh`, run:

```bash
bash -n bin/pixied lib/*.sh install-local.sh install.sh
shellcheck -x bin/pixied lib/*.sh install-local.sh install.sh
```

Run the integration suite with:

```bash
tests/run.sh
tests/run.sh generate
tests/run.sh all
```

`generate` requires Docker. The `CLI contract is stable` test keeps the important help output stable.

## Help and warnings

User-facing operation details are defined by help and runtime warnings. `pixied help` describes the overall tool; `pixied <command> --help` describes command options. The install entrypoints accept the same installation options. Runtime decisions such as configuration review, non-local filesystem warnings, synchronization warnings, lease warnings, and ownership errors are reported on standard error.

## NFS local-home preflight

In `nfs` mode, the interactive preflight displays the local-home candidate. If the default `/local/$USER` or a user-selected absolute path does not exist, it asks:

```text
Create local home '<path>'? [y/N]
```

Only an affirmative answer permits directory creation. The path is then validated for existence, ownership, write access, separation from the account home, and local filesystem placement before payload deployment, state writes, or Pixi provisioning.

With `--yes`, or when either standard input or output is not a TTY such as `curl | bash`, the installer never prompts and never creates a directory. A missing local home fails with an error showing `--local-home PATH`, so it must be created in advance. To use the remote interactive wizard, download the installer to a temporary file and run it from a TTY, or run `install-local.sh` from a cloned repository in a TTY.

For an existing state, reinstall identity and active-runtime constraints are checked before preflight. Creation confirmation can only target the local home recorded by the validated state.

## Environment variables

Supported user-facing install settings are `PIXIED_HOME_MODE`, `PIXIED_LOCAL_HOME`, and `PIXIED_SESSION_MANAGER`. `PIXIED_AUTO_ATTACH` controls runtime shell attachment. `PIXIED_MACHINE_ID` identifies machine state. Release configuration uses `PIXIED_RELEASE_URL`.

Resolved paths such as `PIXIED_DATA_DIR`, `PIXIED_CONFIG_DIR`, and `PIXIED_STATE_DIR` are outputs, not user configuration inputs. Test and development injection variables are not part of the public compatibility contract.

## Responsibility boundaries

| Path | Responsibility |
|---|---|
| `bin/pixied` | CLI dispatch and install, runtime, and uninstall ordering |
| `lib/paths.sh` | Home, local-home, XDG, machine-ID, and dedicated Pixi path resolution and validation |
| `lib/options.sh` | CLI, environment, state, auto-detection, defaults, wizard, and preflight |
| `lib/state.sh` | State parsing, validation, locking, and atomic writes |
| `lib/pixi.sh` | Dedicated Pixi download, checksum validation, and provisioning |
| `lib/hook.sh` | Runtime hook generation and shell initialization output |
| `lib/sync.sh` | NFS shell-file allowlist and account-to-local reconciliation |
| `lib/session.sh` | Child commands and session management |
| `lib/uninstall.sh` | Ownership validation, quarantine, and cleanup |
| `lib/generate.sh` | Project integration file generation |

## Release verification

The release archive is built from `install-local.sh`, `bin/`, `lib/`, README files, and `docs/`. `install.sh` downloads and verifies the archive, then delegates to the archive's `install-local.sh`.
