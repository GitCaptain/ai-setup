#!/usr/bin/env bash
set -Eeuo pipefail

# setup-omp-ai.sh
#
# Arch Linux setup for an isolated local OMP + llama.cpp environment.
# Configuration is read from an INI-like KEY=VALUE file.
#
# Normal workflow:
#   1. Edit omp-ai.conf next to this script.
#   2. Run: ./setup-omp-ai.sh
#
# CLI flags are optional overrides for one-off changes.

AI_USER="ompai"
AI_HOME="/var/lib/ompai"
SHARE_GROUP="ompai-share"
WORKSPACE="/srv/ompai/workspace"
MODEL_STORE="/var/lib/ompai/models"
ETC_DIR="/etc/ompai"

LLAMA_IMAGE="ghcr.io/ggml-org/llama.cpp:server-cuda"
OMP_REPO="https://github.com/can1357/oh-my-pi.git"
OMP_REF="main"

LLAMA_PORT=18080
LLAMA_CTX=8192
LLAMA_MEM="22g"
OMP_MEM="3g"
AI_SLICE_MEM="25G"
AI_SLICE_CPU="2400%"
VRAM_RESERVE_MIB=2048

INITIAL_MODELS=()
MODELS_MAX=1
EXA_API_KEY=""
WEB_SEARCH_PRIMARY="auto"
WEB_SEARCH_FALLBACK="duckduckgo"

HARDEN_HOME="true"
ASSUME_YES="false"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CONFIG_FILE="$SCRIPT_DIR/omp-ai.conf"

log()  { printf '\033[1;34m[omp-ai]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[omp-ai]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[omp-ai]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[omp-ai] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage:
  setup-omp-ai.sh [options]

Normal usage:
  Edit ./omp-ai.conf, then run this script with no arguments.

Options (override config):
  --config PATH
  --model PATH            Import a GGUF file/bundle (repeatable)
  --model-store PATH      Host directory used as the persistent model store
  --models-max N          Max simultaneously loaded router models
  --ctx TOKENS
  --vram-reserve MIB
  --llama-memory SIZE
  --omp-memory SIZE
  --ai-memory SIZE
  --ai-cpu PERCENT
  --llama-port PORT
  --llama-image IMAGE
  --omp-ref REF
  --exa-api-key KEY
  --web-search NAME       auto | exa | duckduckgo
  --keep-home-perms
  -y, --yes
  -h, --help

The config is parsed as data, not sourced as shell code.
EOF
}

# Let --help work even when the script is only being inspected as root.
for arg in "$@"; do
  case "$arg" in
    -h|--help) usage; exit 0 ;;
  esac
done

args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  case "${args[i]}" in
    --config)
      (( i + 1 < ${#args[@]} )) || die "--config requires a path"
      CONFIG_FILE="${args[i+1]}"
      ((i++))
      ;;
    --config=*)
      CONFIG_FILE="${args[i]#*=}"
      ;;
  esac
done

if [[ $EUID -eq 0 ]]; then
  MAIN_USER="${SUDO_USER:-}"
  [[ -n "$MAIN_USER" && "$MAIN_USER" != root ]] || \
    die "Run this from your normal desktop account, not a root login."
else
  MAIN_USER="${USER:?USER is unset}"
fi

MAIN_HOME="$(getent passwd "$MAIN_USER" | cut -d: -f6)"
[[ -d "$MAIN_HOME" ]] || die "Cannot determine home for $MAIN_USER"

root() {
  if [[ $EUID -eq 0 ]]; then "$@"; else sudo "$@"; fi
}

as_main() {
  if [[ $EUID -ne 0 && "$(id -un)" == "$MAIN_USER" ]]; then
    "$@"
  else
    root runuser -u "$MAIN_USER" -- env \
      HOME="$MAIN_HOME" USER="$MAIN_USER" LOGNAME="$MAIN_USER" \
      PATH="/usr/local/sbin:/usr/local/bin:/usr/bin:/bin" "$@"
  fi
}

trim_ws() {
  local v="$1"
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  printf '%s' "$v"
}

unquote_value() {
  local v="$1"
  if (( ${#v} >= 2 )); then
    if [[ "${v:0:1}" == '"' && "${v: -1}" == '"' ]] || \
       [[ "${v:0:1}" == "'" && "${v: -1}" == "'" ]]; then
      v="${v:1:${#v}-2}"
    fi
  fi
  printf '%s' "$v"
}

set_config_key() {
  local key="$1" value="$2"
  case "$key" in
    AI_USER) AI_USER="$value" ;;
    AI_HOME) AI_HOME="$value" ;;
    SHARE_GROUP) SHARE_GROUP="$value" ;;
    WORKSPACE) WORKSPACE="$value" ;;
    MODEL_STORE) MODEL_STORE="$value" ;;

    MODEL|MODEL_PATH) [[ -n "$value" ]] && INITIAL_MODELS+=("$value") ;;
    MODELS_MAX) MODELS_MAX="$value" ;;
    LLAMA_IMAGE) LLAMA_IMAGE="$value" ;;
    LLAMA_PORT) LLAMA_PORT="$value" ;;
    LLAMA_CTX) LLAMA_CTX="$value" ;;
    LLAMA_MEM) LLAMA_MEM="$value" ;;
    VRAM_RESERVE_MIB) VRAM_RESERVE_MIB="$value" ;;

    OMP_REPO) OMP_REPO="$value" ;;
    OMP_REF) OMP_REF="$value" ;;
    OMP_MEM) OMP_MEM="$value" ;;

    AI_SLICE_MEM) AI_SLICE_MEM="$value" ;;
    AI_SLICE_CPU) AI_SLICE_CPU="$value" ;;

    EXA_API_KEY) EXA_API_KEY="$value" ;;
    WEB_SEARCH_PRIMARY) WEB_SEARCH_PRIMARY="$value" ;;
    WEB_SEARCH_FALLBACK) WEB_SEARCH_FALLBACK="$value" ;;

    HARDEN_HOME) HARDEN_HOME="$value" ;;
    ASSUME_YES) ASSUME_YES="$value" ;;
    "") ;;
    *) die "Unknown config key '$key' in $CONFIG_FILE" ;;
  esac
}

load_config() {
  local file="$1" line key value lineno=0
  [[ -f "$file" ]] || return 1

  while IFS= read -r line || [[ -n "$line" ]]; do
    ((lineno++))
    line="${line%$'\r'}"
    line="$(trim_ws "$line")"

    [[ -z "$line" ]] && continue
    [[ "$line" == \#* || "$line" == \;* ]] && continue
    [[ "$line" == \[*\] ]] && continue

    [[ "$line" == *=* ]] || die "$file:$lineno: expected KEY=VALUE"
    key="$(trim_ws "${line%%=*}")"
    value="$(trim_ws "${line#*=}")"
    value="$(unquote_value "$value")"

    [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || \
      die "$file:$lineno: invalid key '$key'"
    set_config_key "$key" "$value"
  done < "$file"
}

bool_to_int() {
  case "${1,,}" in
    1|true|yes|y|on) printf '1' ;;
    0|false|no|n|off) printf '0' ;;
    *) die "Invalid boolean value: $1" ;;
  esac
}

if [[ "$CONFIG_FILE" == "$SCRIPT_DIR/omp-ai.conf" && ! -f "$CONFIG_FILE" ]]; then
  alt="$MAIN_HOME/.config/omp-ai/omp-ai.conf"
  [[ -f "$alt" ]] && CONFIG_FILE="$alt"
fi

if [[ -f "$CONFIG_FILE" ]]; then
  log "Reading config: $CONFIG_FILE"
  load_config "$CONFIG_FILE"
else
  warn "Config not found: $CONFIG_FILE"
  warn "Using built-in defaults."
fi

while (($#)); do
  case "$1" in
    --config)           shift 2 ;;
    --config=*)         shift ;;
    --model)            INITIAL_MODELS+=("${2:?missing value}"); shift 2 ;;
    --model-store)      MODEL_STORE="${2:?missing value}"; shift 2 ;;
    --models-max)       MODELS_MAX="${2:?missing value}"; shift 2 ;;
    --ctx)              LLAMA_CTX="${2:?missing value}"; shift 2 ;;
    --vram-reserve)     VRAM_RESERVE_MIB="${2:?missing value}"; shift 2 ;;
    --llama-memory)     LLAMA_MEM="${2:?missing value}"; shift 2 ;;
    --omp-memory)       OMP_MEM="${2:?missing value}"; shift 2 ;;
    --ai-memory)        AI_SLICE_MEM="${2:?missing value}"; shift 2 ;;
    --ai-cpu)           AI_SLICE_CPU="${2:?missing value}"; shift 2 ;;
    --llama-port)       LLAMA_PORT="${2:?missing value}"; shift 2 ;;
    --llama-image)      LLAMA_IMAGE="${2:?missing value}"; shift 2 ;;
    --omp-ref)          OMP_REF="${2:?missing value}"; shift 2 ;;
    --exa-api-key)      EXA_API_KEY="${2:?missing value}"; shift 2 ;;
    --web-search)       WEB_SEARCH_PRIMARY="${2:?missing value}"; shift 2 ;;
    --keep-home-perms)  HARDEN_HOME="false"; shift ;;
    -y|--yes)           ASSUME_YES="true"; shift ;;
    -h|--help)          usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

HARDEN_HOME="$(bool_to_int "$HARDEN_HOME")"
ASSUME_YES="$(bool_to_int "$ASSUME_YES")"

# MODEL_STORE is a host path managed by root and exposed read-only to llama.cpp.
# Keep it outside the desktop user's home so HOME=0700 remains a useful boundary.
[[ "$MODEL_STORE" = /* ]] || die "MODEL_STORE must be an absolute host path"
[[ "$MODEL_STORE" != "/" ]] || die "MODEL_STORE must not be /"
case "$MODEL_STORE" in
  "$MAIN_HOME"|"$MAIN_HOME"/*)
    die "MODEL_STORE must be outside your normal home ($MAIN_HOME); use /var/lib/ompai/models, /srv/..., or /mnt/..."
    ;;
esac

case "${WEB_SEARCH_PRIMARY,,}" in
  auto)
    if [[ -n "$EXA_API_KEY" ]]; then
      WEB_SEARCH_PRIMARY="exa"
    else
      WEB_SEARCH_PRIMARY="duckduckgo"
    fi
    ;;
  exa|duckduckgo) WEB_SEARCH_PRIMARY="${WEB_SEARCH_PRIMARY,,}" ;;
  *) die "WEB_SEARCH_PRIMARY must be auto, exa, or duckduckgo" ;;
esac

case "${WEB_SEARCH_FALLBACK,,}" in
  ""|none|off) WEB_SEARCH_FALLBACK="" ;;
  exa|duckduckgo) WEB_SEARCH_FALLBACK="${WEB_SEARCH_FALLBACK,,}" ;;
  *) die "WEB_SEARCH_FALLBACK must be exa, duckduckgo, or none" ;;
esac

[[ "$WEB_SEARCH_FALLBACK" == "$WEB_SEARCH_PRIMARY" ]] && WEB_SEARCH_FALLBACK=""

if [[ -n "$EXA_API_KEY" && -f "$CONFIG_FILE" ]]; then
  owner="$(stat -c '%U' "$CONFIG_FILE")"
  [[ "$owner" == "$MAIN_USER" ]] || \
    die "Config contains EXA_API_KEY but is owned by '$owner', not '$MAIN_USER'"
  mode="$(stat -c '%a' "$CONFIG_FILE")"
  if (( (8#$mode & 077) != 0 )); then
    log "Config contains a secret; setting $CONFIG_FILE to mode 0600"
    as_main chmod 0600 "$CONFIG_FILE"
  fi
fi

source /etc/os-release
[[ "${ID:-}" == arch ]] || die "This installer currently targets Arch Linux."

[[ "$LLAMA_CTX" =~ ^[0-9]+$ ]] && (( LLAMA_CTX >= 1024 )) || die "LLAMA_CTX/--ctx must be >= 1024"
[[ "$VRAM_RESERVE_MIB" =~ ^[0-9]+$ ]] || die "VRAM_RESERVE_MIB/--vram-reserve must be integer MiB"
[[ "$LLAMA_PORT" =~ ^[0-9]+$ ]] && (( LLAMA_PORT >= 1024 && LLAMA_PORT <= 65535 )) || die "Invalid LLAMA_PORT/--llama-port"
[[ "$AI_SLICE_CPU" =~ ^[0-9]+%$ ]] || die "AI_SLICE_CPU/--ai-cpu must look like 2400%"
[[ "$MODELS_MAX" =~ ^[0-9]+$ ]] && (( MODELS_MAX >= 1 )) || die "MODELS_MAX/--models-max must be >= 1"

# Resolve MODEL= entries. Files are imported later, after the isolated model store exists.
resolved_models=()
for src in "${INITIAL_MODELS[@]}"; do
  [[ -n "$src" ]] || continue
  if [[ "$src" == "~/"* ]]; then
    src="$MAIN_HOME/${src#~/}"
  fi
  src="$(realpath -e "$src")" || die "Initial model path does not exist: $src"
  as_main test -r "$src" || die "Initial model path is not readable by $MAIN_USER: $src"
  [[ -f "$src" || -d "$src" ]] || die "MODEL must be a GGUF file or model-bundle directory: $src"
  resolved_models+=("$src")
done
INITIAL_MODELS=("${resolved_models[@]}")

log "Installing required Arch packages..."
root pacman -S --needed --noconfirm \
  podman crun passt netavark aardvark-dns fuse-overlayfs \
  nvidia-container-toolkit \
  git base-devel curl rsync acl sudo shadow

log "Creating dedicated host identity..."
getent group "$SHARE_GROUP" >/dev/null || root groupadd "$SHARE_GROUP"

if ! id "$AI_USER" &>/dev/null; then
  root useradd -m -U -d "$AI_HOME" -s /usr/bin/nologin "$AI_USER"
else
  [[ "$(getent passwd "$AI_USER" | cut -d: -f6)" == "$AI_HOME" ]] || \
    die "Existing user $AI_USER has a different home"
fi

root passwd -l "$AI_USER" >/dev/null 2>&1 || true
root usermod -s /usr/bin/nologin "$AI_USER"
root usermod -aG "$SHARE_GROUP" "$AI_USER"
root usermod -aG "$SHARE_GROUP" "$MAIN_USER"

AI_UID="$(id -u "$AI_USER")"
AI_GID="$(id -g "$AI_USER")"

root chmod 0700 "$AI_HOME"

if (( HARDEN_HOME )); then
  mode="$(stat -c '%a' "$MAIN_HOME")"
  if [[ "$mode" != "700" ]]; then
    answer="y"
    if (( ! ASSUME_YES )); then
      printf '\nYour normal home is mode %s: %s\n' "$mode" "$MAIN_HOME"
      printf 'Recommended for this threat model: remove group/other permissions.\n'
      read -r -p "Run chmod go-rwx on it? [Y/n] " answer
      answer="${answer:-Y}"
    fi
    if [[ "$answer" =~ ^[Yy]$ ]]; then
      root chmod go-rwx "$MAIN_HOME"
    else
      warn "Normal home permissions were left unchanged."
    fi
  fi
fi

log "Creating shared workspace..."
root install -d -o "$AI_USER" -g "$SHARE_GROUP" -m 2770 "$WORKSPACE"
root setfacl -m \
  "u:$MAIN_USER:rwx,u:$AI_USER:rwx,g:$SHARE_GROUP:rwx,m:rwx" "$WORKSPACE"
root setfacl -d -m \
  "u:$MAIN_USER:rwx,u:$AI_USER:rwx,g:$SHARE_GROUP:rwx,m:rwx" "$WORKSPACE"

LINK="$MAIN_HOME/AI"
if [[ ! -e "$LINK" && ! -L "$LINK" ]]; then
  as_main ln -s "$WORKSPACE" "$LINK"
elif [[ -L "$LINK" ]]; then
  target="$(readlink -f "$LINK" || true)"
  [[ "$target" == "$WORKSPACE" ]] || warn "$LINK already points somewhere else; not replacing it."
else
  warn "$LINK already exists and is not a symlink; not replacing it."
fi

# Ensure rootless Podman has a subordinate-ID range.
get_subid_start() {
  local file="$1" user="$2"
  awk -F: -v u="$user" '$1==u {print $2; exit}' "$file" 2>/dev/null || true
}
next_subid_start() {
  awk -F: '
    BEGIN { max=99999 }
    NF>=3 {
      e=$2+$3-1
      if (e>max) max=e
    }
    END {
      block=65536
      s=int((max+block)/block)*block
      if (s<100000) s=100000
      print s
    }
  ' /etc/subuid /etc/subgid 2>/dev/null
}

SU_START="$(get_subid_start /etc/subuid "$AI_USER")"
SG_START="$(get_subid_start /etc/subgid "$AI_USER")"
if [[ -z "$SU_START" || -z "$SG_START" ]]; then
  chosen="${SU_START:-${SG_START:-$(next_subid_start)}}"
  end=$((chosen + 65535))
  [[ -n "$SU_START" ]] || root usermod --add-subuids "$chosen-$end" "$AI_USER"
  [[ -n "$SG_START" ]] || root usermod --add-subgids "$chosen-$end" "$AI_USER"
fi

log "Installing root-owned host limits for escaped processes..."
root install -d -m 0755 "/etc/systemd/system/user-${AI_UID}.slice.d"
root tee "/etc/systemd/system/user-${AI_UID}.slice.d/90-ompai.conf" >/dev/null <<EOF
[Slice]
MemoryMax=$AI_SLICE_MEM
MemorySwapMax=0
CPUQuota=$AI_SLICE_CPU
TasksMax=4096
EOF
root systemctl daemon-reload

# We use linger only to make /run/user/$uid and the user manager reliably exist.
# Podman itself remains daemonless.
root loginctl enable-linger "$AI_USER"
root systemctl start "user@${AI_UID}.service"

# Apply the persisted limits immediately too (important on idempotent re-runs).
root systemctl set-property "user-${AI_UID}.slice" \
  "MemoryMax=$AI_SLICE_MEM" \
  "MemorySwapMax=0" \
  "CPUQuota=$AI_SLICE_CPU" \
  "TasksMax=4096" >/dev/null

AI_RUNTIME="/run/user/$AI_UID"
for _ in $(seq 1 30); do
  [[ -d "$AI_RUNTIME" ]] && break
  sleep 1
done
[[ -d "$AI_RUNTIME" ]] || die "No runtime dir appeared for $AI_USER"

as_ai() {
  root runuser -u "$AI_USER" -- env \
    HOME="$AI_HOME" \
    USER="$AI_USER" \
    LOGNAME="$AI_USER" \
    XDG_RUNTIME_DIR="$AI_RUNTIME" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=$AI_RUNTIME/bus" \
    PATH="/usr/local/sbin:/usr/local/bin:/usr/bin:/bin" \
    "$@"
}

log "Checking rootless Podman..."
podman_info="$(as_ai podman info --format '{{.Host.Security.Rootless}} {{.Host.CgroupVersion}} {{.Host.CgroupManager}} {{.Host.OCIRuntime.Name}}' 2>/dev/null || true)"
[[ "$podman_info" == true* ]] || die "Podman is not rootless for $AI_USER: $podman_info"
[[ "$podman_info" == *"v2"* || "$podman_info" == *" 2 "* ]] || \
  die "cgroup v2 is required: $podman_info"
[[ "$podman_info" == *"systemd"* ]] || \
  die "Podman must use the systemd cgroup manager: $podman_info"

# Create user-owned storage/state.
root install -d -o "$AI_USER" -g "$AI_GID" -m 0700 \
  "$AI_HOME/.config" \
  "$AI_HOME/.config/containers" \
  "$AI_HOME/state" \
  "$AI_HOME/state/.omp" \
  "$AI_HOME/state/.omp/agent" \
  "$AI_HOME/src" \
  "$AI_HOME/build"

root install -d -o root -g "$AI_GID" -m 0750 "$AI_HOME/secrets"
root install -d -o root -g "$AI_GID" -m 0750 "$MODEL_STORE"
root install -d -o root -g root -m 0755 "$ETC_DIR"

SECRET_ENV="$AI_HOME/secrets/omp.env"
if [[ -n "$EXA_API_KEY" ]]; then
  [[ "$EXA_API_KEY" != *$'\n'* && "$EXA_API_KEY" != *$'\r'* ]] ||     die "EXA_API_KEY must not contain newlines"
  secret_tmp="$(mktemp)"
  chmod 0600 "$secret_tmp"
  printf 'EXA_API_KEY=%s\n' "$EXA_API_KEY" > "$secret_tmp"
  root install -o root -g "$AI_GID" -m 0640 "$secret_tmp" "$SECRET_ENV"
  rm -f "$secret_tmp"
else
  root rm -f "$SECRET_ENV"
fi

validate_model_source() {
  local src="$1" f found=0
  as_main test -r "$src" || die "Model source is not readable by $MAIN_USER: $src"
  if [[ -f "$src" ]]; then
    [[ "${src,,}" == *.gguf ]] || die "Model file must end in .gguf: $src"
    [[ "$(as_main head -c4 "$src" 2>/dev/null || true)" == "GGUF" ]] || die "Invalid GGUF header: $src"
    return
  fi
  [[ -d "$src" ]] || die "Model source must be file or directory: $src"
  if find "$src" -type l -print -quit | grep -q .; then
    die "Model bundle must not contain symlinks: $src"
  fi
  while IFS= read -r -d '' f; do
    found=1
    as_main test -r "$f" || die "Unreadable model file in bundle: $f"
    [[ "$(as_main head -c4 "$f" 2>/dev/null || true)" == "GGUF" ]] || die "Invalid GGUF header: $f"
  done < <(find "$src" -type f -iname '*.gguf' -print0)
  (( found )) || die "Model bundle contains no .gguf files: $src"
}

install_model_source() {
  local src="$1" name dest tmp
  validate_model_source "$src"
  name="$(basename "$src")"
  dest="$MODEL_STORE/$name"
  if [[ -e "$dest" ]]; then
    log "Model already present, skipping: $name"
    return
  fi
  tmp="$MODEL_STORE/.import-${name}.$$"
  root rm -rf -- "$tmp"
  log "Importing model: $src -> $dest"
  if [[ -f "$src" ]]; then
    root cp --reflink=auto --sparse=always -- "$src" "$tmp"
  else
    root cp -a --reflink=auto -- "$src" "$tmp"
  fi
  root chown -R root:"$AI_GID" "$tmp"
  if [[ -d "$tmp" ]]; then
    root find "$tmp" -type d -exec chmod 0550 {} +
    root find "$tmp" -type f -exec chmod 0440 {} +
  else
    root chmod 0440 "$tmp"
  fi
  root mv -- "$tmp" "$dest"
}

for src in "${INITIAL_MODELS[@]}"; do
  install_model_source "$src"
done

if ! root find "$MODEL_STORE" -type f -iname '*.gguf' -print -quit | grep -q .; then
  warn "No models installed yet. Use: ai-model add /path/to/model.gguf"
fi

# OMP config.
OMP_MAX_TOKENS=$(( LLAMA_CTX / 2 ))
(( OMP_MAX_TOKENS >= 1024 )) || OMP_MAX_TOKENS=1024

WEB_PRIMARY_SELECTOR="web/$WEB_SEARCH_PRIMARY"

root tee "$AI_HOME/state/.omp/agent/config.yml" >/dev/null <<EOF
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
  web: $WEB_PRIMARY_SELECTOR

retry:
  fallbackChains:
EOF

if [[ -n "$WEB_SEARCH_FALLBACK" ]]; then
  root tee -a "$AI_HOME/state/.omp/agent/config.yml" >/dev/null <<EOF
    web:
      - web/$WEB_SEARCH_FALLBACK
EOF
else
  root tee -a "$AI_HOME/state/.omp/agent/config.yml" >/dev/null <<'EOF'
    web: []
EOF
fi

# Use OMP's implicit llama.cpp provider so runtime discovery sees every router model.
# Remove the old single-model provider file if upgrading from v1.
root rm -f "$AI_HOME/state/.omp/agent/models.yml"

root chown -R "$AI_USER:$AI_GID" "$AI_HOME/state"
root chmod -R go-rwx "$AI_HOME/state"

log "Preparing NVIDIA CDI..."
root install -d -m 0755 /etc/cdi

# Arch's nvidia-container-toolkit package normally maintains the CDI file via hook.
# Generate it explicitly if absent or stale enough to omit the all-GPU selector.
if ! root nvidia-ctk cdi list 2>/dev/null | grep -q '^nvidia.com/gpu=all$'; then
  root nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
fi

root nvidia-ctk cdi list | grep -q '^nvidia.com/gpu=all$' || \
  die "NVIDIA CDI device nvidia.com/gpu=all is unavailable"

log "Creating Podman networks..."
if ! as_ai podman network exists omp-llm; then
  as_ai podman network create --internal omp-llm >/dev/null
else
  # Ensure it really is internal; recreate only if it isn't.
  internal="$(as_ai podman network inspect -f '{{.Internal}}' omp-llm 2>/dev/null || true)"
  if [[ "$internal" != "true" ]]; then
    warn "Existing omp-llm is not internal; recreating it."
    as_ai podman network rm omp-llm >/dev/null || true
    as_ai podman network create --internal omp-llm >/dev/null
  fi
fi

if ! as_ai podman network exists omp-web; then
  as_ai podman network create omp-web >/dev/null
fi

log "Cloning/updating OMP..."
OMP_SRC="$AI_HOME/src/oh-my-pi"
if [[ ! -d "$OMP_SRC/.git" ]]; then
  as_ai git clone "$OMP_REPO" "$OMP_SRC"
fi

as_ai git -C "$OMP_SRC" fetch --prune origin
as_ai git -C "$OMP_SRC" reset --hard HEAD >/dev/null
as_ai git -C "$OMP_SRC" clean -fdx >/dev/null

if as_ai git -C "$OMP_SRC" rev-parse --verify --quiet "origin/$OMP_REF" >/dev/null; then
  as_ai git -C "$OMP_SRC" checkout --detach "origin/$OMP_REF"
else
  as_ai git -C "$OMP_SRC" fetch origin "$OMP_REF"
  as_ai git -C "$OMP_SRC" checkout --detach FETCH_HEAD
fi

OMP_COMMIT="$(as_ai git -C "$OMP_SRC" rev-parse HEAD)"

log "Building OMP OCI image with Podman..."
as_ai podman build --pull=newer -t localhost/omp-base:latest "$OMP_SRC"

# Tiny wrapper image: predictable entrypoint, group-friendly umask.
OMP_WRAP="$AI_HOME/build/omp-wrapper"
as_ai mkdir -p "$OMP_WRAP"

root tee "$OMP_WRAP/entrypoint.sh" >/dev/null <<'EOF'
#!/bin/sh
umask 0002
exec /usr/local/bin/omp "$@"
EOF

root tee "$OMP_WRAP/Containerfile" >/dev/null <<EOF
FROM localhost/omp-base:latest
LABEL omp.source.commit="$OMP_COMMIT"
COPY entrypoint.sh /usr/local/bin/omp-sandbox-entrypoint
RUN chmod 0755 /usr/local/bin/omp-sandbox-entrypoint
ENTRYPOINT ["/usr/local/bin/omp-sandbox-entrypoint"]
CMD ["--help"]
EOF

root chown -R "$AI_USER:$AI_GID" "$OMP_WRAP"
as_ai podman build -t localhost/omp:latest -f "$OMP_WRAP/Containerfile" "$OMP_WRAP"

log "Pulling llama.cpp image..."
as_ai podman pull "$LLAMA_IMAGE"

log "Testing NVIDIA from rootless Podman..."
as_ai podman run --rm \
  --device nvidia.com/gpu=all \
  docker.io/library/ubuntu:24.04 \
  nvidia-smi -L >/dev/null || \
  die "Rootless Podman cannot access the NVIDIA GPU through CDI"

# Root-owned launcher that the main user may invoke as ompai.
INNER="/usr/local/libexec/omp-ai-inner"
root install -d -m 0755 /usr/local/libexec

root tee "$INNER" >/dev/null <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

AI_HOME="$AI_HOME"
WORKSPACE="$WORKSPACE"
MODEL_STORE="$MODEL_STORE"
LLAMA_IMAGE="$LLAMA_IMAGE"
LLAMA_PORT="$LLAMA_PORT"
LLAMA_CTX="$LLAMA_CTX"
LLAMA_MEM="$LLAMA_MEM"
OMP_MEM="$OMP_MEM"
VRAM_RESERVE_MIB="$VRAM_RESERVE_MIB"
MODELS_MAX="$MODELS_MAX"
AI_UID="$AI_UID"
SECRET_ENV="$AI_HOME/secrets/omp.env"

[[ "\$(id -un)" == "$AI_USER" ]] || {
  echo "This helper must run as $AI_USER." >&2
  exit 1
}

export HOME="\$AI_HOME"
export XDG_RUNTIME_DIR="/run/user/\$AI_UID"
export DBUS_SESSION_BUS_ADDRESS="unix:path=\$XDG_RUNTIME_DIR/bus"
export PATH="/usr/local/sbin:/usr/local/bin:/usr/bin:/bin"
export TERM="\${TERM:-xterm-256color}"

LLAMA_NAME="ompai-llama"
OMP_NAME="ompai-agent"
LEASE="\$XDG_RUNTIME_DIR/omp-ai.lease"

cleanup() {
  rc=\$?
  trap - EXIT INT TERM HUP
  podman rm -f -t 10 "\$OMP_NAME" >/dev/null 2>&1 || true
  podman rm -f -t 10 "\$LLAMA_NAME" >/dev/null 2>&1 || true
  rm -f "\$LEASE"
  exit "\$rc"
}

case "\${1:-}" in
  stop)
    podman rm -f -t 5 "\$OMP_NAME" "\$LLAMA_NAME" >/dev/null 2>&1 || true
    rm -f "\$LEASE"
    exit 0
    ;;
  status)
    podman ps -a --filter "name=^\${OMP_NAME}$" --filter "name=^\${LLAMA_NAME}$"
    exit 0
    ;;
  logs)
    shift
    exec podman logs -f "\$LLAMA_NAME"
    ;;
esac

workdir_rel=""
if [[ "\${1:-}" == "--workdir" ]]; then
  workdir_rel="\${2:-}"
  shift 2
  [[ "\${1:-}" == "--" ]] && shift
fi

candidate="\$(realpath -m "\$WORKSPACE/\$workdir_rel")"
case "\$candidate" in
  "\$WORKSPACE"|"\$WORKSPACE"/*) ;;
  *) echo "Invalid workspace path." >&2; exit 2 ;;
esac

[[ -d "\$candidate" ]] || {
  echo "Missing workspace directory: \$candidate" >&2
  exit 2
}

container_workdir="/workspace"
if [[ "\$candidate" != "\$WORKSPACE" ]]; then
  container_workdir="/workspace/\${candidate#"\$WORKSPACE/"}"
fi

if ! find "\$MODEL_STORE" -type f -iname '*.gguf' -print -quit | grep -q .; then
  echo "No GGUF models installed." >&2
  echo "Use: ai-model add /path/to/model.gguf" >&2
  exit 3
fi

# Only one interactive AI session at a time.
exec 9>"\$XDG_RUNTIME_DIR/omp-ai.session.lock"
flock -n 9 || {
  echo "Another omp-ai session is already active." >&2
  exit 4
}

touch "\$LEASE"
trap cleanup EXIT INT TERM HUP

# Remove stale containers from a crashed previous run.
podman rm -f "\$OMP_NAME" "\$LLAMA_NAME" >/dev/null 2>&1 || true

echo "[omp-ai] Starting llama.cpp model router..."

podman run -d \
  --name "\$LLAMA_NAME" \
  --replace \
  --network omp-llm \
  --network-alias llama \
  --device nvidia.com/gpu=all \
  --memory "\$LLAMA_MEM" \
  --cpus 20 \
  --pids-limit 512 \
  --read-only \
  --cap-drop ALL \
  --security-opt no-new-privileges \
  --tmpfs /tmp:rw,nosuid,nodev,size=512m \
  --mount "type=bind,src=\$MODEL_STORE,dst=/models,ro=true,bind-nonrecursive" \
  -p "127.0.0.1:\$LLAMA_PORT:8080" \
  "\$LLAMA_IMAGE" \
    --models-dir /models \
    --models-max "\$MODELS_MAX" \
    --models-autoload \
    --host 0.0.0.0 \
    --port 8080 \
    --ctx-size "\$LLAMA_CTX" \
    --cache-type-k q8_0 \
    --cache-type-v q8_0 \
    --parallel 1 \
    --flash-attn auto \
    --fit on \
    --fit-target "\$VRAM_RESERVE_MIB" \
    --offline \
  >/dev/null

ready=0
for _ in \$(seq 1 300); do
  body="\$(curl -fsS "http://127.0.0.1:\$LLAMA_PORT/health" 2>/dev/null || true)"
  if grep -q '"status"[[:space:]]*:[[:space:]]*"ok"' <<<"\$body"; then
    ready=1
    break
  fi

  running="\$(podman inspect -f '{{.State.Running}}' "\$LLAMA_NAME" 2>/dev/null || true)"
  if [[ "\$running" != "true" ]]; then
    break
  fi
  sleep 1
done

if (( ! ready )); then
  echo "[omp-ai] llama.cpp did not become healthy. Logs:" >&2
  podman logs --tail=120 "\$LLAMA_NAME" >&2 || true
  exit 5
fi

catalog="\$(curl -fsS "http://127.0.0.1:\$LLAMA_PORT/v1/models" 2>/dev/null || true)"
if ! grep -q '"id"' <<<"\$catalog"; then
  echo "[omp-ai] Router is healthy but exposes no models. Check: ai-model list" >&2
  exit 6
fi

echo "[omp-ai] Router ready. Models are loaded into RAM/VRAM only when selected/used."
echo "[omp-ai] Use /model inside OMP to switch models. At most \$MODELS_MAX model(s) stay loaded."
echo "[omp-ai] Exit OMP to remove the router and release all model RAM/VRAM."

secret_args=()
if [[ -r "$SECRET_ENV" ]]; then
  secret_args+=(--env-file "$SECRET_ENV")
fi

podman run --rm -it \
  --name "\$OMP_NAME" \
  --replace \
  --user 0:0 \
  --network omp-web \
  --network omp-llm \
  --network-alias omp \
  --memory "\$OMP_MEM" \
  --cpus 8 \
  --pids-limit 1024 \
  --read-only \
  --cap-drop ALL \
  --security-opt no-new-privileges \
  --tmpfs /tmp:rw,nosuid,nodev,size=1g \
  --tmpfs /data:rw,nosuid,nodev,size=512m \
  --mount "type=bind,src=\$WORKSPACE,dst=/workspace,rw=true,bind-nonrecursive" \
  --mount "type=bind,src=\$AI_HOME/state,dst=/state,rw=true,bind-nonrecursive" \
  "\${secret_args[@]}" \
  -e HOME=/state \
  -e "TERM=\$TERM" \
  -e LLAMA_CPP_BASE_URL=http://llama:8080 \
  -w "\$container_workdir" \
  localhost/omp:latest \
  cli "\$@"
EOF

root chmod 0755 "$INNER"
root chown root:root "$INNER"

PUBLIC="/usr/local/bin/omp-ai"
root tee "$PUBLIC" >/dev/null <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

INNER="$INNER"
WORKSPACE="$WORKSPACE"
AI_USER="$AI_USER"

case "\${1:-}" in
  stop|status|logs)
    exec sudo -n -u "\$AI_USER" "\$INNER" "\$@"
    ;;
esac

pwd_real="\$(realpath -m "\$PWD")"
rel=""
case "\$pwd_real" in
  "\$WORKSPACE") rel="" ;;
  "\$WORKSPACE"/*) rel="\${pwd_real#"\$WORKSPACE/"}" ;;
esac

exec sudo -n -u "\$AI_USER" "\$INNER" --workdir "\$rel" -- "\$@"
EOF
root chmod 0755 "$PUBLIC"
root chown root:root "$PUBLIC"

GIVE="/usr/local/bin/ai-give"
root tee "$GIVE" >/dev/null <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

WORKSPACE="$WORKSPACE"
AI_USER="$AI_USER"
MAIN_USER="$MAIN_USER"
SHARE_GROUP="$SHARE_GROUP"

(( \$# > 0 )) || {
  echo "Usage: ai-give FILE_OR_DIR [...]" >&2
  exit 2
}

for src in "\$@"; do
  src="\$(realpath -e "\$src")"
  base="\$(basename "\$src")"
  dest="\$WORKSPACE/\$base"

  if [[ -d "\$src" && ! -L "\$src" ]]; then
    mkdir -p "\$dest"
    rsync -rlE --safe-links "\$src/" "\$dest/"
  else
    rsync -lE --safe-links "\$src" "\$WORKSPACE/"
  fi

  # Shared workspace: both users may freely modify content.
  find "\$dest" -xdev -type d -exec chmod g+rwx {} + 2>/dev/null || true
  find "\$dest" -xdev -type f -exec chmod g+rw {} + 2>/dev/null || true

  find "\$dest" -xdev -type d -exec setfacl \
    -m "u:\$AI_USER:rwx,u:\$MAIN_USER:rwx,g:\$SHARE_GROUP:rwx,m:rwx" \
    -m "d:u:\$AI_USER:rwx,d:u:\$MAIN_USER:rwx,d:g:\$SHARE_GROUP:rwx,d:m:rwx" {} + \
    2>/dev/null || true

  echo "Added: \$dest"
done
EOF
root chmod 0755 "$GIVE"
root chown root:root "$GIVE"

# Root-owned model-store helper. It only imports sources readable by the desktop
# user, validates GGUF content, and never exposes arbitrary root-readable files.
MODEL_INNER="/usr/local/libexec/omp-ai-model-inner"
root tee "$MODEL_INNER" >/dev/null <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

AI_USER="$AI_USER"
MAIN_USER="$MAIN_USER"
AI_HOME="$AI_HOME"
AI_UID="$AI_UID"
AI_GID="$AI_GID"
MODELS_DIR="$MODEL_STORE"

[[ "\$(id -u)" -eq 0 ]] || { echo "model helper must run as root" >&2; exit 1; }

as_main() {
  runuser -u "\$MAIN_USER" -- env HOME="$MAIN_HOME" USER="\$MAIN_USER" LOGNAME="\$MAIN_USER" \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/bin:/bin "\$@"
}

as_ai() {
  runuser -u "\$AI_USER" -- env HOME="\$AI_HOME" USER="\$AI_USER" LOGNAME="\$AI_USER" \
    XDG_RUNTIME_DIR="/run/user/\$AI_UID" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/\$AI_UID/bus" \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/bin:/bin "\$@"
}

require_idle() {
  if as_ai podman ps --format '{{.Names}}' 2>/dev/null | grep -Eq '^ompai-(agent|llama)$'; then
    echo "An omp-ai session is active. Exit it (or run: omp-ai stop) before changing models." >&2
    exit 3
  fi
}

resolve_source() {
  local src="\$1"
  if [[ "\$src" == "~/"* ]]; then src="$MAIN_HOME/\${src#~/}"; fi
  realpath -e -- "\$src"
}

validate_source() {
  local src="\$1" f found=0
  as_main test -r "\$src" || { echo "Not readable by $MAIN_USER: \$src" >&2; return 1; }
  if [[ -f "\$src" ]]; then
    [[ "\${src,,}" == *.gguf ]] || { echo "Model file must end in .gguf: \$src" >&2; return 1; }
    [[ "\$(as_main head -c4 "\$src" 2>/dev/null || true)" == GGUF ]] || { echo "Invalid GGUF: \$src" >&2; return 1; }
    return 0
  fi
  [[ -d "\$src" ]] || { echo "Expected GGUF file or model directory: \$src" >&2; return 1; }
  if find "\$src" -type l -print -quit | grep -q .; then
    echo "Model directories containing symlinks are rejected: \$src" >&2
    return 1
  fi
  while IFS= read -r -d '' f; do
    found=1
    as_main test -r "\$f" || { echo "Unreadable GGUF in bundle: \$f" >&2; return 1; }
    [[ "\$(as_main head -c4 "\$f" 2>/dev/null || true)" == GGUF ]] || { echo "Invalid GGUF: \$f" >&2; return 1; }
  done < <(find "\$src" -type f -iname '*.gguf' -print0)
  (( found )) || { echo "No .gguf files found in: \$src" >&2; return 1; }
}

install_one() {
  local mode="\$1" raw="\$2" src name dest tmp
  src="\$(resolve_source "\$raw")" || { echo "Path does not exist: \$raw" >&2; return 1; }
  validate_source "\$src"
  name="\$(basename "\$src")"
  [[ "\$name" != .* ]] || { echo "Refusing hidden model-store entry: \$name" >&2; return 1; }
  dest="\$MODELS_DIR/\$name"

  if [[ -e "\$dest" ]]; then
    if [[ "\$mode" == add ]]; then
      echo "Already exists: \$name (use: ai-model replace \\"\$src\\")" >&2
      return 1
    fi
    rm -rf -- "\$dest"
  fi

  tmp="\$MODELS_DIR/.import-\${name}.\$\$"
  rm -rf -- "\$tmp"
  trap 'rm -rf -- "\$tmp"' RETURN

  if [[ -f "\$src" ]]; then
    cp --reflink=auto --sparse=always -- "\$src" "\$tmp"
  else
    cp -a --reflink=auto -- "\$src" "\$tmp"
  fi
  chown -R root:"\$AI_GID" "\$tmp"
  if [[ -d "\$tmp" ]]; then
    find "\$tmp" -type d -exec chmod 0550 {} +
    find "\$tmp" -type f -exec chmod 0440 {} +
  else
    chmod 0440 "\$tmp"
  fi
  mv -- "\$tmp" "\$dest"
  trap - RETURN
  echo "Installed: \$name"
}

cmd="\${1:-help}"; shift || true
case "\$cmd" in
  add|replace)
    (( \$# > 0 )) || { echo "Usage: ai-model \$cmd FILE_OR_DIR [...]" >&2; exit 2; }
    require_idle
    for src in "\$@"; do install_one "\$cmd" "\$src"; done
    ;;
  remove|rm)
    (( \$# > 0 )) || { echo "Usage: ai-model remove NAME [...]" >&2; exit 2; }
    require_idle
    for name in "\$@"; do
      [[ "\$name" != */* && "\$name" != . && "\$name" != .. && -n "\$name" ]] || { echo "Invalid model name: \$name" >&2; exit 2; }
      target="\$MODELS_DIR/\$name"
      [[ -e "\$target" ]] || { echo "Not found: \$name" >&2; continue; }
      rm -rf -- "\$target"
      echo "Removed: \$name"
    done
    ;;
  list|ls)
    printf '%-46s %10s  %s\\n' NAME SIZE TYPE
    while IFS= read -r -d '' entry; do
      name="\$(basename "\$entry")"
      size="\$(du -sh -- "\$entry" | awk '{print \$1}')"
      if [[ -d "\$entry" ]]; then kind=bundle; else kind=gguf; fi
      printf '%-46s %10s  %s\\n' "\$name" "\$size" "\$kind"
    done < <(find "\$MODELS_DIR" -mindepth 1 -maxdepth 1 ! -name '.import-*' -print0 | sort -z)
    ;;
  path)
    echo "\$MODELS_DIR"
    ;;
  help|-h|--help)
    cat <<'HELP'
Usage:
  ai-model add FILE_OR_DIR [...]
  ai-model replace FILE_OR_DIR [...]
  ai-model remove NAME [...]
  ai-model list
  ai-model path

`ai-model path` prints the configured host MODEL_STORE.
A FILE must be GGUF. A DIR is treated as one llama.cpp model bundle and may
contain sharded GGUF files and/or mmproj*.gguf. Changes are allowed only while
omp-ai is stopped; the next omp-ai launch rescans --models-dir.
HELP
    ;;
  *) echo "Unknown command: \$cmd" >&2; exit 2 ;;
esac
EOF
root chmod 0755 "$MODEL_INNER"
root chown root:root "$MODEL_INNER"

MODEL_PUBLIC="/usr/local/bin/ai-model"
root tee "$MODEL_PUBLIC" >/dev/null <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
exec sudo -n "$MODEL_INNER" "\$@"
EOF
root chmod 0755 "$MODEL_PUBLIC"
root chown root:root "$MODEL_PUBLIC"

# Narrow sudo permission: the desktop user can become ompai only for this one
# root-owned helper, not for an arbitrary shell.
SUDOERS="/etc/sudoers.d/omp-ai"
root tee "$SUDOERS" >/dev/null <<EOF
$MAIN_USER ALL=($AI_USER) NOPASSWD: $INNER *
$MAIN_USER ALL=(root) NOPASSWD: $MODEL_INNER *
EOF
root chmod 0440 "$SUDOERS"
root visudo -cf "$SUDOERS" >/dev/null

# Reaper: if terminal/launcher dies with SIGKILL or machine loses the session,
# remove abandoned containers and release VRAM.
REAPER="/usr/local/libexec/omp-ai-reap"
root tee "$REAPER" >/dev/null <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

export HOME="$AI_HOME"
export XDG_RUNTIME_DIR="/run/user/$AI_UID"
export DBUS_SESSION_BUS_ADDRESS="unix:path=\$XDG_RUNTIME_DIR/bus"
export PATH="/usr/local/sbin:/usr/local/bin:/usr/bin:/bin"

lease="\$XDG_RUNTIME_DIR/omp-ai.lease"

if podman ps --format '{{.Names}}' | grep -qx 'ompai-agent'; then
  exit 0
fi

if [[ -e "\$lease" ]]; then
  now=\$(date +%s)
  mtime=\$(stat -c %Y "\$lease" 2>/dev/null || echo 0)
  if (( now - mtime < 600 )); then
    exit 0
  fi
fi

podman rm -f -t 5 ompai-agent ompai-llama >/dev/null 2>&1 || true
rm -f "\$lease"
EOF
root chmod 0755 "$REAPER"
root chown root:root "$REAPER"

root tee /etc/systemd/system/omp-ai-reaper.service >/dev/null <<EOF
[Unit]
Description=Reap abandoned on-demand OMP/llama Podman containers
After=user@${AI_UID}.service
Requires=user@${AI_UID}.service

[Service]
Type=oneshot
User=$AI_USER
Group=$AI_USER
Environment=HOME=$AI_HOME
Environment=XDG_RUNTIME_DIR=/run/user/$AI_UID
Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$AI_UID/bus
ExecStart=$REAPER
EOF

root tee /etc/systemd/system/omp-ai-reaper.timer >/dev/null <<'EOF'
[Unit]
Description=Periodically unload orphaned OMP local AI

[Timer]
OnBootSec=5min
OnUnitActiveSec=2min
AccuracySec=30s
Persistent=true

[Install]
WantedBy=timers.target
EOF

root systemctl daemon-reload
root systemctl enable --now omp-ai-reaper.timer

# Leave setup with no AI containers running.
as_ai podman rm -f -t 5 ompai-agent ompai-llama >/dev/null 2>&1 || true

echo
ok "Podman-based OMP environment is ready."
echo
echo "Isolation user:       $AI_USER (login disabled)"
echo "Workspace:            $WORKSPACE"
echo "Model store:          $MODEL_STORE"
echo "Desktop shortcut:     $MAIN_HOME/AI"
echo "Runtime:              rootless Podman (daemonless)"
echo "GPU:                  NVIDIA CDI"
echo "Model lifecycle:      router on-demand; selected model autoloaded"
echo "Host-user hard cap:   RAM=$AI_SLICE_MEM, CPU=$AI_SLICE_CPU, swap=0"
echo "llama container cap:  $LLAMA_MEM"
echo "OMP container cap:    $OMP_MEM"
echo "Router models max:    $MODELS_MAX"
echo "VRAM reserve target:  ${VRAM_RESERVE_MIB} MiB"
echo "Web search primary:   $WEB_SEARCH_PRIMARY"
echo "Web search fallback:  ${WEB_SEARCH_FALLBACK:-none}"
if [[ -n "$EXA_API_KEY" ]]; then
  echo "Exa credential:       installed as protected env file"
else
  echo "Exa credential:       not configured"
fi
echo
echo "Use:"
echo "  ai-model add ~/Downloads/model.gguf"
echo "  ai-model list"
echo "  ai-give ~/Downloads/document.pdf"
echo "  cd ~/AI && omp-ai"
echo "  cd ~/AI/my-project && omp-ai"
echo "  omp-ai status"
echo "  omp-ai logs"
echo "  omp-ai stop"
echo
echo "IMPORTANT:"
echo "  Anything under ~/AI is intentionally available to the agent and may"
echo "  be uploaded to the Internet. Keep credentials and secrets outside it."

if ! root find "$MODEL_STORE" -type f -iname '*.gguf' -print -quit | grep -q .; then
  echo
  warn "No model installed. Add one with: ai-model add /path/to/model.gguf"
fi
