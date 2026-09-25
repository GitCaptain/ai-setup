# OMP Local AI Sandbox

Arch Linux setup for OMP + local GGUF models through a shared on-demand `llama.cpp` router.

## First install

```bash
chmod 755 setup-omp-ai.sh
chmod 600 omp-ai.conf
./setup-omp-ai.sh
```

Run it as your normal desktop user, **not** with `sudo`.

Then add a model:

```bash
ai-model add ~/Downloads/Qwen3.8-27B-Q4_K_M.gguf
```

and start OMP:

```bash
omp-ai
```

## Concurrent OMP windows

All `omp-ai` windows execute inside one persistent writable `ompai-workbench` container and share one `ompai-llama` router. The workbench is stopped when the last window closes, but its writable filesystem is kept on disk.

Default:

```ini
MODELS_MAX=1
LLAMA_PARALLEL=2
LLAMA_CTX_PER_SLOT=8192
```

Meaning:

- one model instance resident at a time;
- two simultaneous inference slots;
- up to 8192 tokens of context per slot;
- continuous batching is enabled;
- unified KV is enabled;
- total KV pool is auto-sized by llama.cpp as `parallel × context-per-slot`.

The launcher passes:

```text
--parallel 2
--cont-batching
--kv-unified
--kv-unified-per-slot 8192
```

It deliberately does **not** pass `--ctx-size`, so current llama.cpp can size the shared KV pool from the per-slot value.

`LLAMA_CTX` is still accepted by the installer as a deprecated alias for `LLAMA_CTX_PER_SLOT`.

### Prompt-cache safety

`LLAMA_CACHE_RAM_MIB=0` and `--no-cache-idle-slots` are explicit defaults for now. They disable the RAM-backed cross-slot prompt cache while keeping continuous batching enabled. This avoids a currently reported llama.cpp issue where stale content from another concurrent conversation can be restored into a fresh slot.

## Lifecycle

```text
first OMP window   -> starts persistent workbench + shared llama router
more OMP windows   -> podman exec into the same workbench; reuse router
one window closes  -> only that OMP process exits
last window closes -> workbench stops; router is removed; RAM/VRAM released
next launch        -> same workbench rootfs starts again
```

The stopped workbench consumes disk space but no model VRAM and essentially no runtime RAM/CPU.

Useful commands:

```bash
omp-ai status
omp-ai logs
omp-ai stop
omp-ai shell
```

`omp-ai shell` opens a shell inside the same persistent Debian environment OMP uses. `omp-ai stop` terminates all OMP windows, stops the workbench, and removes the shared llama router; it does **not** delete the workbench filesystem.

## Data

Persistent workspace:

```text
~/AI -> /srv/ompai/workspace
```

Copy data into it:

```bash
ai-give ~/Downloads/file.pdf
```

Work on an original path directly:

```bash
omp-ai --share ~/code/project
```

Read-only direct access:

```bash
omp-ai --share-ro ~/Documents/reference
```

Direct shares are temporary bind mounts. The helper snapshots/restores ACLs and refuses overlapping active direct shares.

## Models

```bash
ai-model add FILE_OR_DIR
ai-model replace FILE_OR_DIR
ai-model remove NAME
ai-model list
ai-model path
```

`MODEL_STORE` is persistent and mounted read-only into llama.cpp as `/models`.

## Updating OMP

The workbench root filesystem is writable, so `omp update` now works from inside OMP and survives a restart. For a host-side update with no active OMP windows, use:

```bash
omp-ai update
```

If the persistent workbench already exists, this updates `/usr/local/bin/omp` **inside that same container** without touching packages you installed with `apt`, `pip`, `npm`, `cargo`, etc. If no workbench exists yet, it refreshes the base image from the official prebuilt OMP binary.

If `OMP_VERSION` is pinned in the installed configuration, `omp-ai update` installs that pinned release; with an empty value it follows the current stable release.

## Persistent workbench and package installation

The persistent workbench defaults to:

```text
debian:13-slim
    -> Debian 13 (Trixie)
```

The base is configurable in `omp-ai.conf`:

```ini
WORKBENCH_BASE_IMAGE=debian:13-slim
```

The generated workbench image installs Python 3, pip/venv, the C/C++ build toolchain, git, curl, SSH client, SQLite, jq, ripgrep and a few basic utilities. The system package manager is **APT**, not pacman. For example, the agent can run:

```bash
apt-get update
apt-get install -y clang cmake ninja-build libsqlite3-dev
```

or install language tooling normally:

```bash
pip install ...
npm install -g ...
cargo install ...
```

Those changes are written to the `ompai-workbench` container's writable layer and remain there when the container is stopped and started again.

### Why Debian 13? Other bases

Debian is not required. The workbench wants a conventional glibc Linux with broad developer-package availability and predictable upgrades. Debian 13 is the default because it is small, current stable, and has a large APT ecosystem.

`ubuntu:26.04` is also a reasonable choice if you prefer Ubuntu/LTS vendor documentation and somewhat newer distro packages:

```ini
WORKBENCH_BASE_IMAGE=ubuntu:26.04
```

The current generated Containerfile assumes an **APT + glibc** base, so Debian and Ubuntu are supported directly. Alpine is deliberately not the default because its musl libc can make third-party/prebuilt developer binaries more troublesome. Arch would give very fresh packages but is rolling-release, which makes a long-lived autonomous workbench less reproducible. Fedora could work, but would require a separate `dnf` build path and brings little benefit for this setup.

Changing `WORKBENCH_BASE_IMAGE` rebuilds `localhost/omp:latest`, but an existing persistent `ompai-workbench` is **not silently destroyed**. To move an existing workbench to the new OS, first close sessions and then run:

```bash
omp-ai stop
omp-ai reset-env
```

This intentionally removes packages/files installed only into the old workbench rootfs; `/workspace`, `/state`, models and direct-share source data are not removed. The next `omp-ai` creates a clean persistent workbench from the newly built base image.

Persistent areas now look like:

```text
ompai-workbench rootfs   persistent RW (apt/system tools live here)
/workspace               host WORKSPACE, persistent RW
/state                   AI_HOME/state, persistent RW
/shares/...              temporary aliases to explicit direct shares
/tmp                     tmpfs, intentionally ephemeral
```

The workbench is **not** removed on normal exit. It is merely stopped after the last OMP session closes. The llama.cpp container remains intentionally ephemeral/read-only and is removed after the last session so model RAM/VRAM is released.

To inspect/install things manually in the same environment:

```bash
omp-ai shell
```

To deliberately throw away all workbench-level modifications and recreate a clean environment from `localhost/omp:latest` on the next launch:

```bash
omp-ai stop
omp-ai reset-env
```

`reset-env` does not delete `/workspace`, `/state`, or your model store; it deletes only the persistent container writable layer, including packages installed with `apt`.

### Persistence/security tradeoff

This is intentionally less immutable than the old read-only agent container. If the agent installs a malicious package or modifies the OS, that modification can persist across OMP restarts. The host boundary is still rootless Podman under the dedicated `ompai` Unix account, but a persistent workbench should be treated like a development machine that the agent controls. `omp-ai reset-env` is the clean-slate escape hatch.

Direct-share mounts still use temporary ACLs and root-staged bind mounts. Because concurrent OMP processes now share one workbench namespace, treat all simultaneously active OMP windows as belonging to the same trust domain; an agent that deliberately searches the staging area could potentially observe another active session's explicitly shared path.

## Security summary

- dedicated locked host user `ompai`;
- rootless Podman;
- no Podman/Docker socket in OMP;
- rootless persistent OMP workbench with `no-new-privileges`; llama.cpp remains read-only with dropped capabilities;
- host-level memory/CPU/task limits via systemd;
- normal `$HOME` can remain mode `0700`;
- llama.cpp has no external Internet network;
- OMP has Internet access for search/fetch;
- only the persistent workspace/state and explicit `--share` paths are exposed from the host; the workbench rootfs itself is agent-writable.

This is container isolation, not a VM: the host kernel is still shared.

## Re-running setup

The installer is idempotent enough for normal maintenance. Re-running it updates helpers/config/builds and force-stops currently active OMP sessions while doing so.


## OMP installation

OMP is **not built from source**. The installer creates a Debian 12 workbench base image and installs the official prebuilt OMP binary inside it with:

```bash
curl -fsSL https://omp.sh/install | sh -s -- --binary
```

By default the latest stable release is used. You can pin a release tag in `omp-ai.conf`:

```ini
OMP_VERSION=v18.1.15
```

Older versions of this setup cloned OMP into `/var/lib/ompai/src/oh-my-pi`; the installer now removes that obsolete checkout on rerun.
