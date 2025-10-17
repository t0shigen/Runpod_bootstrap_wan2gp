#!/usr/bin/env bash
set -euo pipefail

# ============================================================
#  RunPod Bootstrap for Wan2GP (Er+GPT edition) - add hf_transfer fix
# ============================================================

REPO_URL="${REPO_URL:-https://github.com/t0shigen/Wan2GP.git}"
REPO_BRANCH="${REPO_BRANCH:-main}"
WAN_DIR="${WAN_DIR:-/workspace/Wan2GP}"
WORKDIR="${WORKDIR:-/workspace}"
PORT="${WGP_PORT:-7860}"
USE_CONDA="${USE_CONDA:-0}"
PIP_EXTRA="${PIP_EXTRA:-}"

DL_SERVER="${DL_SERVER:-0}"
DL_PORT="${DL_PORT:-9999}"
DL_ROOT="${DL_ROOT:-/workspace/outputs}"
DL_BIND="${DL_BIND:-0.0.0.0}"

log(){ echo -e "[BOOT] $*"; }
port_busy(){ ss -ltn | awk '{print $4}' | grep -q ":$1$"; }
SLEEP_FOREVER(){ tail -f /dev/null; }

log "Workdir: $WORKDIR"
mkdir -p "$WORKDIR" && cd "$WORKDIR"

if command -v apt-get >/dev/null 2>&1; then
  log "apt-get update/install minimal tools"
  apt-get update -y >/dev/null
  DEBIAN_FRONTEND=noninteractive apt-get install -y git curl wget zip unzip build-essential python3-dev ninja-build pkg-config >/dev/null || true
fi

BOOT_MARKER="${BOOT_MARKER:-/workspace/.bootstrap_done}"
FIRST_BOOT=0
if [ ! -f "$BOOT_MARKER" ]; then
  FIRST_BOOT=1
  log "First boot detected → will run heavy installs"
else
  log "Bootstrap marker found → skipping heavy installs"
fi

PYBIN="python3"
PIPBIN="$PYBIN -m pip"
$PIPBIN install --upgrade pip $PIP_EXTRA

if [ "$FIRST_BOOT" = "1" ]; then
  log "Install build helpers and dependencies"
  $PIPBIN install -U setuptools wheel Cython ninja hf_transfer $PIP_EXTRA || true
  cd "$WAN_DIR"
  if [ -f requirements.txt ]; then
    $PIPBIN install -r requirements.txt $PIP_EXTRA || true
  fi
  $PIPBIN install "mmgp==3.6.2" gradio $PIP_EXTRA || true
  touch "$BOOT_MARKER" || true
fi

if [ "${DL_SERVER:-0}" = "1" ]; then
  log "Starting download server on ${DL_BIND}:${DL_PORT} serving ${DL_ROOT}"
  mkdir -p "$WORKDIR/logs"
  nohup python3 -m http.server "$DL_PORT" --bind "$DL_BIND" --directory "$DL_ROOT" \
    > "$WORKDIR/logs/dl_server_${DL_PORT}.log" 2>&1 &
  echo $! > "$WORKDIR/logs/dl_server_${DL_PORT}.pid"
  log "DL server PID $(cat "$WORKDIR/logs/dl_server_${DL_PORT}.pid")"
fi

cd "$WAN_DIR"
if port_busy "$PORT"; then
  log "Port ${PORT} is already in use. Going idle for debugging..."
  SLEEP_FOREVER
fi

log "Starting Wan2GP on 0.0.0.0:${PORT}"
exec $PYBIN "$WAN_DIR/wgp.py" --server-name 0.0.0.0 --server-port "$PORT"
