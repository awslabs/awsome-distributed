#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
set -euo pipefail
: "${NAMESPACE:?source scripts/env.sh first}"
: "${IMAGE:?}"
: "${NODE_INSTANCE_TYPE:?}"
: "${NUM_NODES:?}"; : "${GPU_PER_NODE:?}"; : "${EFA_PER_NODE:?}"
: "${CONFIG_MAP:?}"
: "${HF_MODEL_ID:?}"
: "${TP:?}"; : "${PP:?}"; : "${EP:?}"
: "${TRAIN_ITERS:?}"; : "${GLOBAL_BS:?}"; : "${MICRO_BS:?}"
HERE=$(cd "$(dirname "$0")/../.." && pwd)

# Re-create the ConfigMap to pick up any local edits to src/ since setup.
kubectl -n "$NAMESPACE" create configmap "$CONFIG_MAP" \
  --from-file="$HERE/src/xlam_runner.py" \
  --from-file="$HERE/src/export_lora_adapter.py" \
  --from-file="$HERE/src/prep_xlam_dataset.py" \
  --from-file="$HERE/src/eval_function_calling.py" \
  --dry-run=client -o yaml | kubectl apply -f -

envsubst '$NAMESPACE $IMAGE $NODE_INSTANCE_TYPE $NUM_NODES $GPU_PER_NODE $EFA_PER_NODE $CONFIG_MAP $HF_MODEL_ID $TP $PP $EP $TRAIN_ITERS $GLOBAL_BS $MICRO_BS' \
  < "$HERE/kubernetes/manifests/3.pytorchjob-train.yaml-template" | kubectl apply -f -

echo "Training submitted. Watch:"
echo "  kubectl -n $NAMESPACE get pytorchjob"
echo "  kubectl -n $NAMESPACE logs -f qwen36-xlam-train-worker-0"
