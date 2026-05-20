#!/bin/bash
# Override DATA_HOME_DIR if your shared filesystem mount differs.
: "${DATA_HOME_DIR:=/fsxl/${USER}/bionemo}"

mkdir -p "${DATA_HOME_DIR}"

# Remove any prior squash image so the import below can write fresh.
# Path matches the IMAGE default used by train-esm.sbatch.
rm -f "${DATA_HOME_DIR}/bionemo.sqsh"

enroot import -o "${DATA_HOME_DIR}/bionemo.sqsh" dockerd://bionemo:aws
