#!/bin/bash
# Submit the AMR Navigation Pipeline as OSMO workflows
#
# Submits two OSMO workflows:
#   1. Data pipeline (combination workflow) — stages 1-5 with parallel rendering
#   2. Training workflow (single-task) — stage 6 on P-series Capacity Blocks
#
# Prerequisites:
#   - kubectl configured for your EKS cluster
#   - OSMO installed on the cluster
#   - NGC secret created (0.setup-ngc-secret.sh)
#   - All 3 container images built and pushed (1.build-container.sh)
#   - S3 bucket created with IRSA configured
#
# Environment variables:
#   ISAAC_SIM_IMAGE_URI  - Isaac Sim AMR image (stages 1-4) (required)
#   COSMOS_IMAGE_URI     - Cosmos Transfer image (stage 5) (required)
#   XMOBILITY_IMAGE_URI  - X-Mobility training image (stage 6) (required)
#   S3_BUCKET            - S3 bucket for pipeline data (required)
#   RUN_ID               - Pipeline run identifier (default: timestamp)
#   NAMESPACE            - K8s namespace (default: isaac-sim)
#   NUM_TRAJECTORIES     - Number of trajectories (default: 10)
#   NUM_AISLES           - Warehouse aisles (default: 4)
#   PRETRAIN_EPOCHS      - World model pretrain epochs (default: 10)
#   TRAIN_EPOCHS         - Policy fine-tune epochs (default: 10)
#   SKIP_TRAINING        - Set to "true" to submit data pipeline only

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Validate required variables
for var in ISAAC_SIM_IMAGE_URI COSMOS_IMAGE_URI S3_BUCKET; do
    if [ -z "${!var:-}" ]; then
        echo "ERROR: ${var} environment variable is not set."
        exit 1
    fi
done

export NAMESPACE="${NAMESPACE:-isaac-sim}"
export RUN_ID="${RUN_ID:-$(date +%Y%m%d-%H%M%S)}"
export NUM_TRAJECTORIES="${NUM_TRAJECTORIES:-10}"
export NUM_AISLES="${NUM_AISLES:-4}"
export PRETRAIN_EPOCHS="${PRETRAIN_EPOCHS:-10}"
export TRAIN_EPOCHS="${TRAIN_EPOCHS:-10}"

echo "=== Submitting AMR Navigation Pipeline ==="
echo "  Isaac Sim Image:  ${ISAAC_SIM_IMAGE_URI}"
echo "  Cosmos Image:     ${COSMOS_IMAGE_URI}"
echo "  S3 Bucket:        ${S3_BUCKET}"
echo "  Run ID:           ${RUN_ID}"
echo "  Namespace:        ${NAMESPACE}"
echo "  Trajectories:     ${NUM_TRAJECTORIES}"
echo "  Warehouse Aisles: ${NUM_AISLES}"

# Apply IRSA ServiceAccount
echo ""
echo "--- Setting up ServiceAccount ---"
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
envsubst < "${SCRIPT_DIR}/serviceaccount.yaml" | kubectl apply -f -

# Submit data pipeline (combination workflow — stages 1-5)
echo ""
echo "--- Submitting Data Pipeline (combination workflow) ---"
envsubst < "${SCRIPT_DIR}/data-pipeline-workflow.yaml" | osmo workflow submit -f -

echo "  Data pipeline submitted: amr-data-pipeline-${RUN_ID}"
echo "  Parallel rendering: rgb + depth + segmentation on 3 G-series GPUs"

# Submit training workflow (single-task — stage 6)
if [ "${SKIP_TRAINING:-false}" != "true" ]; then
    if [ -z "${XMOBILITY_IMAGE_URI:-}" ]; then
        echo ""
        echo "WARNING: XMOBILITY_IMAGE_URI not set — skipping training workflow"
    else
        echo ""
        echo "--- Submitting Training Workflow ---"
        envsubst < "${SCRIPT_DIR}/training-workflow.yaml" | osmo workflow submit -f -
        echo "  Training submitted: amr-training-${RUN_ID}"
        echo "  8 GPUs on P-series Capacity Blocks"
    fi
else
    echo ""
    echo "--- Skipping training (SKIP_TRAINING=true) ---"
fi

echo ""
echo "=== Workflows submitted ==="
echo ""
echo "Monitor with:"
echo "  osmo workflow list"
echo "  osmo workflow status amr-data-pipeline-${RUN_ID}"
echo "  osmo workflow status amr-training-${RUN_ID}"
echo ""
echo "S3 output path:"
echo "  s3://${S3_BUCKET}/amr-pipeline/${RUN_ID}/"
