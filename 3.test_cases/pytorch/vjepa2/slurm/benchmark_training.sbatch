#!/bin/bash

# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

#SBATCH --nodes=8
#SBATCH --ntasks-per-node=8
#SBATCH --gpus-per-node=8
#SBATCH --job-name=vjepa2-benchmark
#SBATCH --output=logs/vjepa2_benchmark/%A.out
#SBATCH --error=logs/vjepa2_benchmark/%A.err
#SBATCH --exclusive
#SBATCH --partition=p5en

set -euo pipefail

###########################
###### User Variables #####
###########################

# Path to your V-JEPA 2 files on shared storage
VJEPA2_DIR=/fsx/${USER}/vjepa2

###########################
## Container Variables ####
###########################

export CONTAINER_IMAGE=${VJEPA2_DIR}/vjepa2.sqsh
export FSX_MOUNT=/fsx:/fsx

###########################
## Environment Variables ##
###########################

export NCCL_DEBUG=INFO
export FI_PROVIDER=efa
export FI_EFA_SET_CUDA_SYNC_MEMOPS=0
# NCCL lib path (ParallelCluster p5en); adjust if using a different setup
export LD_PRELOAD=/lib/x86_64-linux-gnu/libnccl.so.2
export NCCL_SOCKET_IFNAME=^docker,lo,veth

###########################
## Container Args #########
###########################

declare -a ARGS=(
    --container-image $CONTAINER_IMAGE
    --container-mounts $FSX_MOUNT
    --container-workdir /workspace
)

###########################
## Training Args ##########
###########################

# V-JEPA 2 uses srun directly (not torchrun).
# scripts/run_train.py calls app.vjepa.train.main() which reads:
#   SLURM_LOCALID  -> sets CUDA_VISIBLE_DEVICES (1 GPU per process)
#   SLURM_NTASKS   -> world size for torch.distributed
#   SLURM_PROCID   -> global rank for torch.distributed

declare -a TRAINING_ARGS=(
    --fname ${VJEPA2_DIR}/configs/benchmark-vitg-8nodes.yaml
)

###########################
## HyperPod Auto-Resume ###
###########################

AUTO_RESUME=""
if [ -d "/opt/sagemaker_cluster" ]; then
    echo "Detected Hyperpod cluster.. enabling --auto-resume=1"
    AUTO_RESUME="--auto-resume=1"
fi

mkdir -p logs/vjepa2_benchmark

srun ${AUTO_RESUME} -l "${ARGS[@]}" python scripts/run_train.py "${TRAINING_ARGS[@]}"
