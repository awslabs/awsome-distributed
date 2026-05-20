#!/bin/bash

# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# Benchmark script for V-JEPA 2.1 on SageMaker HyperPod with B200 GPUs.
#
# This script uses a NeMo container that ships a compatible EFA/NCCL/OFI
# stack for Blackwell GPUs.  V-JEPA 2 dependencies and source code are
# installed to shared storage and added to PYTHONPATH at runtime.
#
# V-JEPA 2.1 uses image+video co-training: with img_data.rank_ratio=0.5,
# half the ranks train on images and half on video.  The code is mounted
# at /workspace inside the container so that the NeMo container's
# PYTHONPATH picks it up automatically.
#
# Prerequisites (run once from the login node):
#   1. Obtain a NeMo container with NCCL 2.29+ and EFA support:
#        enroot import 'docker://nvcr.io#nvidia/nemo:25.11.01'
#        # or use a pre-built .sqsh with the correct EFA/NCCL stack
#   2. Clone the V-JEPA 2 repository (includes 2.1 code in app/vjepa_2_1/):
#        git clone https://github.com/facebookresearch/vjepa2.git \
#            /fsx/<your_username>/vjepa2_code
#   3. Install V-JEPA 2 Python dependencies into a shared directory
#      (use the same container to ensure compatible packages):
#        srun --partition=b200 --account=root -N1 --ntasks=1 \
#            --container-image <your_container.sqsh> \
#            --container-mounts /fsx:/fsx --no-container-mount-home \
#            pip install --target /fsx/<your_username>/vjepa_deps \
#                -r /fsx/<your_username>/vjepa2_code/requirements.txt
#   4. Generate synthetic image and video datasets (see scripts/).
#   5. Copy configs and scripts from this test case to shared storage.

#SBATCH --nodes=8
#SBATCH --ntasks-per-node=8
#SBATCH --gpus-per-node=8
#SBATCH --job-name=vjepa21-benchmark
#SBATCH --output=logs/vjepa21_benchmark/%A.out
#SBATCH --error=logs/vjepa21_benchmark/%A.err
#SBATCH --exclusive
#SBATCH --partition=b200
#SBATCH --account=root
#SBATCH --time=01:00:00

set -euo pipefail

###########################
###### User Variables #####
###########################

# Path to your V-JEPA 2.1 files on shared storage
VJEPA21_DIR=/fsx/${USER}/vjepa2.1

# Path to the cloned V-JEPA 2 repository (contains app/vjepa_2_1/)
VJEPA2_CODE=/fsx/${USER}/vjepa2_code

# Path to pip --target install of V-JEPA 2 dependencies
VJEPA_DEPS=/fsx/${USER}/vjepa_deps

###########################
## Container Variables ####
###########################

# NeMo container with NCCL 2.29+ and EFA support for Blackwell GPUs.
export CONTAINER_IMAGE=/fsx/${USER}/nemo-efa-nccl29.sqsh
export FSX_MOUNT=/fsx:/fsx

# V-JEPA 2.1 code overlay: mount code at /workspace so it takes
# priority in the NeMo container's PYTHONPATH (which includes /workspace).
export CODE_MOUNT=${VJEPA2_CODE}:/workspace

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

# V-JEPA 2.1 needs /workspace in PYTHONPATH for the code overlay
export PYTHONPATH=/workspace:${VJEPA_DEPS}:${VJEPA2_CODE}:${PYTHONPATH:-}

###########################
## Container Args #########
###########################

declare -a ARGS=(
    --container-image $CONTAINER_IMAGE
    --container-mounts "${FSX_MOUNT},${CODE_MOUNT}"
    --container-workdir /workspace
    --no-container-mount-home
    --mpi=pmix
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
