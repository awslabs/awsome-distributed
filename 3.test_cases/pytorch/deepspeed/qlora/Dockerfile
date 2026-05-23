# Dockerfile for QLoRA Fine-tuning of Qwen3-8B
# =============================================
# Base Image: PyTorch 25.04 with CUDA 12.9.0 (supports Blackwell, Hopper, Ampere)
# Python: 3.12 (bundled with pytorch:25.04-py3)
# Key Libraries: PyTorch, Transformers, PEFT, BitsAndBytes, DeepSpeed
# Networking: EFA 1.47, NCCL 2.29.3, GDRCopy 2.5.1
#
# Build:
#   docker build -t qwen3-qlora-training:latest .
#
# If you encounter CUBLAS errors at runtime (typically caused by CUDA
# library conflicts on the host), see docs/TROUBLESHOOTING.md.

# ============================================================
# Base image: PyTorch 25.04 with CUDA 12.9.0
# ============================================================
FROM nvcr.io/nvidia/pytorch:25.04-py3

ENV DEBIAN_FRONTEND=noninteractive

# ============================================================
# 1. System packages and SSH setup (needed for multi-node training)
# ============================================================
RUN apt-get update -y && apt-get upgrade -y
RUN apt-get remove -y --allow-change-held-packages \
    ibverbs-utils \
    libibverbs-dev \
    libibverbs1 \
    && rm -rf /opt/hpcx/ompi \
    && rm -rf /usr/local/ucx \
    && ldconfig

RUN apt-get install -y --no-install-recommends \
    autoconf \
    automake \
    build-essential \
    cmake \
    curl \
    gcc \
    gdb \
    git \
    git-lfs \
    gnupg \
    kmod \
    libtool \
    openssh-client \
    openssh-server \
    wget

# SSH configuration for multi-node
RUN rm -rf /root/.ssh/ \
 && mkdir -p /root/.ssh/ \
 && ssh-keygen -q -t rsa -N '' -f /root/.ssh/id_rsa \
 && cp /root/.ssh/id_rsa.pub /root/.ssh/authorized_keys \
 && printf "Host *\n  StrictHostKeyChecking no\n" >> /root/.ssh/config

# ============================================================
# 2. Install EFA Installer 1.47.0
# ============================================================
ENV EFA_INSTALLER_VERSION=1.47.0
WORKDIR /tmp
RUN curl -sL https://efa-installer.amazonaws.com/aws-efa-installer-${EFA_INSTALLER_VERSION}.tar.gz | tar xz \
    && cd aws-efa-installer \
    && ./efa_installer.sh -y -g -d --skip-kmod --skip-limit-conf --no-verify \
    && cd / && rm -rf /tmp/aws-efa-installer

# ============================================================
# 3. NCCL plugin symlinks
#    EFA installer names the plugin libnccl-net-ofi.so but NCCL
#    looks for libnccl-net-aws-ofi.so. Without this symlink NCCL
#    falls back to TCP sockets silently.
# ============================================================
RUN rm -rf /opt/amazon/aws-ofi-nccl

RUN ln -sf /opt/amazon/ofi-nccl/lib/libnccl-net-ofi.so \
           /opt/amazon/ofi-nccl/lib/libnccl-net-aws-ofi.so && \
    ln -sf /opt/amazon/ofi-nccl/lib/libnccl-ofi-tuner.so \
           /opt/amazon/ofi-nccl/lib/libnccl-tuner-aws-ofi.so

# ============================================================
# 4. Upgrade NCCL to 2.29.3 (requires CUDA >= 12.9)
# ============================================================
ENV NCCL_VERSION=2.29.3-1
RUN apt-get update && \
    apt-get install -y --no-install-recommends wget && \
    wget -qO /tmp/cuda-keyring.deb \
      https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb && \
    dpkg -i /tmp/cuda-keyring.deb && \
    rm /tmp/cuda-keyring.deb && \
    apt-get update && \
    apt-get install -y --allow-downgrades --allow-change-held-packages \
      libnccl2=${NCCL_VERSION}+cuda12.9 \
      libnccl-dev=${NCCL_VERSION}+cuda12.9 && \
    rm -rf /var/lib/apt/lists/*

# ============================================================
# 5. Install GDRCopy v2.5.1 (lib-only)
# ============================================================
RUN cd /tmp && \
    git clone --branch v2.5.1 --depth 1 https://github.com/NVIDIA/gdrcopy.git && \
    cd gdrcopy && \
    make -j$(nproc) lib lib_install && \
    cd / && rm -rf /tmp/gdrcopy

# ============================================================
# 6. Library path configuration
# ============================================================
RUN echo "/opt/amazon/ofi-nccl/lib" > /etc/ld.so.conf.d/aws-ofi-nccl.conf && \
    echo "/opt/amazon/efa/lib" > /etc/ld.so.conf.d/efa.conf

RUN sed -i 's|/opt/amazon/aws-ofi-nccl/lib|/opt/amazon/ofi-nccl/lib|g' /etc/environment 2>/dev/null || true
RUN sed -i 's|/opt/amazon/aws-ofi-nccl/lib|/opt/amazon/ofi-nccl/lib|g' /etc/shinit_v2 2>/dev/null || true

RUN rm -f /etc/ld.so.cache && ldconfig

ENV LD_LIBRARY_PATH="/opt/amazon/ofi-nccl/lib:/opt/amazon/efa/lib:/usr/local/cuda/extras/CUPTI/lib64:/opt/amazon/openmpi/lib:${LD_LIBRARY_PATH}"
ENV PATH="/opt/amazon/openmpi/bin:/opt/amazon/efa/bin:${PATH}"

# ============================================================
# 7. OpenMPI tuning for EFA
# ============================================================
ARG OPEN_MPI_PATH=/opt/amazon/openmpi
RUN echo "hwloc_base_binding_policy = none" >> ${OPEN_MPI_PATH}/etc/openmpi-mca-params.conf \
 && echo "rmaps_base_mapping_policy = slot" >> ${OPEN_MPI_PATH}/etc/openmpi-mca-params.conf

RUN mv ${OPEN_MPI_PATH}/bin/mpirun ${OPEN_MPI_PATH}/bin/mpirun.real \
 && echo '#!/bin/bash' > ${OPEN_MPI_PATH}/bin/mpirun \
 && echo "${OPEN_MPI_PATH}/bin/mpirun.real \"\$@\"" >> ${OPEN_MPI_PATH}/bin/mpirun \
 && chmod a+x ${OPEN_MPI_PATH}/bin/mpirun

# ============================================================
# 8. Python dependencies for QLoRA training
# ============================================================
WORKDIR /app

# Copy requirements first for better caching
COPY requirements.txt .

# Note: pytorch:25.04-py3 base image already includes torch with CUDA 12.9
# support. We skip installing torch separately to avoid version conflicts.
# The base image sets PIP_CONSTRAINT which pins dill==0.3.9, but all current
# versions of `datasets` require dill<0.3.9. Unset the constraint file to
# allow pip to resolve freely.
RUN PIP_CONSTRAINT="" pip install --no-cache-dir -r requirements.txt

# ============================================================
# 9. Application code
# ============================================================

# Copy source code and entrypoint
COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh
COPY src/ /app/src/
COPY configs/ /app/configs/

# Create directories for outputs and cache
RUN mkdir -p /workspace/outputs /workspace/hf_cache

# ============================================================
# 10. Environment variables
# ============================================================
ENV PYTHONPATH=/app
ENV HF_HOME=/workspace/hf_cache
ENV PYTHONUNBUFFERED=1
# Do NOT set CUDA_VISIBLE_DEVICES here -- let torchrun / K8s manage GPU visibility

# NCCL / EFA settings for multi-GPU and multi-node communication
ENV NCCL_DEBUG=INFO
ENV NCCL_SOCKET_IFNAME=^docker,lo,veth
ENV FI_PROVIDER=efa
ENV NCCL_TUNER_PLUGIN=/opt/amazon/ofi-nccl/lib/libnccl-ofi-tuner.so

# PyTorch memory allocator -- expandable segments reduces fragmentation
# Note: capital T is required in pytorch:25.04 containers
ENV PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True

# Clean up apt lists to reduce image size
RUN rm -rf /var/lib/apt/lists/*

# Entrypoint reads PET_* env vars set by the Kubeflow Training Operator
# and launches torchrun with the correct number of processes per node.
# Falls back to single-process mode outside PyTorchJob.
ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["src/train.py", "--config_path=configs/training_config_zero2.yaml"]
