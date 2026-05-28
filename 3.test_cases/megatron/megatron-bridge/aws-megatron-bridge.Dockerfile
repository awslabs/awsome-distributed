# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# Megatron-Bridge (https://pypi.org/project/megatron-bridge/) Qwen 3 training sample.
#
# This Dockerfile uses the NeMo Framework container which bundles Megatron-Bridge,
# Megatron-Core, and all required dependencies out of the box. We then upgrade Megatron-Bridge to the latest version (0.4.0 as of this writing) to get the latest features and fixes, including support for Qwen 3 training.
#
# See: https://github.com/NVIDIA-NeMo/Megatron-Bridge

FROM nvcr.io/nvidia/nemo:25.07

ARG GDRCOPY_VERSION=v2.5.1
ARG EFA_INSTALLER_VERSION=1.47.0

ARG OPEN_MPI_PATH=/opt/amazon/openmpi

######################
# Remove CUDA compat libs to prevent conflict with host driver.
# The host driver (injected via nvidia-container-runtime) provides libcuda.so.
# The bundled compat libs are for older host drivers and cause error 803 when
# the host driver is already newer than the compat version.
######################
RUN rm -rf /usr/local/cuda/compat/lib.real /usr/local/cuda/compat/libcuda* \
    /usr/local/cuda/compat/libcudadebugger* /usr/local/cuda/compat/libnvidia-nvvm* \
    /usr/local/cuda/compat/libnvidia-ptxjitcompiler*

######################
# Update and remove the IB libverbs
######################
RUN apt-get update -y && apt-get upgrade -y
RUN apt-get remove -y --allow-change-held-packages \
    ibverbs-utils \
    libibverbs-dev \
    libibverbs1 \
    libmlx5-1

RUN rm -rf /opt/hpcx/ompi \
    && rm -rf /opt/hpcx/nccl_rdma_sharp_plugin \
    && rm -rf /opt/hpcx/ncclnet_plugin \
    && rm -rf /usr/local/mpi \
    && rm -rf /usr/local/ucx \
    && ldconfig

RUN DEBIAN_FRONTEND=noninteractive apt install -y --allow-unauthenticated \
    apt-utils \
    autoconf \
    automake \
    build-essential \
    cmake \
    curl \
    gcc \
    gdb \
    git \
    kmod \
    libtool \
    openssh-client \
    openssh-server \
    vim \
    && apt remove -y python3-blinker \
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

ENV LD_LIBRARY_PATH=/usr/local/cuda/extras/CUPTI/lib64:/opt/amazon/openmpi/lib:/opt/nccl/build/lib:/opt/amazon/efa/lib:/opt/amazon/ofi-nccl/lib:/opt/amazon/ofi-nccl/lib/aarch64-linux-gnu:/opt/amazon/ofi-nccl/lib/x86_64-linux-gnu:/usr/local/lib:$LD_LIBRARY_PATH
ENV PATH=/opt/amazon/openmpi/bin/:/opt/amazon/efa/bin:/usr/bin:/usr/local/bin:$PATH

#################################################
## Install NVIDIA GDRCopy
RUN git clone -b ${GDRCOPY_VERSION} https://github.com/NVIDIA/gdrcopy.git /tmp/gdrcopy \
    && cd /tmp/gdrcopy \
    && make prefix=/opt/gdrcopy install

ENV LD_LIBRARY_PATH=/opt/gdrcopy/lib:$LD_LIBRARY_PATH
ENV LIBRARY_PATH=/opt/gdrcopy/lib:$LIBRARY_PATH
ENV CPATH=/opt/gdrcopy/include:$CPATH
ENV PATH=/opt/gdrcopy/bin:$PATH

#################################################
## Install EFA installer
RUN cd $HOME \
    && curl -O https://efa-installer.amazonaws.com/aws-efa-installer-${EFA_INSTALLER_VERSION}.tar.gz \
    && tar -xf $HOME/aws-efa-installer-${EFA_INSTALLER_VERSION}.tar.gz \
    && cd aws-efa-installer \
    && ./efa_installer.sh -y -g -d --skip-kmod --skip-limit-conf --no-verify \
    && rm -rf $HOME/aws-efa-installer

RUN echo "Verifying AWS OFI NCCL plugin installation..." && \
    (ls -la /opt/amazon/ofi-nccl/lib/libnccl-net*.so || \
     ls -la /opt/amazon/ofi-nccl/lib/x86_64-linux-gnu/libnccl-ofi*.so || \
     ls -la /opt/amazon/ofi-nccl/lib/aarch64-linux-gnu/libnccl-ofi*.so)

###################################################
RUN rm -rf /var/lib/apt/lists/*

RUN echo "hwloc_base_binding_policy = none" >> /opt/amazon/openmpi/etc/openmpi-mca-params.conf \
 && echo "rmaps_base_mapping_policy = slot" >> /opt/amazon/openmpi/etc/openmpi-mca-params.conf

RUN pip3 install --no-cache-dir "awscli>=1.44,<2.0" "pynvml>=12.0,<13.0" "wandb>=0.26,<1.0"

RUN mv $OPEN_MPI_PATH/bin/mpirun $OPEN_MPI_PATH/bin/mpirun.real \
 && echo '#!/bin/bash' > $OPEN_MPI_PATH/bin/mpirun \
 && echo '/opt/amazon/openmpi/bin/mpirun.real "$@"' >> $OPEN_MPI_PATH/bin/mpirun \
 && chmod a+x $OPEN_MPI_PATH/bin/mpirun

######################
# Additional dependencies for the training script
# (Megatron-Bridge, Megatron-Core, and transformers are already in the base image)
######################
RUN pip install --no-cache-dir \
    "sentencepiece>=0.2,<1.0" "python-etcd>=0.4,<1.0"

######################
# Upgrade Megatron-Bridge to 0.4.0 for Qwen3 support
# The NeMo 25.07 base ships megatron-bridge 0.2.0rc0 and MCore 0.13.1.
# megatron-bridge 0.4.0 requires MCore >=0.18 and transformers >=4.57, so we
# upgrade the full stack. modelopt is also upgraded to fix Conv1D compat.
######################
RUN pip uninstall -y megatron-bridge megatron-core \
    && rm -rf /opt/Megatron-Bridge /opt/megatron-lm \
    && pip install --no-cache-dir --no-deps git+https://github.com/NVIDIA/Megatron-LM.git@main \
    && pip install --no-cache-dir "transformers>=4.57,<5.0" \
    && pip install --no-cache-dir --no-deps "nvidia-modelopt>=0.33" \
    && pip install --no-cache-dir --no-deps "megatron-bridge>=0.4.0"

######################
# Copy training script
######################
COPY kubernetes/qwen3/pretrain_qwen3.py /workspace/pretrain_qwen3.py

## Set Open MPI variables to exclude network interface and conduit.
ENV OMPI_MCA_pml=^ucx            \
    OMPI_MCA_btl=tcp,self           \
    OMPI_MCA_btl_tcp_if_exclude=lo,docker0,veth_def_agent \
    OPAL_PREFIX=/opt/amazon/openmpi \
    NCCL_SOCKET_IFNAME=^docker,lo,veth_def_agent

## Turn off PMIx Error https://github.com/open-mpi/ompi/issues/7516
ENV PMIX_MCA_gds=hash

WORKDIR /workspace
