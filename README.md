# NemoClaw — DGX Spark Edition

**Fork of [NVIDIA/NemoClaw](https://github.com/NVIDIA/NemoClaw) optimised for DGX Spark (GB10 Grace Blackwell, 128 GB unified memory, ARM64).**

<!-- start-badges -->
[![License](https://img.shields.io/badge/License-Apache_2.0-blue)](https://github.com/NVIDIA/NemoClaw/blob/main/LICENSE)
[![Security Policy](https://img.shields.io/badge/Security-Report%20a%20Vulnerability-red)](https://github.com/NVIDIA/NemoClaw/blob/main/SECURITY.md)
[![Project Status](https://img.shields.io/badge/status-alpha-orange)](https://github.com/NVIDIA/NemoClaw/blob/main/docs/about/release-notes.md)
[![DGX Spark](https://img.shields.io/badge/DGX_Spark-optimised-76b900)](docs/deployment/dgx-spark.md)
<!-- end-badges -->

NemoClaw is an open source stack that runs [OpenClaw](https://openclaw.ai) agents inside the [NVIDIA OpenShell](https://github.com/NVIDIA/OpenShell) secure runtime (Landlock + seccomp + network namespaces).

This fork changes three things from upstream:

| Change | Upstream | This Fork |
|--------|----------|-----------|
| **Default model** | Nemotron 3 Super 120B (~87 GB) | **Nemotron Super 49B v1** (~24 GB) |
| **DGX Spark support** | Basic `setup-spark.sh` | Full setup, health check, benchmark, ARM64 Dockerfile |
| **Network policy presets** | 9 presets | **17 presets** (+AWS, GCP, Azure, GitHub, GitLab, PostgreSQL, Anthropic, OpenAI) |

The 49B model requires only 24 GB, leaving over 80 GB of headroom on a single Spark unit for the OS, Docker, OpenShell and concurrent workloads.

> **Alpha software** — based on upstream NemoClaw which is early-stage. Interfaces, APIs and behaviour may change without notice.

---

## DGX Spark Quick Start

```bash
export NVIDIA_API_KEY=nvapi-...
sudo bash scripts/setup-dgx-spark.sh
```

The script auto-detects the GB10 hardware, configures Docker for cgroup v2, selects the right model for available memory and runs the full NemoClaw setup.

**Options:**

```bash
# Local inference (no cloud calls, runs vLLM on Spark GPU)
sudo bash scripts/setup-dgx-spark.sh --local-inference

# Use the 120B model instead (fits on single Spark, ~87 GB)
sudo bash scripts/setup-dgx-spark.sh --model nvidia/nemotron-3-super-120b-a12b

# Dual-stack mode (two Spark units, 256 GB combined)
sudo bash scripts/setup-dgx-spark.sh --dual-stack

# Dry run (show what would happen)
sudo bash scripts/setup-dgx-spark.sh --dry-run
```

**After setup:**

```bash
# Validate everything is running
bash scripts/spark-health.sh

# Benchmark local vs cloud inference
bash scripts/spark-benchmark.sh

# Connect to the agent
nemoclaw my-assistant connect
```

Full deployment guide: [docs/deployment/dgx-spark.md](docs/deployment/dgx-spark.md)

---

## Standard Quick Start

<!-- start-quickstart-guide -->

Follow these steps to get started with NemoClaw and your first sandboxed OpenClaw agent.

:::{note}
NemoClaw currently requires a fresh installation of OpenClaw.
:::

### Prerequisites

Check the prerequisites before you start to ensure you have the necessary software and hardware to run NemoClaw.

#### Software

- Linux Ubuntu 22.04 LTS releases and later
- Node.js 20+ and npm 10+ (the installer recommends Node.js 22)
- Docker installed and running
- [NVIDIA OpenShell](https://github.com/NVIDIA/OpenShell) installed

### Install NemoClaw and Onboard OpenClaw Agent

Download and run the installer script.
The script installs Node.js if it is not already present, then runs the guided onboard wizard to create a sandbox, configure inference, and apply security policies.

```console
$ curl -fsSL https://nvidia.com/nemoclaw.sh | bash
```

When the install completes, a summary confirms the running environment:

```
──────────────────────────────────────────────────
Sandbox      my-assistant (Landlock + seccomp + netns)
Model        nvidia/llama-3.3-nemotron-super-49b-v1 (NVIDIA Cloud API)
──────────────────────────────────────────────────
Run:         nemoclaw my-assistant connect
Status:      nemoclaw my-assistant status
Logs:        nemoclaw my-assistant logs --follow
──────────────────────────────────────────────────

[INFO]  === Installation complete ===
```

### Chat with the Agent

Connect to the sandbox, then chat with the agent through the TUI or the CLI.

```console
$ nemoclaw my-assistant connect
```

#### OpenClaw TUI

The OpenClaw TUI opens an interactive chat interface. Type a message and press Enter to send it to the agent:

```console
sandbox@my-assistant:~$ openclaw tui
```

Send a test message to the agent and verify you receive a response.

#### OpenClaw CLI

Use the OpenClaw CLI to send a single message and print the response:

```console
sandbox@my-assistant:~$ openclaw agent --agent main --local -m "hello" --session-id test
```

<!-- end-quickstart-guide -->

---

## How It Works

NemoClaw installs the NVIDIA OpenShell runtime and Nemotron models, then uses a versioned blueprint to create a sandboxed environment where every network request, file access, and inference call is governed by declarative policy. The `nemoclaw` CLI orchestrates the full stack: OpenShell gateway, sandbox, inference provider, and network policy.

| Component        | Role                                                                                      |
|------------------|-------------------------------------------------------------------------------------------|
| **Plugin**       | TypeScript CLI commands for launch, connect, status, and logs.                            |
| **Blueprint**    | Versioned Python artifact that orchestrates sandbox creation, policy, and inference setup. |
| **Sandbox**      | Isolated OpenShell container running OpenClaw with policy-enforced egress and filesystem.  |
| **Inference**    | NVIDIA cloud model calls, routed through the OpenShell gateway, transparent to the agent.  |

The blueprint lifecycle follows four stages: resolve the artifact, verify its digest, plan the resources, and apply through the OpenShell CLI.

When something goes wrong, errors may originate from either NemoClaw or the OpenShell layer underneath. Run `nemoclaw <name> status` for NemoClaw-level health and `openshell sandbox list` to check the underlying sandbox state.

---

## Inference

Inference requests from the agent never leave the sandbox directly. OpenShell intercepts every call and routes it to the NVIDIA cloud provider.

| Provider     | Model                               | Use Case                                       |
|--------------|--------------------------------------|-------------------------------------------------|
| NVIDIA cloud | `nvidia/nemotron-3-super-120b-a12b` | Production. Requires an NVIDIA API key.         |

Get an API key from [build.nvidia.com](https://build.nvidia.com). The `nemoclaw onboard` command prompts for this key during setup.

---

## Protection Layers

The sandbox starts with a strict baseline policy that controls network egress and filesystem access:

| Layer      | What it protects                                    | When it applies             |
|------------|-----------------------------------------------------|-----------------------------|
| Network    | Blocks unauthorized outbound connections.           | Hot-reloadable at runtime.  |
| Filesystem | Prevents reads/writes outside `/sandbox` and `/tmp`.| Locked at sandbox creation. |
| Process    | Blocks privilege escalation and dangerous syscalls. | Locked at sandbox creation. |
| Inference  | Reroutes model API calls to controlled backends.    | Hot-reloadable at runtime.  |

When the agent tries to reach an unlisted host, OpenShell blocks the request and surfaces it in the TUI for operator approval.

---

## Key Commands

### Host commands (`nemoclaw`)

Run these on the host to set up, connect to, and manage sandboxes.

| Command                              | Description                                            |
|--------------------------------------|--------------------------------------------------------|
| `nemoclaw onboard`                  | Interactive setup wizard: gateway, providers, sandbox. |
| `nemoclaw deploy <instance>`         | Deploy to a remote GPU instance through Brev.          |
| `nemoclaw <name> connect`            | Open an interactive shell inside the sandbox.          |
| `openshell term`                     | Launch the OpenShell TUI for monitoring and approvals. |
| `nemoclaw start` / `stop` / `status` | Manage auxiliary services (Telegram bridge, tunnel).   |

### Plugin commands (`openclaw nemoclaw`)

Run these inside the OpenClaw CLI. These commands are under active development and may not all be functional yet.

| Command                                    | Description                                              |
|--------------------------------------------|----------------------------------------------------------|
| `openclaw nemoclaw launch [--profile ...]` | Bootstrap OpenClaw inside an OpenShell sandbox.          |
| `openclaw nemoclaw status`                 | Show sandbox health, blueprint state, and inference.     |
| `openclaw nemoclaw logs [-f]`              | Stream blueprint execution and sandbox logs.             |

See the full [CLI reference](https://docs.nvidia.com/nemoclaw/latest/reference/commands.md) for all commands, flags, and options.

> **Known limitations:**
> - The `openclaw nemoclaw` plugin commands are under active development. Use the `nemoclaw` host CLI as the primary interface.
> - Setup may require manual workarounds on some platforms. File an issue if you encounter blockers.

---

## Learn More

Refer to the documentation for more information on NemoClaw.

- [Overview](https://docs.nvidia.com/nemoclaw/latest/about/overview.html): what NemoClaw does and how it fits together
- [How It Works](https://docs.nvidia.com/nemoclaw/latest/about/how-it-works.html): plugin, blueprint, and sandbox lifecycle
- [Architecture](https://docs.nvidia.com/nemoclaw/latest/reference/architecture.html): plugin structure, blueprint lifecycle, and sandbox environment
- [Inference Profiles](https://docs.nvidia.com/nemoclaw/latest/reference/inference-profiles.html): NVIDIA cloud inference configuration
- [Network Policies](https://docs.nvidia.com/nemoclaw/latest/reference/network-policies.html): egress control and policy customization
- [CLI Commands](https://docs.nvidia.com/nemoclaw/latest/reference/commands.html): full command reference

## License

This project is licensed under the [Apache License 2.0](LICENSE).
