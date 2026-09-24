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

Each `omp-ai` gets its own agent container, but all windows share one `ompai-llama` router.

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
first OMP window   -> starts shared llama router
more OMP windows   -> reuse it
one window closes  -> only its agent container is removed
last window closes -> router stops and RAM/VRAM are released
```

Useful commands:

```bash
omp-ai status
omp-ai logs
omp-ai stop
```

`omp-ai stop` stops all OMP windows and the shared router.

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

## Security summary

- dedicated locked host user `ompai`;
- rootless Podman;
- no Podman/Docker socket in OMP;
- read-only container roots, dropped capabilities, `no-new-privileges`;
- host-level memory/CPU/task limits via systemd;
- normal `$HOME` can remain mode `0700`;
- llama.cpp has no external Internet network;
- OMP has Internet access for search/fetch;
- only `~/AI` and explicit `--share` paths are exposed to the agent.

This is container isolation, not a VM: the host kernel is still shared.

## Re-running setup

The installer is idempotent enough for normal maintenance. Re-running it updates helpers/config/builds and force-stops currently active OMP sessions while doing so.
