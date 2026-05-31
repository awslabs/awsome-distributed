#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# Build the model-agnostic Megatron-Bridge + UCCL-EP environment image and push
# it to Amazon ECR. This image is shared by every model test case under this
# library — per-model SFT configs are mounted at runtime, not baked in.
#
# Usage:
#   ./1.build-and-push.sh
#
# Override defaults via environment variables:
#   TAG=<tag>       Image tag (default: nemo-25.11.01-uccl-0dc87eb)
#   REGION=<region> AWS region (default: us-west-2)
#   ACCOUNT=<id>    AWS account ID (default: 159553542841)
#   REPO_NAME=<name> ECR repository name (default: megatron-bridge-uccl)
#
# Prerequisites:
#   - AWS CLI configured with credentials that have ECR push access.
#   - Docker running (buildx not required; plain docker build is used).
#   - Run from the directory containing Dockerfile.

set -euo pipefail

###########################
###### User Variables #####
###########################

TAG="${TAG:-nemo-25.11.01-uccl-0dc87eb}"
REGION="${REGION:-us-west-2}"
ACCOUNT="${ACCOUNT:-159553542841}"
REPO_NAME="${REPO_NAME:-megatron-bridge-uccl}"

###########################
###### Derived Values #####
###########################

REGISTRY="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"
LOCAL_IMAGE="${REPO_NAME}:${TAG}"
REMOTE_IMAGE="${REGISTRY}/${REPO_NAME}:${TAG}"
DOCKERFILE="Dockerfile"

echo "============================================"
echo "Megatron-Bridge UCCL-EP env image — Docker Build & Push"
echo "============================================"
echo "Dockerfile : ${DOCKERFILE}"
echo "Local tag  : ${LOCAL_IMAGE}"
echo "ECR image  : ${REMOTE_IMAGE}"
echo "Region     : ${REGION}"
echo "Account    : ${ACCOUNT}"
echo "============================================"

###########################
####### Verify Dockerfile #
###########################

if [ ! -f "${DOCKERFILE}" ]; then
    echo "ERROR: ${DOCKERFILE} not found in $(pwd)."
    echo "Run this script from the directory that contains it."
    exit 1
fi

###########################
######### Build ###########
###########################

echo ""
echo "Building image: ${LOCAL_IMAGE} ..."
docker build \
    --progress=plain \
    -f "${DOCKERFILE}" \
    -t "${LOCAL_IMAGE}" \
    .

###########################
######### ECR Setup #######
###########################

echo ""
echo "Logging in to ECR: ${REGISTRY} ..."
aws ecr get-login-password --region "${REGION}" \
    | docker login --username AWS --password-stdin "${REGISTRY}"

echo ""
echo "Ensuring ECR repository '${REPO_NAME}' exists ..."
if aws ecr describe-repositories \
        --repository-names "${REPO_NAME}" \
        --region "${REGION}" \
        >/dev/null 2>&1; then
    echo "  Repository already exists — skipping creation."
else
    echo "  Repository not found — creating..."
    aws ecr create-repository \
        --repository-name "${REPO_NAME}" \
        --region "${REGION}" \
        --image-scanning-configuration scanOnPush=true
    echo "  Repository created."
fi

###########################
######## Tag & Push #######
###########################

echo ""
echo "Tagging: ${LOCAL_IMAGE} -> ${REMOTE_IMAGE}"
docker tag "${LOCAL_IMAGE}" "${REMOTE_IMAGE}"

echo ""
echo "Pushing: ${REMOTE_IMAGE} ..."
docker push "${REMOTE_IMAGE}"

echo ""
echo "============================================"
echo "Done!  Image available at:"
echo "  ${REMOTE_IMAGE}"
echo ""
echo "Export for subsequent scripts:"
echo "  export IMAGE=${REMOTE_IMAGE}"
echo "============================================"
