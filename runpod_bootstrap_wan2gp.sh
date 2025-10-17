apt-get update -y >/dev/null
  # include build tools so native builds (e.g., Cython extensions) succeed
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    git curl wget zip unzip \
    build-essential python3-dev ninja-build pkg-config \
    >/dev/null || true#!/usr/bin/env bash
set -euo pipefail

# ============================================================
#  RunPod Bootstrap for Wan2GP (Er+GPT edition)
# ============================================================

# -------- User-tunable ENV (override via RunPod Env Vars) --------
REPO_URL="${REPO_URL:-https://github.com/t0shigen/Wan2GP.git}"
REPO_BRANCH="${REPO_BRANCH:-main}"
WAN_DIR="${WAN_DIR:-/workspace/Wan2GP}"
WORKDIR="${WORKDIR:-/workspace}"
PORT="${WGP_PORT:-7860}"
USE_CONDA="${USE_CONDA:-0}"
CONDA_PY="${CONDA_PY:-3.10.13}"
FLASH_ATTENTION="${FLASH_ATTENTION:-0}"
SAGE_ATTN="${SAGE_ATTN:-1}"
TORCH_CUDA_ARCH_LIST="${TORCH_CUDA_ARCH_LIST:-12.0+PTX}"
PIP_EXTRA="${PIP_EXTRA:-}"

# Download server options (optional)
DL_SERVER="${DL_SERVER:-0}"
DL_PORT="${DL_PORT:-9999}"
DL_ROOT="${DL_ROOT:-/workspace/outputs}"
DL_BIND="${DL_BIND:-0.0.0.0}"

# -------- Helpers --------
log(){ echo -e "[BOOT] $*"; }
port_busy(){ ss -ltn | awk '{print $4}' | grep -q ":$1$"; }
SLEEP_FOREVER(){ tail -f /dev/null; }

# -------- Safe Mode --------
# If SAFE_MODE=1, skip everything and keep the pod alive for manual fixes.
if [ "${SAFE_MODE:-0}" = "1" ]; then
  log "SAFE_MODE=1 → skipping bootstrap; keeping container alive."
  SLEEP_FOREVER
fi

# -------- Prep --------
log "Workdir: $WORKDIR"
mkdir -p "$WORKDIR" && cd "$WORKDIR"

if command -v apt-get >/dev/null 2>&1; then
  log "apt-get update/install minimal tools"
  apt-get update -y >/dev/null
  DEBIAN_FRONTEND=noninteractive apt-get install -y git curl wget zip unzip build-essential python3-dev ninja-build pkg-config >/dev/null || true
fi

# -------- Clone or Update Repo --------
BOOT_MARKER="${BOOT_MARKER:-/workspace/.bootstrap_done}"
if [ ! -d "$WAN_DIR/.git" ]; then
  log "Cloning Wan2GP: $REPO_URL (branch: $REPO_BRANCH)"
  for i in 1 2 3; do
    git clone --branch "$REPO_BRANCH" --depth=1 "$REPO_URL" "$WAN_DIR" && break || {
      log "Clone failed (attempt $i), retrying in 2s..."; sleep 2;
    }
  done
else
  log "Updating existing repo at $WAN_DIR"
  git -C "$WAN_DIR" remote set-url origin "$REPO_URL" || true
  git -C "$WAN_DIR" fetch --depth=1 origin "$REPO_BRANCH" || true
  git -C "$WAN_DIR" reset --hard "origin/$REPO_BRANCH" || true
fi

# Avoid re-running heavy installs on every restart
FIRST_BOOT=0
if [ ! -f "$BOOT_MARKER" ]; then
  FIRST_BOOT=1
  log "First boot detected → will run heavy installs"
else
  log "Bootstrap marker found → skipping heavy installs"
fi

# -------- Python --------
PYBIN="python3"
PIPBIN="$PYBIN -m pip"

if [ "$USE_CONDA" = "1" ]; then
  log "(conda path omitted for brevity)"
else
  log "Using system Python from container (expected Torch 2.8.0+cu128 preinstalled)"
  $PIPBIN install --upgrade pip $PIP_EXTRA
fi

log "Preinstall build helpers: setuptools, wheel, Cython, ninja"
if [ "$FIRST_BOOT" = "1" ]; then
  $PIPBIN install -U setuptools wheel Cython ninja $PIP_EXTRA || true
else
  log "Skip build helpers (not first boot)"
fi

# -------- Python deps for Wan2GP --------
cd "$WAN_DIR"
log "Install repo requirements (if present)"
if [ "$FIRST_BOOT" = "1" ] && [ -f requirements.txt ]; then
  $PIPBIN install -r requirements.txt $PIP_EXTRA || true
else
  log "Skipping requirements install (not first boot or file missing)"
fi

if [ "$FIRST_BOOT" = "1" ]; then
  log "Pin mmgp to 3.6.2 and ensure gradio present"
  $PIPBIN install "mmgp==3.6.2" gradio $PIP_EXTRA || true
fi

# stamp as completed heavy bootstrap
if [ "$FIRST_BOOT" = "1" ]; then
  touch "$BOOT_MARKER" || true
fi

# -------- Optional Download Server --------
if [ "${DL_SERVER:-0}" = "1" ]; then
  log "Starting download server on ${DL_BIND}:${DL_PORT} serving ${DL_ROOT}"
  mkdir -p "$WORKDIR/logs"
  nohup python3 -m http.server "$DL_PORT" --bind "$DL_BIND" --directory "$DL_ROOT" \
    > "$WORKDIR/logs/dl_server_${DL_PORT}.log" 2>&1 &
  echo $! > "$WORKDIR/logs/dl_server_${DL_PORT}.pid"
  log "DL server PID $(cat "$WORKDIR/logs/dl_server_${DL_PORT}.pid")"
fi

# -------- Ready - Launch --------
cd "$WAN_DIR"

# If the desired port is busy, avoid restart loops; idle for debugging
if port_busy "$PORT"; then
  log "Port ${PORT} is already in use. Set WGP_PORT to a free port or kill the process. Going idle for debugging..."
  SLEEP_FOREVER
fi

log "Starting Wan2GP on 0.0.0.0:${PORT}"
exec $PYBIN "$WAN_DIR/wgp.py" --server-name 0.0.0.0 --server-port "$PORT"
