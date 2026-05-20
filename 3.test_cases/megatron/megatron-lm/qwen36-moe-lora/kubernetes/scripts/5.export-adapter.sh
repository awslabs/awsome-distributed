#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
set -euo pipefail
: "${NAMESPACE:?source scripts/env.sh first}"
: "${IMAGE:?}"
: "${NODE_INSTANCE_TYPE:?}"
: "${GPU_PER_NODE:?}"; : "${EFA_PER_NODE:?}"
: "${CONFIG_MAP:?}"
: "${HF_MODEL_ID:?}"
: "${ITER:?}"
: "${TP:?}"; : "${PP:?}"; : "${EP:?}"
HERE=$(cd "$(dirname "$0")/../.." && pwd)

envsubst '$NAMESPACE $IMAGE $NODE_INSTANCE_TYPE $GPU_PER_NODE $EFA_PER_NODE $CONFIG_MAP $HF_MODEL_ID $ITER $TP $PP $EP' \
  < "$HERE/kubernetes/manifests/4.export-adapter.yaml-template" | kubectl apply -f -

echo "Adapter export submitted. Watch:"
echo "  kubectl -n $NAMESPACE logs -f qwen-export-adapter"
