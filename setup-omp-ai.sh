#!/usr/bin/env bash
set -Eeuo pipefail

# setup-omp-ai.sh
#
# Arch Linux installer/updater for:
# - dedicated host user: ompai
# - rootless/daemonless Podman
# - NVIDIA CDI
# - OMP in a hardened container
# - one shared llama.cpp multi-model router for concurrent OMP sessions
# - persistent configurable model store
# - persistent ~/AI workspace
# - temporary direct --share / --share-ro mounts
#
# Normal usage:
#   1. edit omp-ai.conf
#   2. chmod 600 omp-ai.conf
#   3. ./setup-omp-ai.sh

AI_USER="ompai"
AI_HOME="/var/lib/ompai"
SHARE_GROUP="ompai-share"
WORKSPACE="/srv/ompai/workspace"
MODEL_STORE="/var/lib/ompai/models"

LLAMA_IMAGE="ghcr.io/ggml-org/llama.cpp:server-cuda"
OMP_REPO="https://github.com/can1357/oh-my-pi.git"
OMP_REF="main"

MODELS_MAX=1
LLAMA_PORT=18080
LLAMA_CTX=8192
LLAMA_PARALLEL=1
LLAMA_MEM="22g"
OMP_MEM="3g"
AI_SLICE_MEM="25G"
AI_SLICE_CPU="2400%"
VRAM_RESERVE_MIB=2048

EXA_API_KEY=""
WEB_SEARCH_PRIMARY="auto"
WEB_SEARCH_FALLBACK="duckduckgo"
HARDEN_HOME="true"
ASSUME_YES="false"

INITIAL_MODELS=()

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CONFIG_FILE="$SCRIPT_DIR/omp-ai.conf"

log()  { printf '\033[1;34m[omp-ai]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[omp-ai]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[omp-ai]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[omp-ai] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
cat <<'EOF'
Usage:
  ./setup-omp-ai.sh [options]

Normally edit omp-ai.conf and run with no arguments.

Overrides:
  --config PATH
  --model PATH             Import model/bundle; repeatable
  --model-store PATH
  --models-max N
  --ctx N
  --llama-parallel N
  --vram-reserve MIB
  --llama-memory SIZE
  --omp-memory SIZE
  --exa-api-key KEY
  --web-search auto|exa|duckduckgo
  -y, --yes
  -h, --help
EOF
}

for a in "$@"; do
  case "$a" in -h|--help) usage; exit 0;; esac
done

# Discover config override before parsing config.
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  case "${args[i]}" in
    --config) CONFIG_FILE="${args[i+1]:?--config needs a path}"; ((i++));;
    --config=*) CONFIG_FILE="${args[i]#*=}";;
  esac
done

if [[ $EUID -eq 0 ]]; then
  MAIN_USER="${SUDO_USER:-}"
  [[ -n "$MAIN_USER" && "$MAIN_USER" != root ]] ||
    die "Run from your normal desktop user, not a root login."
else
  MAIN_USER="${USER:?}"
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
    root runuser -u "$MAIN_USER" -- env HOME="$MAIN_HOME" USER="$MAIN_USER" LOGNAME="$MAIN_USER" "$@"
  fi
}
trim() {
  local v="$1"
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  printf '%s' "$v"
}
unquote() {
  local v="$1"
  if (( ${#v} >= 2 )); then
    if [[ "${v:0:1}" == '"' && "${v: -1}" == '"' ]] ||
       [[ "${v:0:1}" == "'" && "${v: -1}" == "'" ]]; then
      v="${v:1:${#v}-2}"
    fi
  fi
  printf '%s' "$v"
}
bool01() {
  case "${1,,}" in
    1|true|yes|y|on) echo 1;;
    0|false|no|n|off) echo 0;;
    *) die "Invalid boolean: $1";;
  esac
}
set_cfg() {
  local k="$1" v="$2"
  case "$k" in
    AI_USER) AI_USER="$v";;
    AI_HOME) AI_HOME="$v";;
    SHARE_GROUP) SHARE_GROUP="$v";;
    WORKSPACE) WORKSPACE="$v";;
    MODEL_STORE) MODEL_STORE="$v";;

    MODEL|MODEL_PATH) [[ -n "$v" ]] && INITIAL_MODELS+=("$v");;
    MODELS_MAX) MODELS_MAX="$v";;
    LLAMA_IMAGE) LLAMA_IMAGE="$v";;
    LLAMA_PORT) LLAMA_PORT="$v";;
    LLAMA_CTX) LLAMA_CTX="$v";;
    LLAMA_PARALLEL) LLAMA_PARALLEL="$v";;
    LLAMA_MEM) LLAMA_MEM="$v";;
    VRAM_RESERVE_MIB) VRAM_RESERVE_MIB="$v";;

    OMP_REPO) OMP_REPO="$v";;
    OMP_REF) OMP_REF="$v";;
    OMP_MEM) OMP_MEM="$v";;

    AI_SLICE_MEM) AI_SLICE_MEM="$v";;
    AI_SLICE_CPU) AI_SLICE_CPU="$v";;

    EXA_API_KEY) EXA_API_KEY="$v";;
    WEB_SEARCH_PRIMARY) WEB_SEARCH_PRIMARY="$v";;
    WEB_SEARCH_FALLBACK) WEB_SEARCH_FALLBACK="$v";;

    HARDEN_HOME) HARDEN_HOME="$v";;
    ASSUME_YES) ASSUME_YES="$v";;
    "") ;;
    *) die "Unknown config key: $k";;
  esac
}
load_config() {
  local line k v n=0
  [[ -f "$1" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    ((n++))
    line="${line%$'\r'}"
    line="$(trim "$line")"
    [[ -z "$line" || "$line" == \#* || "$line" == \;* || "$line" == \[*\] ]] && continue
    [[ "$line" == *=* ]] || die "$1:$n: expected KEY=VALUE"
    k="$(trim "${line%%=*}")"
    v="$(unquote "$(trim "${line#*=}")")"
    [[ "$k" =~ ^[A-Z][A-Z0-9_]*$ ]] || die "$1:$n: invalid key: $k"
    set_cfg "$k" "$v"
  done < "$1"
}

if [[ -f "$CONFIG_FILE" ]]; then
  log "Reading config: $CONFIG_FILE"
  load_config "$CONFIG_FILE"
else
  warn "Config not found: $CONFIG_FILE; using defaults."
fi

while (($#)); do
  case "$1" in
    --config) shift 2;;
    --config=*) shift;;
    --model) INITIAL_MODELS+=("${2:?}"); shift 2;;
    --model-store) MODEL_STORE="${2:?}"; shift 2;;
    --models-max) MODELS_MAX="${2:?}"; shift 2;;
    --ctx) LLAMA_CTX="${2:?}"; shift 2;;
    --llama-parallel) LLAMA_PARALLEL="${2:?}"; shift 2;;
    --vram-reserve) VRAM_RESERVE_MIB="${2:?}"; shift 2;;
    --llama-memory) LLAMA_MEM="${2:?}"; shift 2;;
    --omp-memory) OMP_MEM="${2:?}"; shift 2;;
    --exa-api-key) EXA_API_KEY="${2:?}"; shift 2;;
    --web-search) WEB_SEARCH_PRIMARY="${2:?}"; shift 2;;
    -y|--yes) ASSUME_YES=true; shift;;
    -h|--help) usage; exit 0;;
    *) die "Unknown option: $1";;
  esac
done

HARDEN_HOME="$(bool01 "$HARDEN_HOME")"
ASSUME_YES="$(bool01 "$ASSUME_YES")"

source /etc/os-release
[[ "${ID:-}" == arch ]] || die "This installer targets Arch Linux."

[[ "$MODEL_STORE" = /* && "$MODEL_STORE" != / ]] || die "MODEL_STORE must be an absolute non-root path"
case "$MODEL_STORE" in
  "$MAIN_HOME"|"$MAIN_HOME"/*) die "MODEL_STORE must be outside $MAIN_HOME";;
esac
[[ "$WORKSPACE" = /* && "$WORKSPACE" != / ]] || die "WORKSPACE must be an absolute non-root path"
[[ "$MODELS_MAX" =~ ^[0-9]+$ ]] && (( MODELS_MAX >= 1 )) || die "MODELS_MAX must be >= 1"
[[ "$LLAMA_CTX" =~ ^[0-9]+$ ]] && (( LLAMA_CTX >= 1024 )) || die "LLAMA_CTX must be >= 1024"
[[ "$LLAMA_PARALLEL" =~ ^[0-9]+$ ]] && (( LLAMA_PARALLEL >= 1 )) || die "LLAMA_PARALLEL must be >= 1"
[[ "$VRAM_RESERVE_MIB" =~ ^[0-9]+$ ]] || die "VRAM_RESERVE_MIB must be an integer"
[[ "$LLAMA_PORT" =~ ^[0-9]+$ ]] || die "LLAMA_PORT must be an integer"

case "${WEB_SEARCH_PRIMARY,,}" in
  auto) [[ -n "$EXA_API_KEY" ]] && WEB_SEARCH_PRIMARY=exa || WEB_SEARCH_PRIMARY=duckduckgo;;
  exa|duckduckgo) WEB_SEARCH_PRIMARY="${WEB_SEARCH_PRIMARY,,}";;
  *) die "WEB_SEARCH_PRIMARY: use auto, exa, or duckduckgo";;
esac
case "${WEB_SEARCH_FALLBACK,,}" in
  ""|none|off) WEB_SEARCH_FALLBACK="";;
  exa|duckduckgo) WEB_SEARCH_FALLBACK="${WEB_SEARCH_FALLBACK,,}";;
  *) die "WEB_SEARCH_FALLBACK: use exa, duckduckgo, or none";;
esac
[[ "$WEB_SEARCH_PRIMARY" == "$WEB_SEARCH_FALLBACK" ]] && WEB_SEARCH_FALLBACK=""

if [[ -n "$EXA_API_KEY" && -f "$CONFIG_FILE" ]]; then
  [[ "$(stat -c %U "$CONFIG_FILE")" == "$MAIN_USER" ]] ||
    die "Config contains EXA_API_KEY but is not owned by $MAIN_USER"
  as_main chmod 0600 "$CONFIG_FILE"
fi

log "Installing packages..."
root pacman -S --needed --noconfirm \
  podman crun passt netavark aardvark-dns fuse-overlayfs \
  nvidia-container-toolkit git curl rsync acl sudo shadow

log "Creating dedicated account and workspace..."
getent group "$SHARE_GROUP" >/dev/null || root groupadd "$SHARE_GROUP"
if ! id "$AI_USER" &>/dev/null; then
  root useradd -m -U -d "$AI_HOME" -s /usr/bin/nologin "$AI_USER"
else
  [[ "$(getent passwd "$AI_USER" | cut -d: -f6)" == "$AI_HOME" ]] ||
    die "$AI_USER already exists with another home"
fi
root passwd -l "$AI_USER" >/dev/null 2>&1 || true
root usermod -s /usr/bin/nologin "$AI_USER"
root usermod -aG "$SHARE_GROUP" "$AI_USER"
root usermod -aG "$SHARE_GROUP" "$MAIN_USER"

AI_UID="$(id -u "$AI_USER")"
AI_GID="$(id -g "$AI_USER")"
MAIN_UID="$(id -u "$MAIN_USER")"
MAIN_GID="$(id -g "$MAIN_USER")"
root chmod 0700 "$AI_HOME"

if (( HARDEN_HOME )); then
  mode="$(stat -c %a "$MAIN_HOME")"
  if [[ "$mode" != 700 ]]; then
    ans=Y
    if (( ! ASSUME_YES )); then
      read -r -p "Harden $MAIN_HOME with chmod go-rwx? [Y/n] " ans
      ans="${ans:-Y}"
    fi
    [[ "$ans" =~ ^[Yy]$ ]] && root chmod go-rwx "$MAIN_HOME" ||
      warn "Home permissions left unchanged."
  fi
fi

root install -d -o "$AI_USER" -g "$SHARE_GROUP" -m 2770 "$WORKSPACE"
root setfacl -m "u:$MAIN_USER:rwx,u:$AI_USER:rwx,g:$SHARE_GROUP:rwx,m:rwx" "$WORKSPACE"
root setfacl -d -m "u:$MAIN_USER:rwx,u:$AI_USER:rwx,g:$SHARE_GROUP:rwx,m:rwx" "$WORKSPACE"

LINK="$MAIN_HOME/AI"
if [[ ! -e "$LINK" && ! -L "$LINK" ]]; then
  as_main ln -s "$WORKSPACE" "$LINK"
fi

# subuid/subgid for rootless Podman
subid_start() { awk -F: -v u="$2" '$1==u{print $2;exit}' "$1" 2>/dev/null || true; }
next_subid() {
  awk -F: 'BEGIN{m=99999} NF>=3{e=$2+$3-1;if(e>m)m=e}
           END{b=65536;s=int((m+b)/b)*b;if(s<100000)s=100000;print s}' /etc/subuid /etc/subgid 2>/dev/null
}
su0="$(subid_start /etc/subuid "$AI_USER")"
sg0="$(subid_start /etc/subgid "$AI_USER")"
if [[ -z "$su0" || -z "$sg0" ]]; then
  chosen="${su0:-${sg0:-$(next_subid)}}"
  end=$((chosen+65535))
  [[ -n "$su0" ]] || root usermod --add-subuids "$chosen-$end" "$AI_USER"
  [[ -n "$sg0" ]] || root usermod --add-subgids "$chosen-$end" "$AI_USER"
fi

log "Applying host-level limits..."
root install -d -m 0755 "/etc/systemd/system/user-${AI_UID}.slice.d"
root tee "/etc/systemd/system/user-${AI_UID}.slice.d/90-ompai.conf" >/dev/null <<EOF
[Slice]
MemoryMax=$AI_SLICE_MEM
MemorySwapMax=0
CPUQuota=$AI_SLICE_CPU
TasksMax=4096
EOF
root systemctl daemon-reload
root loginctl enable-linger "$AI_USER"
root systemctl start "user@${AI_UID}.service"
root systemctl set-property "user-${AI_UID}.slice" \
  "MemoryMax=$AI_SLICE_MEM" "MemorySwapMax=0" \
  "CPUQuota=$AI_SLICE_CPU" "TasksMax=4096" >/dev/null

AI_RUNTIME="/run/user/$AI_UID"
for _ in $(seq 1 30); do [[ -d "$AI_RUNTIME" ]] && break; sleep 1; done
[[ -d "$AI_RUNTIME" ]] || die "No runtime dir for $AI_USER"

as_ai() {
  root runuser -u "$AI_USER" -- env \
    HOME="$AI_HOME" USER="$AI_USER" LOGNAME="$AI_USER" \
    XDG_RUNTIME_DIR="$AI_RUNTIME" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=$AI_RUNTIME/bus" \
    PATH="/usr/local/sbin:/usr/local/bin:/usr/bin:/bin" "$@"
}

info="$(as_ai podman info --format '{{.Host.Security.Rootless}} {{.Host.CgroupVersion}} {{.Host.CgroupManager}}' 2>/dev/null || true)"
[[ "$info" == true* && "$info" == *systemd* ]] || die "Rootless Podman/systemd cgroups unavailable: $info"

log "Preparing storage..."
root install -d -o "$AI_USER" -g "$AI_GID" -m 0700 \
  "$AI_HOME/state" "$AI_HOME/state/.omp" "$AI_HOME/state/.omp/agent" \
  "$AI_HOME/src" "$AI_HOME/build"
root install -d -o root -g "$AI_GID" -m 0750 "$AI_HOME/secrets"
root install -d -o root -g "$AI_GID" -m 0750 "$MODEL_STORE"

SECRET_ENV="$AI_HOME/secrets/omp.env"
if [[ -n "$EXA_API_KEY" ]]; then
  tmp="$(mktemp)"
  printf 'EXA_API_KEY=%s\n' "$EXA_API_KEY" >"$tmp"
  root install -o root -g "$AI_GID" -m 0640 "$tmp" "$SECRET_ENV"
  rm -f "$tmp"
else
  root rm -f "$SECRET_ENV"
fi

# Import MODEL= entries, if any.
validate_model() {
  local src="$1" f found=0
  as_main test -r "$src" || die "Unreadable model source: $src"
  if [[ -f "$src" ]]; then
    [[ "${src,,}" == *.gguf ]] || die "Model file must end with .gguf: $src"
    [[ "$(as_main head -c4 "$src" 2>/dev/null || true)" == GGUF ]] || die "Invalid GGUF: $src"
    return
  fi
  [[ -d "$src" ]] || die "Model source must be file or directory: $src"
  find "$src" -type l -print -quit | grep -q . && die "Model bundle may not contain symlinks: $src"
  while IFS= read -r -d '' f; do
    found=1
    [[ "$(as_main head -c4 "$f" 2>/dev/null || true)" == GGUF ]] || die "Invalid GGUF: $f"
  done < <(find "$src" -type f -iname '*.gguf' -print0)
  (( found )) || die "No GGUF files in bundle: $src"
}
for raw in "${INITIAL_MODELS[@]}"; do
  [[ "$raw" == "~/"* ]] && raw="$MAIN_HOME/${raw#~/}"
  src="$(realpath -e "$raw")"
  validate_model "$src"
  name="$(basename "$src")"
  dest="$MODEL_STORE/$name"
  if [[ -e "$dest" ]]; then
    log "Model already exists, skipping: $name"
    continue
  fi
  tmp="$MODEL_STORE/.import-${name}.$$"
  root rm -rf "$tmp"
  if [[ -f "$src" ]]; then root cp --reflink=auto --sparse=always "$src" "$tmp"
  else root cp -a --reflink=auto "$src" "$tmp"; fi
  root chown -R root:"$AI_GID" "$tmp"
  if [[ -d "$tmp" ]]; then
    root find "$tmp" -type d -exec chmod 0550 {} +
    root find "$tmp" -type f -exec chmod 0440 {} +
  else
    root chmod 0440 "$tmp"
  fi
  root mv "$tmp" "$dest"
done

WEB_SELECTOR="web/$WEB_SEARCH_PRIMARY"
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
  web: $WEB_SELECTOR
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
root rm -f "$AI_HOME/state/.omp/agent/models.yml"
root chown -R "$AI_USER:$AI_GID" "$AI_HOME/state"
root chmod -R go-rwx "$AI_HOME/state"

log "Preparing NVIDIA CDI..."
root install -d -m 0755 /etc/cdi
if ! root nvidia-ctk cdi list 2>/dev/null | grep -q '^nvidia.com/gpu=all$'; then
  root nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
fi
root nvidia-ctk cdi list | grep -q '^nvidia.com/gpu=all$' || die "NVIDIA CDI unavailable"

log "Creating networks..."
as_ai podman network exists omp-llm 2>/dev/null || as_ai podman network create --internal omp-llm >/dev/null
as_ai podman network exists omp-web 2>/dev/null || as_ai podman network create omp-web >/dev/null

log "Building OMP from upstream source..."
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
as_ai podman build --pull=newer -t localhost/omp:latest "$OMP_SRC"
as_ai podman pull "$LLAMA_IMAGE"

log "Testing NVIDIA in rootless Podman..."
as_ai podman run --rm --device nvidia.com/gpu=all docker.io/library/ubuntu:24.04 nvidia-smi -L >/dev/null ||
  die "Rootless Podman cannot use NVIDIA CDI"

root install -d -m 0755 /usr/local/libexec

# ---------- privileged direct-share helper ----------
SHARE_HELPER="/usr/local/libexec/omp-ai-share"
SHARE_STATE="/var/lib/ompai-share-state"
SHARE_STAGE="/run/omp-ai-shares"
root install -d -o root -g root -m 0700 "$SHARE_STATE"
root install -d -o root -g root -m 0711 "$SHARE_STAGE"

root tee "$SHARE_HELPER" >/dev/null <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
AI_USER="$AI_USER"
MAIN_USER="$MAIN_USER"
MAIN_UID="$MAIN_UID"
MAIN_GID="$MAIN_GID"
STATE="$SHARE_STATE"
STAGE="$SHARE_STAGE"

[[ \$EUID -eq 0 ]] || { echo "Must run as root" >&2; exit 1; }
valid_sid(){ [[ "\$1" =~ ^[A-Za-z0-9._-]+$ ]]; }
sdir(){ valid_sid "\$1" || exit 2; printf '%s/%s' "\$STATE" "\$1"; }
exec 9>"\$STATE/.lock"
flock 9

cleanup_one() {
  local sid="\$1" d item src mnt before after
  d="\$(sdir "\$sid")"
  [[ -d "\$d" ]] || return 0

  # Unmount staging binds first.
  if [[ -f "\$d/mounts" ]]; then
    tac "\$d/mounts" | while IFS= read -r mnt; do
      umount -l -- "\$mnt" >/dev/null 2>&1 || true
    done
  fi

  # Restore old ACLs/ownership, then hand new files back to the desktop user.
  while IFS= read -r item; do
    src="\$(cat "\$item/source" 2>/dev/null || true)"
    before="\$item/before"
    after="\$item/after"
    if [[ -d "\$src" ]]; then find -P "\$src" -print0 2>/dev/null | sort -z >"\$after" || :
    elif [[ -e "\$src" ]]; then printf '%s\0' "\$src" | sort -z >"\$after"
    else : >"\$after"; fi

    setfacl --restore="\$item/acl" -P >/dev/null 2>&1 || true

    if [[ -f "\$before" && -f "\$after" ]]; then
      comm -z -13 "\$before" "\$after" |
      while IFS= read -r -d '' p; do
        [[ -e "\$p" || -L "\$p" ]] || continue
        chown -h "\$MAIN_UID:\$MAIN_GID" "\$p" 2>/dev/null || true
        [[ -L "\$p" ]] || setfacl -x "u:\$AI_USER" "\$p" >/dev/null 2>&1 || true
        [[ -d "\$p" ]] && setfacl -x "d:u:\$AI_USER" "\$p" >/dev/null 2>&1 || true
      done
    fi
  done < <(find "\$d" -mindepth 1 -maxdepth 1 -type d -name 'item-*' -print | sort -Vr)

  rm -rf -- "\$STAGE/\$sid" "\$d"
}

case "\${1:-}" in
  begin)
    sid="\$(cat /proc/sys/kernel/random/uuid)"
    install -d -o root -g root -m 0700 "\$STATE/\$sid"
    install -d -o root -g root -m 0711 "\$STAGE/\$sid"
    date +%s >"\$STATE/\$sid/started"
    date +%s >"\$STATE/\$sid/heartbeat"
    echo 0 >"\$STATE/\$sid/owner_pid"
    echo 0 >"\$STATE/\$sid/owner_start"
    cat /proc/sys/kernel/random/boot_id >"\$STATE/\$sid/boot_id"
    echo 0 >"\$STATE/\$sid/count"
    : >"\$STATE/\$sid/mounts"
    echo "\$sid"
    ;;
  grant)
    sid="\${2:?}"; mode="\${3:?}"; raw="\${4:?}"
    [[ "\$mode" == rw || "\$mode" == ro ]] || exit 2
    d="\$(sdir "\$sid")"; [[ -d "\$d" ]] || exit 2

    src="\$(realpath -e -- "\$raw")"
    [[ -f "\$src" || -d "\$src" ]] || { echo "Only files/directories can be shared" >&2; exit 2; }
    [[ "\$src" != "/" && "\$src" != "$MAIN_HOME" ]] || { echo "Refusing overly broad share" >&2; exit 2; }
    case "\$src" in /proc|/proc/*|/sys|/sys/*|/dev|/dev/*|/run|/run/*) echo "Refusing pseudo-filesystem" >&2; exit 2;; esac

    # Overlapping direct shares are refused. Otherwise one session could restore
    # ACLs while another session still relies on them. Separate projects/files
    # can be shared concurrently without this ambiguity.
    shopt -s nullglob
    for source_file in "\$STATE"/*/item-*/source; do
      other="\$(cat "\$source_file" 2>/dev/null || true)"
      [[ -n "\$other" ]] || continue
      if [[ "\$src" == "\$other" || "\$src" == "\$other"/* || "\$other" == "\$src"/* ]]; then
        echo "Direct share overlaps an active share: \$other" >&2
        exit 4
      fi
    done
    shopt -u nullglob

    # User must already own/have the requested access. We do not use this helper
    # to grant the desktop user new access to root/system files.
    runuser -u "\$MAIN_USER" -- test -r "\$src" || { echo "Source not readable by $MAIN_USER" >&2; exit 3; }
    [[ "\$mode" == ro ]] || runuser -u "\$MAIN_USER" -- test -w "\$src" || { echo "Source not writable by $MAIN_USER" >&2; exit 3; }

    count="\$(cat "\$d/count")"; count=\$((count+1)); echo "\$count" >"\$d/count"
    item="\$d/item-\$(printf '%04d' "\$count")"
    install -d -o root -g root -m 0700 "\$item"
    printf '%s\n' "\$src" >"\$item/source"

    if [[ -d "\$src" ]]; then
      find -P "\$src" -print0 | sort -z >"\$item/before"
      getfacl -R -P -p -- "\$src" >"\$item/acl"
    else
      printf '%s\0' "\$src" | sort -z >"\$item/before"
      getfacl -p -- "\$src" >"\$item/acl"
    fi

    # Grant ACL only to the shared target tree. No traversal permission is added
    # to the original parent directories because root bind-mounts it into STAGE.
    if [[ -d "\$src" ]]; then
      if [[ "\$mode" == ro ]]; then
        find -P "\$src" -type d -print0 | xargs -0 -r setfacl -m "u:\$AI_USER:r-x" --
        find -P "\$src" -type f -print0 | xargs -0 -r setfacl -m "u:\$AI_USER:r--" --
        runuser -u "\$MAIN_USER" -- find -P "\$src" -type f -executable -print0 |
          xargs -0 -r setfacl -m "u:\$AI_USER:r-x" --
      else
        find -P "\$src" -type d -print0 |
          xargs -0 -r setfacl -m "u:\$AI_USER:rwx" -m "d:u:\$AI_USER:rwx" -m "d:u:\$MAIN_USER:rwx" --
        find -P "\$src" -type f -print0 | xargs -0 -r setfacl -m "u:\$AI_USER:rw-" --
        runuser -u "\$MAIN_USER" -- find -P "\$src" -type f -executable -print0 |
          xargs -0 -r setfacl -m "u:\$AI_USER:rwx" --
      fi
    else
      [[ "\$mode" == ro ]] && perms=r-- || perms=rw-
      setfacl -m "u:\$AI_USER:\$perms" -- "\$src"
    fi

    # Bind source to a staging path whose parents are traversable by ompai.
    base="\$(basename -- "\$src" | sed 's/[^A-Za-z0-9._-]/_/g')"
    [[ -n "\$base" ]] || base=share
    mnt="\$STAGE/\$sid/\$(printf '%04d' "\$count")-\$base"
    if [[ -d "\$src" ]]; then install -d -o root -g root -m 0711 "\$mnt"
    else install -o root -g root -m 0644 /dev/null "\$mnt"; fi
    mount --bind -- "\$src" "\$mnt"
    [[ "\$mode" == ro ]] && mount -o remount,bind,ro "\$mnt"
    printf '%s\n' "\$mnt" >>"\$d/mounts"
    printf '%s\n' "\$mnt"
    ;;
  attach)
    sid="\${2:?}"; pid="\${3:?}"; start="\${4:?}"; d="\$(sdir "\$sid")"
    [[ -d "\$d" && "\$pid" =~ ^[0-9]+$ && "\$start" =~ ^[0-9]+$ ]] || exit 2
    current="\$(awk '{print \$22}' "/proc/\$pid/stat" 2>/dev/null || true)"
    [[ "\$current" == "\$start" ]] || { echo "Share owner process is no longer alive" >&2; exit 3; }
    printf '%s\n' "\$pid" >"\$d/owner_pid"
    printf '%s\n' "\$start" >"\$d/owner_start"
    date +%s >"\$d/heartbeat"
    ;;
  heartbeat)
    sid="\${2:?}"; d="\$(sdir "\$sid")"
    [[ -d "\$d" ]] || exit 2
    date +%s >"\$d/heartbeat"
    ;;
  cleanup)
    cleanup_one "\${2:?}"
    ;;
  cleanup-stale)
    age="\${2:-180}"; now="\$(date +%s)"; boot="\$(cat /proc/sys/kernel/random/boot_id)"
    shopt -s nullglob
    for d in "\$STATE"/*; do
      [[ -d "\$d" ]] || continue
      sid="\$(basename "\$d")"
      heartbeat="\$(cat "\$d/heartbeat" 2>/dev/null || cat "\$d/started" 2>/dev/null || echo 0)"
      oldboot="\$(cat "\$d/boot_id" 2>/dev/null || true)"
      owner_pid="\$(cat "\$d/owner_pid" 2>/dev/null || echo 0)"
      owner_start="\$(cat "\$d/owner_start" 2>/dev/null || echo 0)"
      current_start="\$(awk '{print \$22}' "/proc/\$owner_pid/stat" 2>/dev/null || true)"
      live=0
      [[ "\$owner_pid" != 0 && -n "\$current_start" && "\$current_start" == "\$owner_start" ]] && live=1
      if [[ "\$oldboot" != "\$boot" ]] || (( ! live && now-heartbeat >= age )); then cleanup_one "\$sid"; fi
    done
    ;;
  *) echo "Usage: omp-ai-share {begin|grant SID rw|ro PATH|attach SID PID START|heartbeat SID|cleanup SID|cleanup-stale [SECONDS]}" >&2; exit 2;;
esac
EOF
root chmod 0755 "$SHARE_HELPER"
root chown root:root "$SHARE_HELPER"

# ---------- unprivileged runtime helper ----------
INNER="/usr/local/libexec/omp-ai-inner"
root tee "$INNER" >/dev/null <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
AI_HOME="$AI_HOME"
WORKSPACE="$WORKSPACE"
MODEL_STORE="$MODEL_STORE"
LLAMA_IMAGE="$LLAMA_IMAGE"
LLAMA_PORT="$LLAMA_PORT"
LLAMA_CTX="$LLAMA_CTX"
LLAMA_PARALLEL="$LLAMA_PARALLEL"
LLAMA_MEM="$LLAMA_MEM"
OMP_MEM="$OMP_MEM"
VRAM_RESERVE_MIB="$VRAM_RESERVE_MIB"
MODELS_MAX="$MODELS_MAX"
AI_UID="$AI_UID"
SECRET_ENV="$SECRET_ENV"
SHARE_STAGE="$SHARE_STAGE"

export HOME="\$AI_HOME"
export XDG_RUNTIME_DIR="/run/user/\$AI_UID"
export DBUS_SESSION_BUS_ADDRESS="unix:path=\$XDG_RUNTIME_DIR/bus"
export PATH="/usr/local/sbin:/usr/local/bin:/usr/bin:/bin"
export TERM="\${TERM:-xterm-256color}"

LLAMA_NAME=ompai-llama
SESS_DIR="\$XDG_RUNTIME_DIR/omp-ai-sessions"
ROUTER_LOCK="\$XDG_RUNTIME_DIR/omp-ai-router.lock"
mkdir -p "\$SESS_DIR"
chmod 0700 "\$SESS_DIR"

with_router_lock() {
  exec 8>"\$ROUTER_LOCK"
  flock 8
}
release_router_lock() {
  flock -u 8 || true
  exec 8>&-
}
marker_count() {
  local markers=()
  shopt -s nullglob
  markers=("\$SESS_DIR"/*.session)
  shopt -u nullglob
  (( \${#markers[@]} > 0 ))
}
stop_router_if_unused_locked() {
  if ! marker_count; then
    podman rm -f -t 10 "\$LLAMA_NAME" >/dev/null 2>&1 || true
  fi
}
router_healthy() {
  local body
  body="\$(curl -fsS "http://127.0.0.1:\$LLAMA_PORT/health" 2>/dev/null || true)"
  grep -q '"status"[[:space:]]*:[[:space:]]*"ok"' <<<"\$body"
}
start_router_locked() {
  if [[ "\$(podman inspect -f '{{.State.Running}}' "\$LLAMA_NAME" 2>/dev/null || true)" == true ]] && router_healthy; then
    return 0
  fi

  podman rm -f -t 5 "\$LLAMA_NAME" >/dev/null 2>&1 || true
  echo "[omp-ai] Starting shared llama.cpp router..."
  podman run -d --name "\$LLAMA_NAME" --replace \
    --network omp-llm --network-alias llama \
    --device nvidia.com/gpu=all \
    --memory "\$LLAMA_MEM" --cpus 20 --pids-limit 512 \
    --read-only --cap-drop ALL --security-opt no-new-privileges \
    --tmpfs /tmp:rw,nosuid,nodev,size=512m \
    --mount "type=bind,src=\$MODEL_STORE,dst=/models,ro=true,bind-nonrecursive" \
    -p "127.0.0.1:\$LLAMA_PORT:8080" \
    "\$LLAMA_IMAGE" \
      --models-dir /models --models-max "\$MODELS_MAX" --models-autoload \
      --host 0.0.0.0 --port 8080 \
      --ctx-size "\$LLAMA_CTX" --parallel "\$LLAMA_PARALLEL" \
      --cache-type-k q8_0 --cache-type-v q8_0 \
      --flash-attn auto --fit on --fit-target "\$VRAM_RESERVE_MIB" \
      --offline >/dev/null

  for _ in \$(seq 1 300); do
    router_healthy && return 0
    [[ "\$(podman inspect -f '{{.State.Running}}' "\$LLAMA_NAME" 2>/dev/null || true)" == true ]] || break
    sleep 1
  done
  podman logs --tail=120 "\$LLAMA_NAME" >&2 || true
  return 1
}

case "\${1:-}" in
  stop)
    with_router_lock
    mapfile -t agents < <(podman ps -a --format '{{.Names}}' | grep '^ompai-agent-' || true)
    (( \${#agents[@]} )) && podman rm -f -t 5 "\${agents[@]}" >/dev/null 2>&1 || true
    rm -f "\$SESS_DIR"/*.session 2>/dev/null || true
    podman rm -f -t 5 "\$LLAMA_NAME" >/dev/null 2>&1 || true
    release_router_lock
    exit 0
    ;;
  status)
    podman ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}' | { head -n1; grep -E '^ompai-(llama|agent-)' || true; }
    exit 0
    ;;
  logs)
    shift
    exec podman logs -f "\$LLAMA_NAME"
    ;;
  reap)
    age="\${2:-120}"
    now="\$(date +%s)"
    with_router_lock
    shopt -s nullglob
    for marker in "\$SESS_DIR"/*.session; do
      mt="\$(stat -c %Y "\$marker" 2>/dev/null || echo 0)"
      agent="\$(sed -n '1p' "\$marker" 2>/dev/null || true)"
      owner_pid="\$(sed -n '2p' "\$marker" 2>/dev/null || echo 0)"
      owner_start="\$(sed -n '3p' "\$marker" 2>/dev/null || echo 0)"
      current_start="\$(awk '{print \$22}' "/proc/\$owner_pid/stat" 2>/dev/null || true)"
      live=0
      [[ "\$owner_pid" != 0 && -n "\$current_start" && "\$current_start" == "\$owner_start" ]] && live=1
      if (( ! live && now-mt >= age )); then
        [[ -n "\$agent" ]] && podman rm -f -t 5 "\$agent" >/dev/null 2>&1 || true
        rm -f "\$marker"
      fi
    done

    # Remove orphaned agent containers for which no live session marker exists.
    mapfile -t known < <(for m in "\$SESS_DIR"/*.session; do head -n1 "\$m" 2>/dev/null || true; done)
    mapfile -t agents < <(podman ps -a --format '{{.Names}}' | grep '^ompai-agent-' || true)
    for agent in "\${agents[@]}"; do
      keep=0
      for known_agent in "\${known[@]}"; do [[ "\$agent" == "\$known_agent" ]] && { keep=1; break; }; done
      (( keep )) || podman rm -f -t 5 "\$agent" >/dev/null 2>&1 || true
    done
    shopt -u nullglob
    stop_router_if_unused_locked
    release_router_lock
    exit 0
    ;;
esac

workdir_rel=""
share_modes=()
share_sources=()
omp_args=()
while (( \$# )); do
  case "\$1" in
    --workdir) workdir_rel="\${2:-}"; shift 2;;
    --share) share_modes+=(rw); share_sources+=("\${2:?}"); shift 2;;
    --share-ro) share_modes+=(ro); share_sources+=("\${2:?}"); shift 2;;
    --) shift; omp_args=("\$@"); break;;
    *) omp_args+=("\$1"); shift;;
  esac
done

candidate="\$(realpath -m "\$WORKSPACE/\$workdir_rel")"
case "\$candidate" in "\$WORKSPACE"|"\$WORKSPACE"/*) ;; *) echo "Invalid workspace path" >&2; exit 2;; esac
[[ -d "\$candidate" ]] || exit 2
container_workdir=/workspace
[[ "\$candidate" != "\$WORKSPACE" ]] && container_workdir="/workspace/\${candidate#"\$WORKSPACE/"}"

share_mounts=()
declare -A used=()
first_share_dir=""
for i in "\${!share_sources[@]}"; do
  src="\$(realpath -e -- "\${share_sources[\$i]}")"
  case "\$src" in "\$SHARE_STAGE"/*) ;; *) echo "Invalid staged share path" >&2; exit 2;; esac
  base="\$(basename -- "\$src" | sed 's/^[0-9][0-9][0-9][0-9]-//')"
  name="\$base"; n=2
  while [[ -n "\${used[\$name]:-}" ]]; do name="\${base}-\$n"; ((n++)); done
  used["\$name"]=1
  dst="/shares/\$name"
  if [[ "\${share_modes[\$i]}" == ro ]]; then
    share_mounts+=(--mount "type=bind,src=\$src,dst=\$dst,ro=true,bind-nonrecursive")
  else
    share_mounts+=(--mount "type=bind,src=\$src,dst=\$dst,rw=true,bind-nonrecursive")
  fi
  [[ -z "\$first_share_dir" && -d "\$src" ]] && first_share_dir="\$dst"
done
[[ -n "\$first_share_dir" && -z "\$workdir_rel" ]] && container_workdir="\$first_share_dir"

find "\$MODEL_STORE" -type f -iname '*.gguf' -print -quit | grep -q . ||
  { echo "No models. Use: ai-model add /path/model.gguf" >&2; exit 3; }

SESSION_ID="\$(cat /proc/sys/kernel/random/uuid)"
OMP_NAME="ompai-agent-\$SESSION_ID"
MARKER="\$SESS_DIR/\$SESSION_ID.session"
HB_PID=""

cleanup(){
  rc=\$?
  trap - EXIT INT TERM HUP
  [[ -n "\$HB_PID" ]] && kill "\$HB_PID" >/dev/null 2>&1 || true
  podman rm -f -t 10 "\$OMP_NAME" >/dev/null 2>&1 || true
  with_router_lock
  rm -f "\$MARKER"
  stop_router_if_unused_locked
  release_router_lock
  exit "\$rc"
}
trap cleanup EXIT INT TERM HUP

with_router_lock
start_router_locked || { release_router_lock; exit 5; }
proc_start="\$(awk '{print \$22}' /proc/\$\$/stat 2>/dev/null || true)"
printf '%s\n%s\n%s\n' "\$OMP_NAME" "\$\$" "\$proc_start" >"\$MARKER"
release_router_lock

# Heartbeat lets the reaper distinguish a live terminal/session from stale state
# left by SIGKILL, terminal crashes, or abrupt process death.
parent_pid=\$\$
(
  while kill -0 "\$parent_pid" 2>/dev/null; do
    touch "\$MARKER" 2>/dev/null || exit 0
    sleep 20
  done
) &
HB_PID=\$!

secret_args=()
[[ -r "\$SECRET_ENV" ]] && secret_args+=(--env-file "\$SECRET_ENV")

echo "[omp-ai] Shared router ready; session \$SESSION_ID"
echo "[omp-ai] llama parallel slots: \$LLAMA_PARALLEL; model cache limit: \$MODELS_MAX"
podman run --rm -it --name "\$OMP_NAME" \
  --network omp-web --network omp-llm \
  --memory "\$OMP_MEM" --cpus 8 --pids-limit 1024 \
  --read-only --cap-drop ALL --security-opt no-new-privileges \
  --tmpfs /tmp:rw,nosuid,nodev,size=1g \
  --tmpfs /data:rw,nosuid,nodev,size=512m \
  --mount "type=bind,src=\$WORKSPACE,dst=/workspace,rw=true,bind-nonrecursive" \
  --mount "type=bind,src=\$AI_HOME/state,dst=/state,rw=true,bind-nonrecursive" \
  "\${share_mounts[@]}" "\${secret_args[@]}" \
  -e HOME=/state -e "TERM=\$TERM" -e LLAMA_CPP_BASE_URL=http://llama:8080 \
  -w "\$container_workdir" localhost/omp:latest cli "\${omp_args[@]}"
EOF
root chmod 0755 "$INNER"

# ---------- public omp-ai wrapper ----------
PUBLIC="/usr/local/bin/omp-ai"
root tee "$PUBLIC" >/dev/null <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
INNER="$INNER"
SHARE_HELPER="$SHARE_HELPER"
WORKSPACE="$WORKSPACE"
AI_USER="$AI_USER"

case "\${1:-}" in
  stop)
    sudo -n -u "\$AI_USER" "\$INNER" stop
    sudo -n "\$SHARE_HELPER" cleanup-stale 0 >/dev/null 2>&1 || true
    exit 0
    ;;
  status|logs)
    exec sudo -n -u "\$AI_USER" "\$INNER" "\$@"
    ;;
esac

pwd_real="\$(realpath -m "\$PWD")"
rel=""
case "\$pwd_real" in "\$WORKSPACE") rel="";; "\$WORKSPACE"/*) rel="\${pwd_real#"\$WORKSPACE/"}";; esac

modes=(); paths=(); omp_args=()
while (( \$# )); do
  case "\$1" in
    --share) modes+=(rw); paths+=("\${2:?--share needs FILE_OR_DIR}"); shift 2;;
    --share-ro) modes+=(ro); paths+=("\${2:?--share-ro needs FILE_OR_DIR}"); shift 2;;
    --) shift; omp_args+=("\$@"); break;;
    *) omp_args+=("\$1"); shift;;
  esac
done

if (( \${#paths[@]} == 0 )); then
  exec sudo -n -u "\$AI_USER" "\$INNER" --workdir "\$rel" -- "\${omp_args[@]}"
fi

sid="\$(sudo -n "\$SHARE_HELPER" begin)"
child=""
share_hb=""
cleanup(){
  rc=\$?
  trap - EXIT INT TERM HUP
  [[ -n "\$share_hb" ]] && kill "\$share_hb" >/dev/null 2>&1 || true
  [[ -n "\$child" ]] && kill -0 "\$child" 2>/dev/null && kill -TERM "\$child" 2>/dev/null || true
  [[ -n "\$child" ]] && wait "\$child" 2>/dev/null || true
  sudo -n "\$SHARE_HELPER" cleanup "\$sid" >/dev/null 2>&1 || true
  exit "\$rc"
}
trap cleanup EXIT INT TERM HUP

inner_shares=()
for i in "\${!paths[@]}"; do
  staged="\$(sudo -n "\$SHARE_HELPER" grant "\$sid" "\${modes[\$i]}" "\${paths[\$i]}")"
  [[ "\${modes[\$i]}" == ro ]] && inner_shares+=(--share-ro "\$staged") || inner_shares+=(--share "\$staged")
done

set +e
sudo -n -u "\$AI_USER" "\$INNER" --workdir "\$rel" "\${inner_shares[@]}" -- "\${omp_args[@]}" &
child=\$!
child_start="\$(awk '{print \$22}' "/proc/\$child/stat" 2>/dev/null || true)"
sudo -n "\$SHARE_HELPER" attach "\$sid" "\$child" "\$child_start" >/dev/null
(
  while kill -0 "\$child" 2>/dev/null; do
    sudo -n "\$SHARE_HELPER" heartbeat "\$sid" >/dev/null 2>&1 || exit 0
    sleep 20
  done
) &
share_hb=\$!
wait "\$child"; rc=\$?; child=""
set -e
exit "\$rc"
EOF
root chmod 0755 "$PUBLIC"

# ---------- model manager ----------
MODEL_HELPER="/usr/local/libexec/omp-ai-model"
root tee "$MODEL_HELPER" >/dev/null <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
STORE="$MODEL_STORE"
AI_USER="$AI_USER"
AI_GID="$AI_GID"
MAIN_USER="$MAIN_USER"
cmd="\${1:-help}"; shift || true

idle(){
  runuser -u "\$AI_USER" -- env HOME="$AI_HOME" XDG_RUNTIME_DIR="/run/user/$AI_UID" \
    podman ps --format '{{.Names}}' 2>/dev/null | grep -Eq '^ompai-(agent-|llama$)' &&
    { echo "Stop omp-ai before changing models" >&2; exit 3; } || true
}
validate(){
  local src="\$1" f found=0
  runuser -u "\$MAIN_USER" -- test -r "\$src" || return 1
  if [[ -f "\$src" ]]; then
    [[ "\${src,,}" == *.gguf && "\$(runuser -u "\$MAIN_USER" -- head -c4 "\$src")" == GGUF ]]
    return
  fi
  [[ -d "\$src" ]] || return 1
  find "\$src" -type l -print -quit | grep -q . && return 1
  while IFS= read -r -d '' f; do found=1; [[ "\$(runuser -u "\$MAIN_USER" -- head -c4 "\$f")" == GGUF ]] || return 1; done \
    < <(find "\$src" -type f -iname '*.gguf' -print0)
  (( found ))
}
install_one(){
  local mode="\$1" raw="\$2" src name dest tmp
  src="\$(realpath -e -- "\$raw")"
  validate "\$src" || { echo "Invalid/unreadable GGUF source: \$raw" >&2; exit 2; }
  name="\$(basename "\$src")"; dest="\$STORE/\$name"
  [[ ! -e "\$dest" || "\$mode" == replace ]] || { echo "Exists: \$name; use replace" >&2; exit 2; }
  [[ "\$mode" == replace ]] && rm -rf -- "\$dest"
  tmp="\$STORE/.import-\$name.\$\$"; rm -rf "\$tmp"
  [[ -f "\$src" ]] && cp --reflink=auto --sparse=always "\$src" "\$tmp" || cp -a --reflink=auto "\$src" "\$tmp"
  chown -R root:"\$AI_GID" "\$tmp"
  [[ -d "\$tmp" ]] && { find "\$tmp" -type d -exec chmod 0550 {} +; find "\$tmp" -type f -exec chmod 0440 {} +; } || chmod 0440 "\$tmp"
  mv "\$tmp" "\$dest"; echo "Installed: \$name"
}
case "\$cmd" in
  add|replace) idle; (( \$# )) || exit 2; for x in "\$@"; do install_one "\$cmd" "\$x"; done;;
  remove|rm) idle; for n in "\$@"; do [[ "\$n" != */* ]] || exit 2; rm -rf -- "\$STORE/\$n"; done;;
  list|ls) find "\$STORE" -mindepth 1 -maxdepth 1 ! -name '.import-*' -printf '%f\n' | sort;;
  path) echo "\$STORE";;
  *) echo "Usage: ai-model {add|replace|remove|list|path} ..." ;;
esac
EOF
root chmod 0755 "$MODEL_HELPER"

root tee /usr/local/bin/ai-model >/dev/null <<EOF
#!/usr/bin/env bash
exec sudo -n "$MODEL_HELPER" "\$@"
EOF
root chmod 0755 /usr/local/bin/ai-model

# ---------- ai-give ----------
root tee /usr/local/bin/ai-give >/dev/null <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
(( \$# )) || { echo "Usage: ai-give FILE_OR_DIR [...]" >&2; exit 2; }
for src in "\$@"; do
  src="\$(realpath -e "\$src")"
  base="\$(basename "\$src")"
  dest="$WORKSPACE/\$base"
  if [[ -d "\$src" && ! -L "\$src" ]]; then mkdir -p "\$dest"; rsync -rlE --safe-links "\$src/" "\$dest/"
  else rsync -lE --safe-links "\$src" "$WORKSPACE/"; fi
  setfacl -R -m "u:$AI_USER:rwX,u:$MAIN_USER:rwX,g:$SHARE_GROUP:rwX,m:rwX" "\$dest" 2>/dev/null || true
  echo "Added: \$dest"
done
EOF
root chmod 0755 /usr/local/bin/ai-give

# ---------- sudoers ----------
root tee /etc/sudoers.d/omp-ai >/dev/null <<EOF
$MAIN_USER ALL=($AI_USER) NOPASSWD: $INNER *
$MAIN_USER ALL=(root) NOPASSWD: $MODEL_HELPER *
$MAIN_USER ALL=(root) NOPASSWD: $SHARE_HELPER *
EOF
root chmod 0440 /etc/sudoers.d/omp-ai
root visudo -cf /etc/sudoers.d/omp-ai >/dev/null

# ---------- crash reaper ----------
REAPER="/usr/local/libexec/omp-ai-reap"
root tee "$REAPER" >/dev/null <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
AI_USER="$AI_USER"
AI_HOME="$AI_HOME"
AI_UID="$AI_UID"
INNER="$INNER"
SHARE_HELPER="$SHARE_HELPER"

runuser -u "\$AI_USER" -- env \
  HOME="\$AI_HOME" USER="\$AI_USER" LOGNAME="\$AI_USER" \
  XDG_RUNTIME_DIR="/run/user/\$AI_UID" \
  DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/\$AI_UID/bus" \
  PATH=/usr/local/sbin:/usr/local/bin:/usr/bin:/bin \
  "\$INNER" reap 120 >/dev/null 2>&1 || true

# Direct-share wrapper has its own heartbeat. Three minutes without one means
# the owning terminal/wrapper disappeared; restore its ACLs and unmount staging.
"\$SHARE_HELPER" cleanup-stale 180 >/dev/null 2>&1 || true
EOF
root chmod 0755 "$REAPER"
root tee /etc/systemd/system/omp-ai-reaper.service >/dev/null <<EOF
[Unit]
Description=Reap orphaned local AI containers and direct shares
After=user@${AI_UID}.service
[Service]
Type=oneshot
ExecStart=$REAPER
EOF
root tee /etc/systemd/system/omp-ai-reaper.timer >/dev/null <<'EOF'
[Timer]
OnBootSec=2min
OnUnitActiveSec=2min
AccuracySec=30s
Persistent=true
[Install]
WantedBy=timers.target
EOF
root systemctl daemon-reload
root systemctl enable --now omp-ai-reaper.timer

mapfile -t _old_agents < <(as_ai podman ps -a --format '{{.Names}}' | grep '^ompai-agent-' || true)
(( ${#_old_agents[@]} )) && as_ai podman rm -f -t 5 "${_old_agents[@]}" >/dev/null 2>&1 || true
as_ai podman rm -f -t 5 ompai-agent ompai-llama >/dev/null 2>&1 || true
as_ai rm -rf "$AI_RUNTIME/omp-ai-sessions" >/dev/null 2>&1 || true
root "$SHARE_HELPER" cleanup-stale 0 >/dev/null 2>&1 || true

echo
ok "Setup complete"
echo "Workspace:       $WORKSPACE"
echo "Model store:    $MODEL_STORE"
echo "Model instances: $MODELS_MAX"
echo "Llama slots:     $LLAMA_PARALLEL"
echo
echo "Examples:"
echo "  ai-model add ~/Downloads/model.gguf"
echo "  omp-ai"
echo "  omp-ai --share ~/code/project"
echo "  omp-ai --share-ro ~/Documents/reference.pdf"
