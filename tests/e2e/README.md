# PixiEden E2E

## Fast Contract Tests

Run the fast contract suite from the repository root:

```sh
bash tests/run.sh
```

The suite uses Bats fake commands, so it does not call or modify the host's
Pixi or Zellij. Paths and command logs are kept in test-only temporary
directories.

## Multipass E2E

Real Pixi, direct Zellij attach, PTY handling, and session persistence are
tested in a disposable Multipass VM:

```sh
./tests/e2e/run-multipass.sh
```

Before launching the VM, the runner invokes `scripts/package-release.sh` and
transfers the resulting deployable archive. The guest installs from that
archive's `pixied/` directory, so the release path does not install directly
from the checkout.

When run from WSL, the runner uses the Windows client `multipass.exe` by
default. Set it explicitly when needed:

```sh
PIXIED_E2E_MULTIPASS=multipass.exe ./tests/e2e/run-multipass.sh
```

The runner creates a new Ubuntu 24.04 VM with a unique `pixied-e2e-*` name and
purges only the VM it created, both on success and failure. It does not modify
existing Multipass VMs or paths on the WSL host.

The runner requires Windows Multipass, network access, 2 CPUs, at least 3 GiB
of memory, and at least 16 GiB of disk. Adjust these environment variables when
needed:

- `PIXIED_E2E_IMAGE`
- `PIXIED_E2E_CPUS`
- `PIXIED_E2E_MEMORY`
- `PIXIED_E2E_DISK`
- `PIXIED_E2E_TIMEOUT_SECONDS`

Use `--keep-vm` only when investigating a failure. After the investigation,
verify the printed VM name and remove that disposable VM explicitly:

```sh
./tests/e2e/run-multipass.sh --keep-vm
multipass.exe delete --purge pixied-e2e-<timestamp>-<pid>
```

Docker remains useful for optional lightweight smoke tests and fake contract
checks, but no separate Docker harness is added for real Zellij or PTY behavior.
Keeping real-environment checks in one Multipass runner limits the maintenance
surface to Bats and one E2E runner.

The current runner covers the release archive, local home, and direct Zellij
session path. NFS remains a separate E2E item for its respective phase.
