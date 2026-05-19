# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
#
# OpenRLHF with EFA support for Amazon EKS (HyperPod)
#
# Base: NGC PyTorch 25.02 (CUDA 12.8, PyTorch 2.8, Python 3.12)
# OpenRLHF: v0.9.0 with vLLM 0.11.0 + DeepSpeed ZeRO-3 + Ray
#
# Build:
#   docker build -t openrlhf-rlvr:latest .
#
# The image supports both g5.12xlarge (4× A10G 24GB) and p5en.48xlarge
# (8× H100 80GB) with Non-Hybrid Engine (separate vLLM + training nodes).

FROM nvcr.io/nvidia/pytorch:25.02-py3

# ---------------------------------------------------------------------------
# System dependencies + EFA
# ---------------------------------------------------------------------------
ARG EFA_VERSION=1.47.0

RUN apt-get update && apt-get install -y --no-install-recommends \
        git wget curl ninja-build autoconf build-essential \
        pciutils environment-modules tcl tcl-dev \
        libnl-3-dev libnl-route-3-dev libevent-dev libhwloc-dev \
        dmidecode ethtool iproute2 \
        openssh-server openssh-client \
        systemd udev \
    && rm -rf /var/lib/apt/lists/*

# SSH configuration for multi-node
RUN mkdir -p /var/run/sshd \
    && sed -i 's/[ #]\(.*StrictHostKeyChecking \).*/ \1no/g' /etc/ssh/ssh_config \
    && echo "    UserKnownHostsFile /dev/null" >> /etc/ssh/ssh_config \
    && sed -i 's/#\(StrictModes \).*/\1no/g' /etc/ssh/sshd_config

# ---------------------------------------------------------------------------
# EFA installer (skip kernel modules — provided by the host)
# ---------------------------------------------------------------------------
RUN cd /tmp \
    && curl -O https://efa-installer.amazonaws.com/aws-efa-installer-${EFA_VERSION}.tar.gz \
    && tar -xf aws-efa-installer-${EFA_VERSION}.tar.gz \
    && cd aws-efa-installer \
    && ./efa_installer.sh -y --skip-kmod --skip-limit-conf --no-verify \
    && rm -rf /tmp/aws-efa-installer*

# Clean up HPC-X to avoid conflicts with EFA
RUN rm -rf /opt/hpcx /usr/local/mpi \
    && rm -f /etc/ld.so.conf.d/hpcx.conf \
    && ldconfig

# EFA / OpenMPI paths
ENV PATH="/opt/amazon/openmpi/bin:/opt/amazon/efa/bin:${PATH}"
ENV LD_LIBRARY_PATH="/opt/amazon/openmpi/lib:/opt/nccl/build/lib:/opt/amazon/efa/lib:/opt/amazon/ofi-nccl/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH}"
ENV OMPI_MCA_pml=^ucx
ENV OMPI_MCA_btl=tcp,self
ENV OMPI_MCA_btl_tcp_if_exclude=lo,docker0,veth_def_agent
ENV OPAL_PREFIX=/opt/amazon/openmpi

# EFA / NCCL tuning
ENV FI_PROVIDER=efa
ENV FI_EFA_USE_DEVICE_RDMA=1
ENV FI_EFA_FORK_SAFE=1
ENV FI_EFA_ENABLE_SHM_TRANSFER=1
ENV NCCL_PROTO=simple
ENV NCCL_SOCKET_IFNAME=^docker,lo,veth
ENV NCCL_TUNER_PLUGIN=/opt/amazon/ofi-nccl/lib/x86_64-linux-gnu/libnccl-ofi-tuner.so
ENV PMIX_MCA_gds=hash

# ---------------------------------------------------------------------------
# NCCL tests (optional — useful for cluster validation)
# ---------------------------------------------------------------------------
RUN git clone --branch v2.13.11 --depth 1 https://github.com/NVIDIA/nccl-tests.git /opt/nccl-tests \
    && cd /opt/nccl-tests \
    && make -j $(nproc) MPI=1 MPI_HOME=/opt/amazon/openmpi CUDA_HOME=/usr/local/cuda NCCL_HOME=/opt/nccl/build

# ---------------------------------------------------------------------------
# Python dependencies — OpenRLHF + vLLM
# ---------------------------------------------------------------------------
# Remove NGC packages that conflict with OpenRLHF's pinned versions
RUN pip uninstall -y xgboost transformer_engine flash_attn pynvml opencv-python-headless 2>/dev/null || true

# Install vLLM first (heavy dependency — bundles its own flash-attention)
RUN pip install --no-cache-dir vllm==0.11.0

# Fix NumPy / cv2 compatibility issues introduced by vLLM 0.11.0:
#   1. vLLM pulls opencv-python-headless which crashes with NumPy 2.4 from NGC
#   2. vLLM imports numba which requires NumPy ≤ 2.2
RUN pip install --no-cache-dir 'numpy<2.3' \
    && pip uninstall -y opencv-python-headless 2>/dev/null || true \
    && rm -rf /usr/local/lib/python3.12/dist-packages/cv2*

# Note: flash-attn is NOT installed separately.  vLLM 0.11.0 bundles its own
# flash-attention backend, and HuggingFace Transformers' flash_attention_2
# implementation uses it automatically.  Building flash-attn from source
# requires a GPU (CUDA compilation), which is unavailable in CI/CodeBuild.

# Install OpenRLHF v0.9.0
RUN pip install --no-cache-dir openrlhf==0.9.0

# Additional dependencies for our reward function and evaluation
RUN pip install --no-cache-dir \
    langdetect \
    boto3 \
    botocore \
    s3torchconnector

# ---------------------------------------------------------------------------
# Working directory and ports
# ---------------------------------------------------------------------------
WORKDIR /workspace

# Ray dashboard (8265), Ray client (10001), Ray GCS (6379), metrics (8080)
EXPOSE 8265 10001 6379 8080
