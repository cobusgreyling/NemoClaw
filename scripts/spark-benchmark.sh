#!/usr/bin/env bash
# NemoClaw — DGX Spark inference benchmark
#
# Tests inference latency and throughput for the configured model.
# Useful for comparing local vLLM vs NVIDIA Cloud API on Spark.
#
# Usage:
#   bash scripts/spark-benchmark.sh [--endpoint URL] [--model MODEL] [--rounds N]

set -euo pipefail

GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

ENDPOINT="${1:-http://localhost:8000/v1}"
MODEL="${2:-nvidia/llama-3.3-nemotron-super-49b-v1}"
ROUNDS="${3:-5}"

# Parse named arguments
while [ $# -gt 0 ]; do
  case "$1" in
    --endpoint) ENDPOINT="$2"; shift ;;
    --model)    MODEL="$2"; shift ;;
    --rounds)   ROUNDS="$2"; shift ;;
    *)          ;;
  esac
  shift 2>/dev/null || true
done

echo -e "${BOLD}NemoClaw Spark Benchmark${NC}"
echo -e "Endpoint: $ENDPOINT"
echo -e "Model:    $MODEL"
echo -e "Rounds:   $ROUNDS"
echo ""

# Short prompt for latency test
SHORT_PROMPT="What is 2+2? Answer in one word."

# Medium prompt for throughput test
MEDIUM_PROMPT="Explain the difference between supervised and unsupervised learning in exactly three sentences."

# Long prompt for sustained throughput
LONG_PROMPT="Write a detailed technical comparison of Docker containers vs WebAssembly sandboxes for AI agent isolation. Cover security, performance, portability, and developer experience. Be thorough."

run_test() {
  local label="$1"
  local prompt="$2"
  local max_tokens="$3"

  echo -e "${CYAN}── $label ──${NC}"

  TOTAL_MS=0
  TOTAL_TOKENS=0

  for i in $(seq 1 "$ROUNDS"); do
    START_MS=$(date +%s%N)

    RESPONSE=$(curl -s -w "\n%{time_total}" "$ENDPOINT/chat/completions" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer ${NVIDIA_API_KEY:-dummy}" \
      -d "{
        \"model\": \"$MODEL\",
        \"messages\": [{\"role\": \"user\", \"content\": \"$prompt\"}],
        \"max_tokens\": $max_tokens,
        \"temperature\": 0.1
      }" 2>/dev/null)

    # Extract timing from curl
    CURL_TIME=$(echo "$RESPONSE" | tail -1)
    BODY=$(echo "$RESPONSE" | head -n -1)

    # Extract token count from response
    TOKENS=$(echo "$BODY" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    u = d.get('usage', {})
    print(u.get('completion_tokens', 0))
except:
    print(0)
" 2>/dev/null || echo "0")

    TIME_MS=$(echo "$CURL_TIME" | python3 -c "import sys; print(int(float(sys.stdin.read().strip()) * 1000))" 2>/dev/null || echo "0")

    if [ "$TOKENS" -gt 0 ] && [ "$TIME_MS" -gt 0 ]; then
      TPS=$(python3 -c "print(f'{$TOKENS / ($TIME_MS / 1000):.1f}')" 2>/dev/null || echo "n/a")
      TTFT="n/a"
      echo "  Round $i: ${TIME_MS}ms, ${TOKENS} tokens, ${TPS} tok/s"
      TOTAL_MS=$((TOTAL_MS + TIME_MS))
      TOTAL_TOKENS=$((TOTAL_TOKENS + TOKENS))
    else
      echo "  Round $i: failed (endpoint may be down)"
    fi
  done

  if [ "$TOTAL_MS" -gt 0 ] && [ "$TOTAL_TOKENS" -gt 0 ]; then
    AVG_MS=$((TOTAL_MS / ROUNDS))
    AVG_TPS=$(python3 -c "print(f'{$TOTAL_TOKENS / ($TOTAL_MS / 1000):.1f}')" 2>/dev/null || echo "n/a")
    echo -e "  ${GREEN}Average: ${AVG_MS}ms, ${AVG_TPS} tok/s${NC}"
  fi
  echo ""
}

# Check endpoint is reachable
if ! curl -s "$ENDPOINT/models" > /dev/null 2>&1; then
  echo "Endpoint $ENDPOINT is not reachable."
  echo "Start vLLM first: python3 -m vllm.entrypoints.openai.api_server --model $MODEL --port 8000"
  exit 1
fi

# System info
echo -e "${BOLD}System${NC}"
if command -v nvidia-smi > /dev/null 2>&1; then
  GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader,nounits 2>/dev/null || echo "unknown")
  echo "GPU: $GPU_NAME"
fi
TOTAL_MEM=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo "unknown")
echo "Memory: ${TOTAL_MEM} MB"
echo "Arch: $(uname -m)"
echo ""

run_test "Latency (short prompt, 16 tokens max)" "$SHORT_PROMPT" 16
run_test "Throughput (medium prompt, 256 tokens max)" "$MEDIUM_PROMPT" 256
run_test "Sustained (long prompt, 1024 tokens max)" "$LONG_PROMPT" 1024

echo -e "${BOLD}Benchmark complete.${NC}"
echo "Compare local vLLM vs cloud by running with different --endpoint values."
