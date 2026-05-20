#!/bin/bash

# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

#SBATCH --nodes=8
#SBATCH --ntasks-per-node=8
#SBATCH --gpus-per-node=8
#SBATCH --job-name=vjepa21-benchmark
#SBATCH --output=logs/vjepa21_benchmark/%A.out
#SBATCH --error=logs/vjepa21_benchmark/%A.err
#SBATCH --exclusive
#SBATCH --partition=p5en

set -euo pipefail

###########################
###### User Variables #####
###########################

# Path to your V-JEPA 2.1 files on shared storage
VJEPA21_DIR=/fsx/${USER}/vjepa2.1

###########################
## Container Variables ####
###########################

# Reuses the same container as V-JEPA 2 (same repo, same image)
export CONTAINER_IMAGE=${VJEPA21_DIR}/vjepa2.sqsh
export FSX_MOUNT=/fsx:/fsx
# V-JEPA 2.1 code must be available inside the container. If the container
# was built before 2.1 was released, clone the latest repo to shared storage
# and mount it over /workspace (the container's default PYTHONPATH entry):
#   git clone https://github.com/facebookresearch/vjepa2.git ${VJEPA21_DIR}/code
export CODE_MOUNT=${VJEPA21_DIR}/code:/workspace

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
    --container-mounts "${FSX_MOUNT},${CODE_MOUNT}"
    --container-workdir /workspace
)

###########################
## Training Args ##########
###########################

# V-JEPA 2.1 uses srun directly (not torchrun), same as V-JEPA 2.
# scripts/run_train.py uses app.scaffold.main() to dispatch to the
# correct training app based on the 'app' field in the config.
# For vjepa_2_1, this routes to app.vjepa_2_1.train.main() which reads:
#   SLURM_LOCALID  -> sets CUDA_VISIBLE_DEVICES (1 GPU per process)
#   SLURM_NTASKS   -> world size for torch.distributed
#   SLURM_PROCID   -> global rank for torch.distributed
#
# With img_data.rank_ratio=0.5, ranks 0-31 process images (batch 72)
# and ranks 32-63 process video (batch 24).

declare -a TRAINING_ARGS=(
    --fname ${VJEPA21_DIR}/configs/benchmark-vitg-8nodes.yaml
)

###########################
## HyperPod Auto-Resume ###
###########################

AUTO_RESUME=""
if [ -d "/opt/sagemaker_cluster" ]; then
    echo "Detected Hyperpod cluster.. enabling --auto-resume=1"
    AUTO_RESUME="--auto-resume=1"
fi

mkdir -p logs/vjepa21_benchmark

srun ${AUTO_RESUME} -l "${ARGS[@]}" python ${VJEPA21_DIR}/scripts/run_train.py "${TRAINING_ARGS[@]}"
