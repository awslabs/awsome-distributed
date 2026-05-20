#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
set -euo pipefail
: "${NAMESPACE:?source scripts/env.sh first}"
: "${IMAGE:?}"
: "${NODE_INSTANCE_TYPE:?}"
: "${CONFIG_MAP:?}"
: "${HF_MODEL_ID:?}"
: "${GATE:?}"
: "${N_SAMPLES:?}"
: "${BEDROCK_REGION:?}"
: "${JUDGE_MODEL:?}"
HERE=$(cd "$(dirname "$0")/../.." && pwd)

# Delete any prior Job with the same name (Jobs are immutable on spec).
kubectl -n "$NAMESPACE" delete job qwen-eval --ignore-not-found --wait=true >/dev/null

envsubst '$NAMESPACE $IMAGE $NODE_INSTANCE_TYPE $CONFIG_MAP $HF_MODEL_ID $GATE $N_SAMPLES $BEDROCK_REGION $JUDGE_MODEL' \
  < "$HERE/kubernetes/manifests/6.eval-job.yaml-template" | kubectl apply -f -

echo "Eval Job submitted. Watch:"
echo "  kubectl -n $NAMESPACE logs -f job/qwen-eval"
