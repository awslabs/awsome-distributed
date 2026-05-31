#!/bin/bash
# Build and push the AMR pipeline container images to Amazon ECR
#
# Prerequisites:
#   - Docker installed and running
#   - AWS CLI configured with ECR push permissions
#   - NGC_API_KEY set (to pull base image from nvcr.io)

set -euo pipefail

REGION="${AWS_REGION:-us-west-2}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
IMAGE_TAG="${IMAGE_TAG:-latest}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$(dirname "${SCRIPT_DIR}")"

# Image URIs for all 3 pipeline images
ISAAC_SIM_REPO="${ISAAC_SIM_REPO:-isaac-sim-amr}"
COSMOS_REPO="${COSMOS_REPO:-cosmos-transfer-amr}"
XMOBILITY_REPO="${XMOBILITY_REPO:-xmobility-amr}"

ISAAC_SIM_IMAGE_URI="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${ISAAC_SIM_REPO}:${IMAGE_TAG}"
COSMOS_IMAGE_URI="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${COSMOS_REPO}:${IMAGE_TAG}"
XMOBILITY_IMAGE_URI="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${XMOBILITY_REPO}:${IMAGE_TAG}"

echo "=== Building AMR Pipeline containers ==="
echo "  Region:    ${REGION}"
echo "  Account:   ${ACCOUNT_ID}"
echo ""
echo "  Images:"
echo "    Isaac Sim AMR: ${ISAAC_SIM_IMAGE_URI}"
echo "    Cosmos:        ${COSMOS_IMAGE_URI}"
echo "    X-Mobility:    ${XMOBILITY_IMAGE_URI}"

# Authenticate to NGC (base image)
if [ -n "${NGC_API_KEY:-}" ]; then
    echo "Logging in to NGC registry..."
    echo "${NGC_API_KEY}" | docker login nvcr.io --username '$oauthtoken' --password-stdin
fi

# Authenticate to ECR
aws ecr get-login-password --region "${REGION}" | \
    docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

# Create ECR repos if they don't exist
for repo in "${ISAAC_SIM_REPO}" "${COSMOS_REPO}" "${XMOBILITY_REPO}"; do
    aws ecr describe-repositories --repository-names "${repo}" --region "${REGION}" 2>/dev/null || \
        aws ecr create-repository --repository-name "${repo}" --region "${REGION}"
done

# Build 3 pipeline images
echo ""
echo "--- Building Isaac Sim AMR image (stages 1-4) ---"
docker build -t "${ISAAC_SIM_IMAGE_URI}" -f "${BUILD_DIR}/Dockerfile.isaac-sim" "${BUILD_DIR}"
docker push "${ISAAC_SIM_IMAGE_URI}"

echo ""
echo "--- Building Cosmos Transfer image (stage 5) ---"
docker build -t "${COSMOS_IMAGE_URI}" -f "${BUILD_DIR}/Dockerfile.cosmos-transfer" "${BUILD_DIR}"
docker push "${COSMOS_IMAGE_URI}"

echo ""
echo "--- Building X-Mobility image (stage 6) ---"
docker build -t "${XMOBILITY_IMAGE_URI}" -f "${BUILD_DIR}/Dockerfile.xmobility" "${BUILD_DIR}"
docker push "${XMOBILITY_IMAGE_URI}"

echo ""
echo "=== All images pushed ==="
echo ""
echo "Export for use with submit scripts:"
echo "  export ISAAC_SIM_IMAGE_URI=${ISAAC_SIM_IMAGE_URI}"
echo "  export COSMOS_IMAGE_URI=${COSMOS_IMAGE_URI}"
echo "  export XMOBILITY_IMAGE_URI=${XMOBILITY_IMAGE_URI}"
