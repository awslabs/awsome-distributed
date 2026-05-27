#!/usr/bin/env bash
# Warm up and run a rate sweep against a deployed topology.
#
# Usage:
#   ./recipe/benchmark.sh <topology> [results_dir]
#
# Where <topology> is one of unified|1p1d|1p3d|1p4d|1p5d. The script targets
# http://${PREFILL_IP}:${PORT} where PORT=8000 (proxy for disaggregated, vLLM
# directly for unified).

set -euo pipefail

TOPOLOGY="${1:-}"
RESULT_DIR="${2:-results/${TOPOLOGY}}"

if [[ -z "${TOPOLOGY}" ]]; then
    echo "Usage: $0 <unified|1p1d|1p3d|1p4d|1p5d> [results_dir]" >&2
    exit 1
fi
if [[ -z "${PREFILL_IP:-}" || -z "${MODEL:-}" ]]; then
    echo "ERROR: source setup/env_vars first." >&2
    exit 1
fi

ENDPOINT="http://${PREFILL_IP}:8000"

mkdir -p "${RESULT_DIR}"

echo "==> Warmup against ${ENDPOINT}"
vllm bench serve \
    --base-url "${ENDPOINT}" \
    --model "${MODEL}" \
    --dataset-name random \
    --random-input-len 1024 \
    --random-output-len 256 \
    --num-prompts 10 \
    --request-rate 1 \
    --seed 1234

echo "==> Rate sweep (results -> ${RESULT_DIR})"
for RATE in 1 4 8 16 inf; do
    echo "----- rate=${RATE} -----"
    vllm bench serve \
        --base-url "${ENDPOINT}" \
        --model "${MODEL}" \
        --dataset-name random \
        --random-input-len 1024 \
        --random-output-len 256 \
        --num-prompts 50 \
        --request-rate "${RATE}" \
        --metric-percentiles "50,90,95,99" \
        --seed 1234 \
        --save-result \
        --result-dir "${RESULT_DIR}"
done

echo "==> Done. Result JSON files in ${RESULT_DIR}"
