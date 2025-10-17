#!/usr/bin/env bash
set -euo pipefail

# ============================================================
#  RunPod Bootstrap for Wan2GP (Er+GPT edition)
#  - Uses your prior RunPod recipe as baseline
#  - Aligns with original repo steps, but defaults to:
#       * system Python (from the container) unless USE_CONDA=1
#       * SageAttention2 only (no FlashAttention by default)
#       * Torch 2.8.0+cu128 from base image (if not using conda)
#       * InsightFace pinned stack (numpy 1.26.4, ORT 1.18.0, insightface 0.7.3)
#       * mmgp==3.6.2 to resolve version mismatch
#  - Keeps everything under /workspace
# ============================================================

# -------- User-tunable ENV (override via RunPod Env Vars) --------
REPO_URL="${REPO_URL:-https://github.com/t0shigen/Wan2GP.git}"   # your fork
REPO_BRANCH="${REPO_BRANCH:-main}"
WAN_DIR="${WAN_DIR:-/workspace/Wan2GP}"
WORKDIR="${WORKDIR:-/workspace}"
PORT="${WGP_PORT:-7860}"
USE_CONDA="${USE_CONDA:-0}"           # 1 = follow original conda flow; 0 = use system Python
CONDA_PY="${CONDA_PY:-3.10.13}"      # original said 3.10.9; using 3.10.13 is safer
FLASH_ATTENTION="${FLASH_ATTENTION:-0}"  # 1 = install flash-attn==2.7.2.post1 (NOT default)
SAGE_ATTN="${SAGE_ATTN:-1}"           # 1 = install SageAttention2 (default)
TORCH_CUDA_ARCH_LIST="${TORCH_CUDA_ARCH_LIST:-12.0+PTX}"  # Blackwell-friendly PTX fallback
PIP_EXTRA="${PIP_EXTRA:-}"            # extra pip args if needed

# Download server options (optional)
DL_SERVER="${DL_SERVER:-0}"          # 1 = start a background http.server to serve outputs
DL_PORT="${DL_PORT:-9999}"          # port to expose and use in proxy URL
DL_ROOT="${DL_ROOT:-/workspace/outputs}"  # which directory to serve
DL_BIND="${DL_BIND:-0.0.0.0}"        # bind address

# -------- Helpers --------
log(){ echo -e "[BOOT] $*"; }
abort(){ echo "[BOOT][ERROR] $*" >&2; exit 1; }

# -------- Prep --------
log "Workdir: $WORKDIR"
mkdir -p "$WORKDIR" && cd "$WORKDIR"

# Basic tools if apt-get exists
if command -v apt-get >/dev/null 2>&1; then
  log "apt-get update/install minimal tools"
  apt-get update -y >/dev/null
  DEBIAN_FRONTEND=noninteractive apt-get install -y git curl wget zip unzip >/dev/null || true
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

# -------- Python selection --------
PYBIN="python3"
PIPBIN="$PYBIN -m pip"

if [ "$USE_CONDA" = "1" ]; then
  if ! command -v conda >/dev/null 2>&1; then
    log "conda not found; installing micromamba minimal..."
    curl -fsSL https://micro.mamba.pm/api/micromamba/linux-64/latest | tar -xvj bin/micromamba >/dev/null 2>&1 || true
    MAMBA_BIN="$PWD/bin/micromamba"
    export MAMBA_ROOT_PREFIX="$WORKDIR/micromamba"
    mkdir -p "$MAMBA_ROOT_PREFIX"
    # create env
    "$MAMBA_BIN" create -y -n wan2gp python="$CONDA_PY" >/dev/null
    # activate via shell hook
    eval "$("$MAMBA_BIN" shell hook -s bash)"
    micromamba activate wan2gp
  else
    log "Using existing conda to create env wan2gp (python $CONDA_PY)"
    conda create -y -n wan2gp python="$CONDA_PY"
    # shellcheck disable=SC1091
    source "$(conda info --base)/etc/profile.d/conda.sh"
    conda activate wan2gp
  fi
  PYBIN="python"
  PIPBIN="$PYBIN -m pip"

  # Original pinned Torch (optional): Torch 2.7.0 test/cu128
  log "Installing PyTorch 2.7.0 (cu128 test index) per original flow"
  $PIPBIN install torch==2.7.0 torchvision torchaudio --index-url https://download.pytorch.org/whl/test/cu128 $PIP_EXTRA
else
  log "Using system Python from container (expected Torch 2.8.0+cu128 preinstalled)"
  $PIPBIN install --upgrade pip $PIP_EXTRA
fi

# -------- Global caches under /workspace --------
export HF_HOME="$WORKDIR/.cache/huggingface"
export TORCH_HOME="$WORKDIR/.cache/torch"
export TRANSFORMERS_CACHE="$WORKDIR/.cache/huggingface/transformers"
mkdir -p "$HF_HOME" "$TORCH_HOME" "$TRANSFORMERS_CACHE" "$WORKDIR/models" "$WORKDIR/outputs" "$WORKDIR/logs"

# -------- Repo requirements + critical pins --------
cd "$WAN_DIR"
log "Force-reinstall setuptools<=75.8.2 per original"
$PIPBIN install "setuptools<=75.8.2" --force-reinstall $PIP_EXTRA

log "Pin InsightFace stack (numpy 1.26.4, ORT 1.18.0, insightface 0.7.3)"
$PIPBIN uninstall -y insightface onnxruntime onnxruntime-gpu numpy || true
$PIPBIN install --no-cache-dir numpy==1.26.4 opencv-python-headless==4.9.0.80 $PIP_EXTRA
# Try GPU ORT first; fall back to CPU
if ! $PIPBIN install --no-cache-dir onnxruntime-gpu==1.18.0 $PIP_EXTRA; then
  $PIPBIN install --no-cache-dir onnxruntime==1.18.0 $PIP_EXTRA
fi
$PIPBIN install --no-cache-dir --no-deps --no-build-isolation insightface==0.7.3 $PIP_EXTRA

log "Install repo requirements"
if [ -f requirements.txt ]; then
  $PIPBIN install -r requirements.txt $PIP_EXTRA || true
fi

log "Pin mmgp to 3.6.2 to avoid the mismatch"
$PIPBIN install "mmgp==3.6.2" $PIP_EXTRA || true

# -------- Attention backends --------
if [ "$SAGE_ATTN" = "1" ]; then
  log "Installing SageAttention2 (no FlashAttention by default)"
  if [ ! -d "$WORKDIR/SageAttention" ]; then
    git clone https://github.com/thu-ml/SageAttention "$WORKDIR/SageAttention"
  fi
  cd "$WORKDIR/SageAttention"
  export TORCH_CUDA_ARCH_LIST="$TORCH_CUDA_ARCH_LIST"
  $PIPBIN install --no-build-isolation -v . $PIP_EXTRA || true
fi

if [ "$FLASH_ATTENTION" = "1" ]; then
  log "Installing FlashAttention per user override (2.7.2.post1)"
  $PIPBIN install "flash-attn==2.7.2.post1" $PIP_EXTRA || true
else
  log "Skipping FlashAttention (default)"
fi

# -------- Optional Download Server --------
if [ "$DL_SERVER" = "1" ]; then
  log "Starting download server on ${DL_BIND}:${DL_PORT} serving ${DL_ROOT}"
  mkdir -p "$WORKDIR/logs"
  # Launch in background and persist PID/log
  nohup python3 -m http.server "$DL_PORT" \
    --bind "$DL_BIND" \
    --directory "$DL_ROOT" \
    > "$WORKDIR/logs/dl_server_${DL_PORT}.log" 2>&1 &
  echo $! > "$WORKDIR/logs/dl_server_${DL_PORT}.pid"
  log "DL server PID $(cat "$WORKDIR/logs/dl_server_${DL_PORT}.pid")"
  log "Remember to EXPOSE port ${DL_PORT} in RunPod. Access via https://<pod-id>-${DL_PORT}.proxy.runpod.net"
fi

# -------- Ready - Launch --------
cd "$WAN_DIR"
log "Starting Wan2GP on 0.0.0.0:${PORT}"
exec $PYBIN "$WAN_DIR/wgp.py" --host 0.0.0.0 --port "$PORT"
