# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
#
# OpenVLA fine-tuning container for HyperPod Slurm (P5/P5en)
# Build:
#   docker build -t openvla-finetune -f openvla.Dockerfile .
# Import for Pyxis/Enroot:
#   enroot import -o /fsx/$USER/openvla-finetune.sqsh dockerd://openvla-finetune:latest

# Pinned to a tag meeting CI minimums: CUDA >= 13.0, EFA >= 1.47.0, NCCL >= 2.28
FROM public.ecr.aws/hpc-cloud/nccl-tests:cuda13.0.2-efa1.48.0-ofiv1.19.0-ncclv2.30.4-1-testsv2.18.3

# System deps
RUN apt-get update && apt-get install -y --no-install-recommends \
        git \
        nvtop \
    && rm -rf /var/lib/apt/lists/*

# Pinned Python training dependencies
# These versions are validated against OpenVLA commit 8a2e3bd
RUN pip install --no-cache-dir \
        torch==2.6.0 \
        torchvision==0.21.0 \
        transformers==4.44.2 \
        peft==0.13.2 \
        accelerate==1.2.1 \
        datasets>=2.14.0,<3.0.0 \
        tensorflow-datasets>=4.9.0,<5.0.0 \
        tensorflow>=2.15.0,<3.0.0 \
        tensorflow-graphics>=2021.12.20 \
        huggingface-hub>=0.20.0,<1.0.0 \
        wandb>=0.16.0,<1.0.0 \
        pillow>=10.0.0,<11.0.0 \
        scipy>=1.11.0,<2.0.0 \
        einops>=0.7.0,<1.0.0

# dlimp (data loading for RLDS) — no-deps to avoid conflicts
RUN pip install --no-cache-dir --no-deps \
        git+https://github.com/kvablack/dlimp.git@5edaa4691567873d495633f2708982b42edf1972

# Clone OpenVLA and pin to tested commit
RUN git clone https://github.com/openvla/openvla.git /openvla \
    && cd /openvla && git checkout 8a2e3bd

# Install OpenVLA in editable mode (pulls remaining deps)
RUN cd /openvla && pip install --no-cache-dir -e .

# Symlink python for convenience
RUN ln -sf /usr/bin/python3 /usr/bin/python

WORKDIR /openvla
