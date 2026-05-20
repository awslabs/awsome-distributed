#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
set -euo pipefail
: "${NAMESPACE:?source scripts/env.sh first}"
: "${IMAGE:?}"
: "${HF_MODEL_ID:?}"
: "${NODE_INSTANCE_TYPE:?}"
: "${HF_TOKEN_SECRET:=hf-token}"
HERE=$(cd "$(dirname "$0")/../.." && pwd)

envsubst '$NAMESPACE $IMAGE $HF_MODEL_ID $NODE_INSTANCE_TYPE $HF_TOKEN_SECRET' \
  < "$HERE/kubernetes/manifests/0.precache-weights.yaml-template" | kubectl apply -f -

echo "Precache submitted. Watch:"
echo "  kubectl -n $NAMESPACE logs -f qwen-precache-weights"
