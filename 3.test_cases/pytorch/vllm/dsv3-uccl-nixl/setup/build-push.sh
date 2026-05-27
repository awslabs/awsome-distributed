#!/usr/bin/env bash
# Build the vLLM + UCCL-EP + NIXL image and push it to ECR.
#
# Reads REGISTRY / IMAGE / TAG / AWS_REGION from setup/env_vars.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ -z "${REGISTRY:-}" || -z "${IMAGE:-}" || -z "${TAG:-}" ]]; then
    echo "ERROR: source setup/env_vars first." >&2
    exit 1
fi

FULL_IMAGE="${REGISTRY}${IMAGE}:${TAG}"

echo "==> Building ${FULL_IMAGE}"
DOCKER_BUILDKIT=1 docker build \
    --platform linux/amd64 \
    -f "${PROJECT_DIR}/Dockerfile" \
    -t "${FULL_IMAGE}" \
    "${PROJECT_DIR}"

echo "==> Ensuring ECR repository exists"
if ! aws ecr describe-repositories --repository-names "${IMAGE}" --region "${AWS_REGION}" >/dev/null 2>&1; then
    aws ecr create-repository --repository-name "${IMAGE}" --region "${AWS_REGION}" >/dev/null
fi

echo "==> Logging in to ${REGISTRY}"
aws ecr get-login-password --region "${AWS_REGION}" \
    | docker login --username AWS --password-stdin "${REGISTRY%/}"

echo "==> Pushing ${FULL_IMAGE}"
docker push "${FULL_IMAGE}"

echo "==> Done. Image digest:"
docker inspect --format='{{index .RepoDigests 0}}' "${FULL_IMAGE}" || true
