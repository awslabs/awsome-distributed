#!/usr/bin/env bash
# Quick OSMO control plane readiness check before submitting workflows.
# Verifies the minimum components needed for OSMO workflow execution.
set -euo pipefail

echo "=== OSMO Pre-flight Check ==="

ERRORS=0

# Check OSMO CRD
if kubectl get crd workflows.osmo.nvidia.com > /dev/null 2>&1; then
  echo "[OK] OSMO Workflow CRD installed"
else
  echo "[FAIL] OSMO Workflow CRD not found — install OSMO first"
  ((ERRORS++))
fi

# Check db-secret
if kubectl get secret db-secret -n osmo-system > /dev/null 2>&1; then
  echo "[OK] db-secret exists in osmo-system"
else
  echo "[FAIL] db-secret not found — run secrets sync job"
  ((ERRORS++))
fi

# Check OSMO service pods
OSMO_READY=$(kubectl get pods -n osmo-system -l app.kubernetes.io/name=osmo-service \
  --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
if [ "$OSMO_READY" -gt 0 ]; then
  echo "[OK] osmo-service running (${OSMO_READY} pod(s))"
else
  echo "[FAIL] osmo-service not running"
  ((ERRORS++))
fi

# Check KAI scheduler
KAI_READY=$(kubectl get pods -n kai-scheduler --field-selector=status.phase=Running \
  --no-headers 2>/dev/null | wc -l)
if [ "$KAI_READY" -gt 0 ]; then
  echo "[OK] KAI scheduler running (${KAI_READY} pod(s))"
else
  echo "[FAIL] KAI scheduler not running"
  ((ERRORS++))
fi

# Check NodePools
for pool in osmo-rendering osmo-gpu-training osmo-cpu-batch osmo-cpu-system; do
  if kubectl get nodepool "$pool" > /dev/null 2>&1; then
    echo "[OK] NodePool ${pool}"
  else
    echo "[WARN] NodePool ${pool} not found"
  fi
done

echo ""
if [ "$ERRORS" -eq 0 ]; then
  echo "=== All checks passed — ready to submit OSMO workflows ==="
else
  echo "=== ${ERRORS} check(s) failed — fix before submitting workflows ==="
  exit 1
fi
