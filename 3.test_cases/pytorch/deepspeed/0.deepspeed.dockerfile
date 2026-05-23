# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# ============================================================
# Base image: PyTorch 25.04 with CUDA 12.9.0 (required for NCCL 2.29.x)
# Supports Blackwell (sm_100), Hopper, Ampere architectures
# ============================================================
FROM nvcr.io/nvidia/pytorch:25.04-py3

ARG TRANSFORMERS_VERSION=4.44.2
ARG OPEN_MPI_PATH=/opt/amazon/openmpi

ENV DEBIAN_FRONTEND=noninteractive

# ============================================================
# 1. System packages and SSH setup (needed for multi-node training)
# ============================================================
RUN apt-get update -y && apt-get upgrade -y
RUN apt-get remove -y --allow-change-held-packages \
    ibverbs-utils \
    libibverbs-dev \
    libibverbs1 \
    libmlx5-1

RUN rm -rf /opt/hpcx/ompi \
    && rm -rf /usr/local/mpi \
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
    gnupg \
    kmod \
    libtool \
    openssh-client \
    openssh-server \
    vim \
    && apt autoremove -y

RUN mkdir -p /var/run/sshd && \
    sed -i 's/[ #]\(.*StrictHostKeyChecking \).*/ \1no/g' /etc/ssh/ssh_config && \
    echo "    UserKnownHostsFile /dev/null" >> /etc/ssh/ssh_config && \
    sed -i 's/#\(StrictModes \).*/\1no/g' /etc/ssh/sshd_config && \
    sed 's@session\s*required\s*pam_loginuid.so@session optional pam_loginuid.so@g' -i /etc/pam.d/sshd

RUN rm -rf /root/.ssh/ \
 && mkdir -p /root/.ssh/ \
 && ssh-keygen -q -t rsa -N '' -f /root/.ssh/id_rsa \
 && cp /root/.ssh/id_rsa.pub /root/.ssh/authorized_keys \
 && printf "Host *\n  StrictHostKeyChecking no\n" >> /root/.ssh/config

# ============================================================
# 2. Install EFA Installer 1.47.0
#    This bundles libfabric, rdma-core, and pre-built aws-ofi-nccl
#    No source build of aws-ofi-nccl needed (unlike EFA < 1.40)
# ============================================================
ENV EFA_INSTALLER_VERSION=1.47.0
WORKDIR /tmp
RUN curl -sL https://efa-installer.amazonaws.com/aws-efa-installer-${EFA_INSTALLER_VERSION}.tar.gz | tar xz \
    && cd aws-efa-installer \
    && ./efa_installer.sh -y -g -d --skip-kmod --skip-limit-conf --no-verify \
    && cd / && rm -rf /tmp/aws-efa-installer

# ============================================================
# 3. Remove old aws-ofi-nccl and create NCCL plugin symlinks
#    NCCL_NET_PLUGIN=aws-ofi looks for libnccl-net-aws-ofi.so
#    EFA installer names it libnccl-net-ofi.so
#    Without this symlink NCCL falls back to TCP sockets silently
# ============================================================
RUN rm -rf /opt/amazon/aws-ofi-nccl

RUN ln -sf /opt/amazon/ofi-nccl/lib/libnccl-net-ofi.so \
           /opt/amazon/ofi-nccl/lib/libnccl-net-aws-ofi.so && \
    ln -sf /opt/amazon/ofi-nccl/lib/libnccl-ofi-tuner.so \
           /opt/amazon/ofi-nccl/lib/libnccl-tuner-aws-ofi.so

# ============================================================
# 4. Upgrade NCCL to 2.29.3 (matches B200 host version)
#    Requires CUDA >= 12.9 (which pytorch:25.04-py3 provides)
#    Must add NVIDIA CUDA apt repo first since base image may not have it
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
# 5. Install GDRCopy v2.5.1 (lib-only, no binaries needed)
# ============================================================
RUN cd /tmp && \
    git clone --branch v2.5.1 --depth 1 https://github.com/NVIDIA/gdrcopy.git && \
    cd gdrcopy && \
    make -j$(nproc) lib lib_install && \
    cd / && rm -rf /tmp/gdrcopy

# ============================================================
# 6. Fix library path references
#    Use ld.so.conf.d for system-wide discovery (more robust
#    than relying solely on LD_LIBRARY_PATH)
# ============================================================
RUN echo "/opt/amazon/ofi-nccl/lib" > /etc/ld.so.conf.d/aws-ofi-nccl.conf && \
    echo "/opt/amazon/efa/lib" > /etc/ld.so.conf.d/efa.conf

RUN sed -i 's|/opt/amazon/aws-ofi-nccl/lib|/opt/amazon/ofi-nccl/lib|g' /etc/environment 2>/dev/null || true
RUN sed -i 's|/opt/amazon/aws-ofi-nccl/lib|/opt/amazon/ofi-nccl/lib|g' /etc/shinit_v2 2>/dev/null || true

# Rebuild ldconfig cache
RUN rm -f /etc/ld.so.cache && ldconfig

# ============================================================
# 7. Environment variables
# ============================================================
ENV LD_LIBRARY_PATH="/opt/amazon/ofi-nccl/lib:/opt/amazon/efa/lib:/usr/local/cuda/extras/CUPTI/lib64:/opt/amazon/openmpi/lib:${LD_LIBRARY_PATH}"
ENV PATH="/opt/amazon/openmpi/bin:/opt/amazon/efa/bin:${PATH}"
ENV FI_PROVIDER=efa

# ============================================================
# 8. OpenMPI tuning for EFA (needed for multi-node training)
# ============================================================
RUN echo "hwloc_base_binding_policy = none" >> ${OPEN_MPI_PATH}/etc/openmpi-mca-params.conf \
 && echo "rmaps_base_mapping_policy = slot" >> ${OPEN_MPI_PATH}/etc/openmpi-mca-params.conf

RUN mv ${OPEN_MPI_PATH}/bin/mpirun ${OPEN_MPI_PATH}/bin/mpirun.real \
 && echo '#!/bin/bash' > ${OPEN_MPI_PATH}/bin/mpirun \
 && echo "${OPEN_MPI_PATH}/bin/mpirun.real \"\$@\"" >> ${OPEN_MPI_PATH}/bin/mpirun \
 && chmod a+x ${OPEN_MPI_PATH}/bin/mpirun

# ============================================================
# 9. Python packages for DeepSpeed training
# ============================================================
RUN pip3 install --no-cache-dir \
    awscli pynvml \
    transformers==${TRANSFORMERS_VERSION} \
    sentencepiece python-etcd \
    'deepspeed>=0.16,<1.0' 'accelerate>=1.0,<2.0'

RUN rm -rf /var/lib/apt/lists/*

WORKDIR /workspace
