#!/usr/bin/env bash
# Render and apply manifests for a chosen disaggregation topology.
#
# Usage:
#   ./recipe/deploy.sh <topology>
#
# Where <topology> is one of:
#   unified  → 1 node, single dsv3-unified pod
#   1p1d     → 1 prefill + 1 decode (2 nodes)
#   1p3d     → 1 prefill + 3 decode (4 nodes)
#   1p4d     → 1 prefill + 4 decode (5 nodes — peak burst RPS)
#   1p5d     → 1 prefill + 5 decode (6 nodes)
#
# Reads node hostnames + IPs and image / model config from setup/env_vars.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
MANIFEST_DIR="${PROJECT_DIR}/manifests"

TOPOLOGY="${1:-}"
if [[ -z "${TOPOLOGY}" ]]; then
    echo "Usage: $0 <unified|1p1d|1p3d|1p4d|1p5d>" >&2
    exit 1
fi

# Sanity check required environment.
required=(NAMESPACE INSTANCE_TYPE REGISTRY IMAGE TAG MODEL
          PREFILL_NODE PREFILL_IP
          TENSOR_PARALLEL_SIZE DATA_PARALLEL_SIZE GPU_MEMORY_UTILIZATION
          MAX_MODEL_LEN NUM_GPU_BLOCKS_OVERRIDE PREFILL_BACKEND DECODE_BACKEND)
for v in "${required[@]}"; do
    if [[ -z "${!v:-}" ]]; then
        echo "ERROR: $v is unset. Did you 'source setup/env_vars'?" >&2
        exit 1
    fi
done

# Variables that envsubst is allowed to substitute. Anything else (e.g.
# $endpoint, $MY_IP, $h inside the embedded shell scripts) must survive
# untouched so the pod's bash interpreter can use it at runtime.
SUBST_VARS='$NAMESPACE $INSTANCE_TYPE $REGISTRY $IMAGE $TAG $MODEL
            $PREFILL_NODE $PREFILL_IP $DECODE_NODE $DECODE_INDEX
            $DECODER_HOSTS $DECODER_PORTS
            $TENSOR_PARALLEL_SIZE $DATA_PARALLEL_SIZE
            $GPU_MEMORY_UTILIZATION $MAX_MODEL_LEN $NUM_GPU_BLOCKS_OVERRIDE
            $PREFILL_BACKEND $DECODE_BACKEND'

# Decide the decode-pod count for the chosen topology.
case "${TOPOLOGY}" in
    unified) NUM_DECODE=0 ;;
    1p1d)    NUM_DECODE=1 ;;
    1p3d)    NUM_DECODE=3 ;;
    1p4d)    NUM_DECODE=4 ;;
    1p5d)    NUM_DECODE=5 ;;
    *)
        echo "ERROR: unknown topology '${TOPOLOGY}'" >&2
        exit 1
        ;;
esac

echo "==> Ensuring namespace ${NAMESPACE} exists"
kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1 \
    || kubectl create namespace "${NAMESPACE}"

if [[ "${TOPOLOGY}" == "unified" ]]; then
    echo "==> Applying unified pod"
    envsubst "${SUBST_VARS}" < "${MANIFEST_DIR}/unified.yaml" | kubectl apply -f -
    echo "==> Done. Probe with: curl -sf http://${PREFILL_IP}:8000/health"
    exit 0
fi

# Disaggregated path: prefill + N decode + proxy.
echo "==> Applying prefill pod on ${PREFILL_NODE}"
envsubst "${SUBST_VARS}" < "${MANIFEST_DIR}/prefill.yaml" | kubectl apply -f -

DECODER_HOSTS=""
DECODER_PORTS=""
for ((i=0; i<NUM_DECODE; i++)); do
    node_var="DECODE_NODE_${i}"
    ip_var="DECODE_${i}_IP"
    decode_node="${!node_var:-}"
    decode_ip="${!ip_var:-}"
    if [[ -z "${decode_node}" || -z "${decode_ip}" ]]; then
        echo "ERROR: ${node_var} or ${ip_var} unset for topology ${TOPOLOGY}" >&2
        exit 1
    fi

    echo "==> Applying decode-${i} on ${decode_node}"
    DECODE_INDEX="${i}" DECODE_NODE="${decode_node}" \
        envsubst "${SUBST_VARS}" < "${MANIFEST_DIR}/decode.yaml" | kubectl apply -f -

    DECODER_HOSTS="${DECODER_HOSTS}${decode_ip} "
    DECODER_PORTS="${DECODER_PORTS}8200 "
done

DECODER_HOSTS="${DECODER_HOSTS% }"
DECODER_PORTS="${DECODER_PORTS% }"

echo "==> Applying proxy pod (decoders: ${DECODER_HOSTS})"
DECODER_HOSTS="${DECODER_HOSTS}" DECODER_PORTS="${DECODER_PORTS}" \
    envsubst "${SUBST_VARS}" < "${MANIFEST_DIR}/proxy.yaml" | kubectl apply -f -

echo
echo "==> All pods applied."
echo "    Watch: kubectl logs -f -n ${NAMESPACE} dsv3-proxy"
echo "    Probe: curl -sf http://${PREFILL_IP}:8000/health"
