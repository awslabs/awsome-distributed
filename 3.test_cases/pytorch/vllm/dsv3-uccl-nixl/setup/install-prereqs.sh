#!/usr/bin/env bash
# Install the NVIDIA device plugin and the AWS EFA Kubernetes device plugin
# on a vanilla EKS cluster. Skip this on SageMaker HyperPod EKS — both
# plugins are pre-installed there.

set -euo pipefail

NVIDIA_PLUGIN_VERSION="${NVIDIA_PLUGIN_VERSION:-v0.16.2}"
EFA_PLUGIN_VERSION="${EFA_PLUGIN_VERSION:-v0.5.7}"

echo "==> Installing NVIDIA Kubernetes device plugin ${NVIDIA_PLUGIN_VERSION}"
kubectl apply -f \
    "https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/${NVIDIA_PLUGIN_VERSION}/deployments/static/nvidia-device-plugin.yml"

echo "==> Installing AWS EFA Kubernetes device plugin ${EFA_PLUGIN_VERSION}"
kubectl apply -f \
    "https://raw.githubusercontent.com/aws-samples/aws-efa-eks/main/manifest/efa-k8s-device-plugin.yml"

echo "==> Waiting for plugins to roll out"
kubectl -n kube-system rollout status ds/nvidia-device-plugin-daemonset --timeout=300s
kubectl -n kube-system rollout status ds/aws-efa-k8s-device-plugin-daemonset --timeout=300s

echo "==> Sample node allocatable (look for nvidia.com/gpu and vpc.amazonaws.com/efa):"
kubectl get nodes -o json \
    | jq -r '.items[].status.allocatable
        | with_entries(select(.key == "nvidia.com/gpu" or .key == "vpc.amazonaws.com/efa"))' \
    || true
