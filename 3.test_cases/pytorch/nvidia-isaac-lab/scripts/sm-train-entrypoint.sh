#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
set -euo pipefail

echo "=== SageMaker Training Job ==="
echo "Hostname: $(hostname)"
echo "Date: $(date)"
nvidia-smi -L

# === NCCL / Networking Configuration ===
# Let NCCL pick the best transport. On EFA-capable instances with the EFA
# userspace stack installed (we install it in the Dockerfile), NCCL uses EFA
# for inter-node collectives. On instances without EFA it falls back to TCP
# over the default interface.
#
# Caveat: on non-EFA instances, NCCL auto-detect may pick a non-eth0
# interface (e.g. a CNI / docker bridge) and fail to reach peers with
# "Connection refused". If that happens, set NCCL_SOCKET_IFNAME=eth0 here
# or in the launcher's environment block.
#
# To force TCP (e.g. on a cluster where EFA is misconfigured), set:
#   export NCCL_NET_PLUGIN=none
#   export NCCL_SOCKET_IFNAME=eth0
export NCCL_DEBUG=INFO

# Isaac Sim base image sets NVIDIA_VISIBLE_DEVICES=void — override
export NVIDIA_VISIBLE_DEVICES=all
export NVIDIA_DRIVER_CAPABILITIES=all

# NVIDIA EULA
export ACCEPT_EULA=Y
export PRIVACY_CONSENT=Y

# Enable full error tracebacks
export HYDRA_FULL_ERROR=1
export TORCHELASTIC_ERROR_FILE=/tmp/torch_elastic_error.json

# Isaac Sim's internal pip env initialization is not process-safe. When torchrun
# spawns multiple workers on the same node, they race to create
# /isaac-sim/kit/data/Kit/Isaac-Sim/4.5/pip3-envs/default. Isaac Sim checks this
# env var and uses file-based locking to serialize the initialization.
export ISAACLAB_INIT_LOCK=/tmp/isaaclab_init.lock

echo "=== Network Interfaces ==="
(ip addr show eth0 2>/dev/null || ifconfig eth0 2>/dev/null || hostname -I 2>/dev/null || true) | head -5
echo "=== /dev/shm ==="
df -h /dev/shm
echo ""

# SageMaker BYOC doesn't inject SM_* env vars automatically.
# For multi-node, we need to read from /opt/ml/input/config/resourceconfig.json
CONFIG_FILE="/opt/ml/input/config/resourceconfig.json"
if [ -f "$CONFIG_FILE" ]; then
  echo "=== Resource Config ==="
  cat "$CONFIG_FILE"
  echo ""

  # Use Isaac Sim's bundled python
  PYTHON="/isaac-sim/python.sh"

  CURRENT_HOST=$($PYTHON -c "import json; cfg=json.load(open('$CONFIG_FILE')); print(cfg['current_host'])")
  ALL_HOSTS=$($PYTHON -c "import json; cfg=json.load(open('$CONFIG_FILE')); print(','.join(cfg['hosts']))")
  NNODES=$($PYTHON -c "import json; cfg=json.load(open('$CONFIG_FILE')); print(len(cfg['hosts']))")
  NODE_RANK=$($PYTHON -c "import json; cfg=json.load(open('$CONFIG_FILE')); print(cfg['hosts'].index(cfg['current_host']))")
  MASTER_HOST=$($PYTHON -c "import json; cfg=json.load(open('$CONFIG_FILE')); print(cfg['hosts'][0])")
  NPROC=$($PYTHON -c "
import subprocess
result = subprocess.run(['nvidia-smi', '-L'], capture_output=True, text=True)
print(len([l for l in result.stdout.strip().split(chr(10)) if l.startswith('GPU')]))
")
else
  echo "No resource config found, assuming single node"
  CURRENT_HOST=$(hostname)
  MASTER_HOST=$(hostname)
  NNODES=1
  NODE_RANK=0
  NPROC=4
fi

MASTER_PORT=29500

echo "=== Training Configuration ==="
echo "CURRENT_HOST=$CURRENT_HOST"
echo "MASTER_HOST=$MASTER_HOST"
echo "ALL_HOSTS=$ALL_HOSTS"
echo "NNODES=$NNODES"
echo "NODE_RANK=$NODE_RANK"
echo "NPROC=$NPROC"
echo "MASTER_PORT=$MASTER_PORT"
echo "NCCL_DEBUG=$NCCL_DEBUG"
echo "MAX_ITERATIONS=${MAX_ITERATIONS:-1000}"

# Test cross-node connectivity before starting training
if [ "$NNODES" -gt 1 ]; then
  echo "=== Testing Cross-Node Connectivity ==="
  MASTER_IP=$(getent hosts $MASTER_HOST | awk '{print $1}')
  echo "Master IP: $MASTER_IP"
  # Test if we can reach the master port (non-blocking, just informational)
  timeout 5 bash -c "echo > /dev/tcp/$MASTER_HOST/$MASTER_PORT" 2>/dev/null && echo "Master port reachable" || echo "Master port not yet open (expected if we start before master)"
  # Also test basic ICMP
  ping -c 1 -W 2 $MASTER_HOST 2>/dev/null && echo "Ping to master OK" || echo "Ping to master failed (ICMP may be blocked, not fatal)"
fi

echo "=== Starting Isaac Lab H1 Training ==="
cd /workspace/IsaacLab

# Redirect skrl's log/checkpoint directory to /opt/ml/checkpoints so SageMaker
# syncs checkpoints to S3 continuously during training.  On a resumed job,
# SageMaker will have already restored the previous checkpoints into that path.
mkdir -p /opt/ml/checkpoints
ln -s /opt/ml/checkpoints /workspace/IsaacLab/logs

# Auto-resume: find the latest checkpoint restored by SageMaker from a previous run
LATEST_CKPT=$(find /opt/ml/checkpoints -name "best_agent.pt" -printf "%T@ %p\n" 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2)
if [ -n "$LATEST_CKPT" ]; then
  echo "=== RESUMING from checkpoint: $LATEST_CKPT ==="
  RESUME_FLAG="--checkpoint $LATEST_CKPT"
else
  echo "=== Starting fresh (no checkpoint found) ==="
  RESUME_FLAG=""
fi

# MLflow run metadata (read by mlflow_isaaclab.py on rank 0). The hook is a
# no-op when MLFLOW_TRACKING_URI is unset.
if [ -n "${MLFLOW_TRACKING_URI:-}" ]; then
  export MLFLOW_EXPERIMENT_NAME="${MLFLOW_EXPERIMENT_NAME:-isaaclab}"
  # Point at the framework root; mlflow_isaaclab.finalize() walks it to find
  # the most recently created run subdirectory (skrl renames the task in the
  # path, so we cannot construct the per-run path from env vars upfront).
  export MLFLOW_ARTIFACT_DIR="${MLFLOW_ARTIFACT_DIR:-/workspace/IsaacLab/logs/${FRAMEWORK:-skrl}}"
fi

/isaac-sim/python.sh -m torch.distributed.run \
  --nproc_per_node=$NPROC \
  --nnodes=$NNODES \
  --node_rank=$NODE_RANK \
  --rdzv_id=sm-isaaclab \
  --rdzv_backend=c10d \
  --rdzv_endpoint=$MASTER_HOST:$MASTER_PORT \
  run_train.py \
  --distributed \
  --task=${TASK:-Isaac-Velocity-Rough-H1-v0} \
  --max_iterations=${MAX_ITERATIONS:-1000} \
  --headless \
  $RESUME_FLAG

TRAIN_EXIT=$?
echo "=== Training Exit Code: $TRAIN_EXIT ==="

# Check for error files
if [ -f /tmp/torch_elastic_error.json ]; then
  echo "=== Torch Elastic Error File ==="
  cat /tmp/torch_elastic_error.json
fi

echo "=== Copying Checkpoints ==="
mkdir -p /opt/ml/model
cp -rv /workspace/IsaacLab/logs/* /opt/ml/model/ 2>/dev/null || true
echo "=== Checkpoints ==="
find /opt/ml/model -name "*.pt" -ls 2>/dev/null
echo "Done!"
