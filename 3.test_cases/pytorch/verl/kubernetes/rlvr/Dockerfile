# Dockerfile for VERL with EFA support
# Using hiyouga/verl base image and adding EFA capabilities
ARG TAG=vllm011.latest
FROM verlai/verl:${TAG}
ARG MEGATRON_LM_VERSION=core_v0.13.1
# EFA configuration
ARG OPEN_MPI_PATH=/opt/amazon/openmpi/
ENV EFA_VERSION=1.43.3

# Install system dependencies including EFA requirements
RUN apt-get update && apt-get install -y \
    python3.11 \
    python3.11-dev \
    python3-pip \
    git \
    wget \
    curl \
    ninja-build \
    autoconf \
    build-essential \
    pciutils \
    environment-modules \
    tcl \
    tcl-dev \
    libnl-3-dev \
    libnl-route-3-dev \
    dmidecode \
    ethtool \
    iproute2 \
    libevent-dev \
    libhwloc-dev \
    openssh-server \
    openssh-client \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /var/run/sshd
RUN sed -i 's/[ #]\(.*StrictHostKeyChecking \).*/ \1no/g' /etc/ssh/ssh_config && \
    echo "    UserKnownHostsFile /dev/null" >> /etc/ssh/ssh_config && \
    sed -i 's/#\(StrictModes \).*/\1no/g' /etc/ssh/sshd_config

# Install udev in a container-safe way
RUN apt-get update && apt-get install -y \
    systemd \
    udev \
    && rm -rf /var/lib/apt/lists/*


# Upgrade pip
RUN python3 -m pip install --upgrade pip setuptools wheel

#################################################
## Clean up HPC-X to avoid conflicts with EFA
RUN rm -rf /opt/hpcx \
    && rm -rf /usr/local/mpi \
    && rm -f /etc/ld.so.conf.d/hpcx.conf \
    && ldconfig

#################################################
## EFA SETUP - Install EFA with all dependencies
RUN cd $HOME \
    && curl -O https://efa-installer.amazonaws.com/aws-efa-installer-${EFA_VERSION}.tar.gz \
    && tar -xf aws-efa-installer-${EFA_VERSION}.tar.gz \
    && cd aws-efa-installer \
    && ./efa_installer.sh -y --skip-kmod --skip-limit-conf --no-verify

# Set environment paths for EFA components (order matters!)
ENV PATH="/opt/amazon/openmpi/bin:/opt/amazon/efa/bin:/usr/local/cuda/bin:$PATH"
ENV LD_LIBRARY_PATH="/opt/amazon/openmpi/lib:/opt/nccl/build/lib:/opt/amazon/efa/lib:/opt/amazon/ofi-nccl/lib/x86_64-linux-gnu:/usr/local/cuda/lib64:$LD_LIBRARY_PATH"

# OpenMPI configuration to use EFA and avoid conflicts
ENV OMPI_MCA_pml=^ucx
ENV OMPI_MCA_btl=tcp,self
ENV OMPI_MCA_btl_tcp_if_exclude=lo,docker0,veth_def_agent
ENV OPAL_PREFIX=/opt/amazon/openmpi

# EFA/NCCL configuration for optimal performance
ENV FI_PROVIDER=efa
ENV FI_EFA_USE_DEVICE_RDMA=1
ENV FI_EFA_FORK_SAFE=1
ENV FI_EFA_ENABLE_SHM_TRANSFER=1
ENV NCCL_PROTO=simple
ENV NCCL_SOCKET_IFNAME=^docker,lo,veth
ENV NCCL_TUNER_PLUGIN=/opt/amazon/ofi-nccl/lib/x86_64-linux-gnu/libnccl-ofi-tuner.so
ENV PMIX_MCA_gds=hash

#################################################
## Optional: Install NCCL tests for verification
RUN git clone https://github.com/NVIDIA/nccl-tests.git /opt/nccl-tests \
    && cd /opt/nccl-tests \
    && make -j $(nproc) MPI=1 MPI_HOME=/opt/amazon/openmpi CUDA_HOME=/usr/local/cuda NCCL_HOME=/opt/nccl/build


# Install core ML libraries
RUN pip install \
    transformers>=4.45.0 \
    datasets \
    accelerate \
    tokenizers \
    numpy \
    scipy \
    scikit-learn \
    vllm>=0.7.0 \
    hydra-core \
    omegaconf \
    wandb \
    tensorboard \
    boto3 \
    botocore \
    tenacity \
    s3torchconnector

# Clone and install VERL
WORKDIR /workspace
RUN git clone https://github.com/volcengine/verl.git && \
    cd verl && \
    git checkout v0.6.1
WORKDIR /workspace/verl
# Install VERL in development mode
RUN pip install -e .

#####################
# Install megatron-lm
#####################
RUN pip install -U setuptools
RUN cd /workspace && git clone --depth 1 --branch ${MEGATRON_LM_VERSION} https://github.com/NVIDIA/Megatron-LM.git \
    && cd Megatron-LM \
    && pip install nltk  \
    && pip install .
# Check if speparate Apex is needed
# https://verl.readthedocs.io/en/latest/start/install.html#install-from-docker-image


# Set working directory
WORKDIR /workspace

# Expose Ray ports
EXPOSE 8265 10001 6379
