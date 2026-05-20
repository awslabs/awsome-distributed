#!/bin/bash
# Override DATA_HOME_DIR if your shared filesystem mount differs.
: "${DATA_HOME_DIR:=/fsxl/${USER}/bionemo}"

mkdir -p "${DATA_HOME_DIR}"
docker run --rm -v "${DATA_HOME_DIR}:/root/.cache/bionemo" bionemo:aws \
    download_bionemo_data esm2/testdata_esm2_pretrain:2.0
