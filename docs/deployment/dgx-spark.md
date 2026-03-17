# Deploying NemoClaw on DGX Spark

Complete guide to running NemoClaw on NVIDIA DGX Spark with the Nemotron Super 49B v1 model.

## Hardware Overview

| Spec | DGX Spark |
|------|-----------|
| SoC | GB10 Grace Blackwell superchip |
| CPU | 20-core ARM64 (10x Cortex-X925 + 10x Cortex-A725) |
| GPU | Blackwell, 6144 CUDA cores, SM 12.1 |
| Memory | 128 GB unified LPDDR5x (273 GB/s, CPU + GPU shared) |
| AI Performance | 1 PFLOP FP4, 1000 TOPS inference |
| Storage | 1 TB or 4 TB NVMe SSD |
| Network | 10 GbE + ConnectX-7 (200 Gb/s), Wi-Fi 7 |
| OS | DGX OS (Ubuntu 24.04 LTS) |
| Power | 240W external, ~170W under AI load |
| Size | 150 x 150 x 50.5 mm (1.13 litres) |

The GB10 uses **unified memory**. The GPU and CPU share the full 128 GB pool via NVLink C2C with no PCIe bottleneck. This means models that would normally require dedicated VRAM can use the entire memory space.

## Model Selection

| Model | Total Params | Active Params | Memory Required | Fits Single Spark | Recommended |
|-------|-------------|---------------|-----------------|-------------------|-------------|
| Nemotron 3 Nano 30B | 30B | 3B (MoE) | ~8 GB | Yes | For constrained workloads |
| **Nemotron Super 49B v1** | **49B** | **49B** | **~24 GB** | **Yes** | **Default for this fork** |
| Nemotron 3 Super 120B | 120B | 12B (MoE) | ~87 GB | Yes (tight) | If you need maximum capability |
| Nemotron Ultra 253B | 253B | - | >128 GB | Dual-stack only | Requires two Spark units |

This fork defaults to **Nemotron Super 49B v1**. It requires only 24 GB, leaving over 80 GB of headroom for the OS, Docker, OpenShell, the agent runtime and concurrent workloads. The 120B model fits on a single Spark (~87 GB) but leaves minimal headroom.

## Prerequisites

DGX Spark ships with most dependencies pre-installed.

**Included with DGX OS:**
- Docker 28.x with NVIDIA Container Toolkit
- Python 3.12+
- NVIDIA drivers and CUDA 13.x
- `nvidia-smi` (reports "GB10" for the GPU name)

**You need:**
- Node.js 22+ and npm 10+ (the installer handles this)
- An NVIDIA API key from [build.nvidia.com](https://build.nvidia.com) (for cloud inference)
- OpenShell CLI (installed by setup script)

## Quick Start

```bash
# Set your API key
export NVIDIA_API_KEY=nvapi-...

# Run the Spark-optimised setup
sudo bash scripts/setup-dgx-spark.sh
```

The script will automatically:
1. Detect the GB10 hardware and unified memory
2. Select the Nemotron Super 49B v1 model
3. Add your user to the Docker group
4. Configure Docker for cgroup v2 (cgroupns=host)
5. Configure the NVIDIA Container Toolkit
6. Run the standard NemoClaw setup

## Setup Options

```bash
# Cloud inference (default) — uses NVIDIA Cloud API
sudo bash scripts/setup-dgx-spark.sh --cloud-inference

# Local inference — runs vLLM on the Spark GPU
sudo bash scripts/setup-dgx-spark.sh --local-inference

# Override model selection
sudo bash scripts/setup-dgx-spark.sh --model nvidia/nemotron-3-super-120b-a12b

# Dual-stack mode (two Spark units, 256 GB combined)
sudo bash scripts/setup-dgx-spark.sh --dual-stack

# Skip Docker reconfiguration (if already done)
sudo bash scripts/setup-dgx-spark.sh --skip-docker

# Dry run — show what would happen without executing
sudo bash scripts/setup-dgx-spark.sh --dry-run
```

## Using the Spark-Optimised Dockerfile

For building the sandbox image locally on Spark (ARM64 native):

```bash
docker build -f Dockerfile.spark -t nemoclaw-spark:latest .
```

The Spark Dockerfile differs from the standard image:
- Explicitly targets `linux/arm64` platform
- Defaults to Nemotron Super 49B v1
- Uses Python venv instead of `--break-system-packages`
- Multi-stage build for smaller image size

## Local Inference with vLLM

Running inference locally on Spark eliminates cloud latency and keeps all data on-device.

```bash
# Setup with local vLLM
sudo bash scripts/setup-dgx-spark.sh --local-inference
```

This starts vLLM on port 8000 with:
- Nemotron Super 49B v1 model
- 85% GPU memory utilisation (reserves 15% for system)
- Tensor parallel size 1 (single GPU)
- OpenAI-compatible API at `http://localhost:8000/v1`

Model loading takes 2-5 minutes on first run. Subsequent starts are faster with cached weights.

### Manual vLLM Start

```bash
python3 -m vllm.entrypoints.openai.api_server \
  --model nvidia/llama-3.3-nemotron-super-49b-v1 \
  --port 8000 \
  --host 0.0.0.0 \
  --dtype auto \
  --tensor-parallel-size 1 \
  --gpu-memory-utilization 0.85
```

## Health Check

After setup, verify everything is running:

```bash
bash scripts/spark-health.sh
```

This checks:
- GB10 hardware detection
- Unified memory availability
- Docker daemon and cgroup v2 configuration
- NVIDIA Container Toolkit
- OpenShell gateway status
- vLLM inference endpoint (if running)
- NVIDIA Cloud API reachability
- NemoClaw sandbox status
- Dashboard UI on port 18789

## Benchmarking

Compare local vLLM vs cloud inference:

```bash
# Benchmark local vLLM
bash scripts/spark-benchmark.sh --endpoint http://localhost:8000/v1

# Benchmark NVIDIA Cloud API
bash scripts/spark-benchmark.sh --endpoint https://integrate.api.nvidia.com/v1
```

The benchmark runs three test profiles:
- **Latency** — short prompt, 16 token response
- **Throughput** — medium prompt, 256 token response
- **Sustained** — long prompt, 1024 token response

## Dual-Stack Configuration

Two DGX Spark units can be connected via QSFP56 DAC cable for 256 GB combined memory. This enables running models up to 405B parameters.

```bash
# Enable dual-stack mode
sudo bash scripts/setup-dgx-spark.sh --dual-stack --model nvidia/nemotron-3-super-120b-a12b
```

Dual-stack requirements:
- Two DGX Spark units
- QSFP56 DAC cable connecting the ConnectX-7 ports
- Both units running the same DGX OS version

## DGX Spark-Specific Notes

### Unified Memory

The GB10 reports memory differently from discrete GPUs. `nvidia-smi --query-gpu=memory.total` may not return values because there is no separate VRAM. The setup script falls back to system memory detection via `/proc/meminfo`. This is expected behaviour.

### cgroup v2

DGX OS (Ubuntu 24.04) uses cgroup v2. OpenShell's gateway runs k3s inside a Docker container, which requires `--cgroupns=host` to manage cgroup hierarchies. The setup script configures this in `/etc/docker/daemon.json`.

Without this configuration, kubelet fails with:
```
openat2 /sys/fs/cgroup/kubepods/pids.max: no
```

### ARM64 Container Images

DGX Spark is ARM64 (aarch64). Docker images built for `linux/amd64` will not run. Always verify ARM64 support before pulling images. The `Dockerfile.spark` explicitly targets `linux/arm64`.

### PyTorch SM 12.1 Warning

PyTorch 2.9.x may emit a warning about SM 12.1 compute capability. This is safely ignorable and fixed in PyTorch 2.10+.

### Docker GPU Access

GPU passthrough uses `--gpus all` with the NVIDIA Container Toolkit (OCI hooks). Ensure the toolkit is configured:
```bash
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
```

## Troubleshooting

**Docker fails to start after cgroup change:**
```bash
sudo systemctl status docker
# Check for JSON syntax errors in daemon.json
sudo python3 -c "import json; json.load(open('/etc/docker/daemon.json'))"
```

**vLLM exits immediately:**
```bash
cat /tmp/vllm-spark.log
# Common causes: insufficient memory, missing CUDA libraries, model download failure
```

**OpenShell gateway fails to connect:**
```bash
openshell gateway info
# Ensure Docker is running and cgroup v2 is configured
openshell gateway destroy -g nemoclaw
openshell gateway start --name nemoclaw --gpu
```

**"No GPU detected" in nvidia-smi:**
This is normal on DGX Spark. The GB10 unified memory architecture reports differently from discrete GPUs. The setup script handles this via the GB10 name detection fallback.

**Model too large for memory:**
```bash
# Check available memory
free -h
# Use a smaller model
sudo bash scripts/setup-dgx-spark.sh --model nvidia/nemotron-3-nano-30b-a3b
```
