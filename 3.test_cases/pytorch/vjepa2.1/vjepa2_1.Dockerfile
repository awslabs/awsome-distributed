# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# V-JEPA 2.1 reuses the same container as V-JEPA 2, since both training
# apps live in the same facebookresearch/vjepa2 repository.
#
# V-JEPA 2.1 requires Python >= 3.11
# Using NVIDIA PyTorch container as base for CUDA 13 + NCCL + EFA compatibility
FROM nvcr.io/nvidia/pytorch:25.03-py3

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    ffmpeg libsm6 libxext6 \
    && rm -rf /var/lib/apt/lists/*

# Install EFA
ARG EFA_INSTALLER_VERSION=1.47.0
RUN cd /tmp && \
    curl -sL https://efa-installer.amazonaws.com/aws-efa-installer-${EFA_INSTALLER_VERSION}.tar.gz | tar xz && \
    cd aws-efa-installer && \
    ./efa_installer.sh -y --skip-kmod --skip-limit-conf --no-verify && \
    cd /tmp && rm -rf aws-efa-installer

# Install NCCL dev headers for EFA plugin compilation.
# The base NVIDIA image (pytorch:25.03-py3) ships NCCL 2.25 at runtime.
# NOTE: For B200 GPUs requiring NCCL >= 2.29, use a NeMo container instead
# (see B200 section in README.md). This container targets H200/p5en.
RUN apt-get update && apt-get install -y libnccl-dev && rm -rf /var/lib/apt/lists/*

# Install V-JEPA 2 / 2.1 dependencies (pinned to tested versions)
RUN pip install --no-cache-dir \
    tensorboard==2.20.0 wandb==0.25.0 iopath==0.1.10 pyyaml==6.0.3 \
    opencv-python==4.11.0.86 submitit==1.5.4 braceexpand==0.1.7 \
    webdataset==1.0.2 timm==1.0.24 transformers==5.1.0 \
    peft==0.18.1 decord==0.6.0 pandas==3.0.0 einops==0.8.2 \
    beartype==0.22.9 psutil==7.2.2 h5py==3.15.1 fire==0.7.1 \
    python-box==7.3.2 scikit-image==0.26.0 ftfy==6.3.1 \
    eva-decord==0.6.1 Pillow==12.0.0

# Clone V-JEPA 2 (includes V-JEPA 2.1 code under app/vjepa_2_1/; pinned to tested commit)
ARG VJEPA2_COMMIT=204698b45b3712590f06245fbfba32d3be539812
RUN git clone https://github.com/facebookresearch/vjepa2.git /vjepa2 && \
    cd /vjepa2 && git checkout ${VJEPA2_COMMIT}
WORKDIR /vjepa2
RUN pip install -e .

# Copy launcher scripts into the container
COPY scripts/run_train.py /vjepa2/scripts/run_train.py

ENV PYTHONPATH="/vjepa2:${PYTHONPATH}"
