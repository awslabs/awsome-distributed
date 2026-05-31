#!/bin/bash
# Create NGC image pull secret for Isaac Sim container access
#
# Prerequisites:
#   - kubectl configured for your EKS cluster
#   - NGC_API_KEY environment variable set (https://ngc.nvidia.com/setup/api-key)

set -euo pipefail

NAMESPACE="${NAMESPACE:-isaac-sim}"

if [ -z "${NGC_API_KEY:-}" ]; then
    echo "ERROR: NGC_API_KEY environment variable is not set."
    echo "Get your API key from: https://ngc.nvidia.com/setup/api-key"
    exit 1
fi

echo "Creating namespace ${NAMESPACE}..."
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

echo "Creating NGC image pull secret..."
kubectl create secret docker-registry ngc-secret \
    --docker-server=nvcr.io \
    --docker-username='$oauthtoken' \
    --docker-password="${NGC_API_KEY}" \
    -n "${NAMESPACE}" \
    --dry-run=client -o yaml | kubectl apply -f -

echo "NGC secret created in namespace ${NAMESPACE}."
