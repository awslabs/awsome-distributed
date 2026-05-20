#!/bin/bash
# Override ESM2_DATA_DIR if your shared filesystem mount differs.
: "${ESM2_DATA_DIR:=/fsxl/${USER}/esm2}"

mkdir -p "${ESM2_DATA_DIR}"

file_name="${ESM2_DATA_DIR}/esm.sqsh"
[ -f "$file_name" ] && rm "$file_name"

enroot import -o "$file_name" dockerd://esm:aws
