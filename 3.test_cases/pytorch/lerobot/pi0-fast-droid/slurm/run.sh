#!/bin/bash

# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

#SBATCH --job-name=lerobot-pi0fast-droid
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=1
#SBATCH --gpus-per-node=8
#SBATCH --exclusive
#SBATCH --wait-all-nodes=1
#SBATCH --output=logs/%x_%j.out
#SBATCH --error=logs/%x_%j.err

set -ex

###########################
###### User Variables #####
###########################

GPUS_PER_NODE=8
CONTAINER_IMAGE="${CONTAINER_IMAGE:-$(pwd)/lerobot-pi0-fast-droid.sqsh}"
OUTPUT_DIR="${OUTPUT_DIR:-/fsx/lerobot-output}"

# Training hyperparameters
DATASET_REPO_ID="${DATASET_REPO_ID:-lerobot/droid_1.0.1}"
PRETRAINED_PATH="${PRETRAINED_PATH:-lerobot/pi0fast_base}"
BATCH_SIZE="${BATCH_SIZE:-4}"
STEPS="${STEPS:-200000}"

###########################
## Environment Variables ##
###########################

## EFA / libfabric settings
export FI_PROVIDER=efa
export FI_EFA_FORK_SAFE=1
export FI_EFA_USE_HUGE_PAGE=0

## NCCL settings
export NCCL_DEBUG=INFO
export NCCL_SOCKET_IFNAME=^docker,lo,veth

## Performance tuning
export NCCL_BUFFSIZE=8388608
export NCCL_P2P_NET_CHUNKSIZE=524288

## HuggingFace timeouts (important for large datasets like DROID 1.7TB)
export HF_HUB_ETAG_TIMEOUT=120
export HF_HUB_DOWNLOAD_TIMEOUT=120

###########################
# Network Configuration
###########################

head_node_ip=$(scontrol show hostnames "$SLURM_JOB_NODELIST" | head -n 1)

###########################
# Accelerate Launcher
###########################

# accelerate does NOT auto-detect SLURM variables — every parameter must be explicit.
# --machine_rank uses escaped $SLURM_PROCID so it expands per-node inside bash -c.
LAUNCHER="accelerate launch \
    --num_processes $((SLURM_NNODES * GPUS_PER_NODE)) \
    --num_machines ${SLURM_NNODES} \
    --machine_rank \$SLURM_PROCID \
    --rdzv_backend c10d \
    --main_process_ip ${head_node_ip} \
    --main_process_port 29500 \
    --mixed_precision bf16"

###########################
# LeRobot Training Args
###########################

TRAIN_ARGS="\
    --dataset.repo_id=${DATASET_REPO_ID} \
    --policy.path=${PRETRAINED_PATH} \
    --policy.dtype=bfloat16 \
    --policy.gradient_checkpointing=true \
    --policy.chunk_size=10 \
    --policy.n_action_steps=10 \
    --policy.max_action_tokens=256 \
    --steps=${STEPS} \
    --batch_size=${BATCH_SIZE} \
    --save_freq=5000 \
    --output_dir=${OUTPUT_DIR} \
    --job_name=pi0fast_droid_${SLURM_JOB_ID}"

# Compose into single string (accelerate launch does not handle multiline args correctly)
CMD="${LAUNCHER} \$(which lerobot-train) ${TRAIN_ARGS}"

###########################
# Container Mounts
###########################

declare -a SRUN_ARGS=(
    --container-image "${CONTAINER_IMAGE}"
    --container-mounts "${OUTPUT_DIR}:${OUTPUT_DIR}"
)

# Mount HF cache if set
if [ -n "${HF_HOME}" ]; then
    SRUN_ARGS+=(--container-mounts "${HF_HOME}:${HF_HOME}")
fi

###########################
# HyperPod Auto-Resume
###########################

if [ -d "/opt/sagemaker_cluster" ]; then
    echo "Detected HyperPod cluster — enabling auto-resume"
    SRUN_ARGS+=(--auto-resume=1)
fi

###########################
# Create log directory
###########################

mkdir -p logs

###########################
# Launch Training
###########################

srun -l "${SRUN_ARGS[@]}" bash -c "${CMD}"
