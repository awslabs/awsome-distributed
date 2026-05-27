#!/usr/bin/env bash
# Delete all pods this sample created. Keeps the namespace and HF secret.

set -euo pipefail

if [[ -z "${NAMESPACE:-}" ]]; then
    echo "ERROR: source setup/env_vars first." >&2
    exit 1
fi

echo "==> Deleting dsv3-disagg pods in namespace ${NAMESPACE}"
kubectl delete pod --selector=app=dsv3-disagg --namespace "${NAMESPACE}" --ignore-not-found
echo "==> Done."
