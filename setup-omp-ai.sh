#!/usr/bin/env bash
set -Eeuo pipefail

# Arch Linux installer/updater for a local OMP + llama.cpp sandbox.
# Normal usage: edit omp-ai.conf next to this file, then run this script
# as your normal desktop user (not with sudo).

AI_USER="ompai"
AI_HOME="/var/lib/ompai"
SHARE_GROUP="ompai-share"
WORKSPACE="/srv/ompai/workspace"
MODEL_STORE="/var/lib/ompai/models"

LLAMA_IMAGE="ghcr.io/ggml-org/llama.cpp:server-cuda"
MODELS_MAX=1
LLAMA_CTX_PER_SLOT=8192
LLAMA_PARALLEL=2
LLAMA_MEM="22g"
LLAMA_PORT=18080
VRAM_RESERVE_MIB=2048
LLAMA_CACHE_RAM_MIB=0

# Empty = latest stable release from the official OMP installer.
# You may pin a release tag, e.g. OMP_VERSION=v18.1.15.
OMP_VERSION=""
# Apt/glibc-based persistent workbench. Debian 13 is the current stable default.
WORKBENCH_BASE_IMAGE="debian:13-slim"
OMP_MEM="3g"

AI_SLICE_MEM="25G"
AI_SLICE_CPU="2400%"

EXA_API_KEY=""
WEB_SEARCH_PRIMARY="auto"
WEB_SEARCH_FALLBACK="duckduckgo"
HARDEN_HOME="true"
ASSUME_YES="false"
INITIAL_MODELS=()

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CONFIG_FILE="$SCRIPT_DIR/omp-ai.conf"

log(){ printf '\033[1;34m[omp-ai]\033[0m %s\n' "$*"; }
ok(){ printf '\033[1;32m[omp-ai]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[omp-ai]\033[0m %s\n' "$*" >&2; }
die(){ printf '\033[1;31m[omp-ai] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }
on_err(){
  local rc=$? line="${BASH_LINENO[0]:-?}" cmd="${BASH_COMMAND:-?}"
  printf '\033[1;31m[omp-ai] FAILED:\033[0m line %s: %s (exit %s)\n' "$line" "$cmd" "$rc" >&2
  exit "$rc"
}
trap on_err ERR

usage(){ cat <<'TXT'
Usage: ./setup-omp-ai.sh [options]

Normally edit omp-ai.conf and run with no arguments.

Overrides:
  --config PATH
  --model PATH                 import GGUF/bundle; repeatable
  --model-store PATH
  --models-max N
  --ctx-per-slot N
  --ctx N                      legacy alias for --ctx-per-slot
  --llama-parallel N
  --vram-reserve MIB
  --llama-memory SIZE
  --omp-memory SIZE
  --workbench-base-image IMAGE
  --exa-api-key KEY
  --web-search auto|exa|duckduckgo
  -y, --yes
  -h, --help
TXT
}

for a in "$@"; do case "$a" in -h|--help) usage; exit 0;; esac; done

args=("$@")
for ((i=0;i<${#args[@]};i++)); do
  case "${args[i]}" in
    --config) CONFIG_FILE="${args[i+1]:?--config needs PATH}"; ((++i));;
    --config=*) CONFIG_FILE="${args[i]#*=}";;
  esac
done

if [[ $EUID -eq 0 ]]; then
  MAIN_USER="${SUDO_USER:-}"
  [[ -n "$MAIN_USER" && "$MAIN_USER" != root ]] || die "Run from your normal desktop user, not a root login."
else
  MAIN_USER="${USER:?}"
fi
MAIN_HOME="$(getent passwd "$MAIN_USER" | cut -d: -f6)"
[[ -d "$MAIN_HOME" ]] || die "Cannot determine home for $MAIN_USER"

root(){ if [[ $EUID -eq 0 ]]; then "$@"; else sudo "$@"; fi; }
as_main(){
  if [[ $EUID -ne 0 && "$(id -un)" == "$MAIN_USER" ]]; then "$@";
  else root runuser -u "$MAIN_USER" -- env HOME="$MAIN_HOME" USER="$MAIN_USER" LOGNAME="$MAIN_USER" "$@"; fi
}
trim(){ local v="$1"; v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"; printf '%s' "$v"; }
unquote(){ local v="$1"; if (( ${#v} >= 2 )) && { [[ "${v:0:1}" == '"' && "${v: -1}" == '"' ]] || [[ "${v:0:1}" == "'" && "${v: -1}" == "'" ]]; }; then v="${v:1:${#v}-2}"; fi; printf '%s' "$v"; }
bool01(){ case "${1,,}" in 1|true|yes|y|on) echo 1;; 0|false|no|n|off) echo 0;; *) die "Invalid boolean: $1";; esac; }

set_cfg(){
  local k="$1" v="$2"
  case "$k" in
    AI_USER) AI_USER="$v";; AI_HOME) AI_HOME="$v";; SHARE_GROUP) SHARE_GROUP="$v";; WORKSPACE) WORKSPACE="$v";;
    MODEL_STORE) MODEL_STORE="$v";; MODEL|MODEL_PATH) [[ -n "$v" ]] && INITIAL_MODELS+=("$v");;
    MODELS_MAX) MODELS_MAX="$v";; LLAMA_IMAGE) LLAMA_IMAGE="$v";; LLAMA_PORT) LLAMA_PORT="$v";;
    LLAMA_CTX_PER_SLOT) LLAMA_CTX_PER_SLOT="$v";;
    LLAMA_CTX) warn "LLAMA_CTX is deprecated; treating it as LLAMA_CTX_PER_SLOT"; LLAMA_CTX_PER_SLOT="$v";;
    LLAMA_PARALLEL) LLAMA_PARALLEL="$v";; LLAMA_MEM) LLAMA_MEM="$v";; VRAM_RESERVE_MIB) VRAM_RESERVE_MIB="$v";;
    LLAMA_CACHE_RAM_MIB) LLAMA_CACHE_RAM_MIB="$v";;
    OMP_VERSION) OMP_VERSION="$v";;
    WORKBENCH_BASE_IMAGE) WORKBENCH_BASE_IMAGE="$v";;
    OMP_REPO) warn "OMP_REPO is deprecated and ignored; OMP is installed from the official binary installer";;
    OMP_REF)
      if [[ -n "$v" && "$v" != main ]]; then
        warn "OMP_REF is deprecated; treating '$v' as OMP_VERSION release tag"
        OMP_VERSION="$v"
      else
        warn "OMP_REF=main is deprecated and ignored; using the latest stable binary release"
      fi
      ;;
    OMP_MEM) OMP_MEM="$v";;
    AI_SLICE_MEM) AI_SLICE_MEM="$v";; AI_SLICE_CPU) AI_SLICE_CPU="$v";;
    EXA_API_KEY) EXA_API_KEY="$v";; WEB_SEARCH_PRIMARY) WEB_SEARCH_PRIMARY="$v";; WEB_SEARCH_FALLBACK) WEB_SEARCH_FALLBACK="$v";;
    HARDEN_HOME) HARDEN_HOME="$v";; ASSUME_YES) ASSUME_YES="$v";; "") ;;
    *) die "Unknown config key: $k";;
  esac
}

load_config(){
  local line k v n=0
  [[ -f "$1" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    ((++n)); line="${line%$'\r'}"; line="$(trim "$line")"
    [[ -z "$line" || "$line" == \#* || "$line" == \;* || "$line" == \[*\] ]] && continue
    [[ "$line" == *=* ]] || die "$1:$n: expected KEY=VALUE"
    k="$(trim "${line%%=*}")"; v="$(unquote "$(trim "${line#*=}")")"
    [[ "$k" =~ ^[A-Z][A-Z0-9_]*$ ]] || die "$1:$n: invalid key: $k"
    set_cfg "$k" "$v"
  done < "$1"
}

if [[ -f "$CONFIG_FILE" ]]; then log "Reading config: $CONFIG_FILE"; load_config "$CONFIG_FILE"; else warn "Config not found; using defaults."; fi

while (($#)); do
  case "$1" in
    --config|--config=*) [[ "$1" == --config ]] && shift 2 || shift;;
    --model) INITIAL_MODELS+=("${2:?}"); shift 2;;
    --model-store) MODEL_STORE="${2:?}"; shift 2;;
    --models-max) MODELS_MAX="${2:?}"; shift 2;;
    --ctx-per-slot|--ctx) LLAMA_CTX_PER_SLOT="${2:?}"; shift 2;;
    --llama-parallel) LLAMA_PARALLEL="${2:?}"; shift 2;;
    --vram-reserve) VRAM_RESERVE_MIB="${2:?}"; shift 2;;
    --llama-memory) LLAMA_MEM="${2:?}"; shift 2;;
    --omp-memory) OMP_MEM="${2:?}"; shift 2;;
    --workbench-base-image) WORKBENCH_BASE_IMAGE="${2:?}"; shift 2;;
    --exa-api-key) EXA_API_KEY="${2:?}"; shift 2;;
    --web-search) WEB_SEARCH_PRIMARY="${2:?}"; shift 2;;
    -y|--yes) ASSUME_YES=true; shift;;
    -h|--help) usage; exit 0;;
    *) die "Unknown option: $1";;
  esac
done

HARDEN_HOME="$(bool01 "$HARDEN_HOME")"; ASSUME_YES="$(bool01 "$ASSUME_YES")"
source /etc/os-release
[[ "${ID:-}" == arch ]] || die "This installer targets Arch Linux."
[[ "$MODEL_STORE" = /* && "$MODEL_STORE" != / ]] || die "MODEL_STORE must be an absolute non-root path"
case "$MODEL_STORE" in "$MAIN_HOME"|"$MAIN_HOME"/*) die "MODEL_STORE must be outside $MAIN_HOME";; esac
[[ "$WORKSPACE" = /* && "$WORKSPACE" != / ]] || die "WORKSPACE must be an absolute non-root path"
[[ "$MODELS_MAX" =~ ^[0-9]+$ ]] && (( MODELS_MAX >= 1 )) || die "MODELS_MAX must be >= 1"
[[ "$LLAMA_CTX_PER_SLOT" =~ ^[0-9]+$ ]] && (( LLAMA_CTX_PER_SLOT >= 1024 )) || die "LLAMA_CTX_PER_SLOT must be >= 1024"
[[ "$LLAMA_PARALLEL" =~ ^[0-9]+$ ]] && (( LLAMA_PARALLEL >= 1 )) || die "LLAMA_PARALLEL must be >= 1"
[[ "$LLAMA_CACHE_RAM_MIB" =~ ^[0-9]+$ ]] || die "LLAMA_CACHE_RAM_MIB must be >= 0"
[[ "$VRAM_RESERVE_MIB" =~ ^[0-9]+$ ]] || die "VRAM_RESERVE_MIB must be an integer"
[[ "$LLAMA_PORT" =~ ^[0-9]+$ ]] || die "LLAMA_PORT must be an integer"
[[ -n "$WORKBENCH_BASE_IMAGE" && "$WORKBENCH_BASE_IMAGE" != *[[:space:]]* ]] || die "WORKBENCH_BASE_IMAGE must be a non-empty image reference without whitespace"

case "${WEB_SEARCH_PRIMARY,,}" in auto) [[ -n "$EXA_API_KEY" ]] && WEB_SEARCH_PRIMARY=exa || WEB_SEARCH_PRIMARY=duckduckgo;; exa|duckduckgo) WEB_SEARCH_PRIMARY="${WEB_SEARCH_PRIMARY,,}";; *) die "WEB_SEARCH_PRIMARY must be auto/exa/duckduckgo";; esac
case "${WEB_SEARCH_FALLBACK,,}" in ""|none|off) WEB_SEARCH_FALLBACK="";; exa|duckduckgo) WEB_SEARCH_FALLBACK="${WEB_SEARCH_FALLBACK,,}";; *) die "WEB_SEARCH_FALLBACK must be exa/duckduckgo/none";; esac
[[ "$WEB_SEARCH_PRIMARY" == "$WEB_SEARCH_FALLBACK" ]] && WEB_SEARCH_FALLBACK=""
if [[ -n "$EXA_API_KEY" && -f "$CONFIG_FILE" ]]; then as_main chmod 0600 "$CONFIG_FILE"; fi

log "Installing packages..."
root pacman -S --needed --noconfirm podman crun passt netavark aardvark-dns fuse-overlayfs nvidia-container-toolkit git curl rsync acl sudo shadow python

log "Creating isolated host account and workspace..."
getent group "$SHARE_GROUP" >/dev/null || root groupadd "$SHARE_GROUP"
if ! id "$AI_USER" &>/dev/null; then root useradd -m -U -d "$AI_HOME" -s /usr/bin/nologin "$AI_USER"; fi
[[ "$(getent passwd "$AI_USER" | cut -d: -f6)" == "$AI_HOME" ]] || die "$AI_USER exists with another home"
root passwd -l "$AI_USER" >/dev/null 2>&1 || true
root usermod -s /usr/bin/nologin "$AI_USER"
root usermod -aG "$SHARE_GROUP" "$AI_USER"; root usermod -aG "$SHARE_GROUP" "$MAIN_USER"
AI_UID="$(id -u "$AI_USER")"; AI_GID="$(id -g "$AI_USER")"; MAIN_UID="$(id -u "$MAIN_USER")"; MAIN_GID="$(id -g "$MAIN_USER")"
root chown "$AI_USER:$AI_GID" "$AI_HOME"
root chmod 0700 "$AI_HOME"

if (( HARDEN_HOME )); then
  mode="$(stat -c %a "$MAIN_HOME")"
  if [[ "$mode" != 700 ]]; then
    ans=Y; (( ASSUME_YES )) || { read -r -p "Harden $MAIN_HOME with chmod go-rwx? [Y/n] " ans; ans="${ans:-Y}"; }
    [[ "$ans" =~ ^[Yy]$ ]] && root chmod go-rwx "$MAIN_HOME" || warn "Home permissions left unchanged."
  fi
fi

root install -d -o "$AI_USER" -g "$SHARE_GROUP" -m 2770 "$WORKSPACE"
root setfacl -m "u:$MAIN_USER:rwx,u:$AI_USER:rwx,g:$SHARE_GROUP:rwx,m:rwx" "$WORKSPACE"
root setfacl -d -m "u:$MAIN_USER:rwx,u:$AI_USER:rwx,g:$SHARE_GROUP:rwx,m:rwx" "$WORKSPACE"
[[ -e "$MAIN_HOME/AI" || -L "$MAIN_HOME/AI" ]] || as_main ln -s "$WORKSPACE" "$MAIN_HOME/AI"

# subuid/subgid for rootless Podman
if ! grep -q "^$AI_USER:" /etc/subuid; then start="$(awk -F: 'BEGIN{m=99999} NF>=3{e=$2+$3-1;if(e>m)m=e} END{b=65536;s=int((m+b)/b)*b;if(s<100000)s=100000;print s}' /etc/subuid /etc/subgid)"; root usermod --add-subuids "$start-$((start+65535))" "$AI_USER"; fi
if ! grep -q "^$AI_USER:" /etc/subgid; then start="$(awk -F: -v u="$AI_USER" '$1==u{print $2;exit}' /etc/subuid)"; root usermod --add-subgids "$start-$((start+65535))" "$AI_USER"; fi

log "Applying host-level resource limits..."
root install -d -m 0755 "/etc/systemd/system/user-${AI_UID}.slice.d"
root tee "/etc/systemd/system/user-${AI_UID}.slice.d/90-ompai.conf" >/dev/null <<EOT
[Slice]
MemoryMax=$AI_SLICE_MEM
MemorySwapMax=0
CPUQuota=$AI_SLICE_CPU
TasksMax=4096
EOT

log "Reloading systemd and enabling linger for $AI_USER..."
root systemctl daemon-reload
root loginctl enable-linger "$AI_USER"

# Do not block forever in `systemctl start`. user@UID.service may wait on a
# broken user-manager dependency/config; start asynchronously and diagnose it
# explicitly below.
log "Starting systemd user manager for $AI_USER (UID $AI_UID)..."
root systemctl start --no-block "user@${AI_UID}.service"
AI_RUNTIME="/run/user/$AI_UID"
user_manager_ok=0
for _ in $(seq 1 60); do
  state="$(root systemctl is-active "user@${AI_UID}.service" 2>/dev/null || true)"
  if [[ "$state" == active && -d "$AI_RUNTIME" ]]; then
    user_manager_ok=1
    break
  fi
  if [[ "$state" == failed ]]; then
    break
  fi
  sleep 0.5
done

if (( ! user_manager_ok )); then
  warn "systemd user manager did not become ready for $AI_USER."
  root systemctl status "user@${AI_UID}.service" --no-pager -l >&2 || true
  root journalctl -b -u "user@${AI_UID}.service" --no-pager -n 80 >&2 || true
  die "Cannot start user@${AI_UID}.service / create $AI_RUNTIME"
fi

# The drop-in is persistent; set-property also makes reruns apply the limits to
# an already-existing slice immediately.
root timeout 15s systemctl set-property --runtime "user-${AI_UID}.slice"   "MemoryMax=$AI_SLICE_MEM" "MemorySwapMax=0"   "CPUQuota=$AI_SLICE_CPU" "TasksMax=4096" >/dev/null
ok "systemd user manager is ready: $AI_RUNTIME"

as_ai(){
  # The installer itself normally runs from somewhere below $MAIN_HOME, which
  # is intentionally chmod 0700.  After switching to ompai, inheriting that
  # cwd makes getcwd()/Podman fail even though HOME/XDG_RUNTIME_DIR are valid.
  # Enter AI_HOME *as ompai* before executing every rootless command.
  root runuser -u "$AI_USER" -- env \
    HOME="$AI_HOME" USER="$AI_USER" LOGNAME="$AI_USER" \
    XDG_RUNTIME_DIR="$AI_RUNTIME" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=$AI_RUNTIME/bus" \
    PATH="/usr/local/sbin:/usr/local/bin:/usr/bin:/bin" \
    /bin/bash -c 'cd "$HOME" && exec "$@"' bash "$@"
}

log "Checking rootless Podman for $AI_USER..."
podman_err="$(mktemp)"
set +e
info_json="$(as_ai timeout --kill-after=5s 15s podman info --format json 2>"$podman_err")"
podman_rc=$?
set -e
if (( podman_rc != 0 )); then
  if (( podman_rc == 124 || podman_rc == 137 )); then
    warn "Rootless Podman did not answer within 15s. A stale Podman/conmon process may be holding libpod/storage state."
    root ps -u "$AI_USER" -o pid,ppid,stat,etime,pcpu,cmd --sort=-pcpu >&2 || true
    rm -f "$podman_err"
    die "Podman is wedged. Recover with: sudo loginctl terminate-user $AI_USER ; sudo systemctl start user-runtime-dir@${AI_UID}.service ; sudo systemctl start --no-block user@${AI_UID}.service ; then rerun setup."
  fi
  warn "Rootless Podman failed to initialize for $AI_USER. Actual Podman error:"
  sed 's/^/  /' "$podman_err" >&2 || true
  rm -f "$podman_err"
  die "Rootless Podman initialization failed"
fi
rm -f "$podman_err"

# Do not rely on Podman's Go-template struct field names here. They have
# changed across releases even when the stable JSON keys stayed the same.
# Arch currently ships Podman 6.x, so parse the documented JSON interface.
if ! info="$(python3 -c '
import json, sys
d = json.load(sys.stdin)
h = d.get("host") or d.get("Host") or {}
sec = h.get("security") or h.get("Security") or {}
rootless = sec.get("rootless", h.get("rootless", h.get("Rootless", False)))
cgv = h.get("cgroupVersion", h.get("CgroupVersion", ""))
cgm = h.get("cgroupManager", h.get("CgroupManager", ""))
print(str(bool(rootless)).lower(), cgv, cgm)
' <<<"$info_json")"; then
  die "Could not parse 'podman info --format json'"
fi

read -r podman_rootless podman_cgroup_version podman_cgroup_manager <<<"$info"
log "Podman: rootless=$podman_rootless cgroups=$podman_cgroup_version manager=$podman_cgroup_manager"
[[ "$podman_rootless" == true ]] || die "Podman is not running rootless for $AI_USER"
[[ "$podman_cgroup_version" == v2 ]] || die "Podman requires cgroup v2 here; got: ${podman_cgroup_version:-<missing>}"
[[ "$podman_cgroup_manager" == systemd ]] || die "Podman cgroup manager is '${podman_cgroup_manager:-<missing>}', expected 'systemd'"

root install -d -o "$AI_USER" -g "$AI_GID" -m 0700 "$AI_HOME/state" "$AI_HOME/state/.omp" "$AI_HOME/state/.omp/agent" "$AI_HOME/src" "$AI_HOME/build"
root install -d -o root -g "$AI_GID" -m 0750 "$AI_HOME/secrets" "$MODEL_STORE"
SECRET_ENV="$AI_HOME/secrets/omp.env"
if [[ -n "$EXA_API_KEY" ]]; then tmp="$(mktemp)"; printf 'EXA_API_KEY=%s\n' "$EXA_API_KEY" >"$tmp"; root install -o root -g "$AI_GID" -m 0640 "$tmp" "$SECRET_ENV"; rm -f "$tmp"; else root rm -f "$SECRET_ENV"; fi

root tee "$AI_HOME/state/.omp/agent/config.yml" >/dev/null <<EOT
tools:
  approvalMode: yolo
web_search:
  enabled: true
fetch:
  enabled: true
browser:
  enabled: false
computer:
  enabled: false
modelRoles:
  web: web/$WEB_SEARCH_PRIMARY
retry:
  fallbackChains:
EOT
if [[ -n "$WEB_SEARCH_FALLBACK" ]]; then root tee -a "$AI_HOME/state/.omp/agent/config.yml" >/dev/null <<EOT
    web:
      - web/$WEB_SEARCH_FALLBACK
EOT
else root tee -a "$AI_HOME/state/.omp/agent/config.yml" >/dev/null <<'EOT'
    web: []
EOT
fi
root rm -f "$AI_HOME/state/.omp/agent/models.yml"
root chown -R "$AI_USER:$AI_GID" "$AI_HOME/state"; root chmod -R go-rwx "$AI_HOME/state"

validate_model(){
  local src="$1" f found=0
  as_main test -r "$src" || die "Unreadable model source: $src"
  if [[ -f "$src" ]]; then [[ "${src,,}" == *.gguf && "$(as_main head -c4 "$src" 2>/dev/null || true)" == GGUF ]] || die "Invalid GGUF: $src"; return; fi
  [[ -d "$src" ]] || die "Model source must be file or directory: $src"
  find "$src" -type l -print -quit | grep -q . && die "Model bundle may not contain symlinks: $src"
  while IFS= read -r -d '' f; do found=1; [[ "$(as_main head -c4 "$f" 2>/dev/null || true)" == GGUF ]] || die "Invalid GGUF: $f"; done < <(find "$src" -type f -iname '*.gguf' -print0)
  (( found )) || die "No GGUF files in bundle: $src"
}
for raw in "${INITIAL_MODELS[@]}"; do
  [[ "$raw" == '~/'* ]] && raw="$MAIN_HOME/${raw#~/}"
  src="$(realpath -e "$raw")"; validate_model "$src"; name="$(basename "$src")"; dest="$MODEL_STORE/$name"
  [[ -e "$dest" ]] && { log "Model already exists, skipping: $name"; continue; }
  tmp="$MODEL_STORE/.import-$name.$$"; root rm -rf "$tmp"
  [[ -f "$src" ]] && root cp --reflink=auto --sparse=always "$src" "$tmp" || root cp -a --reflink=auto "$src" "$tmp"
  root chown -R root:"$AI_GID" "$tmp"
  [[ -d "$tmp" ]] && { root find "$tmp" -type d -exec chmod 0550 {} +; root find "$tmp" -type f -exec chmod 0440 {} +; } || root chmod 0440 "$tmp"
  root mv "$tmp" "$dest"
done

log "Preparing NVIDIA CDI and Podman networks..."
root install -d -m 0755 /etc/cdi
root nvidia-ctk cdi list 2>/dev/null | grep -q '^nvidia.com/gpu=all$' || root nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
root nvidia-ctk cdi list | grep -q '^nvidia.com/gpu=all$' || die "NVIDIA CDI unavailable"
as_ai podman network exists omp-llm 2>/dev/null || as_ai podman network create --internal omp-llm >/dev/null
as_ai podman network exists omp-web 2>/dev/null || as_ai podman network create omp-web >/dev/null

# The persistent workbench mounts this parent with rslave propagation so
# direct-share bind mounts created later become visible without recreating it.
SHARE_STAGE="/run/omp-ai-shares"
root install -d -o root -g root -m 0711 "$SHARE_STAGE"
if ! root mountpoint -q "$SHARE_STAGE"; then root mount --bind "$SHARE_STAGE" "$SHARE_STAGE"; fi
root mount --make-rshared "$SHARE_STAGE"

# ----- OMP updater -----
# The runtime uses a persistent writable workbench container.  If the
# workbench already exists, update OMP in-place so all user-installed apt/pip/
# npm/cargo tooling survives.  Before the first workbench exists, build the
# base image from the official prebuilt OMP binary.
root install -d -m 0755 /usr/local/libexec
OMP_UPDATE_HELPER="/usr/local/libexec/omp-ai-update"
root tee "$OMP_UPDATE_HELPER" >/dev/null <<EOT
#!/usr/bin/env bash
set -Eeuo pipefail
AI_HOME="$AI_HOME"
AI_USER="$AI_USER"
AI_UID="$AI_UID"
OMP_VERSION="$OMP_VERSION"
WORKBENCH_BASE_IMAGE="$WORKBENCH_BASE_IMAGE"
BUILD_DIR="$AI_HOME/build/omp-runtime"
WORKBENCH=ompai-workbench
MODE="\${1:-update}"
SESS_DIR="/run/user/$AI_UID/omp-ai-sessions"

[[ "\$(id -un)" == "\$AI_USER" ]] || { echo "omp-ai-update must run as \$AI_USER" >&2; exit 1; }
export HOME="\$AI_HOME"
export XDG_RUNTIME_DIR="/run/user/\$AI_UID"
export DBUS_SESSION_BUS_ADDRESS="unix:path=\$XDG_RUNTIME_DIR/bus"
export PATH="/usr/local/sbin:/usr/local/bin:/usr/bin:/bin"
cd "\$AI_HOME"

pctl(){ timeout --kill-after=3s 20s podman "\$@"; }
pupdate(){ timeout --kill-after=10s 600s podman "\$@"; }
pbuild(){ timeout --kill-after=20s 1800s podman "\$@"; }
container_exists(){
  local rc=0
  pctl container exists "\$1" || rc=\$?
  case \$rc in 0) return 0;; 1) return 1;; *) echo "[omp-ai] ERROR: Podman control operation failed (rc=\$rc)." >&2; exit "\$rc";; esac
}

shopt -s nullglob
markers=("\$SESS_DIR"/*.session)
shopt -u nullglob
(( \${#markers[@]} == 0 )) || {
  echo "Active OMP sessions exist. Close them (or run: omp-ai stop) before updating." >&2
  exit 3
}

if [[ "\$MODE" != rebuild-base ]] && container_exists "\$WORKBENCH"; then
  was_running="\$(pctl inspect -f '{{.State.Running}}' "\$WORKBENCH" 2>/dev/null || true)"
  [[ "\$was_running" == true ]] || pctl start "\$WORKBENCH" >/dev/null
  old_version="\$(pctl exec "\$WORKBENCH" /usr/local/bin/omp --version 2>/dev/null || true)"

  if [[ -n "\$OMP_VERSION" ]]; then
    echo "[omp-ai] Updating persistent workbench OMP to pinned version: \$OMP_VERSION"
    pupdate exec -e "OMP_VERSION=\$OMP_VERSION" -e PI_INSTALL_DIR=/usr/local/bin "\$WORKBENCH" /bin/bash -lc '
      set -e
      curl --connect-timeout 10 --max-time 300 -fsSL https://omp.sh/install -o /tmp/install-omp.sh
      sh /tmp/install-omp.sh --binary --ref "\$OMP_VERSION"
      rm -f /tmp/install-omp.sh
    '
  else
    echo "[omp-ai] Updating OMP inside persistent workbench..."
    pupdate exec "\$WORKBENCH" /usr/local/bin/omp update
  fi

  new_version="\$(pctl exec "\$WORKBENCH" /usr/local/bin/omp --version)"
  [[ "\$was_running" == true ]] || pctl stop -t 10 "\$WORKBENCH" >/dev/null
  if [[ -n "\$old_version" ]]; then
    echo "[omp-ai] OMP: \$old_version -> \$new_version"
  else
    echo "[omp-ai] OMP installed: \$new_version"
  fi
  exit 0
fi

old_version="\$(pctl run --rm --entrypoint /usr/local/bin/omp localhost/omp:latest --version 2>/dev/null || true)"
rm -rf -- "\$BUILD_DIR"
install -d -m 0700 "\$BUILD_DIR"
cat >"\$BUILD_DIR/Containerfile" <<'CONTAINERFILE'
ARG BASE_IMAGE=debian:13-slim
FROM \${BASE_IMAGE}

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bash ca-certificates curl git openssh-client tini sqlite3 unzip \
      build-essential pkg-config libssl-dev jq ripgrep fd-find \
      python3 python3-pip python3-venv python-is-python3 \
 && ln -sf /usr/bin/fdfind /usr/local/bin/fd \
 && rm -rf /var/lib/apt/lists/*

ARG OMP_VERSION=""
ARG OMP_UPDATE_EPOCH=""
ENV PI_INSTALL_DIR=/usr/local/bin
RUN echo "\$OMP_UPDATE_EPOCH" >/dev/null \
 && curl -fsSL https://omp.sh/install -o /tmp/install-omp.sh \
 && if [ -n "\$OMP_VERSION" ]; then \
      sh /tmp/install-omp.sh --binary --ref "\$OMP_VERSION"; \
    else \
      sh /tmp/install-omp.sh --binary; \
    fi \
 && rm -f /tmp/install-omp.sh \
 && /usr/local/bin/omp --version

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/bin/sleep", "infinity"]
CONTAINERFILE

echo "[omp-ai] Building/updating OMP workbench base image: \$WORKBENCH_BASE_IMAGE"
pbuild build --pull=newer \
  --build-arg "BASE_IMAGE=\$WORKBENCH_BASE_IMAGE" \
  --build-arg "OMP_VERSION=\$OMP_VERSION" \
  --build-arg "OMP_UPDATE_EPOCH=\$(date +%s)" \
  -f "\$BUILD_DIR/Containerfile" \
  -t localhost/omp:latest "\$BUILD_DIR"
new_version="\$(pctl run --rm --entrypoint /usr/local/bin/omp localhost/omp:latest --version)"
if [[ -n "\$old_version" ]]; then
  echo "[omp-ai] OMP base image: \$old_version -> \$new_version"
else
  echo "[omp-ai] OMP base image installed: \$new_version"
fi
EOT
root chmod 0755 "$OMP_UPDATE_HELPER"
root chown root:root "$OMP_UPDATE_HELPER"

# Remove the checkout created by older versions of this installer. OMP is no
# longer built from source; the official installer downloads a release binary.
root rm -rf "$AI_HOME/src/oh-my-pi" 2>/dev/null || true
root rmdir "$AI_HOME/src" 2>/dev/null || true

log "Building/updating lightweight OMP runtime from the official prebuilt binary..."
as_ai "$OMP_UPDATE_HELPER" rebuild-base

as_ai podman pull "$LLAMA_IMAGE"

# Rebuilding localhost/omp:latest does not mutate an already-created writable
# workbench rootfs. Preserve it rather than silently deleting user-installed
# packages; tell the user how to migrate explicitly.
if as_ai timeout --kill-after=3s 20s podman container exists ompai-workbench 2>/dev/null; then
  current_base="$(as_ai timeout --kill-after=3s 20s podman inspect -f '{{ index .Config.Labels "io.ompai.workbench-base" }}' ompai-workbench 2>/dev/null || true)"
  if [[ "$current_base" != "$WORKBENCH_BASE_IMAGE" ]]; then
    warn "Existing ompai-workbench was created from '${current_base:-legacy/unknown}'. New base image is '$WORKBENCH_BASE_IMAGE'."
    warn "To migrate the workbench OS, run: omp-ai stop && omp-ai reset-env  (this removes packages installed inside the old workbench rootfs)."
  fi
fi
as_ai timeout --kill-after=5s 180s podman run --rm --device nvidia.com/gpu=all docker.io/library/ubuntu:24.04 nvidia-smi -L >/dev/null || die "Rootless Podman cannot use NVIDIA CDI"

root install -d -m 0755 /usr/local/libexec

# ----- direct-share helper -----
SHARE_HELPER="/usr/local/libexec/omp-ai-share"
SHARE_STATE="/var/lib/ompai-share-state"
SHARE_STAGE="/run/omp-ai-shares"
root install -d -o root -g root -m 0700 "$SHARE_STATE"
root install -d -o root -g root -m 0711 "$SHARE_STAGE"
root tee "$SHARE_HELPER" >/dev/null <<EOT
#!/usr/bin/env bash
set -Eeuo pipefail
AI_USER="$AI_USER"; MAIN_USER="$MAIN_USER"; MAIN_UID="$MAIN_UID"; MAIN_GID="$MAIN_GID"; STATE="$SHARE_STATE"; STAGE="$SHARE_STAGE"; MAIN_HOME="$MAIN_HOME"
[[ \$EUID -eq 0 ]] || exit 1
valid_sid(){ [[ "\$1" =~ ^[A-Za-z0-9._-]+$ ]]; }
sdir(){ valid_sid "\$1" || exit 2; printf '%s/%s' "\$STATE" "\$1"; }
exec 9>"\$STATE/.lock"
if ! flock -w 10 9; then
  echo "[omp-ai] ERROR: share-state lock is busy for >10s; refusing to hang." >&2
  exit 6
fi
prepare_stage(){
  # Direct shares are bind-mounted below STAGE after the persistent workbench
  # may already be running.  Make STAGE a shared mount point so rslave
  # propagation carries new host submounts into the workbench namespace.
  if ! mountpoint -q "\$STAGE"; then
    mount --bind "\$STAGE" "\$STAGE"
  fi
  mount --make-rshared "\$STAGE"
}
cleanup_one(){
  local sid="\$1" d item src mnt before after
  d="\$(sdir "\$sid")"; [[ -d "\$d" ]] || return 0
  [[ -f "\$d/mounts" ]] && tac "\$d/mounts" | while IFS= read -r mnt; do umount -l -- "\$mnt" >/dev/null 2>&1 || true; done
  while IFS= read -r item; do
    src="\$(cat "\$item/source" 2>/dev/null || true)"; before="\$item/before"; after="\$item/after"
    if [[ -d "\$src" ]]; then find -P "\$src" -print0 2>/dev/null | sort -z >"\$after" || :; elif [[ -e "\$src" ]]; then printf '%s\0' "\$src" | sort -z >"\$after"; else : >"\$after"; fi
    setfacl --restore="\$item/acl" -P >/dev/null 2>&1 || true
    [[ -f "\$before" && -f "\$after" ]] && comm -z -13 "\$before" "\$after" | while IFS= read -r -d '' p; do
      [[ -e "\$p" || -L "\$p" ]] || continue; chown -h "\$MAIN_UID:\$MAIN_GID" "\$p" 2>/dev/null || true
      [[ -L "\$p" ]] || setfacl -x "u:\$AI_USER" "\$p" >/dev/null 2>&1 || true
      [[ -d "\$p" ]] && setfacl -x "d:u:\$AI_USER" "\$p" >/dev/null 2>&1 || true
    done
  done < <(find "\$d" -mindepth 1 -maxdepth 1 -type d -name 'item-*' -print | sort -Vr)
  rm -rf -- "\$STAGE/\$sid" "\$d"
}
case "\${1:-}" in
  prepare)
    prepare_stage
    ;;
  begin)
    prepare_stage
    sid="\$(cat /proc/sys/kernel/random/uuid)"; install -d -m 0700 "\$STATE/\$sid"; install -d -m 0711 "\$STAGE/\$sid"
    date +%s >"\$STATE/\$sid/heartbeat"; echo 0 >"\$STATE/\$sid/owner_pid"; echo 0 >"\$STATE/\$sid/owner_start"; cat /proc/sys/kernel/random/boot_id >"\$STATE/\$sid/boot_id"; echo 0 >"\$STATE/\$sid/count"; : >"\$STATE/\$sid/mounts"; echo "\$sid";;
  grant)
    sid="\${2:?}"; mode="\${3:?}"; raw="\${4:?}"; [[ "\$mode" == rw || "\$mode" == ro ]] || exit 2; d="\$(sdir "\$sid")"; [[ -d "\$d" ]] || exit 2
    src="\$(realpath -e -- "\$raw")"; [[ -f "\$src" || -d "\$src" ]] || exit 2
    [[ "\$src" != / && "\$src" != "$MAIN_HOME" ]] || { echo "Refusing overly broad share" >&2; exit 2; }
    case "\$src" in /proc|/proc/*|/sys|/sys/*|/dev|/dev/*|/run|/run/*) echo "Refusing pseudo-filesystem" >&2; exit 2;; esac
    shopt -s nullglob; for sf in "\$STATE"/*/item-*/source; do other="\$(cat "\$sf" 2>/dev/null || true)"; [[ -z "\$other" ]] && continue; if [[ "\$src" == "\$other" || "\$src" == "\$other"/* || "\$other" == "\$src"/* ]]; then echo "Share overlaps active share: \$other" >&2; exit 4; fi; done; shopt -u nullglob
    runuser -u "\$MAIN_USER" -- test -r "\$src" || exit 3; [[ "\$mode" == ro ]] || runuser -u "\$MAIN_USER" -- test -w "\$src" || exit 3
    count="\$(cat "\$d/count")"; count=\$((count+1)); echo "\$count" >"\$d/count"; item="\$d/item-\$(printf '%04d' "\$count")"; install -d -m 0700 "\$item"; echo "\$src" >"\$item/source"
    if [[ -d "\$src" ]]; then find -P "\$src" -print0 | sort -z >"\$item/before"; getfacl -R -P -p -- "\$src" >"\$item/acl"; else printf '%s\0' "\$src" | sort -z >"\$item/before"; getfacl -p -- "\$src" >"\$item/acl"; fi
    if [[ -d "\$src" ]]; then
      if [[ "\$mode" == ro ]]; then
        find -P "\$src" -type d -print0 | xargs -0 -r setfacl -m "u:\$AI_USER:r-x" --; find -P "\$src" -type f -print0 | xargs -0 -r setfacl -m "u:\$AI_USER:r--" --; runuser -u "\$MAIN_USER" -- find -P "\$src" -type f -executable -print0 | xargs -0 -r setfacl -m "u:\$AI_USER:r-x" --
      else
        find -P "\$src" -type d -print0 | xargs -0 -r setfacl -m "u:\$AI_USER:rwx" -m "d:u:\$AI_USER:rwx" -m "d:u:\$MAIN_USER:rwx" --; find -P "\$src" -type f -print0 | xargs -0 -r setfacl -m "u:\$AI_USER:rw-" --; runuser -u "\$MAIN_USER" -- find -P "\$src" -type f -executable -print0 | xargs -0 -r setfacl -m "u:\$AI_USER:rwx" --
      fi
    else [[ "\$mode" == ro ]] && perms=r-- || perms=rw-; setfacl -m "u:\$AI_USER:\$perms" -- "\$src"; fi
    base="\$(basename -- "\$src" | sed 's/[^A-Za-z0-9._-]/_/g')"; [[ -n "\$base" ]] || base=share; mnt="\$STAGE/\$sid/\$(printf '%04d' "\$count")-\$base"
    if [[ -d "\$src" ]]; then install -d -m 0711 "\$mnt"; else install -m 0644 /dev/null "\$mnt"; fi
    mount --bind -- "\$src" "\$mnt"; [[ "\$mode" == ro ]] && mount -o remount,bind,ro "\$mnt"; echo "\$mnt" >>"\$d/mounts"; echo "\$mnt";;
  attach)
    sid="\${2:?}"; pid="\${3:?}"; start="\${4:?}"; d="\$(sdir "\$sid")"; current="\$(awk '{print \$22}' "/proc/\$pid/stat" 2>/dev/null || true)"; [[ "\$current" == "\$start" ]] || exit 3; echo "\$pid" >"\$d/owner_pid"; echo "\$start" >"\$d/owner_start"; date +%s >"\$d/heartbeat";;
  heartbeat) d="\$(sdir "\${2:?}")"; [[ -d "\$d" ]] || exit 2; date +%s >"\$d/heartbeat";;
  cleanup) cleanup_one "\${2:?}";;
  cleanup-stale)
    age="\${2:-180}"; now="\$(date +%s)"; boot="\$(cat /proc/sys/kernel/random/boot_id)"; shopt -s nullglob
    for d in "\$STATE"/*; do [[ -d "\$d" ]] || continue; sid="\$(basename "\$d")"; hb="\$(cat "\$d/heartbeat" 2>/dev/null || echo 0)"; oldboot="\$(cat "\$d/boot_id" 2>/dev/null || true)"; pid="\$(cat "\$d/owner_pid" 2>/dev/null || echo 0)"; start="\$(cat "\$d/owner_start" 2>/dev/null || echo 0)"; cur="\$(awk '{print \$22}' "/proc/\$pid/stat" 2>/dev/null || true)"; live=0; [[ "\$pid" != 0 && -n "\$cur" && "\$cur" == "\$start" ]] && live=1; [[ "\$oldboot" != "\$boot" ]] || (( !live && now-hb >= age )) && cleanup_one "\$sid"; done;;
  *) exit 2;;
esac
EOT
root chmod 0755 "$SHARE_HELPER"; root chown root:root "$SHARE_HELPER"
root "$SHARE_HELPER" prepare

# ----- shared llama router + persistent OMP workbench helper -----
INNER="/usr/local/libexec/omp-ai-inner"
root tee "$INNER" >/dev/null <<EOT
#!/usr/bin/env bash
set -Eeuo pipefail
AI_HOME="$AI_HOME"; WORKBENCH_BASE_IMAGE="$WORKBENCH_BASE_IMAGE"; WORKSPACE="$WORKSPACE"; MODEL_STORE="$MODEL_STORE"; LLAMA_IMAGE="$LLAMA_IMAGE"; LLAMA_PORT="$LLAMA_PORT"; LLAMA_CTX_PER_SLOT="$LLAMA_CTX_PER_SLOT"; LLAMA_PARALLEL="$LLAMA_PARALLEL"; LLAMA_MEM="$LLAMA_MEM"; OMP_MEM="$OMP_MEM"; VRAM_RESERVE_MIB="$VRAM_RESERVE_MIB"; MODELS_MAX="$MODELS_MAX"; LLAMA_CACHE_RAM_MIB="$LLAMA_CACHE_RAM_MIB"; AI_UID="$AI_UID"; SECRET_ENV="$SECRET_ENV"; SHARE_STAGE="$SHARE_STAGE"
export HOME="\$AI_HOME" XDG_RUNTIME_DIR="/run/user/\$AI_UID" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/\$AI_UID/bus" PATH="/usr/local/sbin:/usr/local/bin:/usr/bin:/bin" TERM="\${TERM:-xterm-256color}"
cd "\$AI_HOME"
LLAMA_NAME=ompai-llama
WORKBENCH=ompai-workbench
SESS_DIR="\$XDG_RUNTIME_DIR/omp-ai-sessions"
EXEC_DIR="\$AI_HOME/state/runtime/omp-exec"
ROUTER_LOCK="\$XDG_RUNTIME_DIR/omp-ai-router.lock"
mkdir -p "\$SESS_DIR" "\$EXEC_DIR"; chmod 0700 "\$SESS_DIR" "\$EXEC_DIR"
pctl(){ timeout --kill-after=3s 20s podman "\$@"; }
container_exists(){
  local rc=0
  pctl container exists "\$1" || rc=\$?
  case \$rc in 0) return 0;; 1) return 1;; *) echo "[omp-ai] ERROR: Podman control operation failed (rc=\$rc)." >&2; return "\$rc";; esac
}
with_lock(){
  exec 8>"\$ROUTER_LOCK"
  if ! flock -w 10 8; then
    echo "[omp-ai] ERROR: lifecycle lock is busy for >10s; refusing to hang." >&2
    echo "[omp-ai] Check: ps -fu \$USER | grep '[o]mp-ai'" >&2
    exec 8>&-
    return 1
  fi
}
unlock(){ flock -u 8 || true; exec 8>&-; }
has_sessions(){ local m=(); shopt -s nullglob; m=("\$SESS_DIR"/*.session); shopt -u nullglob; (( \${#m[@]} > 0 )); }
healthy(){ curl --connect-timeout 2 --max-time 4 -fsS "http://127.0.0.1:\$LLAMA_PORT/health" 2>/dev/null | grep -q '"status"[[:space:]]*:[[:space:]]*"ok"'; }
workbench_running(){ [[ "\$(pctl inspect -f '{{.State.Running}}' "\$WORKBENCH" 2>/dev/null || true)" == true ]]; }
ensure_workbench(){
  local exists_rc=0
  container_exists "\$WORKBENCH" || exists_rc=\$?
  if (( exists_rc > 1 )); then return "\$exists_rc"; fi
  if (( exists_rc == 1 )); then
    echo "[omp-ai] Creating persistent workbench from localhost/omp:latest (base: \$WORKBENCH_BASE_IMAGE)..."
    pctl create --name "\$WORKBENCH" \
      --label "io.ompai.workbench-base=\$WORKBENCH_BASE_IMAGE" \
      --network omp-web --network omp-llm \
      --memory "\$OMP_MEM" --cpus 8 --pids-limit 4096 \
      --security-opt no-new-privileges \
      --tmpfs /tmp:rw,nosuid,nodev,size=1g \
      --mount "type=bind,src=\$WORKSPACE,dst=/workspace,rw=true,bind-nonrecursive" \
      --mount "type=bind,src=\$AI_HOME/state,dst=/state,rw=true,bind-nonrecursive" \
      --mount "type=bind,src=\$SHARE_STAGE,dst=\$SHARE_STAGE,rw=true,bind-propagation=rslave" \
      localhost/omp:latest >/dev/null
  fi
  if ! workbench_running; then
    pctl start "\$WORKBENCH" >/dev/null
    # A stopped workbench may contain aliases/meta from a previous crashed boot.
    podman exec "\$WORKBENCH" /bin/bash -lc 'mkdir -p /shares /state/runtime/omp-exec; rm -rf /shares/* /state/runtime/omp-exec/*' >/dev/null 2>&1 || true
  fi
}
stop_if_unused(){
  if ! has_sessions; then
    workbench_running && pctl stop -t 10 "\$WORKBENCH" >/dev/null 2>&1 || true
    pctl rm -f -t 10 "\$LLAMA_NAME" >/dev/null 2>&1 || true
  fi
}
start_router(){
  if [[ "\$(pctl inspect -f '{{.State.Running}}' "\$LLAMA_NAME" 2>/dev/null || true)" == true ]] && healthy; then return 0; fi
  pctl rm -f -t 5 "\$LLAMA_NAME" >/dev/null 2>&1 || true
  echo "[omp-ai] Starting shared llama.cpp router: parallel=\$LLAMA_PARALLEL, ctx/slot=\$LLAMA_CTX_PER_SLOT"
  pctl run -d --name "\$LLAMA_NAME" --replace --network omp-llm --network-alias llama --device nvidia.com/gpu=all --memory "\$LLAMA_MEM" --cpus 20 --pids-limit 512 --read-only --cap-drop ALL --security-opt no-new-privileges --tmpfs /tmp:rw,nosuid,nodev,size=512m --mount "type=bind,src=\$MODEL_STORE,dst=/models,ro=true,bind-nonrecursive" -p "127.0.0.1:\$LLAMA_PORT:8080" "\$LLAMA_IMAGE" \
    --models-dir /models --models-max "\$MODELS_MAX" --models-autoload \
    --host 0.0.0.0 --port 8080 \
    --parallel "\$LLAMA_PARALLEL" \
    --cont-batching \
    --kv-unified \
    --kv-unified-per-slot "\$LLAMA_CTX_PER_SLOT" \
    --cache-ram "\$LLAMA_CACHE_RAM_MIB" --no-cache-idle-slots \
    --cache-type-k q8_0 --cache-type-v q8_0 \
    --flash-attn auto --fit on --fit-target "\$VRAM_RESERVE_MIB" \
    --offline >/dev/null
  for _ in \$(seq 1 300); do healthy && return 0; [[ "\$(pctl inspect -f '{{.State.Running}}' "\$LLAMA_NAME" 2>/dev/null || true)" == true ]] || break; sleep 1; done
  pctl logs --tail=120 "\$LLAMA_NAME" >&2 || true; return 1
}
kill_exec_session(){
  local sid="\$1" meta="\$EXEC_DIR/\$1.pid" pid exe
  [[ -f "\$meta" && workbench_running ]] || { rm -f "\$meta"; return 0; }
  read -r pid <"\$meta" || true
  [[ "\${pid:-}" =~ ^[0-9]+$ ]] || { rm -f "\$meta"; return 0; }
  exe="\$(pctl exec "\$WORKBENCH" readlink -f "/proc/\$pid/exe" 2>/dev/null || true)"
  if [[ "\$exe" == /usr/local/bin/omp ]]; then
    pctl exec "\$WORKBENCH" kill -TERM "\$pid" >/dev/null 2>&1 || true
  fi
  pctl exec "\$WORKBENCH" rm -rf -- "/shares/\$sid" >/dev/null 2>&1 || true
  rm -f "\$meta"
}
case "\${1:-}" in
  stop)
    # stop is an operator command and must never hang forever behind a stale
    # lifecycle lock or a wedged container runtime operation.
    exec 8>"\$ROUTER_LOCK"
    if ! flock -w 8 8; then
      echo "[omp-ai] ERROR: lifecycle lock is still busy after 8s; refusing to hang." >&2
      echo "[omp-ai] Check for a stuck launcher: ps -fu \$USER | grep '[o]mp-ai'" >&2
      exit 6
    fi
    if workbench_running; then
      timeout 15s podman stop -t 5 "\$WORKBENCH" >/dev/null 2>&1 || {
        echo "[omp-ai] Workbench did not stop cleanly; forcing kill..." >&2
        timeout 10s podman kill "\$WORKBENCH" >/dev/null 2>&1 || true
      }
    fi
    rm -f "\$SESS_DIR"/*.session "\$EXEC_DIR"/*.pid 2>/dev/null || true
    timeout 15s podman rm -f -t 5 "\$LLAMA_NAME" >/dev/null 2>&1 || true
    unlock
    echo "[omp-ai] All OMP sessions/router stopped; persistent workbench preserved."
    exit 0;;
  status)
    pctl ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}' | { head -n1; grep -E '^ompai-(llama|workbench)' || true; }
    shopt -s nullglob; m=("\$SESS_DIR"/*.session); shopt -u nullglob; echo "Active OMP sessions: \${#m[@]}"; exit 0;;
  logs) shift; exec podman logs -f "\$LLAMA_NAME";;
  shell)
    ensure_workbench
    set +e; podman exec -it "\$WORKBENCH" /bin/bash; rc=\$?; set -e
    has_sessions || pctl stop -t 10 "\$WORKBENCH" >/dev/null 2>&1 || true
    exit "\$rc";;
  reset-env)
    has_sessions && { echo "Active OMP sessions exist; close them first." >&2; exit 3; }
    timeout 20s podman rm -f -t 5 "\$WORKBENCH" >/dev/null 2>&1 || {
      echo "[omp-ai] ERROR: failed to remove persistent workbench." >&2
      exit 7
    }
    rm -f "\$EXEC_DIR"/*.pid 2>/dev/null || true
    echo "[omp-ai] Persistent workbench removed. Next omp-ai launch creates a clean one from localhost/omp:latest."
    exit 0;;
  reap)
    age="\${2:-120}"; now="\$(date +%s)"; with_lock || exit 6; shopt -s nullglob
    for m in "\$SESS_DIR"/*.session; do
      mt="\$(stat -c %Y "\$m" 2>/dev/null || echo 0)"; sid="\$(basename "\$m" .session)"; pid="\$(sed -n '2p' "\$m" || echo 0)"; start="\$(sed -n '3p' "\$m" || echo 0)"; cur="\$(awk '{print \$22}' "/proc/\$pid/stat" 2>/dev/null || true)"; live=0; [[ "\$pid" != 0 && -n "\$cur" && "\$cur" == "\$start" ]] && live=1
      if (( !live && now-mt >= age )); then kill_exec_session "\$sid"; rm -f "\$m"; fi
    done
    shopt -u nullglob; stop_if_unused; unlock; exit 0;;
esac

workdir_rel=""; share_modes=(); share_sources=(); omp_args=()
while (( \$# )); do case "\$1" in --workdir) workdir_rel="\${2:-}"; shift 2;; --share) share_modes+=(rw); share_sources+=("\${2:?}"); shift 2;; --share-ro) share_modes+=(ro); share_sources+=("\${2:?}"); shift 2;; --) shift; omp_args=("\$@"); break;; *) omp_args+=("\$1"); shift;; esac; done
candidate="\$(realpath -m "\$WORKSPACE/\$workdir_rel")"; case "\$candidate" in "\$WORKSPACE"|"\$WORKSPACE"/*) ;; *) exit 2;; esac; [[ -d "\$candidate" ]] || exit 2
container_workdir=/workspace; [[ "\$candidate" != "\$WORKSPACE" ]] && container_workdir="/workspace/\${candidate#"\$WORKSPACE/"}"
find "\$MODEL_STORE" -type f -iname '*.gguf' -print -quit | grep -q . || { echo "No models. Use ai-model add ..." >&2; exit 3; }
SESSION_ID="\$(cat /proc/sys/kernel/random/uuid)"; MARKER="\$SESS_DIR/\$SESSION_ID.session"; HB_PID=""

with_lock || exit 6; start_router || { unlock; exit 5; }; ensure_workbench; proc_start="\$(awk '{print \$22}' /proc/\$\$/stat 2>/dev/null || true)"; printf '%s\n%s\n%s\n' "\$SESSION_ID" "\$\$" "\$proc_start" >"\$MARKER"; unlock

# Create convenient per-session aliases for direct shares.  The real mounts
# live below SHARE_STAGE and arrive through rslave propagation.
first_share_dir=""
if (( \${#share_sources[@]} )); then
  pctl exec "\$WORKBENCH" mkdir -p "/shares/\$SESSION_ID"
  declare -A used=()
  for i in "\${!share_sources[@]}"; do
    src="\$(realpath -e -- "\${share_sources[\$i]}")"; case "\$src" in "\$SHARE_STAGE"/*) ;; *) exit 2;; esac
    base="\$(basename -- "\$src" | sed 's/^[0-9][0-9][0-9][0-9]-//')"; name="\$base"; n=2; while [[ -n "\${used[\$name]:-}" ]]; do name="\${base}-\$n"; ((++n)); done; used["\$name"]=1
    dst="/shares/\$SESSION_ID/\$name"
    pctl exec "\$WORKBENCH" ln -s -- "\$src" "\$dst"
    [[ -z "\$first_share_dir" && -d "\$src" ]] && first_share_dir="\$dst"
  done
fi
[[ -n "\$first_share_dir" && -z "\$workdir_rel" ]] && container_workdir="\$first_share_dir"

cleanup(){
  rc=\$?; trap - EXIT INT TERM HUP
  [[ -n "\$HB_PID" ]] && kill "\$HB_PID" >/dev/null 2>&1 || true
  workbench_running && pctl exec "\$WORKBENCH" rm -rf -- "/shares/\$SESSION_ID" >/dev/null 2>&1 || true
  rm -f "\$EXEC_DIR/\$SESSION_ID.pid"
  if with_lock; then
    rm -f "\$MARKER"
    stop_if_unused
    unlock
  else
    rm -f "\$MARKER"
    echo "[omp-ai] WARN: cleanup could not acquire lifecycle lock; reaper will finish cleanup." >&2
  fi
  exit "\$rc"
}
trap cleanup EXIT INT TERM HUP
parent=\$\$; ( while kill -0 "\$parent" 2>/dev/null; do touch "\$MARKER" 2>/dev/null || exit 0; sleep 20; done ) & HB_PID=\$!
secret_args=(); [[ -r "\$SECRET_ENV" ]] && secret_args+=(--env-file "\$SECRET_ENV")
echo "[omp-ai] Shared router ready; persistent workbench active; session \$SESSION_ID"

# The shell writes its container PID into the host-backed /state
# before exec()ing OMP, so the reaper can terminate only a stale OMP process
# without disturbing other live windows in the shared workbench.
podman exec -it --workdir "\$container_workdir" "\${secret_args[@]}" \
  -e HOME=/state -e "TERM=\$TERM" -e LLAMA_CPP_BASE_URL=http://llama:8080 -e "OMP_SESSION_ID=\$SESSION_ID" \
  "\$WORKBENCH" /bin/bash -lc '
    set -e
    mkdir -p /state/runtime/omp-exec
    printf "%s\n" "\$\$" > "/state/runtime/omp-exec/\$OMP_SESSION_ID.pid"
    exec /usr/local/bin/omp "\$@"
  ' bash "\${omp_args[@]}"
EOT
root chmod 0755 "$INNER"

# ----- public wrapper -----
PUBLIC="/usr/local/bin/omp-ai"
root tee "$PUBLIC" >/dev/null <<EOT
#!/usr/bin/env bash
set -Eeuo pipefail
INNER="$INNER"; SHARE_HELPER="$SHARE_HELPER"; UPDATE_HELPER="$OMP_UPDATE_HELPER"; WORKSPACE="$WORKSPACE"; AI_USER="$AI_USER"
case "\${1:-}" in
  stop) sudo -n -u "\$AI_USER" "\$INNER" stop; sudo -n "\$SHARE_HELPER" cleanup-stale 0 >/dev/null 2>&1 || true; exit 0;;
  status|logs) exec sudo -n -u "\$AI_USER" "\$INNER" "\$@";;
  shell) sudo -n "\$SHARE_HELPER" prepare >/dev/null; exec sudo -n -u "\$AI_USER" "\$INNER" shell;;
  reset-env) exec sudo -n -u "\$AI_USER" "\$INNER" reset-env;;
  update) shift; (( \$# == 0 )) || { echo "Usage: omp-ai update" >&2; exit 2; }; sudo -n "\$SHARE_HELPER" prepare >/dev/null; exec sudo -n -u "\$AI_USER" "\$UPDATE_HELPER";;
esac
sudo -n "\$SHARE_HELPER" prepare >/dev/null
pwd_real="\$(realpath -m "\$PWD")"; rel=""; case "\$pwd_real" in "\$WORKSPACE") rel="";; "\$WORKSPACE"/*) rel="\${pwd_real#"\$WORKSPACE/"}";; esac
modes=(); paths=(); omp_args=(); while (( \$# )); do case "\$1" in --share) modes+=(rw); paths+=("\${2:?}"); shift 2;; --share-ro) modes+=(ro); paths+=("\${2:?}"); shift 2;; --) shift; omp_args+=("\$@"); break;; *) omp_args+=("\$1"); shift;; esac; done
if (( \${#paths[@]} == 0 )); then exec sudo -n -u "\$AI_USER" "\$INNER" --workdir "\$rel" -- "\${omp_args[@]}"; fi
sid="\$(sudo -n "\$SHARE_HELPER" begin)"; child=""; share_hb=""
cleanup(){ rc=\$?; trap - EXIT INT TERM HUP; [[ -n "\$share_hb" ]] && kill "\$share_hb" >/dev/null 2>&1 || true; [[ -n "\$child" ]] && kill -0 "\$child" 2>/dev/null && kill -TERM "\$child" 2>/dev/null || true; [[ -n "\$child" ]] && wait "\$child" 2>/dev/null || true; sudo -n "\$SHARE_HELPER" cleanup "\$sid" >/dev/null 2>&1 || true; exit "\$rc"; }; trap cleanup EXIT INT TERM HUP
inner_shares=(); for i in "\${!paths[@]}"; do staged="\$(sudo -n "\$SHARE_HELPER" grant "\$sid" "\${modes[\$i]}" "\${paths[\$i]}")"; [[ "\${modes[\$i]}" == ro ]] && inner_shares+=(--share-ro "\$staged") || inner_shares+=(--share "\$staged"); done
set +e; sudo -n -u "\$AI_USER" "\$INNER" --workdir "\$rel" "\${inner_shares[@]}" -- "\${omp_args[@]}" & child=\$!; child_start="\$(awk '{print \$22}' "/proc/\$child/stat" 2>/dev/null || true)"; sudo -n "\$SHARE_HELPER" attach "\$sid" "\$child" "\$child_start" >/dev/null
( while kill -0 "\$child" 2>/dev/null; do sudo -n "\$SHARE_HELPER" heartbeat "\$sid" >/dev/null 2>&1 || exit 0; sleep 20; done ) & share_hb=\$!
wait "\$child"; rc=\$?; child=""; set -e; exit "\$rc"
EOT
root chmod 0755 "$PUBLIC"

# ----- model manager -----
MODEL_HELPER="/usr/local/libexec/omp-ai-model"
root tee "$MODEL_HELPER" >/dev/null <<EOT
#!/usr/bin/env bash
set -Eeuo pipefail
STORE="$MODEL_STORE"; AI_USER="$AI_USER"; AI_GID="$AI_GID"; MAIN_USER="$MAIN_USER"; AI_HOME="$AI_HOME"; AI_UID="$AI_UID"
cd "\$AI_HOME"
cmd="\${1:-help}"; shift || true
idle(){ runuser -u "\$AI_USER" -- env HOME="\$AI_HOME" XDG_RUNTIME_DIR="/run/user/\$AI_UID" podman ps --format '{{.Names}}' 2>/dev/null | grep -Eq '^ompai-(agent-|llama$)' && { echo "Stop omp-ai before changing models" >&2; exit 3; } || true; }
validate(){ local src="\$1" f found=0; runuser -u "\$MAIN_USER" -- test -r "\$src" || return 1; if [[ -f "\$src" ]]; then [[ "\${src,,}" == *.gguf && "\$(runuser -u "\$MAIN_USER" -- head -c4 "\$src")" == GGUF ]]; return; fi; [[ -d "\$src" ]] || return 1; find "\$src" -type l -print -quit | grep -q . && return 1; while IFS= read -r -d '' f; do found=1; [[ "\$(runuser -u "\$MAIN_USER" -- head -c4 "\$f")" == GGUF ]] || return 1; done < <(find "\$src" -type f -iname '*.gguf' -print0); (( found )); }
install_one(){ local mode="\$1" raw="\$2" src name dest tmp; src="\$(realpath -e -- "\$raw")"; validate "\$src" || { echo "Invalid GGUF source" >&2; exit 2; }; name="\$(basename "\$src")"; dest="\$STORE/\$name"; [[ ! -e "\$dest" || "\$mode" == replace ]] || { echo "Exists: \$name" >&2; exit 2; }; [[ "\$mode" == replace ]] && rm -rf -- "\$dest"; tmp="\$STORE/.import-\$name.\$\$"; rm -rf "\$tmp"; [[ -f "\$src" ]] && cp --reflink=auto --sparse=always "\$src" "\$tmp" || cp -a --reflink=auto "\$src" "\$tmp"; chown -R root:"\$AI_GID" "\$tmp"; [[ -d "\$tmp" ]] && { find "\$tmp" -type d -exec chmod 0550 {} +; find "\$tmp" -type f -exec chmod 0440 {} +; } || chmod 0440 "\$tmp"; mv "\$tmp" "\$dest"; echo "Installed: \$name"; }
case "\$cmd" in add|replace) idle; (( \$# )) || exit 2; for x in "\$@"; do install_one "\$cmd" "\$x"; done;; remove|rm) idle; for n in "\$@"; do [[ "\$n" != */* ]] || exit 2; rm -rf -- "\$STORE/\$n"; done;; list|ls) find "\$STORE" -mindepth 1 -maxdepth 1 ! -name '.import-*' -printf '%f\n' | sort;; path) echo "\$STORE";; *) echo "Usage: ai-model {add|replace|remove|list|path} ...";; esac
EOT
root chmod 0755 "$MODEL_HELPER"
root tee /usr/local/bin/ai-model >/dev/null <<EOT
#!/usr/bin/env bash
exec sudo -n "$MODEL_HELPER" "\$@"
EOT
root chmod 0755 /usr/local/bin/ai-model

root tee /usr/local/bin/ai-give >/dev/null <<EOT
#!/usr/bin/env bash
set -Eeuo pipefail
(( \$# )) || { echo "Usage: ai-give FILE_OR_DIR [...]" >&2; exit 2; }
for src in "\$@"; do src="\$(realpath -e "\$src")"; base="\$(basename "\$src")"; dest="$WORKSPACE/\$base"; if [[ -d "\$src" && ! -L "\$src" ]]; then mkdir -p "\$dest"; rsync -rlE --safe-links "\$src/" "\$dest/"; else rsync -lE --safe-links "\$src" "$WORKSPACE/"; fi; setfacl -R -m "u:$AI_USER:rwX,u:$MAIN_USER:rwX,g:$SHARE_GROUP:rwX,m:rwX" "\$dest" 2>/dev/null || true; echo "Added: \$dest"; done
EOT
root chmod 0755 /usr/local/bin/ai-give

root tee /etc/sudoers.d/omp-ai >/dev/null <<EOT
$MAIN_USER ALL=($AI_USER) NOPASSWD: $INNER *
$MAIN_USER ALL=($AI_USER) NOPASSWD: $OMP_UPDATE_HELPER
$MAIN_USER ALL=(root) NOPASSWD: $MODEL_HELPER *
$MAIN_USER ALL=(root) NOPASSWD: $SHARE_HELPER *
EOT
root chmod 0440 /etc/sudoers.d/omp-ai; root visudo -cf /etc/sudoers.d/omp-ai >/dev/null

# ----- crash reaper -----
REAPER="/usr/local/libexec/omp-ai-reap"
root tee "$REAPER" >/dev/null <<EOT
#!/usr/bin/env bash
set -Eeuo pipefail
runuser -u "$AI_USER" -- env HOME="$AI_HOME" USER="$AI_USER" LOGNAME="$AI_USER" XDG_RUNTIME_DIR="/run/user/$AI_UID" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$AI_UID/bus" PATH=/usr/local/sbin:/usr/local/bin:/usr/bin:/bin "$INNER" reap 120 >/dev/null 2>&1 || true
"$SHARE_HELPER" cleanup-stale 180 >/dev/null 2>&1 || true
EOT
root chmod 0755 "$REAPER"
root tee /etc/systemd/system/omp-ai-reaper.service >/dev/null <<EOT
[Unit]
Description=Reap orphaned OMP sessions and temporary shares
After=user@${AI_UID}.service
[Service]
Type=oneshot
ExecStart=$REAPER
EOT
root tee /etc/systemd/system/omp-ai-reaper.timer >/dev/null <<'EOT'
[Timer]
OnBootSec=2min
OnUnitActiveSec=2min
AccuracySec=30s
Persistent=true
[Install]
WantedBy=timers.target
EOT
root systemctl daemon-reload; root systemctl enable --now omp-ai-reaper.timer

# Maintenance cleanup after rewriting helpers.
mapfile -t old_agents < <(as_ai timeout --kill-after=3s 20s podman ps -a --format '{{.Names}}' | grep '^ompai-agent-' || true)
(( ${#old_agents[@]} )) && as_ai timeout --kill-after=3s 20s podman rm -f -t 5 "${old_agents[@]}" >/dev/null 2>&1 || true
as_ai timeout --kill-after=3s 20s podman rm -f -t 5 ompai-agent ompai-llama >/dev/null 2>&1 || true
as_ai timeout --kill-after=3s 20s podman stop -t 5 ompai-workbench >/dev/null 2>&1 || true
as_ai rm -rf "$AI_RUNTIME/omp-ai-sessions" >/dev/null 2>&1 || true
root "$SHARE_HELPER" cleanup-stale 0 >/dev/null 2>&1 || true

ok "Setup complete"
echo "Workspace:        $WORKSPACE"
echo "Model store:      $MODEL_STORE"
echo "Model instances:  $MODELS_MAX"
echo "Parallel slots:   $LLAMA_PARALLEL"
echo "Context per slot: $LLAMA_CTX_PER_SLOT"
echo "Workbench base:   $WORKBENCH_BASE_IMAGE"
echo
echo "Next: ai-model add /path/model.gguf && omp-ai"
echo "Persistent env: omp-ai shell  # apt installs survive restarts"
