#!/bin/bash

# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# QLoRA fine-tuning of Qwen3-8B on SageMaker HyperPod (Slurm)
# Supports: single-node, multi-node, MIG GPUs, Enroot containers

#SBATCH --job-name=qwen3_8b-qlora-zero2
#SBATCH --nodes=1                      # increase for multi-node DDP
#SBATCH --exclusive                    # full node allocation (portable across instance types)
#SBATCH --wait-all-nodes=1
#SBATCH --output=logs/%x_%j.out
#SBATCH --error=logs/%x_%j.err

set -ex

###########################
###### User Variables #####
###########################

GPUS_PER_NODE=4                        # 4 for g5.12xlarge, 8 for p4d/p5
                                       # Overridden automatically when MIG is enabled

# Training script and config (relative to repo root)
# Use SLURM_SUBMIT_DIR when available (Slurm copies scripts to a spool directory,
# so realpath "$0" would resolve to the spool rather than the original location)
if [ -n "$SLURM_SUBMIT_DIR" ]; then
    REPO_ROOT="$(cd "$SLURM_SUBMIT_DIR/.." && pwd)"
else
    REPO_ROOT="$(dirname "$(realpath "$0")")/.."
fi
export PYTHONPATH="${REPO_ROOT}:${PYTHONPATH:-}"
TRAIN_SCRIPT="${REPO_ROOT}/src/train.py"
CONFIG_PATH="${REPO_ROOT}/configs/training_config_zero2.yaml"
OUTPUT_DIR="/fsx/qwen3-qlora/outputs"

###########################
## Environment Variables ##
###########################

# HuggingFace cache on shared filesystem (HyperPod convention)
export HF_HOME=/fsx/hf_cache

# PyTorch memory allocator — expandable segments reduces fragmentation
export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True

# NCCL debugging (set to WARN for production)
export NCCL_DEBUG=WARN

# Enable Python fault handler and torch elastic error tracking
export PYTHONFAULTHANDLER=1
export TORCH_SHOW_CPP_STACKTRACES=1

## EFA settings — uncomment for EFA-enabled instances (p4d.24xlarge, p5.48xlarge)
## Not needed for g5 instances (no EFA)
export FI_PROVIDER=efa
export FI_EFA_USE_HUGE_PAGE=0
export FI_EFA_SET_CUDA_SYNC_MEMOPS=0
export NCCL_SOCKET_IFNAME=^docker,lo,veth,eth

# Use system NCCL which has EFA support (container NCCL may lack OFI plugin)
export LD_PRELOAD=/lib/x86_64-linux-gnu/libnccl.so

# HuggingFace Hub timeout for large clusters
export HF_HUB_ETAG_TIMEOUT=60

###########################
##### MIG Detection  ######
###########################

# Auto-detect MIG instances. When MIG mode is enabled on a GPU, each MIG instance
# appears as a separate CUDA device to PyTorch. We query nvidia-smi to count them
# and override GPUS_PER_NODE so torchrun launches the correct number of workers.

MIG_MODE=$(nvidia-smi --query-gpu=mig.mode.current --format=csv,noheader,nounits 2>/dev/null | head -1 || echo "Disabled")

if [ "$MIG_MODE" = "Enabled" ]; then
    MIG_COUNT=$(nvidia-smi -L | grep -c "MIG")
    if [ "$MIG_COUNT" -gt 0 ]; then
        echo "MIG detected: ${MIG_COUNT} MIG instance(s) found, overriding GPUS_PER_NODE"
        GPUS_PER_NODE=$MIG_COUNT
    fi
fi

echo "Using GPUS_PER_NODE=${GPUS_PER_NODE}"

###########################
###### Container Args #####
###########################

# Uncomment to run inside an Enroot/Pyxis container instead of a virtual environment.
# Build the container image first:  enroot import dockerd://your-registry/qwen3-qlora:latest
#CONTAINER_IMAGE=/fsx/containers/qwen3-qlora.sqsh
CONTAINER_IMAGE=${CONTAINER_IMAGE:-}

declare -a CONTAINER_ARGS=()
if [ -n "$CONTAINER_IMAGE" ]; then
    declare -a CONTAINER_ARGS=(
        --container-image "$CONTAINER_IMAGE"
        --container-mounts "/fsx:/fsx"
        --no-container-mount-home
    )
fi

###########################
## Create log directory  ##
###########################

mkdir -p logs

###########################
####### Torch Dist  #######
###########################

# Resolve the master node for multi-node rendezvous
MASTER_ADDR=$(scontrol show hostnames "$SLURM_JOB_NODELIST" | head -n 1)

declare -a TORCHRUN_ARGS=(
    --nproc_per_node=$GPUS_PER_NODE
    --nnodes=$SLURM_JOB_NUM_NODES
    --rdzv_id=$SLURM_JOB_ID
    --rdzv_backend=c10d
    --rdzv_endpoint=${MASTER_ADDR}
)

###########################
##### Training Args  ######
###########################

declare -a TRAINING_ARGS=(
    --config_path "$CONFIG_PATH"
    --output_dir "$OUTPUT_DIR"
    --resume_from_checkpoint auto
)

###########################
## HyperPod Auto-Resume  #
###########################

AUTO_RESUME=""
if [ -d "/opt/sagemaker_cluster" ] && [ -z "$CONTAINER_IMAGE" ]; then
    echo "Detected HyperPod cluster — enabling auto-resume"
    AUTO_RESUME="--auto-resume=1"
elif [ -d "/opt/sagemaker_cluster" ]; then
    echo "Detected HyperPod cluster (auto-resume skipped in container mode)"
fi

###########################
######### Launch ##########
###########################

srun ${AUTO_RESUME} -l "${CONTAINER_ARGS[@]}" torchrun \
    "${TORCHRUN_ARGS[@]}" \
    "$TRAIN_SCRIPT" "${TRAINING_ARGS[@]}"
