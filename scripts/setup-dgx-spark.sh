#!/usr/bin/env bash
# NemoClaw — Optimised setup for NVIDIA DGX Spark
#
# DGX Spark hardware:
#   - GB10 Grace Blackwell superchip (ARM64)
#   - 128 GB unified LPDDR5x memory (CPU + GPU shared, 273 GB/s)
#   - 1 PFLOP FP4 inference, 6144 CUDA cores
#   - DGX OS (Ubuntu 24.04), Docker pre-installed, cgroup v2
#
# This script handles everything Spark-specific before handing off
# to the standard NemoClaw setup. It detects hardware, configures
# Docker for cgroup v2, selects the right model for available memory,
# and optionally starts a local vLLM inference server.
#
# Usage:
#   export NVIDIA_API_KEY=nvapi-...
#   sudo bash scripts/setup-dgx-spark.sh [--local-inference] [--model MODEL_ID]
#
# Options:
#   --local-inference   Start vLLM on the Spark GPU (no cloud calls)
#   --cloud-inference   Use NVIDIA Cloud API only (default)
#   --model MODEL_ID    Override model selection (skip auto-detect)
#   --dual-stack        Configure for dual-Spark stacking (256 GB)
#   --skip-docker       Skip Docker reconfiguration
#   --dry-run           Show what would be done without executing

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${GREEN}>>>${NC} $1"; }
warn()  { echo -e "${YELLOW}>>>${NC} $1"; }
fail()  { echo -e "${RED}>>>${NC} $1"; exit 1; }
stage() { echo -e "\n${CYAN}${BOLD}── $1 ──${NC}"; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Parse arguments ─────────────────────────────────────────────

LOCAL_INFERENCE=false
CLOUD_INFERENCE=true
MODEL_OVERRIDE=""
DUAL_STACK=false
SKIP_DOCKER=false
DRY_RUN=false

while [ $# -gt 0 ]; do
  case "$1" in
    --local-inference)  LOCAL_INFERENCE=true; CLOUD_INFERENCE=false ;;
    --cloud-inference)  CLOUD_INFERENCE=true; LOCAL_INFERENCE=false ;;
    --model)            MODEL_OVERRIDE="$2"; shift ;;
    --dual-stack)       DUAL_STACK=true ;;
    --skip-docker)      SKIP_DOCKER=true ;;
    --dry-run)          DRY_RUN=true ;;
    *)                  warn "Unknown option: $1" ;;
  esac
  shift
done

# ── Pre-flight checks ──────────────────────────────────────────

stage "Pre-flight checks"

[ "$(uname -s)" = "Linux" ] || fail "DGX Spark runs Linux. Detected: $(uname -s)"
[ "$(uname -m)" = "aarch64" ] || warn "Expected aarch64 (ARM64). Detected: $(uname -m). Continuing anyway."

if [ "$(id -u)" -ne 0 ]; then
  fail "Must run as root: sudo bash scripts/setup-dgx-spark.sh"
fi

REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || echo "")}"
command -v docker > /dev/null || fail "Docker not found. DGX Spark should have Docker pre-installed."
command -v nvidia-smi > /dev/null || warn "nvidia-smi not found. GPU detection will use fallback."

# ── Detect hardware ─────────────────────────────────────────────

stage "Detecting DGX Spark hardware"

IS_SPARK=false
TOTAL_MEMORY_MB=0
GPU_NAME=""

# Check for GB10 Grace Blackwell chip
if command -v nvidia-smi > /dev/null 2>&1; then
  GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader,nounits 2>/dev/null || echo "")
  if echo "$GPU_NAME" | grep -qi "GB10"; then
    IS_SPARK=true
    info "Detected DGX Spark (GB10 Grace Blackwell)"
  fi
fi

# Get total unified memory
if [ -f /proc/meminfo ]; then
  TOTAL_MEMORY_MB=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
fi

if [ "$IS_SPARK" = true ]; then
  info "GPU: $GPU_NAME"
  info "Unified memory: ${TOTAL_MEMORY_MB} MB (~$((TOTAL_MEMORY_MB / 1024)) GB)"
  info "Architecture: $(uname -m)"
  info "OS: $(lsb_release -ds 2>/dev/null || cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2 | tr -d '"')"
else
  warn "GB10 not detected. This script is optimised for DGX Spark but will continue."
  info "Detected memory: ${TOTAL_MEMORY_MB} MB"
fi

# Dual-stack detection
if [ "$DUAL_STACK" = true ]; then
  info "Dual-stack mode enabled (256 GB combined memory)"
  EFFECTIVE_MEMORY_MB=$((TOTAL_MEMORY_MB * 2))
else
  EFFECTIVE_MEMORY_MB=$TOTAL_MEMORY_MB
fi

# ── Model selection ─────────────────────────────────────────────

stage "Selecting inference model"

# Model selection based on available memory
# Reserve ~20 GB for OS, Docker, OpenShell, and OpenClaw runtime
AVAILABLE_FOR_MODEL_MB=$((EFFECTIVE_MEMORY_MB - 20480))

if [ -n "$MODEL_OVERRIDE" ]; then
  SELECTED_MODEL="$MODEL_OVERRIDE"
  info "Using override model: $SELECTED_MODEL"
elif [ "$AVAILABLE_FOR_MODEL_MB" -ge 200000 ]; then
  # 200+ GB available (dual stack) — can run the full 120B
  SELECTED_MODEL="nvidia/nemotron-3-super-120b-a12b"
  info "Selected: Nemotron 3 Super 120B (dual-stack, ~87 GB model)"
elif [ "$AVAILABLE_FOR_MODEL_MB" -ge 87000 ]; then
  # 87+ GB available (single Spark, 128 GB) — 120B fits but tight
  # Prefer 49B for headroom unless explicitly overridden
  SELECTED_MODEL="nvidia/llama-3.3-nemotron-super-49b-v1"
  info "Selected: Nemotron Super 49B v1 (optimal for single Spark)"
  info "Note: 120B fits (~87 GB) but leaves little headroom. Use --model to override."
elif [ "$AVAILABLE_FOR_MODEL_MB" -ge 24000 ]; then
  # 24+ GB — 49B fits
  SELECTED_MODEL="nvidia/llama-3.3-nemotron-super-49b-v1"
  info "Selected: Nemotron Super 49B v1 (24 GB required)"
elif [ "$AVAILABLE_FOR_MODEL_MB" -ge 8000 ]; then
  # 8+ GB — Nano 30B (MoE, only 3B active)
  SELECTED_MODEL="nvidia/nemotron-3-nano-30b-a3b"
  info "Selected: Nemotron 3 Nano 30B (8 GB required, 3B active params)"
else
  fail "Insufficient memory for any Nemotron model. Available: ${AVAILABLE_FOR_MODEL_MB} MB"
fi

info "Model: $SELECTED_MODEL"
info "Available memory for model: ~$((AVAILABLE_FOR_MODEL_MB / 1024)) GB"

if [ "$DRY_RUN" = true ]; then
  info "[DRY RUN] Would configure Docker, select model $SELECTED_MODEL, and run setup."
  exit 0
fi

# ── Docker group ────────────────────────────────────────────────

stage "Configuring Docker access"

if [ -n "$REAL_USER" ]; then
  if id -nG "$REAL_USER" | grep -qw docker; then
    info "User '$REAL_USER' already in docker group"
  else
    info "Adding '$REAL_USER' to docker group..."
    usermod -aG docker "$REAL_USER"
    info "Added. Takes effect on next login (or run 'newgrp docker')."
  fi
fi

# ── Docker cgroup v2 configuration ──────────────────────────────

if [ "$SKIP_DOCKER" = false ]; then
  stage "Configuring Docker for cgroup v2"

  # Verify cgroup v2
  CGROUP_TYPE=$(stat -fc %T /sys/fs/cgroup 2>/dev/null || echo "unknown")
  if [ "$CGROUP_TYPE" = "cgroup2fs" ]; then
    info "cgroup v2 detected (expected for DGX OS / Ubuntu 24.04)"
  else
    warn "Expected cgroup2fs, got: $CGROUP_TYPE. Continuing anyway."
  fi

  DAEMON_JSON="/etc/docker/daemon.json"
  NEEDS_RESTART=false

  # Ensure NVIDIA Container Toolkit is configured
  if command -v nvidia-ctk > /dev/null 2>&1; then
    info "Configuring NVIDIA Container Toolkit..."
    nvidia-ctk runtime configure --runtime=docker > /dev/null 2>&1 || true
    NEEDS_RESTART=true
  fi

  # Configure cgroup namespace mode
  if [ -f "$DAEMON_JSON" ]; then
    CURRENT_MODE=$(python3 -c "import json; print(json.load(open('$DAEMON_JSON')).get('default-cgroupns-mode',''))" 2>/dev/null || echo "")
    if [ "$CURRENT_MODE" = "host" ]; then
      info "Docker daemon already configured for cgroupns=host"
    else
      info "Setting Docker daemon cgroupns mode to 'host'..."
      python3 -c "
import json
with open('$DAEMON_JSON') as f:
    d = json.load(f)
d['default-cgroupns-mode'] = 'host'
with open('$DAEMON_JSON', 'w') as f:
    json.dump(d, f, indent=2)
"
      NEEDS_RESTART=true
    fi
  else
    info "Creating Docker daemon config..."
    mkdir -p "$(dirname "$DAEMON_JSON")"
    echo '{ "default-cgroupns-mode": "host" }' > "$DAEMON_JSON"
    NEEDS_RESTART=true
  fi

  if [ "$NEEDS_RESTART" = true ]; then
    info "Restarting Docker daemon..."
    systemctl restart docker
    for i in $(seq 1 15); do
      if docker info > /dev/null 2>&1; then
        break
      fi
      [ "$i" -eq 15 ] && fail "Docker failed to restart. Check: systemctl status docker"
      sleep 2
    done
    info "Docker restarted successfully"
  fi
else
  info "Skipping Docker configuration (--skip-docker)"
fi

# ── Local inference (optional) ──────────────────────────────────

if [ "$LOCAL_INFERENCE" = true ]; then
  stage "Setting up local inference with vLLM"

  # Install vLLM if needed
  if ! python3 -c "import vllm" 2>/dev/null; then
    info "Installing vLLM (this may take a few minutes)..."
    pip3 install --break-system-packages vllm 2>&1 | tail -3
    info "vLLM installed"
  else
    info "vLLM already installed"
  fi

  # Determine vLLM model (may differ from inference model for cloud)
  VLLM_MODEL="$SELECTED_MODEL"

  # Check if vLLM already running
  if curl -s http://localhost:8000/v1/models > /dev/null 2>&1; then
    info "vLLM already running on :8000"
    RUNNING_MODEL=$(curl -s http://localhost:8000/v1/models | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['data'][0]['id'] if d.get('data') else 'unknown')" 2>/dev/null || echo "unknown")
    info "Running model: $RUNNING_MODEL"
    if [ "$RUNNING_MODEL" != "$VLLM_MODEL" ]; then
      warn "Running model differs from selected model. Stop vLLM and re-run to switch."
    fi
  else
    info "Starting vLLM with $VLLM_MODEL..."
    info "Spark unified memory allows large models without PCIe bottleneck."

    VLLM_ARGS=(
      --model "$VLLM_MODEL"
      --port 8000
      --host 0.0.0.0
      --dtype auto
      --trust-remote-code
    )

    # For 49B on Spark, set tensor parallel to 1 (single GPU)
    VLLM_ARGS+=(--tensor-parallel-size 1)

    # Spark-specific: adjust GPU memory utilisation
    # Reserve memory for OS + OpenShell + agent runtime
    VLLM_ARGS+=(--gpu-memory-utilization 0.85)

    nohup python3 -m vllm.entrypoints.openai.api_server \
      "${VLLM_ARGS[@]}" \
      > /tmp/vllm-spark.log 2>&1 &
    VLLM_PID=$!

    info "Waiting for vLLM to load model (2-5 minutes on Spark)..."
    for i in $(seq 1 180); do
      if curl -s http://localhost:8000/v1/models > /dev/null 2>&1; then
        info "vLLM ready (PID $VLLM_PID)"
        break
      fi
      if ! kill -0 "$VLLM_PID" 2>/dev/null; then
        warn "vLLM exited unexpectedly. Check: cat /tmp/vllm-spark.log"
        break
      fi
      [ "$((i % 30))" -eq 0 ] && info "Still loading... ($i seconds)"
      sleep 1
    done
  fi
fi

# ── Run NemoClaw setup ──────────────────────────────────────────

stage "Running NemoClaw setup"

# Export model selection for setup.sh to use
export NEMOCLAW_MODEL="$SELECTED_MODEL"
export NEMOCLAW_SPARK=true

if [ -n "$REAL_USER" ]; then
  sudo -u "$REAL_USER" -E \
    NVIDIA_API_KEY="${NVIDIA_API_KEY:-}" \
    DOCKER_HOST="${DOCKER_HOST:-}" \
    NEMOCLAW_MODEL="$SELECTED_MODEL" \
    NEMOCLAW_SPARK=true \
    bash "$SCRIPT_DIR/setup.sh"
else
  bash "$SCRIPT_DIR/setup.sh"
fi

# ── Summary ─────────────────────────────────────────────────────

stage "DGX Spark setup complete"

echo ""
echo -e "${BOLD}┌──────────────────────────────────────────────────────────────┐${NC}"
echo -e "${BOLD}│  NemoClaw on DGX Spark                                       │${NC}"
echo -e "${BOLD}│                                                              │${NC}"
echo -e "${BOLD}│  Hardware:   GB10 Grace Blackwell, ${TOTAL_MEMORY_MB} MB unified memory${NC}"
if [ "$DUAL_STACK" = true ]; then
echo -e "${BOLD}│  Stacking:   Dual-stack (256 GB combined)                    │${NC}"
fi
echo -e "${BOLD}│  Model:      $SELECTED_MODEL${NC}"
if [ "$LOCAL_INFERENCE" = true ]; then
echo -e "${BOLD}│  Inference:  Local vLLM on :8000                             │${NC}"
else
echo -e "${BOLD}│  Inference:  NVIDIA Cloud API                                │${NC}"
fi
echo -e "${BOLD}│  Sandbox:    Landlock + seccomp + netns                       │${NC}"
echo -e "${BOLD}│                                                              │${NC}"
echo -e "${BOLD}│  Connect:    nemoclaw my-assistant connect                    │${NC}"
echo -e "${BOLD}│  Status:     nemoclaw my-assistant status                     │${NC}"
echo -e "${BOLD}│  Logs:       nemoclaw my-assistant logs --follow              │${NC}"
echo -e "${BOLD}│  vLLM logs:  cat /tmp/vllm-spark.log                         │${NC}"
echo -e "${BOLD}└──────────────────────────────────────────────────────────────┘${NC}"
echo ""
