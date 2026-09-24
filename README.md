# OMP Local AI Sandbox

Rootless Podman sandbox for running **OMP (oh-my-pi)** with local GGUF models through **llama.cpp** and an NVIDIA GPU.

## What it provides

- dedicated host user `ompai`;
- rootless, daemonless Podman;
- NVIDIA GPU through CDI;
- one shared `llama.cpp` multi-model router for all concurrent OMP windows;
- models stay loaded only while at least one OMP session is active;
- configurable persistent model store;
- persistent `~/AI` workspace;
- temporary direct `--share` and `--share-ro` access to files/projects outside `~/AI`;
- OMP has Internet access; `llama.cpp` does not;
- Exa search with DuckDuckGo fallback;
- root-owned RAM/CPU/process limits for the entire `ompai` account.

## Files

```text
setup-omp-ai.sh
omp-ai.conf
README.md
```

## Installation

Edit the config:

```bash
nano omp-ai.conf
chmod 600 omp-ai.conf
```

Then:

```bash
chmod +x setup-omp-ai.sh
./setup-omp-ai.sh
```

The installer is intended to be re-runnable. Treat re-running it as a maintenance operation: it force-stops currently active OMP session containers and the shared llama router before finishing the update.

## Persistent data areas

There are three separate concepts:

```text
AI_HOME     =/var/lib/ompai
MODEL_STORE =/var/lib/ompai/models
WORKSPACE   =/srv/ompai/workspace
```

`AI_HOME` is private infrastructure state: OMP config/history, source/build state and secrets.

`MODEL_STORE` contains GGUF models and is mounted read-only into `llama.cpp` as `/models`.

`WORKSPACE` is persistent user data that OMP may modify freely. The installer creates:

```text
~/AI -> /srv/ompai/workspace
```

Nothing in `WORKSPACE` is automatically deleted when OMP exits.

## Models

Add:

```bash
ai-model add ~/Downloads/model.gguf
```

List:

```bash
ai-model list
```

Replace:

```bash
ai-model replace ~/Downloads/model.gguf
```

Remove:

```bash
ai-model remove model.gguf
```

See configured store:

```bash
ai-model path
```

`MODEL_STORE` is configured in `omp-ai.conf`:

```ini
MODEL_STORE=/var/lib/ompai/models
```

It may live on another disk, for example:

```ini
MODEL_STORE=/mnt/nvme-ai/llm-models
```

The path must be absolute and outside your normal `$HOME`.

### Multi-model routing

At runtime the model store is mounted:

```text
HOST MODEL_STORE
       |
       +---- read-only ----> /models
```

and `llama.cpp` starts with:

```text
--models-dir /models
--models-max 1
--models-autoload
```

Inside OMP use:

```text
/model
```

to select a model.

For the original target machine (32 GiB RAM / 8 GiB VRAM), keep:

```ini
MODELS_MAX=1
```

`MODELS_MAX` is the number of different model instances the router may keep resident. It is independent from the number of OMP windows. Ten OMP sessions can all share the same one loaded model.

The number of simultaneous llama inference slots is controlled separately:

```ini
LLAMA_PARALLEL=1
```

With `LLAMA_PARALLEL=1`, multiple OMP windows are fully usable at the same time, but overlapping LLM requests are queued/serialized by llama.cpp. This is the conservative default for 32 GiB RAM / 8 GiB VRAM because extra parallel slots consume additional KV-cache memory. If resources permit, try `LLAMA_PARALLEL=2`.

## Normal workspace

For data you want to copy into the sandbox:

```bash
ai-give ~/Downloads/report.pdf
```

This copies it into `~/AI`.

Then:

```bash
cd ~/AI
omp-ai
```

OMP may freely change or delete the copied version; the original remains untouched.

## Direct shares: work on original files without copying

For projects or files that OMP should modify **in place**, use `--share`.

Directory:

```bash
omp-ai --share ~/code/my-project
```

File:

```bash
omp-ai --share ~/Documents/todo.md
```

Multiple direct shares:

```bash
omp-ai \
  --share ~/code/frontend \
  --share ~/code/backend
```

They appear inside OMP under:

```text
/shares/frontend
/shares/backend
```

If the first direct share is a directory and you did not launch from a subdirectory of `~/AI`, OMP starts in that direct-share directory.

### Read-only direct share

Use:

```bash
omp-ai --share-ro ~/Documents/reference
```

or:

```bash
omp-ai \
  --share ~/code/project \
  --share-ro ~/Documents/specs
```

`--share-ro` is mounted read-only in the OMP container.

### Why a symlink in `~/AI` is not enough

This:

```bash
ln -s ~/code/project ~/AI/project
```

does **not** grant container access to the target outside the mounted workspace.

Use explicit `--share` / `--share-ro` instead.

## How direct sharing is isolated

A direct share does **not** grant `ompai` traversal permission through your whole `$HOME`.

The privileged helper:

1. validates that your desktop user already has the requested access;
2. snapshots ACL/ownership metadata for the target;
3. grants `ompai` temporary ACL access only to the target tree;
4. root bind-mounts the target into a staging path under `/run/omp-ai-shares`;
5. rootless Podman mounts that staging path into `/shares/...`;
6. on exit, it unmounts the staging bind and restores the saved ACL metadata.

This keeps `/home/<you>` itself protected while permitting explicitly selected files/directories.

For `--share` (RW), files created by the agent are handed back to the desktop user's UID/GID during cleanup.

A systemd reaper also cleans stale direct-share sessions after crashes/reboots.

Direct shares from different OMP windows may run concurrently as long as their source paths do not overlap. The helper deliberately rejects sharing the exact same path, a parent, or a child of an already-active direct share; otherwise one session could restore temporary ACLs while another session still depends on them. If you need several OMP windows on the same project, place that project in the persistent `~/AI` workspace.

### Direct-share security contract

Anything passed via:

```text
--share
--share-ro
```

must be considered visible to the agent.

For `--share`, the agent may alter or delete the original data.

For both RW and RO shares, because OMP has Internet access, the agent may potentially upload readable contents.

Do not share secrets unless that is intentional.

The helper refuses `/`, your entire home directory, and `/proc`, `/sys`, `/dev`, `/run`.

## Starting OMP

Persistent workspace:

```bash
cd ~/AI/my-project
omp-ai
```

Direct project:

```bash
omp-ai --share ~/code/my-project
```

Mixed:

```bash
omp-ai \
  --share ~/code/my-project \
  --share-ro ~/Documents/reference.pdf
```

## Multiple OMP windows

Multiple independent OMP processes are supported. Start them from separate terminals, for example:

```bash
# terminal 1
cd ~/AI/project-a
omp-ai
```

```bash
# terminal 2
cd ~/AI/project-b
omp-ai
```

```bash
# terminal 3
omp-ai --share ~/code/project-c
```

Each session gets its own Podman container with a unique name such as:

```text
ompai-agent-<uuid>
```

but every session connects to the same:

```text
ompai-llama
```

router. The lifecycle is reference-counted through per-session heartbeat markers:

```text
first OMP session starts
        -> start llama router
        -> active sessions = 1

second OMP session starts
        -> reuse existing router
        -> active sessions = 2

first session exits
        -> remove only its OMP container
        -> router remains

last session exits
        -> remove its OMP container
        -> stop llama router
        -> release model RAM/VRAM
```

If a terminal or launcher dies with `SIGKILL`, the heartbeat stops. The systemd reaper removes stale OMP containers/session markers and shuts down the router once no live sessions remain.

### Concurrent models and inference

With:

```ini
MODELS_MAX=1
LLAMA_PARALLEL=1
```

all windows share one model slot and one inference slot. This gives the lowest memory use. Several windows can be open, use tools and queue model requests, but only one llama inference runs at a time.

If two windows select different models while `MODELS_MAX=1`, the router may need to evict/reload models between requests. For concurrent work, using the same model in all windows is much faster.

If you have enough memory for additional KV cache, increase:

```ini
LLAMA_PARALLEL=2
```

to allow two llama inference slots. Re-run `./setup-omp-ai.sh` after changing it.

Useful runtime commands:

```bash
# show shared router + every OMP session container
omp-ai status

# follow the shared llama.cpp router logs
omp-ai logs

# force-stop ALL OMP sessions, the shared router, and stale direct shares
omp-ai stop
```

Closing one OMP window no longer unloads the model if another OMP session is still active. RAM/VRAM is released after the **last** session exits (or after `omp-ai stop`).

## Web search

Default:

```ini
EXA_API_KEY=
WEB_SEARCH_PRIMARY=auto
WEB_SEARCH_FALLBACK=duckduckgo
```

With `auto`:

```text
EXA_API_KEY set   -> Exa
EXA_API_KEY empty -> DuckDuckGo
```

The Exa key is stored outside `~/AI` and passed to the OMP container as an environment variable.

A compromised OMP process can still inspect its own environment, so this does not hide the key from OMP itself.

## Security model

Main layers:

1. separate host account `ompai`;
2. locked login shell/password;
3. rootless Podman;
4. user namespaces;
5. read-only container roots;
6. dropped Linux capabilities;
7. `no-new-privileges`;
8. root-owned systemd limits;
9. normal home recommended mode `0700`;
10. only explicit data mounts;
11. model store read-only to llama.cpp;
12. llama.cpp internal network + `--offline`;
13. temporary direct shares with root-staged bind mounts and ACL restoration.

This is still container isolation, not a separate VM: the host kernel is shared.

## OMP build

The current installer clones the configured OMP repository and builds its upstream container image:

```ini
OMP_REPO=https://github.com/can1357/oh-my-pi.git
OMP_REF=main
```

That is why `AI_HOME/src` exists.

This favors a reproducible containerized OMP runtime using the project's own Dockerfile. A future version could switch to an official prebuilt OCI image if OMP publishes one suitable for this setup.

## Troubleshooting

GPU:

```bash
nvidia-smi
sudo nvidia-ctk cdi list
```

Models:

```bash
ai-model list
ai-model path
```

Llama logs:

```bash
omp-ai logs
```

Force cleanup:

```bash
omp-ai stop
```

`omp-ai stop` also immediately asks the privileged share helper to restore any stale direct-share ACL state; normally the session wrapper performs this cleanup automatically.

If an OMP process or direct-share wrapper is killed abnormally, the installed systemd reaper uses session/share heartbeats to remove abandoned containers, restore stale share ACLs, and stop the shared llama router when no live sessions remain.
