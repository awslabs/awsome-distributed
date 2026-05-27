# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# vLLM 0.21.0 + UCCL-EP + NIXL container image for DeepSeek-V3 disaggregated
# inference on AWS EKS / SageMaker HyperPod EKS with EFA.
#
# Layered on top of an NCCL-tests style EFA base:
#   - CUDA 13 devel
#   - GDRCopy 2.5.2
#   - EFA installer 1.48.0
#   - NCCL 2.30.4 (CUDA arches 8.0/8.6/8.9/9.0/10.0/10.3)
#   - vLLM 0.21.0 from source
#   - NIXL 1.0.1 (cu13 build)
#   - UCCL (commit 0dc87eb) + uccl.ep + deep_ep wrapper
#   - Ray 2.55.1 for DP coordination
#
# Build:
#   ./setup/build-push.sh
#
ARG CUDA_VERSION=13.0.3
FROM nvidia/cuda:${CUDA_VERSION}-devel-ubuntu24.04

ARG GDRCOPY_VERSION=v2.5.2
ARG EFA_INSTALLER_VERSION=1.48.0
ARG NCCL_VERSION=v2.30.4-1
ARG NCCL_TESTS_VERSION=v2.18.3
ARG VLLM_COMMIT=v0.21.0
ARG NIXL_VERSION=v1.0.1
ARG UCCL_COMMIT=0dc87eb3b40c372a16b70ef320f37daaa5299ca7

# --- system packages ---------------------------------------------------------
RUN apt-get update -y && apt-get upgrade -y
RUN apt-get remove -y --allow-change-held-packages \
    ibverbs-utils libibverbs-dev libibverbs1 libmlx5-1 libnccl2 libnccl-dev \
    || true

RUN rm -rf /opt/hpcx /usr/local/mpi \
    && rm -f /etc/ld.so.conf.d/hpcx.conf \
    && ldconfig

ENV OPAL_PREFIX=

RUN DEBIAN_FRONTEND=noninteractive apt-get install -y --allow-unauthenticated \
    apt-utils autoconf automake build-essential check cmake curl debhelper \
    devscripts git gcc gdb kmod libsubunit-dev libtool openssh-client \
    openssh-server pkg-config vim python3-dev python3-pip python3-venv

RUN apt-get purge -y cuda-compat-* || true

RUN mkdir -p /var/run/sshd
RUN sed -i 's/[ #]\(.*StrictHostKeyChecking \).*/ \1no/g' /etc/ssh/ssh_config && \
    echo "    UserKnownHostsFile /dev/null" >> /etc/ssh/ssh_config && \
    sed -i 's/#\(StrictModes \).*/\1no/g' /etc/ssh/sshd_config

ENV LD_LIBRARY_PATH=/usr/local/cuda/extras/CUPTI/lib64:/opt/amazon/openmpi/lib:/opt/nccl/build/lib:/opt/amazon/efa/lib:/opt/amazon/ofi-nccl/lib:/opt/amazon/ofi-nccl/lib/x86_64-linux-gnu:/usr/local/lib:$LD_LIBRARY_PATH
ENV PATH=/opt/amazon/openmpi/bin:/opt/amazon/efa/bin:/usr/bin:/usr/local/bin:$PATH

RUN rm -f /usr/lib/python3.12/EXTERNALLY-MANAGED /usr/lib/python3/EXTERNALLY-MANAGED
RUN pip3 install --break-system-packages awscli pynvml

# --- GDRCopy -----------------------------------------------------------------
RUN git clone -b ${GDRCOPY_VERSION} https://github.com/NVIDIA/gdrcopy.git /tmp/gdrcopy \
    && cd /tmp/gdrcopy \
    && make prefix=/opt/gdrcopy install

ENV LD_LIBRARY_PATH=/opt/gdrcopy/lib:$LD_LIBRARY_PATH
ENV LIBRARY_PATH=/opt/gdrcopy/lib:$LIBRARY_PATH
ENV CPATH=/opt/gdrcopy/include:$CPATH
ENV PATH=/opt/gdrcopy/bin:$PATH

# --- EFA installer -----------------------------------------------------------
RUN cd $HOME \
    && curl -O https://efa-installer.amazonaws.com/aws-efa-installer-${EFA_INSTALLER_VERSION}.tar.gz \
    && tar -xf aws-efa-installer-${EFA_INSTALLER_VERSION}.tar.gz \
    && cd aws-efa-installer \
    && ./efa_installer.sh -y -g -d --skip-kmod --skip-limit-conf --no-verify --disable-ngc \
    && rm -rf $HOME/aws-efa-installer

RUN echo "Verifying AWS OFI NCCL plugin installation..." && \
    (ls -la /opt/amazon/ofi-nccl/lib/libnccl-net*.so || \
     ls -la /opt/amazon/ofi-nccl/lib/x86_64-linux-gnu/libnccl-ofi*.so)

# --- NCCL --------------------------------------------------------------------
RUN git clone -b ${NCCL_VERSION} https://github.com/NVIDIA/nccl.git /opt/nccl \
    && cd /opt/nccl \
    && make -j $(nproc) src.build CUDA_HOME=/usr/local/cuda \
       NVCC_GENCODE="-gencode=arch=compute_80,code=sm_80 -gencode=arch=compute_86,code=sm_86 -gencode=arch=compute_89,code=sm_89 -gencode=arch=compute_90,code=sm_90 -gencode=arch=compute_100,code=sm_100 -gencode=arch=compute_103,code=sm_103"

# --- NCCL tests (handy for fi_info / health checks) --------------------------
RUN git clone -b ${NCCL_TESTS_VERSION} https://github.com/NVIDIA/nccl-tests.git /opt/nccl-tests \
    && cd /opt/nccl-tests \
    && make -j $(nproc) MPI=1 MPI_HOME=/opt/amazon/openmpi/ \
       CUDA_HOME=/usr/local/cuda NCCL_HOME=/opt/nccl/build \
       NVCC_GENCODE="-gencode=arch=compute_80,code=sm_80 -gencode=arch=compute_86,code=sm_86 -gencode=arch=compute_89,code=sm_89 -gencode=arch=compute_90,code=sm_90 -gencode=arch=compute_100,code=sm_100 -gencode=arch=compute_103,code=sm_103"

RUN rm -rf /var/lib/apt/lists/*

ENV OMPI_MCA_pml=^ucx \
    OMPI_MCA_btl=tcp,self \
    OMPI_MCA_btl_tcp_if_exclude=lo,docker0,veth_def_agent \
    OPAL_PREFIX=/opt/amazon/openmpi \
    NCCL_SOCKET_IFNAME=^docker,lo,veth \
    PMIX_MCA_gds=hash \
    LD_PRELOAD=/opt/nccl/build/lib/libnccl.so

# --- Python tooling (uv) -----------------------------------------------------
RUN curl -LsSf https://astral.sh/uv/install.sh | sh
ENV PATH="/root/.local/bin:$PATH"
ENV UV_HTTP_TIMEOUT=500
ENV UV_LINK_MODE=copy

RUN apt-get update -y && DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ccache libibverbs-dev libnl-3-dev libnl-route-3-dev libnuma-dev ninja-build \
    && rm -rf /var/lib/apt/lists/*

# --- vLLM from source --------------------------------------------------------
ENV CUDA_HOME=/usr/local/cuda
ENV MAX_JOBS=32
ENV NVCC_THREADS=1
ENV TORCH_CUDA_ARCH_LIST="8.0 8.6 8.9 9.0 10.0 10.3"
ENV VLLM_TARGET_DEVICE=cuda

WORKDIR /opt/vllm
RUN git clone https://github.com/vllm-project/vllm.git . \
    && git checkout ${VLLM_COMMIT}

RUN --mount=type=cache,target=/root/.cache/uv \
    --mount=type=cache,target=/root/.cache/ccache \
    uv pip install --system --index-strategy unsafe-best-match \
        -r requirements/build/cuda.txt \
        --extra-index-url https://download.pytorch.org/whl/cu130 \
    && uv pip install --system --index-strategy unsafe-best-match \
        -r requirements/cuda.txt \
        --extra-index-url https://download.pytorch.org/whl/cu130 \
    && python3 setup.py bdist_wheel --dist-dir=dist --py-limited-api=cp38 \
    && uv pip install --system --index-strategy unsafe-best-match \
        dist/*.whl \
        --extra-index-url https://download.pytorch.org/whl/cu130

# --- Ray (DP coordinator) ----------------------------------------------------
RUN --mount=type=cache,target=/root/.cache/uv \
    uv pip install --system "ray[default]>=2.43"

# --- NIXL (cu13) -------------------------------------------------------------
# Install nixl-cu13 first, then nixl meta package, then force-reinstall
# nixl-cu13 to keep cu13 ownership of nixl_ep namespace.
RUN --mount=type=cache,target=/root/.cache/uv \
    uv pip install --system "nixl-cu13==$(echo ${NIXL_VERSION} | sed 's/^v//')" \
    && uv pip install --system "nixl==$(echo ${NIXL_VERSION} | sed 's/^v//')" \
    && uv pip install --system --reinstall --no-deps "nixl-cu13==$(echo ${NIXL_VERSION} | sed 's/^v//')"

# --- UCCL-EP + deep_ep wrapper ----------------------------------------------
RUN git clone https://github.com/uccl-project/uccl.git /opt/uccl \
    && cd /opt/uccl \
    && git checkout ${UCCL_COMMIT} \
    && git submodule update --init --recursive

RUN uv pip install --system nanobind

WORKDIR /opt/uccl
RUN uv pip install --system .

# UCCL-EP uses SM90+ features (TMA, mbarrier); avoid SM80 in this build.
WORKDIR /opt/uccl/ep
ENV PER_EXPERT_BATCHING=1
RUN TORCH_CUDA_ARCH_LIST="9.0a+PTX;10.0a+PTX;10.3a+PTX" python3 setup.py install

WORKDIR /opt/uccl/ep/deep_ep_wrapper
RUN pip install --no-deps .

# --- smoke tests -------------------------------------------------------------
RUN echo "=== Smoke test: vLLM ===" \
    && python3 -c "import vllm; print(f'vLLM {vllm.__version__}')" \
    && echo "=== Smoke test: NIXL ===" \
    && python3 -c "import nixl; print('NIXL OK')" \
    && echo "=== Smoke test: uccl.ep ===" \
    && python3 -c "import torch; import uccl.ep; print('uccl.ep OK')" \
    && echo "=== Smoke test: deep_ep ===" \
    && python3 -c "import torch; from deep_ep import Buffer, Config; print('deep_ep OK')" \
    && echo "=== Smoke test: vLLM has_deep_ep ===" \
    && python3 -c "from vllm.utils.import_utils import has_deep_ep; assert has_deep_ep(); print('vLLM has_deep_ep() = True')" \
    && echo "=== Smoke test: Ray ===" \
    && python3 -c "import ray; print(f'Ray {ray.__version__}')" \
    && echo "=== All smoke tests passed ==="

WORKDIR /workspace
