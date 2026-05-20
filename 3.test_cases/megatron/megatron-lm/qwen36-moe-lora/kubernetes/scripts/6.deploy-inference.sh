#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
set -euo pipefail
: "${NAMESPACE:?source scripts/env.sh first}"
: "${VLLM_IMAGE:?}"
: "${NODE_INSTANCE_TYPE:?}"
: "${HF_MODEL_ID:?}"
: "${LORA_SOURCE:?}"
: "${LORA_REPO:?}"
: "${TP:?}"
HERE=$(cd "$(dirname "$0")/../.." && pwd)

envsubst '$NAMESPACE $VLLM_IMAGE $NODE_INSTANCE_TYPE $HF_MODEL_ID $LORA_SOURCE $LORA_REPO $TP' \
  < "$HERE/kubernetes/manifests/5.inference-vllm.yaml-template" | kubectl apply -f -

echo "vLLM deployment submitted. Wait for Ready:"
echo "  kubectl -n $NAMESPACE rollout status deployment/qwen-inference --timeout=15m"
echo "Then the endpoint is:"
echo "  http://qwen-inference.$NAMESPACE.svc.cluster.local:8000"
