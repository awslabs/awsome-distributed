# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

FROM nvcr.io/nvidia/pytorch:25.08-py3
ENV DEBIAN_FRONTEND=noninteractive

###########################
# Component Versions
###########################
ARG EFA_INSTALLER_VERSION=1.47.0
ARG NCCL_VERSION=2.28.4-1
ARG AWS_OFI_NCCL_VERSION=1.14.1-aws
ARG LEROBOT_VERSION=0.4.3

###########################
# Remove conflicting libs
###########################
RUN apt-get update -y
RUN apt-get remove -y --allow-change-held-packages \
                      libmlx5-1 ibverbs-utils libibverbs-dev libibverbs1

RUN rm -rf /opt/hpcx/ompi \
    && rm -rf /usr/local/mpi \
    && rm -rf /opt/hpcx/nccl_rdma_sharp_plugin \
    && ldconfig
ENV OPAL_PREFIX=

###########################
# System dependencies
###########################
RUN DEBIAN_FRONTEND=noninteractive apt-get install -y --allow-unauthenticated \
    git \
    gcc \
    vim \
    kmod \
    openssh-client \
    openssh-server \
    build-essential \
    curl \
    autoconf \
    libtool \
    automake \
    cmake \
    apt-utils \
    libhwloc-dev \
    # Video decode dependencies for LeRobot dataset pipeline
    ffmpeg \
    libavcodec-dev \
    libavformat-dev \
    libswscale-dev && \
    DEBIAN_FRONTEND=noninteractive apt autoremove -y

###########################
# Install EFA
###########################
RUN cd /tmp && \
    curl -O https://efa-installer.amazonaws.com/aws-efa-installer-${EFA_INSTALLER_VERSION}.tar.gz && \
    tar -xf aws-efa-installer-${EFA_INSTALLER_VERSION}.tar.gz && \
    cd aws-efa-installer && \
    ./efa_installer.sh -y -g -d --skip-kmod --no-verify --skip-limit-conf && \
    ldconfig && \
    rm -rf /tmp/aws-efa-installer /var/lib/apt/lists/*
ENV LD_LIBRARY_PATH=/opt/amazon/efa/lib:$LD_LIBRARY_PATH
ENV PATH=/opt/amazon/efa/bin:/opt/amazon/openmpi/bin:$PATH

###########################
# Install NCCL from source
###########################
RUN apt-get update && apt-get remove -y libnccl2 libnccl-dev \
   && cd /tmp \
   && git clone https://github.com/NVIDIA/nccl.git -b v${NCCL_VERSION} \
   && cd nccl \
   && make -j src.build BUILDDIR=/usr \
   NVCC_GENCODE="-gencode=arch=compute_90,code=sm_90 -gencode=arch=compute_80,code=sm_80" \
   && rm -rf /tmp/nccl \
   && echo NCCL_SOCKET_IFNAME=^docker0,lo >> /etc/nccl.conf

###########################
# Install aws-ofi-nccl
###########################
RUN cd /tmp && \
    curl -LO https://github.com/aws/aws-ofi-nccl/archive/refs/tags/v${AWS_OFI_NCCL_VERSION}.tar.gz && \
    tar -xzf /tmp/v${AWS_OFI_NCCL_VERSION}.tar.gz && \
    rm /tmp/v${AWS_OFI_NCCL_VERSION}.tar.gz && \
    mv aws-ofi-nccl-${AWS_OFI_NCCL_VERSION} aws-ofi-nccl && \
    cd /tmp/aws-ofi-nccl && \
    ./autogen.sh && \
    ./configure --prefix=/opt/amazon/efa \
        --with-libfabric=/opt/amazon/efa \
        --with-cuda=/usr/local/cuda \
        --enable-platform-aws \
        --with-mpi=/opt/amazon/openmpi && \
    make -j$(nproc) install && \
    rm -rf /tmp/aws-ofi-nccl

RUN echo "/usr/local/lib"      >> /etc/ld.so.conf.d/local.conf && \
    echo "/opt/amazon/openmpi/lib" >> /etc/ld.so.conf.d/efa.conf && \
    ldconfig

###########################
# Environment variables
###########################
ENV OMPI_MCA_pml=^cm,ucx \
    OMPI_MCA_btl=tcp,self \
    OMPI_MCA_btl_tcp_if_exclude=lo,docker0 \
    OPAL_PREFIX=/opt/amazon/openmpi \
    NCCL_SOCKET_IFNAME=^docker,lo

ENV LD_LIBRARY_PATH="/usr/local/lib:/usr/local/cuda/lib64:${LD_LIBRARY_PATH}"

###########################
# Install LeRobot + deps
###########################
COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt

# Install LeRobot with pi0 extra (includes custom transformers branch for pi0-fast support)
RUN pip install --no-cache-dir "lerobot[pi]==${LEROBOT_VERSION}"

WORKDIR /workspace
