#!/bin/bash

# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

#SBATCH --nodes=2 # number of nodes to use
#SBATCH --gpus-per-node=8
#SBATCH --job-name=ESM-DDP # name of your job
#SBATCH --exclusive # job has exclusive use of the resource, no sharing

set -ex;

###########################
###### User Variables #####
###########################

# Override ESM2_DATA_DIR if your shared filesystem mount differs.
: "${ESM2_DATA_DIR:=/fsxl/${USER}/esm2}"

GPUS_PER_NODE=8 # 4 for G5.12x, 8 for P4/P5

DATASET_DIR="${ESM2_DATA_DIR}/processed/arrow"

OUTPUT_DIR="${ESM2_DATA_DIR}/output"

IMAGE="${ESM2_DATA_DIR}/esm.sqsh"
###########################
## Environment Variables ##
###########################

## Plenty of EFA level variables
## Comment out for non-efa instances (G4d, P3)
## For G5.12x, Comment out RDMA and Fork safe
## For G4dn and other G5, comment out all

export FI_EFA_USE_DEVICE_RDMA=1 # use for p4d
export FI_EFA_FORK_SAFE=1
export FI_LOG_LEVEL=1
export FI_PROVIDER=efa
export NCCL_DEBUG=INFO


###########################
####### Torch Dist  #######
###########################

declare -a TORCHRUN_ARGS=(
    --nproc_per_node=$GPUS_PER_NODE
    --nnodes=$SLURM_JOB_NUM_NODES
    --rdzv_id=$SLURM_JOB_ID
    --rdzv_backend=c10d
    --rdzv_endpoint=$(hostname)
)
export TRAIN_SCRIPT=/workspace/train.py

############################
#ESM Training Params ##
############################

declare -a TRAINING_ARGS=(
    --config_name "facebook/esm2_t30_150M_UR50D" \
    --dataloader_num_workers 8 \
    --bf16 True \
    --do_eval True \
    --do_preprocess False \
    --do_train True \
    --gradient_accumulation_steps 16 \
    --logging_steps 16 \
    --num_train_epochs 1 \
    --output_dir ${OUTPUT_DIR} \
    --per_device_train_batch_size 8 \
    --max_train_samples 100000 \
    --tokenizer_name "facebook/esm2_t30_150M_UR50D" \
    --dataset_dir ${DATASET_DIR} \
    --torch_compile False \
    --pad_to_max_length True \
    --max_seq_length 512
)

AUTO_RESUME=""
if [ -d "/opt/sagemaker_cluster" ]; then
    echo "Detected Hyperpod cluster.. enabling --auto-resume=1"
    AUTO_RESUME="--auto-resume=1"
fi

declare -a ARGS=(
    --container-image ${IMAGE}
    --container-mount-home
    --container-mounts /fsxl:/fsxl
    --no-container-remap-root
)

srun "${ARGS[@]}" ${AUTO_RESUME} -l torchrun "${TORCHRUN_ARGS[@]}" $TRAIN_SCRIPT "${TRAINING_ARGS[@]}"
