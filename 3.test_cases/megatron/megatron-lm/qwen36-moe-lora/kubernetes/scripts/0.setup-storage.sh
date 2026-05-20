#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
#
# Creates the FSx for Lustre StorageClass (version 2.15) and the shared PVC used
# by every subsequent step. Also creates a ConfigMap holding our Python scripts
# so training / eval pods can mount them.
#
# Prerequisite: env.sh sourced.
set -euo pipefail
: "${NAMESPACE:?source scripts/env.sh first}"
: "${FSX_SUBNET_ID:?}"
: "${FSX_SECURITY_GROUP:?}"
: "${FSX_SIZE_GB:?}"
: "${CONFIG_MAP:?}"

HERE=$(cd "$(dirname "$0")/../.." && pwd)

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

envsubst '$NAMESPACE $FSX_SUBNET_ID $FSX_SECURITY_GROUP $FSX_SIZE_GB' \
  < "$HERE/kubernetes/manifests/storage.yaml-template" | kubectl apply -f -

kubectl -n "$NAMESPACE" create configmap "$CONFIG_MAP" \
  --from-file="$HERE/src/xlam_runner.py" \
  --from-file="$HERE/src/export_lora_adapter.py" \
  --from-file="$HERE/src/prep_xlam_dataset.py" \
  --from-file="$HERE/src/eval_function_calling.py" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Waiting for PVC qwen-moe-lustre to be Bound (this takes 10-15 min for FSx)..."
kubectl -n "$NAMESPACE" wait --for=jsonpath='{.status.phase}'=Bound \
  pvc/qwen-moe-lustre --timeout=20m
echo "Storage ready."
