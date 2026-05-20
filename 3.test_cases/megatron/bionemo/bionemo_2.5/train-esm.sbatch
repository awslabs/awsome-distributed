#!/bin/bash
#SBATCH --nodes=2                    # number of nodes
#SBATCH --ntasks-per-node=8          # n tasks per machine (one task per gpu) <required>
#SBATCH --gpus-per-node=8
#SBATCH --exclusive                   # exclusive node access
#SBATCH --output slurm-esm2-train-%j.out

#export FI_EFA_USE_HUGE_PAGE=0 #Uncomment if you get os.fork() memory error
export FI_PROVIDER=efa
export NCCL_DEBUG=INFO

# Path to store data and checkpoints. Override DATA_HOME_DIR to match your
# shared filesystem mount.
: "${DATA_HOME_DIR:=/fsxl/${USER}/bionemo}"
export DATA_HOME_DIR

###########################
###### User Variables #####
###########################

# default variables for Enroot
: "${IMAGE:=${DATA_HOME_DIR}/bionemo.sqsh}"
: "${DATA_PATH:=/fsxl}"
: "${FSX_MOUNT:=$DATA_PATH:$DATA_PATH}"

declare -a ARGS=(
    --container-image $IMAGE
    --container-mount-home
    --container-mounts ${DATA_HOME_DIR}:${DATA_HOME_DIR}
)

# Enable fused attention in transformer engine for speed-up
DATA_DIR=$(find $DATA_HOME_DIR -type d -name "*untar*" -print -quit)

srun -l "${ARGS[@]}"  python3 /workspace/bionemo2/sub-packages/bionemo-esm2/src/bionemo/esm2/scripts/train_esm2.py \
    --train-cluster-path ${DATA_DIR}/2024_03_sanity/train_clusters_sanity.parquet \
    --train-database-path ${DATA_DIR}/2024_03_sanity/train_sanity.db \
    --valid-cluster-path ${DATA_DIR}/2024_03_sanity/valid_clusters.parquet \
    --valid-database-path ${DATA_DIR}/2024_03_sanity/validation.db \
    --precision="bf16-mixed" \
    --num-gpus ${SLURM_GPUS_PER_NODE:-8} \
    --num-nodes ${SLURM_JOB_NUM_NODES:-2} \
    --num-steps 100 \
    --val-check-interval 25 \
    --max-seq-length 1024 \
    --limit-val-batches 2 \
    --micro-batch-size 2 \
    --num-layers 33 \
    --hidden-size 1280 \
    --num-attention-head 20 \
    --ffn-hidden-size 5120 \
    --tensor-model-parallel-size 1 \
    --create-tensorboard-logger \
    --result-dir ${DATA_HOME_DIR}
