# OMP Local AI Sandbox

Secure local OMP + `llama.cpp` setup for Arch Linux.

The design uses a dedicated locked host account (`ompai`), rootless Podman, a persistent writable OMP workbench, an isolated/on-demand llama.cpp router, and an optional Android Emulator sidecar.

## Current default profile

The current installer defaults are tuned for:

```text
Fast/default model:
  Qwen3.5-9B-Q4_K_M
  65536 context
  q8_0 / q8_0 KV cache

Slow/large model:
  Qwen3.8-27B-Q4_K_M
  32768 context
  f16 / f16 KV cache
  MTP speculative decoding

MTP draft:
  mtp-Qwen3.8-27B-Q4_0.gguf
  SPEC_DRAFT_N_MAX=8
  SPEC_DRAFT_P_MIN=0.8
  draft KV=q4_0

Router:
  MODELS_MAX=1
  LLAMA_PARALLEL=1
  VRAM_RESERVE_MIB=256

Resource limits:
  workbench: 6g
  llama container: 22g
  ompai systemd user slice: 26G
```

`LLAMA_CTX_TOTAL=32768` and the global `f16/f16` KV settings are only fallbacks for models without an explicit profile. The 9B and 27B models use their per-model settings above.

Because `MODELS_MAX=1`, switching between 9B and 27B unloads the current model and loads the other one instead of keeping both resident at once.

## First install

Keep these files together:

```text
setup-omp-ai.sh
omp-ai.conf
```

Run:

```bash
chmod 755 setup-omp-ai.sh
chmod 600 omp-ai.conf
./setup-omp-ai.sh
```

Run the installer as your normal desktop user, **not** with `sudo`. It asks for sudo only for host-level operations.

The installer targets Arch Linux.

### Storage

Default locations:

```text
MODEL_STORE=/mnt/shared/AI_MODELS/
DRAFT_STORE=/var/lib/ompai/drafts
WORKSPACE=/srv/ompai/workspace
AI_HOME=/var/lib/ompai
```

The desktop user can manage model files. The `ompai` account has read-only access to the model and draft stores, and llama.cpp receives them read-only.

Model management:

```bash
ai-model add FILE_OR_DIR
ai-model replace FILE_OR_DIR
ai-model remove NAME
ai-model list
ai-model path
```

OMP is not installed globally for the desktop user. Query it through the launcher:

```bash
omp-ai models llama.cpp
```

or:

```bash
omp-ai shell
omp models llama.cpp
```

## Starting and resuming OMP

```bash
omp-ai          # new/start normally
omp-ai -c       # continue latest session
omp-ai -r       # session picker / resume by ID
```

Useful host commands:

```bash
omp-ai status
omp-ai logs
omp-ai stats
omp-ai stop
omp-ai shell
omp-ai update
omp-ai config
omp-ai config edit
omp-ai reset-env
```

`omp-ai shell` opens a shell inside the same persistent workbench used by the agent.

`omp-ai stop` stops all OMP sessions, stops the persistent workbench, removes the ephemeral llama router, and releases model RAM/VRAM. It does **not** delete the workbench filesystem.

`omp-ai reset-env` intentionally deletes the persistent workbench writable layer. Packages installed with `apt`, `pip`, `npm`, etc. inside the workbench are lost, while `/workspace`, `/state`, model storage, drafts and source paths behind direct shares remain outside that writable layer.

## Persistent workbench

The default base is:

```text
debian:13-slim
```

The persistent container is:

```text
ompai-workbench
```

Its root filesystem is writable and survives ordinary stop/start cycles. The agent can install development tooling, for example:

```bash
apt-get update
apt-get install -y clang cmake ninja-build
pip install ...
npm install -g ...
cargo install ...
```

Those installations remain available on the next `omp-ai` launch.

Persistent/external areas:

```text
/workspace   -> /srv/ompai/workspace
/state       -> /var/lib/ompai/state
/shares/...  -> temporary explicitly granted host paths
/tmp         -> tmpfs, ephemeral
```

The workbench currently has a 6 GiB container memory limit. The installer reapplies the configured limit to an existing persistent workbench on rerun.

Verify it with:

```bash
uid="$(id -u ompai)"

sudo -u ompai \
  env HOME=/var/lib/ompai \
      XDG_RUNTIME_DIR="/run/user/$uid" \
      DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
  bash -c 'cd "$HOME" && podman inspect -f "{{.HostConfig.Memory}}" ompai-workbench'
```

For the default 6 GiB limit:

```text
6442450944
```

### Java / Gradle memory

Android/Gradle builds can be RAM-heavy. An earlier 3 GiB workbench cap was too small and could trigger the workbench cgroup OOM killer, including killing OMP itself. The current default is 6 GiB.

If a future workload repeatedly hits the workbench limit, raise `OMP_MEM` deliberately rather than removing isolation entirely.

## llama.cpp router

The llama container is:

```text
ompai-llama
```

It is ephemeral and recreated as needed. It has:

- NVIDIA GPU access;
- read-only model and draft mounts;
- read-only root filesystem;
- dropped Linux capabilities;
- `no-new-privileges`;
- no Podman/Docker socket;
- no desktop home;
- no external Internet network;
- loopback-only host exposure on `127.0.0.1:18080`.

Networking:

```text
omp-web  external/NAT network used by the OMP workbench
omp-llm  internal network shared by workbench + llama router
```

The router starts with:

```text
--parallel 1
--cont-batching
--kv-unified
--offline
--models-max 1
--models-autoload
```

Context and KV cache sizes are supplied through llama.cpp model presets, not one hard-coded global `--ctx-size`.

### Runtime tuning

Live llama settings live at:

```text
/var/lib/ompai/config/runtime.conf
```

Show/edit them:

```bash
omp-ai config
omp-ai config edit
```

After changing llama runtime settings:

```bash
omp-ai stop
omp-ai -c
```

The installer creates missing runtime keys but preserves existing runtime configuration on normal reruns.

Current important keys:

```ini
LLAMA_CTX_TOTAL=32768
LLAMA_PARALLEL=1
VRAM_RESERVE_MIB=256
LLAMA_LOG_VERBOSITY=4
LLAMA_CACHE_RAM_MIB=0
LLAMA_CACHE_TYPE_K=f16
LLAMA_CACHE_TYPE_V=f16

WORK_MODEL=Qwen3.5-9B-Q4_K_M
WORK_CTX_TOTAL=65536
WORK_CACHE_TYPE_K=q8_0
WORK_CACHE_TYPE_V=q8_0

SPEC_MODE=mtp
SPEC_TARGET_MODEL=Qwen3.8-27B-Q4_K_M
SPEC_CTX_TOTAL=32768
SPEC_CACHE_TYPE_K=f16
SPEC_CACHE_TYPE_V=f16
SPEC_DRAFT_FILE=mtp-Qwen3.8-27B-Q4_0.gguf
SPEC_DRAFT_N_MAX=8
SPEC_DRAFT_P_MIN=0.8
SPEC_DRAFT_NGL=all
SPEC_DRAFT_CACHE_TYPE=q4_0

MODELS_MAX=1
LLAMA_MEM=22g
```

`LLAMA_CACHE_RAM_MIB=0` plus `--no-cache-idle-slots` disables the RAM-backed cross-slot prompt cache.

## Current model performance profile

On the current RTX 3070 Ti 8 GB setup:

```text
Qwen3.5-9B-Q4_K_M
  32K q8_0: ~83.5 tok/s
  32K f16:  ~84.2 tok/s
  64K q8_0: ~83.6 tok/s
  64K f16:  does not fit in 8 GB VRAM
```

Therefore the daily/work model is 9B at 64K context with q8 KV.

The 27B Q4 model cannot fit entirely into 8 GB VRAM and is partially CPU-offloaded. With 32K/f16 and the MTP sidecar it is much slower (roughly single-digit tok/s), but benefits substantially from speculative decoding. It is intended for slower PLAN/SLOW work rather than routine iteration.

## OMP native configuration and roles

OMP keeps persistent native configuration under:

```text
/var/lib/ompai/state/.omp/agent/
```

Important files:

```text
config.yml
models.yml
```

The installer creates an initial `config.yml` only when one does not already exist.

**Normal setup reruns preserve the existing OMP configuration, model roles, cycle order, advisor setting, compaction settings and user edits.**

Initial role mapping for a fresh install:

```yaml
modelRoles:
  default: llama.cpp/Qwen3.5-9B-Q4_K_M
  smol: llama.cpp/Qwen3.5-9B-Q4_K_M
  slow: llama.cpp/Qwen3.8-27B-Q4_K_M:xhigh
  plan: llama.cpp/Qwen3.8-27B-Q4_K_M:xhigh
  commit: llama.cpp/Qwen3.5-9B-Q4_K_M
  tiny: llama.cpp/Qwen3.5-9B-Q4_K_M
  memory: llama.cpp/Qwen3.5-9B-Q4_K_M
  task: llama.cpp/Qwen3.5-9B-Q4_K_M
  advisor: llama.cpp/Qwen3.8-27B-Q4_K_M:xhigh

cycleOrder:
  - default
  - slow

advisor:
  enabled: false
```

Advisor is disabled by default to avoid unnecessary 9B/27B model swaps.

An old session may resume with the model saved in that session. That is session state, not setup overwriting global roles.

### models.yml / compaction

Intended local overrides:

```yaml
providers:
  llama.cpp:
    baseUrl: http://llama:8080
    auth: none
    api: openai-responses
    discovery:
      type: llama.cpp

    modelOverrides:
      Qwen3.5-9B-Q4_K_M:
        contextWindow: 65536
        maxContextWindow: 65536
        compactionModel: llama.cpp/Qwen3.5-9B-Q4_K_M

      Qwen3.8-27B-Q4_K_M:
        contextWindow: 32768
        maxContextWindow: 32768
        compactionModel: llama.cpp/Qwen3.5-9B-Q4_K_M
```

This lets 9B compact itself and lets a long 27B conversation use the fast 9B model for compaction.

`models.yml` is preserved on setup reruns.

## Concurrent OMP windows

Multiple `omp-ai` windows share one persistent `ompai-workbench` and one `ompai-llama` router.

```text
first OMP window   -> starts workbench + llama router
more OMP windows   -> exec into the same workbench/router
one window closes  -> only that OMP process exits
last window closes -> workbench stops; llama router is removed
next launch        -> same workbench writable layer starts again
```

`LLAMA_PARALLEL=1` is deliberate: concurrent generation requests serialize, giving the best single-stream throughput for this hardware/profile.

## Workspace and direct host shares

Persistent workspace:

```text
/srv/ompai/workspace
```

The agent sees it as:

```text
/workspace
```

Copy something into the persistent workspace:

```bash
ai-give ~/Downloads/file.pdf
```

Give a session direct read/write access to a host path:

```bash
omp-ai --share ~/code/project
```

Read-only direct access:

```bash
omp-ai --share-ro ~/Documents/reference
```

The share helper stages explicit bind mounts under:

```text
/run/omp-ai-shares
```

`/run` is tmpfs and is cleared at reboot. The current helper recreates `/run/omp-ai-shares` before preparing shares, so reboot should not require manual recreation.

Direct shares are temporary. ACLs are staged/restored around the active share lifetime.

Because simultaneous OMP sessions share one workbench mount namespace, treat concurrent OMP sessions as one trust domain.

## Search

OMP has web access through the workbench. llama.cpp itself remains on the internal `omp-llm` network and runs `--offline`.

Installer settings:

```ini
WEB_SEARCH_PRIMARY=auto
WEB_SEARCH_FALLBACK=duckduckgo
EXA_API_KEY=
```

If an Exa key is configured, it is stored in the isolated secrets area rather than embedded into the workbench image.

## Updating OMP

The workbench installs the official prebuilt OMP binary from `https://omp.sh/install`; OMP is not built from source.

Update the binary inside the existing persistent workbench:

```bash
omp-ai update
```

This preserves packages/tools already installed in the workbench.

`OMP_VERSION=` means follow the current stable release. A specific release can be pinned in `omp-ai.conf`.

Re-running `setup-omp-ai.sh` rebuilds the base image/helpers as necessary but does not silently destroy the existing persistent workbench.

## Re-running setup

Normal maintenance:

```bash
bash setup-omp-ai.sh
```

Current rerun behavior is intentionally conservative:

- preserves OMP session history;
- preserves existing `config.yml`;
- preserves `models.yml`;
- preserves model roles, cycle order and advisor choices;
- preserves existing runtime tuning in `/var/lib/ompai/config/runtime.conf`;
- preserves the persistent workbench;
- reapplies the configured workbench memory limit to the existing workbench;
- refreshes generated host helpers.

Changing `WORKBENCH_BASE_IMAGE` does not silently replace an existing workbench. To deliberately rebuild it from a new base:

```bash
omp-ai stop
omp-ai reset-env
```

Then launch OMP again.

## Security model

Main boundaries:

- dedicated locked host user `ompai`;
- rootless Podman;
- desktop home is not mounted into the workbench;
- no Podman/Docker socket inside OMP;
- only `/workspace`, `/state` and explicitly requested direct shares are exposed;
- model/draft storage is read-only to the AI side;
- llama has no external Internet;
- llama rootfs is read-only and capabilities are dropped;
- workbench has `no-new-privileges`;
- systemd user-slice resource limits;
- per-container memory/CPU/PID limits.

The workbench is intentionally writable and persistent, so treat it like a development machine controlled by the agent. If it is contaminated or badly modified:

```bash
omp-ai stop
omp-ai reset-env
```

This is container isolation, not a VM: containers share the host Linux kernel.

# Android Emulator sidecar

For Android development, use the separate emulator sidecar rather than giving OMP direct access to a personal phone.

Installer:

```text
setup-omp-android-emulator.sh
```

Run it as the normal desktop user, without parameters and without `sudo`:

```bash
chmod +x setup-omp-android-emulator.sh
./setup-omp-android-emulator.sh
```

Defaults:

```text
Android API:       36
System image:      google_apis / x86_64
AVD name:          omp_api36
Guest RAM:         2048 MiB
Container limit:   4g
CPU limit:         4
Internet:          enabled
```

Optional overrides are environment variables, for example:

```bash
ANDROID_API=35 ./setup-omp-android-emulator.sh
```

## Where Android files live

The Android SDK, emulator binary and system image are downloaded while building this rootless Podman image:

```text
localhost/omp-android-emulator:api36
```

They are stored in the `ompai` rootless Podman image storage, **not in the desktop user's home or project directory**.

Persistent virtual-phone/AVD data is stored at:

```text
/var/lib/ompai/android/avd
```

Generated build files live under:

```text
/var/lib/ompai/android/build
```

## Emulator isolation

```text
ompai-workbench
      |
      | private internal network: omp-android
      v
ompai-android
      |
      +-- /dev/kvm only
      +-- persistent AVD data only
      +-- optional outbound Internet through omp-web
```

The emulator container is rootless and receives only `/dev/kvm` from the host.

It does **not** receive the desktop home, main workspace, model storage, SSH/GPG material, Podman socket, whole USB bus, or `--privileged` access.

Its root filesystem is read-only. Writable state is limited to tmpfs and the dedicated AVD directory.

## Emulator control

The setup installs:

```bash
omp-android start
omp-android stop
omp-android restart
omp-android status
omp-android logs 200
omp-android reset
```

`omp-android reset` wipes only virtual Android device data and asks for explicit confirmation.

The emulator is headless (`-no-window`, `-no-audio`) and uses KVM acceleration. It does not need X11/Wayland access.

## ADB from OMP

Inside the workbench:

```bash
omp-ai shell
adb connect ompai-android:15555
adb devices -l
```

ADB endpoint:

```text
ompai-android:15555
```

The sidecar exposes ADB only over the private container network. The agent can install/debug/test APKs against the virtual device without touching the physical phone.

## KVM access

The emulator setup expects:

```text
/dev/kvm
```

The installer adds `ompai` to the host group owning `/dev/kvm` when necessary. If that group change has not propagated yet, log out/in or reboot once and rerun the emulator setup.

Do not solve KVM access by making the emulator container `--privileged`.

## Emulator memory and the 27B model

The emulator sidecar defaults to a 4 GiB container limit with a 2 GiB Android guest.

All `ompai` workloads still compete within the host-level resource envelope. Gradle + emulator + the large 27B model can create substantial RAM pressure.

For heavy 27B work, stop the emulator first:

```bash
omp-android stop
```

The normal 9B work profile is the better pairing for Android development.

## Physical Android phones

Wireless ADB can work from the workbench, but a paired physical phone gives the agent ordinary ADB-shell capabilities on that phone. For routine autonomous development, the isolated emulator is preferable.

After moving development to the emulator, remove the old physical-device pairing on the phone:

```text
Developer options
  -> Wireless debugging
  -> Paired devices
  -> Forget
```

or disable Wireless debugging entirely.

# Troubleshooting

## `mount: /run/omp-ai-shares: mount point does not exist`

`/run` is tmpfs and disappears across reboot. Current helpers recreate the share directory automatically.

If an older installed helper still shows the error, rerun the current installer:

```bash
bash setup-omp-ai.sh
```

## Workbench unexpectedly exits / OMP disappears during Gradle

Check for cgroup OOM kills:

```bash
journalctl -k -b | grep -i -E 'oom|killed process'
```

Then verify the workbench memory limit with the inspect command shown earlier. Default expected value:

```text
6442450944
```

## 9B works but 27B is much slower

Expected. The 9B model fits on the RTX 3070 Ti and is GPU-bound. The 27B Q4 model cannot fit in 8 GB VRAM and is partially CPU-offloaded.

Use the 9B/default role for routine coding and 27B SLOW/PLAN when the larger model is worth the latency.

## `omp-ai stats` times out while generation is active

With `LLAMA_PARALLEL=1`, the single inference slot may be busy. Completed/cumulative throughput data is more reliable than expecting the metrics endpoint to behave like another concurrent request.

## Android emulator cannot start

Check:

```bash
ls -l /dev/kvm
omp-android status
omp-android logs 200
```

If `/dev/kvm` is absent, enable CPU virtualization/SVM in firmware and ensure KVM is loaded on the host.

If `ompai` was just added to the KVM group, log out/in or reboot once and rerun:

```bash
./setup-omp-android-emulator.sh
```
