#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
set -euo pipefail
: "${NAMESPACE:?source scripts/env.sh first}"
: "${IMAGE:?}"
: "${NODE_INSTANCE_TYPE:?}"
: "${CONFIG_MAP:?}"
HERE=$(cd "$(dirname "$0")/../.." && pwd)

envsubst '$NAMESPACE $IMAGE $NODE_INSTANCE_TYPE $CONFIG_MAP' \
  < "$HERE/kubernetes/manifests/1.prep-dataset.yaml-template" | kubectl apply -f -

echo "Dataset prep submitted. Watch:"
echo "  kubectl -n $NAMESPACE logs -f qwen-prep-xlam"
