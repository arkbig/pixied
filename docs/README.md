# PixiEden Development Documentation

This is the developer entry point. Requirements and design decisions are separated into four layers:

```text
PRD (purpose and background)
  -> UC (system boundary and flows)
    -> US/AC (value slices and acceptance conditions)
      <-> ADR (decisions and rejected alternatives)
```

| Layer | Document | Responsibility |
| --- | --- | --- |
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

## NFS Release lifecycle

NFS distribution and host runtime are separate. A public Release install verifies an archive, publishes an immutable version under the shared state root, atomically selects `current`, and deploys the same verified source to the initiating machine's local payload. The stable account-side dispatcher uses the selected Release for management commands such as `install`, `version`, `prune`, and `uninstall`.

Runtime commands use the current machine's local payload, Pixi home, cache, and runtime resources. They never source the shared Release tree. This lets a host continue running its verified local payload while another host publishes a newer `current` Release.

On another host, `pixied install` resolves and validates the shared `current` Release and deploys it locally without downloading an archive. `pixied version` reports both the shared Release and local payload. A mismatch, legacy state without release metadata, or an uninstalled host is informational; runtime commands continue with the local payload and do not update it automatically.

`pixied prune --keep N` takes the shared release lock, protects `current`, retained history, and live release leases, and removes only revalidated immutable Releases through quarantine. It is an NFS-only management command and never targets local payloads, state, Pixi homes, or caches. An NFS uninstall preserves the shared dispatcher and Release store while another valid machine state exists; only the last valid machine may remove the validated shared distribution.

## Environment variables

Supported user-facing install settings are `PIXIED_HOME_MODE` and `PIXIED_LOCAL_HOME`. `PIXIED_MACHINE_ID` identifies machine state. Release configuration uses `PIXIED_RELEASE_URL`.

Resolved paths such as `PIXIED_DATA_DIR`, `PIXIED_CONFIG_DIR`, and `PIXIED_STATE_DIR` are outputs, not user configuration inputs. Test and development injection variables are not part of the public compatibility contract.

## Responsibility boundaries

| Path | Responsibility |
| --- | --- |
| `bin/pixied` | CLI dispatch and install, runtime, and uninstall ordering |
| `lib/paths.sh` | Home, local-home, XDG, machine-ID, and dedicated Pixi path resolution and validation |
| `lib/options.sh` | CLI, environment, state, defaults, wizard, and preflight |
| `lib/state.sh` | State parsing, validation, locking, and atomic writes |
| `lib/pixi.sh` | Dedicated Pixi download, checksum validation, and direnv provisioning |
| `lib/hook.sh` | Runtime hook generation and shell initialization output |
| `lib/sync.sh` | NFS shell-file allowlist and account-to-local reconciliation |
| `lib/session.sh` | Child commands and interactive Bash startup |
| `lib/uninstall.sh` | Ownership validation, quarantine, and cleanup |
| `lib/generate.sh` | Project integration file generation |

## Release archive verification

The release archive is built from `install-local.sh`, `bin/`, `lib/`, README files, and `docs/`. `install.sh` downloads and verifies the archive, then delegates to the archive's `install-local.sh`.

Build and inspect the archive before a release:

```bash
archive=/tmp/pixied.tar.gz
bash scripts/package-release.sh "$archive"
(cd /tmp && sha256sum -c pixied.tar.gz.sha256)
tar -tzf "$archive" | rg 'pixied/(bin/pixied|install-local.sh|lib/release.sh|release-manifest)$'
```

The package script derives the payload allowlist and manifest from the release library. The remote installer verifies the checksum and the extracted manifest before running `install-local.sh`, so checkout-only files are not part of the deployable archive.
