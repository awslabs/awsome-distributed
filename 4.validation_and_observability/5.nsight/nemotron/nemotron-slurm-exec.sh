#!/bin/bash

# Override NSYS_OUTPUT_DIR to point at your shared filesystem location for
# Nsight profile reports.
: "${NSYS_OUTPUT_DIR:=/fsx/${USER}/nemotron/results/nemotron4--15B-16g/profile_logs}"

NSYS_EXTRAS=""
if [ "$SLURM_LOCALID" == "0" ]; then
        NSYS_EXTRAS="--enable efa_metrics"
fi

if [ "$SLURM_PROCID" == "0" ]; then
        mkdir -p "${NSYS_OUTPUT_DIR}"
        /fsx/nsight-efa-latest/target-linux-x64/nsys profile $NSYS_EXTRAS --sample none --delay 330 --duration 50 -o "${NSYS_OUTPUT_DIR}/profile_%q{SLURM_JOB_ID}_node_%q{SLURM_NODEID}_rank_%q{SLURM_PROCID}_on_%q{HOSTNAME}.nsys-rep" --force-overwrite true \
   "$@"
else
        "$@"
fi