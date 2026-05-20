#!/bin/bash

# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# Benchmark script for V-JEPA 2 on SageMaker HyperPod with B200 GPUs.
#
# This script uses a NeMo container that ships a compatible EFA/NCCL/OFI
# stack for Blackwell GPUs.  V-JEPA 2 dependencies and source code are
# installed to shared storage and added to PYTHONPATH at runtime.
#
# The vjepa2.Dockerfile container (based on pytorch:25.03-py3) ships
# NCCL 2.25 and an older aws-ofi-nccl plugin that are incompatible with
# B200 EFA networking.  A NeMo container with NCCL >= 2.29 and a matching
# OFI/EFA/libfabric stack is required instead.
#
# Prerequisites (run once from the login node):
#   1. Obtain a NeMo container with NCCL 2.29+ and EFA support:
#        enroot import 'docker://nvcr.io#nvidia/nemo:25.11.01'
#        # or use a pre-built .sqsh with the correct EFA/NCCL stack
#   2. Clone the V-JEPA 2 repository:
#        git clone https://github.com/facebookresearch/vjepa2.git \
#            /fsx/<your_username>/vjepa2_code
#   3. Install V-JEPA 2 Python dependencies into a shared directory
#      (use the same container to ensure compatible packages):
#        srun --partition=b200 --account=root -N1 --ntasks=1 \
#            --container-image <your_container.sqsh> \
#            --container-mounts /fsx:/fsx --no-container-mount-home \
#            pip install --target /fsx/<your_username>/vjepa_deps \
#                -r /fsx/<your_username>/vjepa2_code/requirements.txt
#   4. Copy configs and scripts from this test case to shared storage.

#SBATCH --nodes=8
#SBATCH --ntasks-per-node=8
#SBATCH --gpus-per-node=8
#SBATCH --job-name=vjepa2-benchmark
#SBATCH --output=logs/vjepa2_benchmark/%A.out
#SBATCH --error=logs/vjepa2_benchmark/%A.err
#SBATCH --exclusive
#SBATCH --partition=b200
#SBATCH --account=root
#SBATCH --time=01:00:00

set -euo pipefail

###########################
###### User Variables #####
###########################

# Path to your V-JEPA 2 files on shared storage
VJEPA2_DIR=/fsx/${USER}/vjepa2

# Path to the cloned V-JEPA 2 repository
VJEPA2_CODE=/fsx/${USER}/vjepa2_code

# Path to pip --target install of V-JEPA 2 dependencies
VJEPA_DEPS=/fsx/${USER}/vjepa_deps

###########################
## Container Variables ####
###########################

# NeMo container with NCCL 2.29+ and EFA support for Blackwell GPUs.
export CONTAINER_IMAGE=/fsx/${USER}/nemo-efa-nccl29.sqsh
export FSX_MOUNT=/fsx:/fsx

###########################
## Environment Variables ##
###########################

export NCCL_DEBUG=INFO
export FI_PROVIDER=efa
export FI_EFA_SET_CUDA_SYNC_MEMOPS=0
export NCCL_SOCKET_IFNAME=^docker,lo,veth

# NCCL performance tuning for EFA on HyperPod B200
export NCCL_TUNER_PLUGIN=/opt/amazon/ofi-nccl/lib/libnccl-ofi-tuner.so
export NCCL_BUFFSIZE=8388608
export NCCL_P2P_NET_CHUNKSIZE=2097152
export NCCL_NVLS_ENABLE=0
export NCCL_GRAPH_REGISTER=0

# Blackwell-specific
export TRITON_PTXAS_PATH=/usr/local/cuda/bin/ptxas

# PyTorch memory allocator
export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True

# Add V-JEPA 2 deps and source code to Python path
export PYTHONPATH=${VJEPA_DEPS}:${VJEPA2_CODE}:${PYTHONPATH:-}

###########################
## Container Args #########
###########################

declare -a ARGS=(
    --container-image $CONTAINER_IMAGE
    --container-mounts $FSX_MOUNT
    --container-workdir ${VJEPA2_CODE}
    --no-container-mount-home
    --mpi=pmix
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

srun ${AUTO_RESUME} -l "${ARGS[@]}" python ${VJEPA2_DIR}/scripts/run_train.py "${TRAINING_ARGS[@]}"
