#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# Standalone benchmark only. NEVER invokes omp-ai/setup, modifies host ACLs,
# rewrites OMP files, touches workbench, or removes containers other than its own.
# Run from the desktop account, not as root.

log() { printf '[bench] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }
usage() {
  cat <<'EOF'
Standalone GGUF speed benchmark; never changes OMP, model files or ACLs.
Usage:
  bash benchmark-llama-configs.sh --gpu-check
  bash benchmark-llama-configs.sh --check-paths \
    --model /absolute/model.gguf:/absolute/compatible-mtp-draft.gguf
  bash benchmark-llama-configs.sh \
    --model /mnt/shared/AI_MODELS/Qwen3.6-35B-A3B-Q4_K_M.gguf \
    --model /mnt/shared/AI_MODELS/Qwen3.8-27B-Q4_K_M.gguf:/var/lib/ompai/drafts/mtp-Qwen3.8-27B-Q4_0.gguf \
    --tokens 1024

Required for model tests:
  --model ABSOLUTE_GGUF[:ABSOLUTE_MTP_DRAFT_GGUF]  Repeatable; no fixed model names.
  Colon separates paths; literal ':' in filenames is unsupported.
  Without a draft, run only ordinary decoding. With a draft, run ordinary
  decoding + MTP for each specified n_max/profile. You must provide a
  COMPATIBLE MTP draft; the script cannot validate draft architecture ahead
  of loading it. It never reuses a draft for another model automatically.

Profile controls (all optional):
  --profile CONTEXT:KV_K[:KV_V]  Repeatable. Defaults: 32768:f16,
                                 32768:q8_0, 65536:q8_0
  --mtp-n-max 4,8,12,16         Comma-separated values (default shown).
  --mtp-p-min 0.8               Default 0.8.
  --draft-kv q4_0               Draft K/V cache quantization (default q4_0).
  --draft-ngl all               Draft GPU layers (default all).
  --tokens 256                  Generated tokens per scenario.
  --seed 42                     Request seed.
  --prompt-file FILE            Plain UTF-8 input prompt.
  --load-timeout 600            Server startup timeout in seconds.
  --request-timeout 900         Completion timeout in seconds.
  --llama-memory 22g            Podman memory cap.
  --image IMAGE                 Installed llama.cpp server image (never pull).
  --port 18081                  Host localhost port.
  --ai-user ompai               Dedicated rootless Podman user.
  --output NEW_DIR              Unique output directory (never overwritten).
  --gpu-check                   Only hardened NVIDIA CDI GPU check.
  --check-paths                 Only inspect all specified GGUF paths/ACLs.

All combinations are generated from --model, --profile and --mtp-n-max.
No architecture/name-specific presets or speculative drafts are hardcoded.
Results: CSV, summary, response JSON, GPU samples, logs and diagnostics.
EOF
}
if [[ "${1:-}" == '--help' || "${1:-}" == '-h' ]]; then usage; exit 0; fi
(( EUID != 0 )) || die 'Run as a desktop user, not root.'
for x in sudo python3 curl nvidia-smi awk grep readlink date; do
  command -v "$x" >/dev/null 2>&1 || die "Missing command: $x"
done

AI_USER=ompai
LLAMA_IMAGE='ghcr.io/ggml-org/llama.cpp:server-cuda'
PORT=18081
TOKENS=256
SEED=42
LOAD_TIMEOUT=600
REQUEST_TIMEOUT=900
LLAMA_MEMORY='22g'
MTP_P_MIN='0.8'
DRAFT_KV='q4_0'
DRAFT_NGL='all'
MTP_N_MAX='4,8,12,16'
PROMPT_FILE=''
GPU_CHECK_ONLY=0
PATH_CHECK_ONLY=0
OUTDIR=''
MODELS=()
DRAFTS=()
RAW_MODELS=()
PROFILES=()
while (($#)); do
  case "$1" in
    --model|--profile|--mtp-n-max|--mtp-p-min|--draft-kv|--draft-ngl|--tokens|--seed|--prompt-file|--output|--image|--port|--ai-user|--llama-memory|--load-timeout|--request-timeout)
      key="$1"; shift
      (($#)) || die "Missing argument for $key"
      case "$key" in
        --model) RAW_MODELS+=("$1") ;;
        --profile) PROFILES+=("$1") ;;
        --mtp-n-max) MTP_N_MAX="$1" ;;
        --mtp-p-min) MTP_P_MIN="$1" ;;
        --draft-kv) DRAFT_KV="$1" ;;
        --draft-ngl) DRAFT_NGL="$1" ;;
        --tokens) TOKENS="$1" ;;
        --seed) SEED="$1" ;;
        --prompt-file) PROMPT_FILE="$1" ;;
        --output) OUTDIR="$1" ;;
        --image) LLAMA_IMAGE="$1" ;;
        --port) PORT="$1" ;;
        --ai-user) AI_USER="$1" ;;
        --llama-memory) LLAMA_MEMORY="$1" ;;
        --load-timeout) LOAD_TIMEOUT="$1" ;;
        --request-timeout) REQUEST_TIMEOUT="$1" ;;
      esac
      shift ;;
    --gpu-check) GPU_CHECK_ONLY=1; shift ;;
    --check-paths) PATH_CHECK_ONLY=1; shift ;;
    --bench-cdi-no-ldcache) die '--bench-cdi-no-ldcache is obsolete; use standard NVIDIA CDI (omit this flag).' ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown flag: $1" ;;
  esac
done
(( !(GPU_CHECK_ONLY && PATH_CHECK_ONLY) )) || die 'Choose only one of --gpu-check and --check-paths.'
if (( ! GPU_CHECK_ONLY )); then
  ((${#RAW_MODELS[@]})) || die 'Supply at least one --model /absolute/model.gguf[:/absolute/draft.gguf].'
fi
# No hardcoded model filename or model path. Colon is the optional draft separator.
declare -A SEEN_PAIRS=()
for raw in "${RAW_MODELS[@]}"; do
  model="$raw"; draft=''
  if [[ "$raw" == *:* ]]; then
    model="${raw%%:*}"
    draft="${raw#*:}"
    [[ "$draft" != *:* ]] || die "Only one ':' separator allowed in --model: $raw"
  fi
  [[ "$model" = /* && "$model" == *.gguf && "$model" != *$'\n'* ]] || die "Model must be an absolute GGUF path: $model"
  if [[ -n "$draft" ]]; then
    [[ "$draft" = /* && "$draft" == *.gguf && "$draft" != *$'\n'* ]] || die "Draft must be an absolute GGUF path: $draft"
    [[ "$draft" != "$model" ]] || die "A model cannot be its own MTP draft: $model"
  elif [[ "$raw" == *:* ]]; then
    die "Empty draft path in $raw"
  fi
  [[ ! -v 'SEEN_PAIRS[$raw]' ]] || die "Duplicate --model entry: $raw"
  SEEN_PAIRS["$raw"]=1
  MODELS+=("$model"); DRAFTS+=("$draft")
done
((${#PROFILES[@]})) || PROFILES=('32768:f16' '32768:q8_0' '65536:q8_0')
# Normalize profiles into an array of context|KV-K|KV-V triples.
PROFILE_SPECS=(); declare -A SEEN_PROFILES=()
for profile in "${PROFILES[@]}"; do
  [[ "$profile" =~ ^([0-9]+):([A-Za-z0-9_]+)(:([A-Za-z0-9_]+))?$ ]] || die "Invalid --profile: $profile"
  ctx="${BASH_REMATCH[1]}"; kvk="${BASH_REMATCH[2]}"; kvv="${BASH_REMATCH[4]:-${BASH_REMATCH[2]}}"
  (( 10#$ctx >= 1024 )) || die "Profile context must be >=1024: $profile"
  for kv in "$kvk" "$kvv"; do
    [[ "$kv" =~ ^(f32|f16|bf16|q8_0|q4_0|q4_1|iq4_nl|q5_0|q5_1)$ ]] || die "Unsupported KV type: $kv"
  done
  key="$ctx:$kvk:$kvv"; [[ ! -v 'SEEN_PROFILES[$key]' ]] || die "Duplicate profile: $profile"
  SEEN_PROFILES["$key"]=1
  PROFILE_SPECS+=("$ctx|$kvk|$kvv")
done
[[ "$MTP_N_MAX" =~ ^[0-9]+(,[0-9]+)*$ ]] || die 'Invalid comma-separated --mtp-n-max list'
IFS=',' read -r -a N_MAX_VALUES <<<"$MTP_N_MAX"
((${#N_MAX_VALUES[@]})) || die '--mtp-n-max needs at least one value'
declare -A SEEN_N=()
for n in "${N_MAX_VALUES[@]}"; do
  [[ "$n" =~ ^([1-9]|[12][0-9]|3[012])$ ]] || die "Invalid MTP n_max: $n"
  [[ ! -v 'SEEN_N[$n]' ]] || die "Duplicate MTP n_max: $n"
  SEEN_N["$n"]=1
done
[[ "$MTP_P_MIN" =~ ^(0([.][0-9]+)?|1([.]0+)?)$ ]] || die '--mtp-p-min must be 0..1'
[[ "$DRAFT_KV" =~ ^(f32|f16|bf16|q8_0|q4_0|q4_1|iq4_nl|q5_0|q5_1)$ ]] || die 'Invalid --draft-kv'
[[ "$DRAFT_NGL" == all || "$DRAFT_NGL" == auto || "$DRAFT_NGL" =~ ^[0-9]+$ ]] || die 'Invalid --draft-ngl'
for v in PORT TOKENS SEED LOAD_TIMEOUT REQUEST_TIMEOUT; do
  [[ "${!v}" =~ ^[0-9]+$ ]] || die "$v must be an integer"
done
(( PORT >= 1024 && PORT <= 65535 && TOKENS >= 16 && LOAD_TIMEOUT >= 10 && REQUEST_TIMEOUT >= 10 )) || die 'Invalid port/tokens/timeout limits.'
[[ "$LLAMA_MEMORY" =~ ^[0-9]+[kKmMgG]?$ ]] || die '--llama-memory expects a size such as 22g'
[[ -z "$PROMPT_FILE" || -f "$PROMPT_FILE" ]] || die "Prompt file not found: $PROMPT_FILE"
AI_UID="$(id -u "$AI_USER")" || die 'Account ompai not found.'
AI_HOME="$(getent passwd "$AI_USER" | cut -d: -f6)"
[[ -n "$AI_HOME" && -d "$AI_HOME" ]] || die 'Cannot determine isolated user HOME'
XDG_RUNTIME_DIR="/run/user/$AI_UID"
BUS="unix:path=$XDG_RUNTIME_DIR/bus"
CONTAINER="ompai-bench-${AI_UID}-$$"

# Run in the actual ompai rootless context (never root's or sam's Podman).
pctl() {
  sudo -n -u "$AI_USER" \
    env HOME="$AI_HOME" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" DBUS_SESSION_BUS_ADDRESS="$BUS" \
    bash -c 'cd "$HOME" && exec podman "$@"' _ "$@"
}

log 'Requesting sudo authorization once; no privileged configuration changes.'
sudo -v
sudo -n -u "$AI_USER" id -u >/dev/null || die 'Cannot execute read-only checks as ompai with current sudo authorization.'
( while sleep 25; do sudo -n -v >/dev/null 2>&1 || exit; done ) &
KEEPALIVE_PID=$!
GPU_PID=''
BENCH_CONTAINER_ATTEMPTED=0
HOOK_DIR=''
HOOK_FILES=()
HOOK_ANNOTATIONS=()
cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  if [[ -n "$GPU_PID" ]]; then kill "$GPU_PID" 2>/dev/null || :; wait "$GPU_PID" 2>/dev/null || :; fi
  # Unique per-run container name. Never --replace; never touches ompai-llama.
  if (( BENCH_CONTAINER_ATTEMPTED )); then
    pctl rm -f -t 5 "$CONTAINER" >/dev/null 2>&1 || :
  fi
  # Only our unique tmp files under /run/user/$AI_UID, never the CDI spec or OMP data.
  if ((${#HOOK_FILES[@]})); then
    sudo -n -u "$AI_USER" rm -f -- "${HOOK_FILES[@]}" >/dev/null 2>&1 || :
  fi
  if [[ -n "${HOOK_DIR:-}" ]]; then
    sudo -n -u "$AI_USER" rmdir -- "$HOOK_DIR" >/dev/null 2>&1 || :
  fi
  kill "$KEEPALIVE_PID" 2>/dev/null || :
  wait "$KEEPALIVE_PID" 2>/dev/null || :
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ -z "$OUTDIR" ]]; then
  OUTDIR="$PWD/llama-bench-$(date +%Y%m%d-%H%M%S)-$$"
fi
[[ ! -e "$OUTDIR" ]] || die "Refusing to reuse existing output directory: $OUTDIR"
mkdir -m 700 -p -- "$OUTDIR"
OUTDIR="$(cd -- "$OUTDIR" && pwd -P)"
RESULTS="$OUTDIR/results.csv"
SUMMARY="$OUTDIR/summary.txt"
DIAG="$OUTDIR/diagnostics"
mkdir -m 700 -- "$DIAG"

# crun can redirect OCI hook stdout/stderr to host files. This is not a security
# relaxation: Podman stays rootless, the exact hardened options remain intact,
# and only short-lived private files in ompai's runtime dir are created.
# In particular, Podman's --log-level=debug alone loses the hook's stderr.
HOOK_DIR="$(sudo -n -u "$AI_USER" mktemp -d -- "$XDG_RUNTIME_DIR/ompai-bench-hooks.XXXXXXXX")" || \
  die "Cannot create private temporary OCI hook log directory in $XDG_RUNTIME_DIR"
set_hook_capture() { # label; fills HOOK_ANNOTATIONS
  local label="$1" out="$HOOK_DIR/$1.stdout" err="$HOOK_DIR/$1.stderr"
  HOOK_FILES+=("$out" "$err")
  HOOK_ANNOTATIONS=(
    --annotation "run.oci.hooks.stdout=$out"
    --annotation "run.oci.hooks.stderr=$err"
  )
}
save_hook_capture() { # label destination_prefix
  local label="$1" destination="$2" kind src
  for kind in stdout stderr; do
    src="$HOOK_DIR/$label.$kind"
    if sudo -n -u "$AI_USER" test -f "$src"; then
      sudo -n -u "$AI_USER" cat -- "$src" >"$destination.hooks.$kind" 2>&1 || :
    else
      printf 'No OCI hooks %s file was created by crun.\n' "$kind" >"$destination.hooks.$kind"
    fi
  done
}

capture() { # capture FILE COMMAND... and explicit exit status
  local dest="$1" rc; shift
  {
    printf '$'; printf ' %q' "$@"; printf '\n'
    if "$@"; then
      printf 'EXIT_STATUS=0\n'
    else
      rc=$?
      printf 'EXIT_STATUS=%s\n' "$rc"
    fi
  } >"$dest" 2>&1
}
collect_diagnostics() {
  log "Collecting READ-ONLY NVIDIA/CDI diagnostics in $DIAG"
  capture "$DIAG/host-nvidia-smi.txt" nvidia-smi -L
  capture "$DIAG/nvidia-smi-query.txt" nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv
  capture "$DIAG/nvidia-ctk-list.txt" sudo -n nvidia-ctk --debug cdi list
  capture "$DIAG/nvidia-ctk-version.txt" nvidia-ctk --version
  capture "$DIAG/cdi-refresh-journal.txt" sudo -n journalctl -u nvidia-cdi-refresh.service -b --no-pager -n 100
  capture "$DIAG/cdi-refresh-status.txt" sudo -n systemctl status --no-pager nvidia-cdi-refresh.service nvidia-cdi-refresh.path
  capture "$DIAG/podman-info.txt" pctl info --format json
  capture "$DIAG/podman-version.txt" pctl version
  capture "$DIAG/ompai-id.txt" sudo -n -u "$AI_USER" id
  capture "$DIAG/cdi-spec-files.txt" sudo -n ls -ld /etc/cdi /var/run/cdi /etc/cdi/nvidia.yaml /var/run/cdi/nvidia.yaml
  capture "$DIAG/devices.txt" sudo -n ls -l /dev/nvidia0 /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools
  capture "$DIAG/nvidia-packages.txt" pacman -Q nvidia-container-toolkit libnvidia-container nvidia-utils nvidia-open nvidia-dkms
  capture "$DIAG/legacy-oci-hook.txt" sudo -n ls -l /usr/share/containers/oci/hooks.d/oci-nvidia-hook.json /etc/containers/oci/hooks.d/oci-nvidia-hook.json
  capture "$DIAG/nvidia-cdi-spec-hooks.txt" sudo -n grep -nE 'hookName:|nvidia-cdi-hook|update-ldcache|update-ldconfig|update-application-profile|name:' /var/run/cdi/nvidia.yaml /etc/cdi/nvidia.yaml
  # Local excerpt of the generated hook definitions; never edit/regen this file.
  capture "$DIAG/nvidia-cdi-hooks-excerpt.txt" sudo -n sed -n '280,335p' /var/run/cdi/nvidia.yaml
  capture "$DIAG/nvidia-cdi-hook-version.txt" nvidia-cdi-hook --version
  capture "$DIAG/userns.txt" pctl unshare cat /proc/self/uid_map
}

record_path_diagnostics() { # host filename and diagnostic identifier
  local f="$1" label="$2"
  capture "$DIAG/$label.namei.txt" sudo -n namei -l -- "$f"
  # Capture named ACLs for ALL ancestor directories, not just the direct parent.
  # Use an array to handle directories with spaces correctly.
  local parent
  local -a ancestors=("$f")
  parent="$(dirname -- "$f")"
  while [[ "$parent" != / ]]; do
    ancestors+=("$parent")
    parent="$(dirname -- "$parent")"
  done
  capture "$DIAG/$label.acl.txt" sudo -n getfacl -p -- "${ancestors[@]}"
  capture "$DIAG/$label.mount.txt" findmnt -T "$f" -o TARGET,SOURCE,FSTYPE,OPTIONS
  capture "$DIAG/$label.as-ompai.txt" sudo -n -u "$AI_USER" test -r "$f"
  capture "$DIAG/$label.stat-host.txt" sudo -n stat -Lc '%A %a %U:%G %n' "$f"
  capture "$DIAG/$label.stat-ompai.txt" sudo -n -u "$AI_USER" stat -Lc '%A %a %U:%G %n' "$f"
  capture "$DIAG/$label.userns-stat.txt" pctl unshare stat -Lc '%A %a %U:%G %n' "$f"
  capture "$DIAG/$label.open-ompai.txt" sudo -n -u "$AI_USER" dd "if=$f" of=/dev/null bs=1 count=1 status=none
}

# Read-only verification for each explicitly named model/draft. No chmod/setfacl.
MODEL_STATUS=()
DRAFT_STATUS=()
check_single_path() { # file, label; prints resolved path or diagnostic status
  local src="$1" label="$2" resolved
  if ! sudo -n test -f "$src"; then
    printf '%s\n' 'file-missing'; return 1
  fi
  if ! sudo -n -u "$AI_USER" test -r "$src" || \
     ! sudo -n -u "$AI_USER" dd "if=$src" of=/dev/null bs=1 count=1 status=none >/dev/null 2>&1; then
    printf '%s\n' 'unreadable-by-ai-user'; return 1
  fi
  resolved="$(sudo -n -u "$AI_USER" readlink -e -- "$src" 2>/dev/null || :)"
  if [[ -z "$resolved" ]]; then printf '%s\n' 'unresolvable-by-ai-user'; return 1; fi
  printf '%s\n' "$resolved"
}
check_model_paths() {
  local i src resolved result errors=0
  for i in "${!MODELS[@]}"; do
    src="${MODELS[$i]}"
    if resolved="$(check_single_path "$src" "model-$i")"; then
      MODELS[$i]="$resolved"; MODEL_STATUS[$i]=''
      log "Model $i: accessible ($src)"
    else
      MODEL_STATUS[$i]="model-$resolved"; errors=$((errors+1))
      log "Model $i: ${MODEL_STATUS[$i]}: $src"
      record_path_diagnostics "$src" "model-$i"
    fi
    src="${DRAFTS[$i]}"
    if [[ -n "$src" ]]; then
      if result="$(check_single_path "$src" "draft-$i")"; then
        DRAFTS[$i]="$result"; DRAFT_STATUS[$i]=''
        log "Draft $i: accessible ($src)"
      else
        DRAFT_STATUS[$i]="draft-$result"; errors=$((errors+1))
        log "Draft $i: ${DRAFT_STATUS[$i]}: $src"
        record_path_diagnostics "$src" "draft-$i"
      fi
    else
      DRAFT_STATUS[$i]=''
    fi
    if (( PATH_CHECK_ONLY )) && [[ -z "${MODEL_STATUS[$i]}" ]]; then
      record_path_diagnostics "${MODELS[$i]}" "model-$i"
    fi
    if (( PATH_CHECK_ONLY )) && [[ -n "${DRAFTS[$i]}" && -z "${DRAFT_STATUS[$i]}" ]]; then
      record_path_diagnostics "${DRAFTS[$i]}" "draft-$i"
    fi
  done
  (( errors == 0 ))
}

# --check-paths never creates a GPU or llama container; only emits read-only
# authorization and mount/ACL diagnostics. A normal full suite also checks
# paths once before GPU startup. --gpu-check remains GPU-only.
if (( ! GPU_CHECK_ONLY )); then
  if ! check_model_paths; then
    if (( PATH_CHECK_ONLY )); then
      die "Model/draft access check failed; inspect read-only diagnostics in $DIAG"
    fi
    log 'Some models/draft are inaccessible: affected tests will be skipped; independent tests will still run.'
  fi
fi
if (( PATH_CHECK_ONLY )); then
  log "All model and draft paths are readable by ompai. Details: $DIAG"
  exit 0
fi

collect_diagnostics

# GPU test is still a *hardened*, isolated, short-lived rootless container.
# No relaxed fallback: failures must be diagnosed, not hidden by fewer safeguards.
pctl image exists "$LLAMA_IMAGE" >/dev/null 2>&1 || die "Image not present in ompai rootless storage: $LLAMA_IMAGE (no download attempted)."
if ! nvidia-smi -L >"$DIAG/host-driver-check.txt" 2>&1; then
  log 'Host NVIDIA driver check failed (see host-driver-check.txt).'
  die "GPU unavailable on host; diagnostics: $DIAG"
fi
log 'Checking hardened rootless NVIDIA CDI (with separate crun OCI hook stderr capture)...'
GPU_PROBE_LOG="$DIAG/gpu-preflight-debug.log"
set_hook_capture gpu-preflight
if ! pctl --log-level=debug run --rm --pull=never --network none \
    "${HOOK_ANNOTATIONS[@]}" \
    --device nvidia.com/gpu=all --read-only --cap-drop ALL \
    --security-opt no-new-privileges \
    --tmpfs /tmp:rw,nosuid,nodev,size=128m \
    --entrypoint /bin/sh "$LLAMA_IMAGE" -c \
    'test -e /dev/nvidiactl && test -e /dev/nvidia0 && nvidia-smi -L && echo "NVIDIA devices and NVML operational"' \
    >"$GPU_PROBE_LOG" 2>&1; then
  save_hook_capture gpu-preflight "$DIAG/gpu-preflight"
  log 'NVIDIA CDI preflight FAILED. The model benchmark has NOT started.'
  log 'OCI hook stderr (from crun; critical for identifying actual cause):'
  tail -80 "$DIAG/gpu-preflight.hooks.stderr" >&2 || :
  tail -20 "$GPU_PROBE_LOG" >&2 || :
  if grep -Eqi 'nvidia-cdi-hook|createContainer hook|OCI runtime error' "$GPU_PROBE_LOG"; then
    log 'Container OCI/CDI hook failure: inspect toolkit version, CDI hooks, and rootless namespace diagnostics.'
    log 'Read gpu-preflight.hooks.stderr for the precise NVIDIA hook failure.'
  fi
  die "Detailed diagnostics: $DIAG (no host settings changed)"
fi
save_hook_capture gpu-preflight "$DIAG/gpu-preflight"
log 'Hardened rootless CDI preflight PASSED.'
if (( GPU_CHECK_ONLY )); then
  log "GPU-only check complete. Diagnostics: $DIAG"
  exit 0
fi

# Never interfere with a live OMP inference container. Do not stop it for user.
if [[ "$(pctl inspect -f '{{.State.Running}}' ompai-llama 2>/dev/null || :)" == true ]]; then
  die 'Existing OMP llama is RUNNING: benchmark not started. Nothing was stopped or replaced.'
fi
if pctl container exists "$CONTAINER" >/dev/null 2>&1; then
  die "Unexpected existing container with benchmark name $CONTAINER: refusing to touch it."
fi
if ! python3 - "$PORT" <<'PY'
import socket,sys
s=socket.socket()
try: s.bind(('127.0.0.1',int(sys.argv[1])))
except OSError as e:
    print(f'Port already in use: {e}',file=sys.stderr);sys.exit(1)
finally: s.close()
PY
then
  die "Port 127.0.0.1:$PORT is unavailable. Choose --port."
fi

# Ask actual image for supported CLI options; do not assume image tag == fixed binary version.
HELP="$DIAG/llama-server-help.txt"
if ! pctl run --rm --pull=never --network none --read-only --cap-drop ALL \
    --security-opt no-new-privileges \
    --tmpfs /tmp:rw,nosuid,nodev,size=128m \
    "$LLAMA_IMAGE" --help >"$HELP" 2>&1; then
  die "Cannot run installed llama-server --help; see $HELP"
fi
for opt in --model --ctx-size --cache-type-k --cache-type-v --metrics --offline --fit --fit-target --cache-ram --flash-attn --parallel --cont-batching --kv-unified --log-verbosity; do
  grep -Fq -- "$opt" "$HELP" || die "Installed llama-server lacks $opt (see $HELP)."
done
MTP_AVAILABLE=1
for opt in --spec-type --spec-draft-model --spec-draft-n-max --spec-draft-ngl --spec-draft-p-min --cache-type-k-draft --cache-type-v-draft; do
  if ! grep -Fq -- "$opt" "$HELP"; then MTP_AVAILABLE=0; log "MTP option unavailable: $opt"; fi
done

# Generic, architecture-independent matrix. MTP runs only if that model has a
# user-supplied draft. No hidden relation between model filename and draft.
TESTS=()
for idx in "${!MODELS[@]}"; do
  for pidx in "${!PROFILE_SPECS[@]}"; do
    IFS='|' read -r ctx kvk kvv <<<"${PROFILE_SPECS[$pidx]}"
    name="m${idx}-p${pidx}-base"
    TESTS+=("$name|$idx|$ctx|$kvk|$kvv|none|0")
    if [[ -n "${DRAFTS[$idx]}" ]]; then
      for n in "${N_MAX_VALUES[@]}"; do
        TESTS+=("m${idx}-p${pidx}-mtp${n}|$idx|$ctx|$kvk|$kvv|mtp|$n")
      done
    fi
  done
done
printf 'test,model,model_path,draft,draft_path,ctx,kv_k,kv_v,spec,n_max,n_max_reported,decode_tps,prefill_tps,tokens,draft_generated,draft_accepted,acceptance,gpu_avg_pct,power_avg_w,vram_peak_mib,status\n' >"$RESULTS"
log "Suite: ${#TESTS[@]} tests, $TOKENS output tokens each; output $OUTDIR"
log 'No OMP settings, existing containers, sessions or persistent workbench will be changed.'

DEFAULT_PROMPT='Write a detailed technical explanation of Linux scheduler design, page tables, filesystems, process isolation, memory allocators, virtual machines and synchronization. Give specific mechanisms and keep elaborating until the requested output limit.'
REQUEST_JSON="$(python3 - "$TOKENS" "$SEED" "$PROMPT_FILE" "$DEFAULT_PROMPT" <<'PY'
import json,sys,pathlib
n,seed,filename,default=sys.argv[1:]
prompt=pathlib.Path(filename).read_text(encoding='utf-8') if filename else default
if not prompt.strip(): raise SystemExit('Prompt cannot be empty')
print(json.dumps({'prompt':prompt,'n_predict':int(n),'ignore_eos':True,'temperature':0.0,'seed':int(seed),'stream':False,'cache_prompt':False}))
PY
)"
printf '%s\n' "$REQUEST_JSON" >"$OUTDIR/request.json"
python3 - "$OUTDIR/manifest.json" "$TOKENS" "$SEED" "$MTP_P_MIN" "${#MODELS[@]}" "${#PROFILE_SPECS[@]}" <<'PY'
import json,sys
filename,tokens,seed,pmin,models,profiles=sys.argv[1:]
with open(filename,'w') as f:json.dump({'tokens':int(tokens),'seed':int(seed),'mtp_p_min':float(pmin),'models':int(models),'profiles':int(profiles)},f,indent=2)
PY

wait_server() {
  local i
  for ((i=0; i<LOAD_TIMEOUT; i++)); do
    if [[ "$(pctl inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || :)" != true ]]; then
      return 1
    fi
    if curl -fsS --connect-timeout 1 --max-time 2 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

# Metrics can come from /completion and/or Prometheus deltas and/or a per-slot
# "draft acceptance" log line. Unknown acceptance is N/A, never invented 0%.
parse_result() {
  python3 - "$1" "$2" "$3" "$4" <<'PY'
import json,math,re,sys
resp,logfile,before,after=sys.argv[1:]
try:
    d=json.load(open(resp,encoding='utf-8'))
    if not isinstance(d,dict) or d.get('error'): raise ValueError('error/non-object response')
    t=d.get('timings') or {}
    n=int(t.get('predicted_n') or d.get('tokens_predicted') or 0)
    ms=float(t.get('predicted_ms') or 0)
    rate=float(t.get('predicted_per_second') or (1000*n/ms if ms>0 else 0))
    pre=float(t.get('prompt_per_second') or 0)
    if n<=0 or not math.isfinite(rate) or rate<=0: raise ValueError('no valid decode timing')
except (OSError,ValueError,TypeError,KeyError,json.JSONDecodeError):
    print('invalid,,,,,,');sys.exit(0)

def metric(path,name):
    try: lines=open(path,encoding='utf-8',errors='replace')
    except OSError: return None
    result=[]
    for line in lines:
        line=line.strip()
        if not line or line.startswith('#'): continue
        parts=line.split()
        if len(parts)<2: continue
        k=parts[0].split('{',1)[0].split(':')[-1]
        if k==name:
            try: result.append(float(parts[1]))
            except ValueError: pass
    return sum(result) if result else None

gen=acc=None
name_gen='spec_decode_num_draft_tokens_total'
name_acc='spec_decode_num_accepted_tokens_total'
pg,pa=metric(before,name_gen),metric(before,name_acc)
ag,aa=metric(after,name_gen),metric(after,name_acc)
if None not in (pg,pa,ag,aa) and ag>=pg and aa>=pa:
    gen,acc=int(round(ag-pg)),int(round(aa-pa))
if gen is None or gen<=0:
    try: s=open(logfile,encoding='utf-8',errors='replace').read()
    except OSError: s=''
    matches=list(re.finditer(r'draft acceptance\s*=\s*[0-9.]+\s*\(\s*(\d+)\s+accepted\s*/\s*(\d+)\s+generated',s))
    if matches:
        # Log may also include warmup stats; use last emitted per-slot sample.
        acc,gen=map(int,matches[-1].groups())
if gen is None or gen<=0:
    print(f'valid,{rate:.6f},{pre:.6f},{n},,,')
else:
    print(f'valid,{rate:.6f},{pre:.6f},{n},{gen},{acc},{acc/gen:.6f}')
PY
}

gpu_metrics() {
  awk -F, '{
    gsub(/[[:space:]]/,"",$1);gsub(/[[:space:]]/,"",$2);gsub(/[[:space:]]/,"",$3);
    if($1~/^[0-9.]+$/&&$2~/^[0-9.]+$/&&$3~/^[0-9.]+$/){u+=$1;p+=$2;if($3>m)m=$3;n++}
  } END {if(n) printf "%.2f,%.2f,%.0f",u/n,p/n,m;else printf ",,"}' "$1"
}

failures=0
for t in "${TESTS[@]}"; do
  IFS='|' read -r name idx ctx kvk kvv spec n <<<"$t"
  shortmodel="$(basename -- "${MODELS[$idx]}")"
  shortdraft=""; [[ -z "${DRAFTS[$idx]}" ]] || shortdraft="$(basename -- "${DRAFTS[$idx]}")"
  src="${MODELS[$idx]}"
  prefix="$OUTDIR/$name"
  resp="$prefix.response.json"; logs="$prefix.container.log"; err="$prefix.launch.err"
  gpu="$prefix.gpu.csv"; before="$prefix.metrics-before.txt"; after="$prefix.metrics-after.txt"
  : >"$err"; : >"$logs"; : >"$gpu"
  status=ok
  attempted_run=0
  log "===== $name; model=$shortmodel; draft=${shortdraft:-none}; ctx=$ctx; kv=$kvk/$kvv; spec=$spec:$n ====="
  if [[ -n "${MODEL_STATUS[$idx]}" ]]; then status="${MODEL_STATUS[$idx]}"; fi
  if [[ "$status" == ok && "$spec" == mtp && -n "${DRAFT_STATUS[$idx]}" ]]; then status="${DRAFT_STATUS[$idx]}"; fi
  if [[ "$status" == ok && "$spec" == mtp && "$MTP_AVAILABLE" != 1 ]]; then status='mtp-cli-unsupported'; fi
  # Do not run alongside a live OMP model. Leave OMP running and mark remainder.
  if [[ "$status" == ok && "$(pctl inspect -f '{{.State.Running}}' ompai-llama 2>/dev/null || :)" == true ]]; then
    status='omp-llama-running'
  fi
  if [[ "$status" == ok ]]; then
    args=(--model /model.gguf --host 0.0.0.0 --port 8080 --metrics
      --parallel 1 --cont-batching --kv-unified --ctx-size "$ctx"
      --cache-type-k "$kvk" --cache-type-v "$kvv" --cache-ram 0
      --flash-attn auto --fit on --fit-target 256 --offline --log-verbosity 4)
    mounts=(--mount "type=bind,src=$src,dst=/model.gguf,ro=true")
    if [[ "$spec" == mtp ]]; then
      mounts+=(--mount "type=bind,src=${DRAFTS[$idx]},dst=/draft.gguf,ro=true")
      args+=(--spec-type draft-mtp --spec-draft-model /draft.gguf
        --spec-draft-ngl "$DRAFT_NGL" --spec-draft-n-max "$n" --spec-draft-p-min "$MTP_P_MIN"
        --cache-type-k-draft "$DRAFT_KV" --cache-type-v-draft "$DRAFT_KV")
    fi
    set_hook_capture "$name"
    attempted_run=1
    BENCH_CONTAINER_ATTEMPTED=1
    if ! pctl run -d --pull=never --name "$CONTAINER" \
        "${HOOK_ANNOTATIONS[@]}" \
        --network bridge --device nvidia.com/gpu=all \
        --memory "$LLAMA_MEMORY" --cpus 20 --pids-limit 512 \
        --read-only --cap-drop ALL --security-opt no-new-privileges \
        --tmpfs /tmp:rw,nosuid,nodev,size=512m \
        "${mounts[@]}" -p "127.0.0.1:$PORT:8080" \
        "$LLAMA_IMAGE" "${args[@]}" >"$prefix.container-id" 2>"$err"; then
      status='container-create-failed'
    elif ! wait_server; then
      status='model-load-failed-or-timeout'
    else
      # This is the only warmup; timed request is identical across configurations.
      if ! curl -fsS --connect-timeout 3 --max-time 240 \
          -H 'Content-Type: application/json' \
          --data-binary "{\"prompt\":\"Warmup.\",\"n_predict\":1,\"temperature\":0.0,\"seed\":$SEED}" \
          "http://127.0.0.1:$PORT/completion" >"$prefix.warmup.json" 2>>"$err"; then
        status='warmup-request-failed'
      else
        curl -fsS --connect-timeout 2 --max-time 10 "http://127.0.0.1:$PORT/metrics" >"$before" 2>>"$err" || :
        nvidia-smi --query-gpu=utilization.gpu,power.draw,memory.used \
          --format=csv,noheader,nounits -lms 200 >"$gpu" 2>"$prefix.gpu.err" &
        GPU_PID=$!
        if ! curl -fsS --connect-timeout 3 --max-time "$REQUEST_TIMEOUT" \
            -H 'Content-Type: application/json' --data-binary "$REQUEST_JSON" \
            "http://127.0.0.1:$PORT/completion" >"$resp" 2>>"$err"; then
          status='completion-request-failed'
        fi
        kill "$GPU_PID" 2>/dev/null || :;wait "$GPU_PID" 2>/dev/null || :;GPU_PID=''
        curl -fsS --connect-timeout 2 --max-time 10 "http://127.0.0.1:$PORT/metrics" >"$after" 2>>"$err" || :
      fi
    fi
  fi

  # Do not inspect/log/remove a container that was never created.
  # In particular, path-based skips must not produce misleading Podman errors.
  if (( attempted_run )); then
    save_hook_capture "$name" "$prefix"
    if pctl container exists "$CONTAINER" >/dev/null 2>&1; then
      pctl logs "$CONTAINER" >"$logs" 2>&1 || :
      if [[ "$(pctl inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || :)" == true ]]; then
        pctl stop -t 5 "$CONTAINER" >/dev/null 2>>"$err" || :
        pctl logs "$CONTAINER" >"$logs" 2>&1 || :
      fi
      pctl rm "$CONTAINER" >/dev/null 2>>"$err" || :
    else
      printf 'Benchmark container not present after launch attempt; inspect launch.err and OCI hook logs.\n' >"$logs"
    fi
  else
    printf 'Test was not launched. Status: %s\n' "$status" >"$logs"
  fi

  tps='' prefill='' predicted='' dgen='' dacc='' acceptance=''
  if [[ -s "$resp" ]]; then
    IFS=, read -r validity tps prefill predicted dgen dacc acceptance <<<"$(parse_result "$resp" "$logs" "$before" "$after")"
    if [[ "$status" == ok && "$validity" != valid ]]; then status='response-invalid-or-no-decode'; fi
  elif [[ "$status" == ok ]]; then
    status='response-missing'
  fi
  n_reported=''
  if [[ "$spec" == mtp ]]; then
    # Value logged by actual draft-mtp implementation, not the requested CLI flag.
    n_reported="$(python3 - "$logs" <<'PY'
import re,sys
s=open(sys.argv[1],encoding='utf-8',errors='replace').read()
m=list(re.finditer(r'\bn_max\s*=\s*(\d+)\b',s))
print(m[-1].group(1) if m else '')
PY
)"
    if [[ "$status" == ok ]]; then
      if ! grep -qiE "adding speculative implementation.*draft-mtp|speculative implementation.*draft-mtp" "$logs"; then
        status='mtp-not-confirmed-in-log'
      elif [[ -z "$n_reported" ]]; then
        status='mtp-n-max-unverified'
      elif [[ "$n_reported" != "$n" ]]; then
        status='mtp-n-max-clamped-or-mismatched'
      elif [[ -z "$dgen" || "$dgen" == 0 || -z "$acceptance" ]]; then
        status='mtp-acceptance-unavailable'
      fi
    fi
  else
    # Non-MTP baseline: never attribute speculative acceptance.
    dgen='';dacc='';acceptance=''
  fi
  IFS=, read -r gpuavg watts vram <<<"$(gpu_metrics "$gpu")"
  # csv.writer handles arbitrary model filenames containing commas or quotes.
  python3 - "$RESULTS" "$name" "$shortmodel" "$src" "$shortdraft" "${DRAFTS[$idx]}" \
    "$ctx" "$kvk" "$kvv" "$spec" "$n" "$n_reported" "$tps" "$prefill" "$predicted" \
    "$dgen" "$dacc" "$acceptance" "$gpuavg" "$watts" "$vram" "$status" <<'PYCSV'
import csv,sys
with open(sys.argv[1], 'a', newline='') as f: csv.writer(f).writerow(sys.argv[2:])
PYCSV
  log "$name: $status; decode=${tps:-N/A} tok/s; acceptance=${acceptance:-N/A}; VRAM=${vram:-N/A} MiB"
  if [[ "$status" != ok ]]; then
    failures=$((failures+1))
    if (( attempted_run )); then
      log "Reason/status: $status; last launch and server lines:"
      tail -12 "$err" >&2 || :
      tail -16 "$logs" >&2 || :
    else
      log "Skipped before container creation: $status. See $DIAG for the access diagnostics."
    fi
  fi
done

python3 - "$RESULTS" "$SUMMARY" <<'PY'
import csv,sys
with open(sys.argv[1],newline='') as f: rows=list(csv.DictReader(f))
with open(sys.argv[2],'w') as report:
    def say(msg=''):
        print(msg); print(msg,file=report)
    def fmt(x,style):
        try: return format(float(x),style) if x else 'N/A'
        except (TypeError,ValueError): return 'N/A'
    say('Standalone llama.cpp GGUF speed benchmark (generic profiles; supplied drafts only)')
    say('Results sorted by measured decode tokens/s. Comparisons use identical prompt and seed.')
    say(f'{"TEST":27s} {"MODEL":35s} {"TOK/S":>9s} {"MTP ACC":>9s} {"GPU %":>7s} {"VRAM MiB":>10s} STATUS')
    for r in sorted(rows,key=lambda x:(x['status']=='ok',float(x['decode_tps'] or 0)),reverse=True):
        ac=(fmt(100*float(r['acceptance']),'0.1f')+'%') if r['acceptance'] else 'N/A'
        say(f"{r['test']:27s} {r['model'][:35]:35s} {fmt(r['decode_tps'],'0.2f'):>9s} {ac:>9s} "
            f"{fmt(r['gpu_avg_pct'],'0.1f'):>7s} {fmt(r['vram_peak_mib'],'0.0f'):>10s} {r['status']}")
    say('\nMTP speedup over this model\'s ordinary decoding at the SAME ctx/KV:')
    base={(r['model_path'],r['ctx'],r['kv_k'],r['kv_v']):float(r['decode_tps']) for r in rows
          if r['spec']=='none' and r['status']=='ok' and r['decode_tps']}
    for r in rows:
        if r['spec']!='mtp': continue
        b=base.get((r['model_path'],r['ctx'],r['kv_k'],r['kv_v']))
        speed=float(r['decode_tps'] or 0)
        rel=f'{speed/b:.2f}x' if b and speed and r['status']=='ok' else 'N/A'
        say(f"  {r['test']}: {rel}")
    say('\nOnly status=ok counts as a successful measurement. Different contexts,')
    say('KV quantizations and auto-fit GPU offload can affect interpretation.')
    say('GPU usage/VRAM are host nvidia-smi samples (prefill + decode).')
PY
log "CSV: $RESULTS"
log "Summary: $SUMMARY"
log "Raw results and read-only diagnostic snapshots: $OUTDIR"
if ((failures)); then
  log "$failures tests did not complete successfully (independent tests continued)."
  exit 2
fi
