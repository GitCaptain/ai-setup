#!/usr/bin/env bash
set -Eeuo pipefail

AI_USER="${AI_USER:-ompai}"
AI_HOME="${AI_HOME:-/var/lib/ompai}"

ANDROID_API="${ANDROID_API:-36}"
ANDROID_IMAGE_FLAVOR="${ANDROID_IMAGE_FLAVOR:-google_apis}"
ANDROID_ARCH="${ANDROID_ARCH:-x86_64}"
ANDROID_AVD_NAME="${ANDROID_AVD_NAME:-omp_api${ANDROID_API}}"

ANDROID_GUEST_RAM_MB="${ANDROID_GUEST_RAM_MB:-2048}"
ANDROID_CONTAINER_MEM="${ANDROID_CONTAINER_MEM:-4g}"
ANDROID_CPUS="${ANDROID_CPUS:-4}"
ANDROID_INTERNET="${ANDROID_INTERNET:-1}"
ANDROID_BOOT_TIMEOUT="${ANDROID_BOOT_TIMEOUT:-120}"

ANDROID_NET="${ANDROID_NET:-omp-android}"
WEB_NET="${WEB_NET:-omp-web}"
WORKBENCH="${WORKBENCH:-ompai-workbench}"
EMU_CONTAINER="${EMU_CONTAINER:-ompai-android}"
EMU_IMAGE="${EMU_IMAGE:-localhost/omp-android-emulator:api${ANDROID_API}}"

CMDLINE_TOOLS_REV="${CMDLINE_TOOLS_REV:-15859902}"
CMDLINE_TOOLS_SHA256="${CMDLINE_TOOLS_SHA256:-4e4c464f145a7512b57d088ac6c278c03c9eea610886b35a5e0804e74eedf583}"

ANDROID_ROOT="$AI_HOME/android"
ANDROID_AVD_DIR="$ANDROID_ROOT/avd"
BUILD_DIR="$ANDROID_ROOT/build"

log() { printf '[omp-android] %s\n' "$*" >&2; }
die() { printf '[omp-android] ERROR: %s\n' "$*" >&2; exit 1; }

if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
  die "run as your normal desktop user, not with sudo"
fi

for c in sudo curl sha256sum getent awk grep sed; do
  command -v "$c" >/dev/null 2>&1 || die "$c not found"
done

id "$AI_USER" >/dev/null 2>&1 || die "host user '$AI_USER' does not exist; install omp-ai first"
[[ -e /dev/kvm ]] || die "/dev/kvm does not exist. Enable SVM/virtualization in BIOS and load KVM first."

[[ "$ANDROID_BOOT_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || die "ANDROID_BOOT_TIMEOUT must be a positive integer (seconds)"
[[ "$ANDROID_INTERNET" == "0" || "$ANDROID_INTERNET" == "1" ]] || die "ANDROID_INTERNET must be 0 or 1"

log "Authorizing sudo..."
sudo -v

AI_UID="$(id -u "$AI_USER")"
XDG_RUNTIME_DIR="/run/user/$AI_UID"
DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"

as_ai() {
  sudo -n -u "$AI_USER" \
    env HOME="$AI_HOME" \
        XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
        DBUS_SESSION_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS" \
    bash -c 'cd "$HOME" && exec "$@"' _ "$@"
}

KVM_GROUP="$(stat -c '%G' /dev/kvm)"
if [[ "$KVM_GROUP" != "UNKNOWN" && -n "$KVM_GROUP" ]]; then
  if ! id -nG "$AI_USER" | tr ' ' '\n' | grep -qx "$KVM_GROUP"; then
    log "Adding $AI_USER to group '$KVM_GROUP' for /dev/kvm access..."
    sudo usermod -aG "$KVM_GROUP" "$AI_USER"
  fi
fi

if ! sudo -n -u "$AI_USER" test -r /dev/kvm || ! sudo -n -u "$AI_USER" test -w /dev/kvm; then
  die "$AI_USER still cannot access /dev/kvm. Log out/in or reboot once, then rerun this script."
fi

log "Preparing persistent AVD storage..."
sudo install -d -o "$AI_USER" -g "$AI_USER" -m 0700 "$ANDROID_ROOT" "$ANDROID_AVD_DIR" "$BUILD_DIR"

log "Ensuring isolated Android network..."
if ! as_ai podman network exists "$ANDROID_NET" 2>/dev/null; then
  as_ai podman network create --internal "$ANDROID_NET" >/dev/null
fi
if [[ "$ANDROID_INTERNET" == "1" ]]; then
  as_ai podman network exists "$WEB_NET" >/dev/null 2>&1 ||
    die "network $WEB_NET does not exist; refusing to replace existing Android container"
fi

if as_ai podman container exists "$WORKBENCH" 2>/dev/null; then
  if ! as_ai podman inspect -f '{{json .NetworkSettings.Networks}}' "$WORKBENCH" 2>/dev/null | grep -q "\"$ANDROID_NET\""; then
    log "Connecting persistent workbench to $ANDROID_NET..."
    as_ai podman network connect "$ANDROID_NET" "$WORKBENCH"
  fi
else
  die "$WORKBENCH does not exist; run omp-ai once first"
fi

log "Writing emulator image definition..."
sudo -n -u "$AI_USER" tee "$BUILD_DIR/Containerfile" >/dev/null <<'CONTAINERFILE'
FROM ubuntu:24.04

ARG CMDLINE_TOOLS_REV
ARG CMDLINE_TOOLS_SHA256
ARG ANDROID_API
ARG ANDROID_IMAGE_FLAVOR
ARG ANDROID_ARCH

ENV DEBIAN_FRONTEND=noninteractive
ENV ANDROID_SDK_ROOT=/opt/android-sdk
ENV ANDROID_HOME=/opt/android-sdk
ENV PATH=/opt/android-sdk/cmdline-tools/latest/bin:/opt/android-sdk/platform-tools:/opt/android-sdk/emulator:$PATH

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl unzip openjdk-17-jre-headless \
      libc6 libstdc++6 libgcc-s1 \
      libgl1 libpulse0 libx11-6 libxcomposite1 libxcursor1 libxi6 \
      libxtst6 libnss3 libxdamage1 libxrandr2 libasound2t64 \
      libvulkan1 socat procps iproute2 netcat-openbsd \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /opt/android-sdk/cmdline-tools/latest \
    && curl -fL --retry 4 --retry-delay 2 \
       "https://dl.google.com/android/repository/commandlinetools-linux-${CMDLINE_TOOLS_REV}_latest.zip" \
       -o /tmp/cmdline-tools.zip \
    && echo "${CMDLINE_TOOLS_SHA256}  /tmp/cmdline-tools.zip" | sha256sum -c - \
    && unzip -q /tmp/cmdline-tools.zip -d /tmp/cmdline \
    && mv /tmp/cmdline/cmdline-tools/* /opt/android-sdk/cmdline-tools/latest/ \
    && rm -rf /tmp/cmdline /tmp/cmdline-tools.zip

RUN yes | sdkmanager --licenses >/dev/null \
    && sdkmanager \
       "platform-tools" \
       "emulator" \
       "system-images;android-${ANDROID_API};${ANDROID_IMAGE_FLAVOR};${ANDROID_ARCH}"

COPY entrypoint.sh /usr/local/bin/omp-android-entrypoint
RUN chmod 0755 /usr/local/bin/omp-android-entrypoint

ENTRYPOINT ["/usr/local/bin/omp-android-entrypoint"]
CONTAINERFILE

sudo -n -u "$AI_USER" tee "$BUILD_DIR/entrypoint.sh" >/dev/null <<'ENTRYPOINT'
#!/usr/bin/env bash
set -Eeuo pipefail

: "${ANDROID_API:?}"
: "${ANDROID_IMAGE_FLAVOR:?}"
: "${ANDROID_ARCH:?}"
: "${ANDROID_AVD_NAME:?}"
: "${ANDROID_GUEST_RAM_MB:?}"

export ANDROID_SDK_ROOT=/opt/android-sdk
export ANDROID_HOME=/opt/android-sdk
export ANDROID_EMULATOR_HOME=/android-home/.android
export ANDROID_AVD_HOME=/android-home/.android/avd
export HOME=/android-home
export PATH="$ANDROID_SDK_ROOT/cmdline-tools/latest/bin:$ANDROID_SDK_ROOT/platform-tools:$ANDROID_SDK_ROOT/emulator:$PATH"

mkdir -p "$ANDROID_AVD_HOME"

SYSTEM_IMAGE="system-images;android-${ANDROID_API};${ANDROID_IMAGE_FLAVOR};${ANDROID_ARCH}"

if [[ ! -d "$ANDROID_AVD_HOME/${ANDROID_AVD_NAME}.avd" ]]; then
  echo "[omp-android] creating AVD $ANDROID_AVD_NAME from $SYSTEM_IMAGE"
  printf 'no\n' | avdmanager create avd \
    --force \
    --name "$ANDROID_AVD_NAME" \
    --package "$SYSTEM_IMAGE"
fi

echo "[omp-android] KVM check:"
emulator -accel-check || true

socat TCP-LISTEN:15555,reuseaddr,fork,bind=0.0.0.0 TCP:127.0.0.1:5555 &
SOCAT_PID=$!

cleanup() {
  kill "$SOCAT_PID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

exec emulator \
  -avd "$ANDROID_AVD_NAME" \
  -port 5554 \
  -no-snapshot \
  -no-window \
  -no-audio \
  -no-boot-anim \
  -gpu swiftshader \
  -accel on \
  -memory "$ANDROID_GUEST_RAM_MB"
ENTRYPOINT

# Label the managed sidecar with a fingerprint so repeat setup does not rebuild
# or recreate an otherwise healthy persistent Android container.
SETUP_FINGERPRINT="$(
  {
    as_ai sha256sum "$BUILD_DIR/Containerfile" "$BUILD_DIR/entrypoint.sh"
    printf '%s\n' \
      "$CMDLINE_TOOLS_REV" "$CMDLINE_TOOLS_SHA256" \
      "$ANDROID_API" "$ANDROID_IMAGE_FLAVOR" "$ANDROID_ARCH" "$ANDROID_AVD_NAME" \
      "$ANDROID_GUEST_RAM_MB" "$ANDROID_CONTAINER_MEM" "$ANDROID_CPUS" \
      "$ANDROID_INTERNET" "$ANDROID_NET" "$WEB_NET" \
      "$ANDROID_AVD_DIR" "$EMU_IMAGE"
  } | sha256sum | awk '{print $1}'
)"

RECREATE_EMULATOR=1
if as_ai podman container exists "$EMU_CONTAINER" 2>/dev/null; then
  EXISTING_FINGERPRINT="$(as_ai podman inspect -f '{{index .Config.Labels "io.omp-ai.android.setup-sha256"}}' "$EMU_CONTAINER" 2>/dev/null || true)"
  if [[ "$EXISTING_FINGERPRINT" == "$SETUP_FINGERPRINT" ]]; then
    RECREATE_EMULATOR=0
    log "Android sidecar already matches the current setup; preserving existing container and AVD."
  fi
fi

if (( RECREATE_EMULATOR )); then
  # Build before touching the running container. No AVD files are modified.
  log "Building $EMU_IMAGE (first build downloads Android SDK + system image)..."
  as_ai podman build \
    --build-arg "CMDLINE_TOOLS_REV=$CMDLINE_TOOLS_REV" \
    --build-arg "CMDLINE_TOOLS_SHA256=$CMDLINE_TOOLS_SHA256" \
    --build-arg "ANDROID_API=$ANDROID_API" \
    --build-arg "ANDROID_IMAGE_FLAVOR=$ANDROID_IMAGE_FLAVOR" \
    --build-arg "ANDROID_ARCH=$ANDROID_ARCH" \
    -t "$EMU_IMAGE" \
    -f "$BUILD_DIR/Containerfile" \
    "$BUILD_DIR"

  if as_ai podman container exists "$EMU_CONTAINER" 2>/dev/null; then
    log "Updating emulator sidecar; stopping the previous process gracefully (60s)..."
    EXISTING_RUNNING="$(as_ai podman inspect -f '{{.State.Running}}' "$EMU_CONTAINER")"
    if [[ "$EXISTING_RUNNING" == "true" ]]; then
      as_ai podman stop -t 60 "$EMU_CONTAINER" >/dev/null || die "could not stop $EMU_CONTAINER safely; leaving it intact"
    fi
    [[ "$(as_ai podman inspect -f '{{.State.Running}}' "$EMU_CONTAINER")" == "false" ]] || \
      die "$EMU_CONTAINER is still running; refusing to remove it"
    as_ai podman rm "$EMU_CONTAINER" >/dev/null || die "could not remove the stopped sidecar"
  fi

  log "Creating emulator sidecar (persistent AVD data remains untouched)..."
  as_ai podman create \
    --name "$EMU_CONTAINER" \
    --label "io.omp-ai.android.setup-sha256=$SETUP_FINGERPRINT" \
    --network "$ANDROID_NET" \
    --device /dev/kvm:/dev/kvm:rwm \
    --group-add keep-groups \
    --memory "$ANDROID_CONTAINER_MEM" \
    --cpus "$ANDROID_CPUS" \
    --pids-limit 1024 \
    --cap-drop ALL \
    --security-opt no-new-privileges \
    --read-only \
    --tmpfs /tmp:rw,nosuid,nodev,size=1g \
    --shm-size 1g \
    --mount "type=bind,src=$ANDROID_AVD_DIR,dst=/android-home,bind-nonrecursive" \
    -e "ANDROID_API=$ANDROID_API" \
    -e "ANDROID_IMAGE_FLAVOR=$ANDROID_IMAGE_FLAVOR" \
    -e "ANDROID_ARCH=$ANDROID_ARCH" \
    -e "ANDROID_AVD_NAME=$ANDROID_AVD_NAME" \
    -e "ANDROID_GUEST_RAM_MB=$ANDROID_GUEST_RAM_MB" \
    "$EMU_IMAGE" >/dev/null

  if [[ "$ANDROID_INTERNET" == "1" ]]; then
    log "Giving emulator outbound internet via existing $WEB_NET network..."
    as_ai podman network exists "$WEB_NET" >/dev/null 2>&1 || \
      die "network $WEB_NET does not exist; run main omp-ai setup first"
    as_ai podman network connect "$WEB_NET" "$EMU_CONTAINER"
  else
    log "Emulator internet disabled; it will remain only on $ANDROID_NET."
  fi
fi

log "Installing /usr/local/bin/omp-android helper..."
sudo tee /usr/local/bin/omp-android >/dev/null <<EOF_HELPER
#!/usr/bin/env bash
set -Eeuo pipefail

AI_USER="$AI_USER"
AI_HOME="$AI_HOME"
AI_UID="$AI_UID"
CONTAINER="$EMU_CONTAINER"
AVD_DIR="$ANDROID_AVD_DIR"
AVD_NAME="$ANDROID_AVD_NAME"
BOOT_TIMEOUT="$ANDROID_BOOT_TIMEOUT"

pctl() {
  sudo -u "\$AI_USER" \
    env HOME="\$AI_HOME" \
        XDG_RUNTIME_DIR="/run/user/\$AI_UID" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/\$AI_UID/bus" \
    bash -c 'cd "\$HOME" && exec podman "\$@"' _ "\$@"
}

running() {
  [[ "\$(pctl inspect -f '{{.State.Running}}' "\$CONTAINER")" == "true" ]]
}

ready() {
  # Test guest readiness, not merely the socat listener / Podman running state.
  pctl exec "\$CONTAINER" timeout 5 adb -s emulator-5554 shell getprop sys.boot_completed 2>/dev/null \
    | tr -d '\\r' | grep -qx '1'
}

wait_for_boot() {
  local deadline=\$((SECONDS + BOOT_TIMEOUT))
  while (( SECONDS < deadline )); do
    if ! running; then
      echo "[omp-android] emulator exited during startup; last logs:" >&2
      pctl logs --tail 35 "\$CONTAINER" >&2 || true
      return 1
    fi
    if ready; then
      echo "[omp-android] Android boot completed; adb inside workbench:" 
      echo "  adb connect ompai-android:15555"
      return 0
    fi
    sleep 3
  done
  echo "[omp-android] startup timed out after \${BOOT_TIMEOUT}s; diagnostics:" >&2
  pctl logs --tail 35 "\$CONTAINER" >&2 || true
  echo "[omp-android] Container may still be running. Check: omp-android status" >&2
  return 1
}

ensure_stopped() {
  local state
  state="\$(pctl inspect -f '{{.State.Running}}' "\$CONTAINER")" || {
    echo "[omp-android] Cannot inspect the container; refusing to touch AVD data." >&2
    return 1
  }
  if [[ "\$state" != "false" ]]; then
    echo "[omp-android] Stop the emulator first: omp-android stop" >&2
    return 1
  fi
}

recover_locks() {
  # Explicit, conservative recovery only. Never delete locks automatically.
  ensure_stopped || return 1
  if ps -u "\$AI_USER" -o args= | grep -Eq '[q]emu-system|[/]emulator.*-avd'; then
    echo "[omp-android] Emulator/QEMU processes are still running; not touching locks." >&2
    return 1
  fi
  local avd="\$AVD_DIR/.android/avd/\$AVD_NAME.avd"
  sudo -u "\$AI_USER" test -d "\$avd" || {
    echo "[omp-android] AVD directory missing: \$avd" >&2
    return 1
  }
  local backup=""
  local name
  for name in snapshot.lock.lock hardware-qemu.ini.lock multiinstance.lock; do
    if sudo -u "\$AI_USER" test -e "\$avd/\$name" || sudo -u "\$AI_USER" test -L "\$avd/\$name"; then
      if [[ -z "\$backup" ]]; then
        backup="\$(sudo -u "\$AI_USER" mktemp -d "\$AVD_DIR/lock-recovery-XXXXXXXX")"
      fi
      sudo -u "\$AI_USER" mv -- "\$avd/\$name" "\$backup/"
      echo "[omp-android] archived: \$name"
    fi
  done
  if [[ -n "\$backup" ]]; then
    echo "[omp-android] Lock archive: \$backup (do not restore into the AVD)"
  else
    echo "[omp-android] No known stale lock files found. Nothing changed."
  fi
}

case "\${1:-status}" in
  start)
    if running; then
      echo "[omp-android] container already running; checking Android boot..."
    else
      pctl start "\$CONTAINER" >/dev/null
      echo "[omp-android] container started; checking Android boot..."
    fi
    wait_for_boot
    ;;
  stop)
    if running; then
      pctl stop -t 60 "\$CONTAINER" >/dev/null
    fi
    echo "[omp-android] stopped (AVD preserved)"
    ;;
  restart)
    "\$0" stop
    "\$0" start
    ;;
  status)
    pctl ps -a --filter "name=^\${CONTAINER}\$" \
      --format 'table {{.Names}}\t{{.Status}}\t{{.Networks}}'
    ;;
  logs)
    pctl logs --tail="\${2:-200}" "\$CONTAINER"
    ;;
  recover-locks)
    recover_locks
    ;;
  reset)
    echo "This wipes ONLY the virtual Android device data."
    read -r -p "Type RESET to continue: " x
    [[ "\$x" == "RESET" ]] || exit 1
    if running; then
      pctl stop -t 60 "\$CONTAINER" >/dev/null || exit 1
    fi
    ensure_stopped || exit 1
    sudo find "\$AVD_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
    echo "[omp-android] AVD data wiped; run: omp-android start"
    ;;
  *)
    echo "Usage: omp-android {start|stop|restart|status|logs [N]|recover-locks|reset}" >&2
    exit 2
    ;;
esac
EOF_HELPER
sudo chmod 0755 /usr/local/bin/omp-android

log "Starting/checking emulator boot..."
sudo /usr/local/bin/omp-android start

echo
log "Installed."
echo "Android API:       $ANDROID_API"
echo "System image:      $ANDROID_IMAGE_FLAVOR/$ANDROID_ARCH"
echo "AVD:               $ANDROID_AVD_NAME"
echo "Container RAM:     $ANDROID_CONTAINER_MEM"
echo "Guest RAM:         ${ANDROID_GUEST_RAM_MB} MiB"
echo "KVM device:        /dev/kvm only"
echo "ADB endpoint:      ompai-android:15555 (private $ANDROID_NET network)"
echo "Outbound internet: $ANDROID_INTERNET"
echo
echo "Inside the workbench:"
echo "  omp-ai workbench-shell"
echo "  adb connect ompai-android:15555"
echo "  adb devices -l"
echo
echo "Control:"
echo "  omp-android start"
echo "  omp-android stop"
echo "  omp-android status"
echo "  omp-android logs 200"
echo "  omp-android recover-locks  # ONLY if stopped and locks are stale"
echo "  omp-android reset         # DESTRUCTIVE: wipes virtual Android data"
