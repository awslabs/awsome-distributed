#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
#
# Tears down every Kubernetes resource created by this test case. Preserves the
# FSx Lustre PVC so the weights + dataset + adapter persist (delete manually if
# you want the underlying filesystem to be deleted too).
set -euo pipefail
: "${NAMESPACE:?source scripts/env.sh first}"

kubectl -n "$NAMESPACE" delete deployment,service qwen-inference --ignore-not-found --wait=false
kubectl -n "$NAMESPACE" delete pytorchjob qwen36-xlam-train --ignore-not-found
kubectl -n "$NAMESPACE" delete job qwen-eval --ignore-not-found
kubectl -n "$NAMESPACE" delete pod \
  qwen-precache-weights \
  qwen-prep-xlam \
  qwen-convert-to-bridge \
  qwen-export-adapter \
  --ignore-not-found

echo "Stateless resources removed. PVC qwen-moe-lustre retained."
echo "To also delete persistent data:"
echo "  kubectl -n $NAMESPACE delete pvc qwen-moe-lustre"
