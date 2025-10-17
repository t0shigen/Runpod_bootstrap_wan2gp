#!/usr/bin/env bash
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

# -------- Prep --------
log "Workdir: $WORKDIR"
mkdir -p "$WORKDIR" && cd "$WORKDIR"

if command -v apt-get >/dev/null 2>&1; then
  log "apt-get update/install minimal tools"
  apt-get update -y >/dev/null
  DEBIAN_FRONTEND=noninteractive apt-get install -y git curl wget zip unzip build-essential python3-dev ninja-build pkg-config >/dev/null || true
fi

# -------- Clone or Update Repo --------
if [ ! -d "$WAN_DIR/.git" ]; then
  log "Cloning Wan2GP: $REPO_URL (branch: $REPO_BRANCH)"
  git clone --branch "$REPO_BRANCH" --depth=1 "$REPO_URL" "$WAN_DIR"
else
  log "Updating existing repo at $WAN_DIR"
  git -C "$WAN_DIR" remote set-url origin "$REPO_URL" || true
  git -C "$WAN_DIR" fetch --depth=1 origin "$REPO_BRANCH"
  git -C "$WAN_DIR" reset --hard "origin/$REPO_BRANCH"
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
$PIPBIN install -U setuptools wheel Cython ninja $PIP_EXTRA || true

# -------- Ready - Launch --------
cd "$WAN_DIR"
log "Starting Wan2GP on 0.0.0.0:${PORT}"
exec $PYBIN "$WAN_DIR/wgp.py" --server-name 0.0.0.0 --server-port "$PORT"
