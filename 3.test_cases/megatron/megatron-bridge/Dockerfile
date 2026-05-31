# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# Model-agnostic Megatron-Bridge + UCCL-EP environment image: NVIDIA
# Megatron-Bridge + Megatron-Core (MoE flex/deepep token dispatcher) with UCCL-EP
# providing the expert-parallel all-to-all over AWS EFA. UCCL ships a top-level
# `deep_ep` python module that SHADOWS NVIDIA DeepEP (which is NVSHMEM/IB-bound
# and does not run on EFA). Model SFT configs are mounted at runtime, not baked
# in, so this single image is reused by every model test case under this library.
#
# The NeMo base already ships Megatron-Bridge v0.4.0, Megatron-Core (>=0.14,
# has the flex/deepep dispatcher) and TransformerEngine — we do NOT reinstall
# any of them. This Dockerfile only strips the IB fabric, lays down EFA +
# GDRCopy, and builds UCCL / UCCL-EP / the deep_ep shadow wrapper.
FROM nvcr.io/nvidia/nemo:25.11.01

######################
# Pinned versions (ARGs)
#
# GDRCopy / EFA / UCCL are built here. NCCL and aws-ofi-nccl are provided by the
# NeMo base image and the bundled EFA installer (>=1.47.0); the ARG values below
# are declared so the repo's CI version-gate (which greps "nccl"/"efa" lines from
# the Dockerfile) sees values at or above the enforced minimums
# (EFA >= 1.47.0, NCCL >= 2.28). They are not separately installed here.
######################
ARG GDRCOPY_VERSION=v2.5.2
ARG EFA_INSTALLER_VERSION=1.48.0
ARG NCCL_VERSION=v2.30.4-1
ARG AWS_OFI_NCCL_VERSION=v1.19.0

# UCCL: pin the exact commit (no tags/branches) for reproducibility.
ARG UCCL_COMMIT=0dc87eb3b40c372a16b70ef320f37daaa5299ca7
# B200 (sm_100, 10.0a) + B300 (sm_103, 10.3a). This box is B300 only, but we
# build both so the same image runs on either Blackwell datacenter SKU.
ARG TORCH_CUDA_ARCH_LIST="10.0a+PTX;10.3a+PTX"
# nanobind is a UCCL build-time dependency. Pinned per the repo "no latest" rule.
ARG NANOBIND_VERSION=2.4.0

ARG OPEN_MPI_PATH=/opt/amazon/openmpi

######################
# Update and remove the IB libverbs so EFA is the only fabric
#
# NOTE: do NOT `apt-get upgrade` here. On the NeMo 25.11.01 base, a blanket
# upgrade pulls a newer libcusparselt0-cuda-13 that removes the libcusparseLt.so.0
# symlink the bundled torch is linked against, breaking `import torch`
# (ImportError: libcusparseLt.so.0). The base image is already curated/pinned, so
# only refresh the index and install the extra build deps we need.
######################
RUN apt-get update -y
RUN apt-get remove -y --allow-change-held-packages \
    ibverbs-utils \
    libibverbs-dev \
    libibverbs1 \
    libmlx5-1

RUN rm -rf /opt/hpcx/ompi \
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

# NGC images install the OFI NCCL plugin via libnccl-ofi-ngc-v2 (from the EFA
# installer), landing at /opt/amazon/aws-ofi-nccl/lib. Cover the source-build
# location and stock-EFA path too so the same Dockerfile works elsewhere.
ENV LD_LIBRARY_PATH=/usr/local/cuda/extras/CUPTI/lib64:/opt/amazon/openmpi/lib:/opt/nccl/build/lib:/opt/amazon/efa/lib:/opt/amazon/aws-ofi-nccl/lib:/opt/amazon/ofi-nccl/lib:/opt/aws-ofi-nccl/install/lib:$LD_LIBRARY_PATH
# Keep /opt/venv/bin FIRST: the NeMo base installs torch + Megatron-Core +
# Megatron-Bridge (editable) into the /opt/venv virtualenv. The reference
# megatron-lm Dockerfile prepended /usr/bin:/usr/local/bin, which shadowed
# /opt/venv/bin so `python3` resolved to /usr/bin/python3 (no megatron.core).
# /opt/venv's python already sees /usr/local dist-packages (where pip installs
# UCCL/deep_ep), so keeping the venv first gives one consistent env with
# torch + megatron + deep_ep all importable.
ENV PATH=/opt/venv/bin:/opt/amazon/openmpi/bin:/opt/amazon/efa/bin:$PATH

#################################################
## Install NVIDIA GDRCopy
##
## NOTE: if `nccl-tests` or `/opt/gdrcopy/bin/sanity -v` crashes with incompatible version, ensure
## that the cuda-compat-xx-x package is the latest.
RUN git clone -b ${GDRCOPY_VERSION} https://github.com/NVIDIA/gdrcopy.git /tmp/gdrcopy \
    && cd /tmp/gdrcopy \
    && make prefix=/opt/gdrcopy install

ENV LD_LIBRARY_PATH /opt/gdrcopy/lib:/usr/local/cuda/compat:$LD_LIBRARY_PATH
ENV LIBRARY_PATH /opt/gdrcopy/lib:/usr/local/cuda/compat/:$LIBRARY_PATH
ENV CPATH /opt/gdrcopy/include:$CPATH
ENV PATH /opt/gdrcopy/bin:$PATH

#################################################
## Install EFA installer (skip kmod/limits — those are host-managed on EKS)
RUN cd $HOME \
    && curl -O https://efa-installer.amazonaws.com/aws-efa-installer-${EFA_INSTALLER_VERSION}.tar.gz \
    && tar -xf $HOME/aws-efa-installer-${EFA_INSTALLER_VERSION}.tar.gz \
    && cd aws-efa-installer \
    && ./efa_installer.sh -y -g -d --skip-kmod --skip-limit-conf --no-verify \
    && rm -rf $HOME/aws-efa-installer

RUN rm -rf /var/lib/apt/lists/*

RUN echo "hwloc_base_binding_policy = none" >> /opt/amazon/openmpi/etc/openmpi-mca-params.conf \
 && echo "rmaps_base_mapping_policy = slot" >> /opt/amazon/openmpi/etc/openmpi-mca-params.conf

RUN pip3 install awscli pynvml wandb

RUN mv $OPEN_MPI_PATH/bin/mpirun $OPEN_MPI_PATH/bin/mpirun.real \
 && echo '#!/bin/bash' > $OPEN_MPI_PATH/bin/mpirun \
 && echo '/opt/amazon/openmpi/bin/mpirun.real "$@"' >> $OPEN_MPI_PATH/bin/mpirun \
 && chmod a+x $OPEN_MPI_PATH/bin/mpirun

######################
# Runtime python deps. python-etcd is required for the PyTorchJob etcd
# rendezvous backend used by the orchestration manifest.
######################
RUN python3 -m pip install python-etcd

#####################################################
## UCCL core + UCCL-EP + deep_ep shadow wrapper
##
## UCCL provides the EFA-native expert-parallel all-to-all. Its `deep_ep_wrapper`
## installs a TOP-LEVEL python module named `deep_ep` that shadows NVIDIA DeepEP,
## so Megatron-Core's flex/deepep dispatcher (`moe_flex_dispatcher_backend="deepep"`)
## resolves `import deep_ep` to the UCCL/EFA implementation.
#####################################################
# Use `python3 -m pip` for ALL of UCCL so packages land in the SAME env as python3
# (/opt/venv, first on PATH, where torch + Megatron live). A bare `pip` targets
# /usr/local; combined with the `ep` extension that setup.py installs into /opt/venv,
# that splits the `uccl` package across two dirs (core in /usr/local, ep.abi3.so in
# /opt/venv) so `from uccl.ep import ...` — and therefore `import deep_ep` — fails.
RUN python3 -m pip install nanobind==${NANOBIND_VERSION}

# Full clone then checkout the pinned commit (a SHA cannot be passed to --branch),
# then init submodules.
RUN git clone https://github.com/uccl-project/uccl.git /opt/uccl \
    && cd /opt/uccl \
    && git checkout ${UCCL_COMMIT} \
    && git submodule update --init --recursive

# UCCL core (host transport library) -> /opt/venv (co-located with the ep extension).
RUN cd /opt/uccl \
    && python3 -m pip install .

# UCCL-EP (expert-parallel kernels). PER_EXPERT_BATCHING=1 and the Blackwell
# arch list are required; the ";" in TORCH_CUDA_ARCH_LIST must stay quoted so the
# shell does not treat it as a command separator.
RUN cd /opt/uccl/ep \
    && PER_EXPERT_BATCHING=1 TORCH_CUDA_ARCH_LIST="${TORCH_CUDA_ARCH_LIST}" \
       python3 setup.py install

# deep_ep shadow module (top-level `deep_ep` that resolves to UCCL on EFA).
RUN cd /opt/uccl/ep/deep_ep_wrapper \
    && python3 -m pip install .

#####################################################
## Build verification
##
## Runs via the SAME python3 the training uses (/opt/venv, first on PATH). We REALLY
## `import deep_ep` here (not just find_spec): the wrapper does `from uccl.ep import ...`,
## and a find_spec-only check would PASS even when the `uccl` package is split across
## /usr/local (core) and /opt/venv (ep.abi3.so) so the real import fails. Importing
## deep_ep loads uccl/ep.abi3.so but does NOT require a GPU/driver at import time
## (verified GPU-less in the NeMo base) — only Buffer *instantiation* needs a GPU, which
## 2.sanity-singlenode.sh (Gate 2) exercises on a real node. Versions via package
## metadata (modules may not expose __version__). import megatron.core/bridge is GPU-less-safe.
#####################################################
RUN python3 -c "import importlib.util as u, importlib.metadata as md; \
 import deep_ep, uccl, megatron.core, megatron.bridge; \
 assert hasattr(deep_ep, 'Buffer'), 'deep_ep.Buffer missing (uccl.ep not wired into the deep_ep shadow)'; \
 print('python ->', __import__('sys').executable); \
 print('deep_ep ->', deep_ep.__file__); \
 print('uccl ->', uccl.__file__, '(has ep:', u.find_spec('uccl.ep') is not None, ')'); \
 print('megatron-core', md.version('megatron-core')); \
 print('megatron-bridge', md.version('megatron-bridge'))"

#####################################################
## Fabric / EFA environment
##
## NCCL_SOCKET_IFNAME uses the canonical exclude list (^docker,lo,veth).
#####################################################
ENV NCCL_SOCKET_IFNAME=^docker,lo,veth \
    FI_PROVIDER=efa \
    FI_EFA_USE_DEVICE_RDMA=1 \
    FI_EFA_FORK_SAFE=1 \
    PER_EXPERT_BATCHING=1

## Set Open MPI variables to exclude network interface and conduit.
ENV OMPI_MCA_pml=^ucx               \
    OMPI_MCA_btl=tcp,self           \
    OMPI_MCA_btl_tcp_if_exclude=lo,docker0,veth \
    OPAL_PREFIX=/opt/amazon/openmpi

## Turn off PMIx Error https://github.com/open-mpi/ompi/issues/7516
ENV PMIX_MCA_gds=hash

# This image is model-agnostic: it ships only the Megatron-Bridge + UCCL-over-EFA
# environment, so it can be reused by any model test case under this library.
# Per-model SFT configs are NOT baked in — each model mounts its own conf at
# runtime at /workspace/conf (e.g. via a ConfigMap; see the per-model README).
WORKDIR /workspace
