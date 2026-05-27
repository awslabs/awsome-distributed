# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

FROM nvcr.io/nvidia/isaac-sim:5.1.0
USER root

RUN apt-get update -y && \
    apt-get install -y cmake build-essential git ncurses-term curl ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# Install AWS EFA userspace stack (libfabric + AWS-OFI-NCCL plugin) so NCCL
# can use EFA/RDMA when running on EFA-capable instances (g6.12xlarge+, p4d,
# p5). --skip-kmod relies on the kernel module being present on the host
# (provided by SageMaker AMI / HyperPod nodes). On instances without EFA,
# NCCL falls back to TCP automatically — these libraries are inert.
ENV EFA_INSTALLER_VERSION=1.47.0
RUN apt-get update && \
    cd /tmp && \
    curl -sL https://efa-installer.amazonaws.com/aws-efa-installer-${EFA_INSTALLER_VERSION}.tar.gz | tar xz && \
    cd aws-efa-installer && \
    ./efa_installer.sh -y -g -d --skip-kmod --skip-limit-conf --no-verify && \
    cd / && rm -rf /tmp/aws-efa-installer && rm -rf /var/lib/apt/lists/*

# AWS-OFI-NCCL plugin discovery: NCCL looks for libnccl-net-aws-ofi.so but the
# installer ships libnccl-net-ofi.so. Without this symlink NCCL silently falls
# back to TCP sockets even when EFA is otherwise available.
RUN ln -sf /opt/amazon/ofi-nccl/lib/libnccl-net-ofi.so \
           /opt/amazon/ofi-nccl/lib/libnccl-net-aws-ofi.so && \
    echo "/opt/amazon/ofi-nccl/lib" > /etc/ld.so.conf.d/aws-ofi-nccl.conf && \
    echo "/opt/amazon/efa/lib"      > /etc/ld.so.conf.d/efa.conf && \
    ldconfig

# AWS-OFI-NCCL also needs libcudart.so for GPU memory pinning, but the Isaac
# Sim base image ships CUDA only inside its own pip prebundle. Expose it
# system-wide so the plugin's dlopen("libcudart.so") succeeds; without this
# the plugin loads but its CUDA init fails and NCCL silently falls back to
# Socket. The path comes from the pinned nvidia-cuda-runtime wheel that
# ships with Isaac Sim 5.1.0 — bump if upgrading the base image.
ENV ISAAC_CUDA_RUNTIME=/isaac-sim/exts/omni.isaac.ml_archive/pip_prebundle/nvidia/cuda_runtime/lib
RUN ln -sf ${ISAAC_CUDA_RUNTIME}/libcudart.so.12 /usr/local/lib/libcudart.so && \
    echo "${ISAAC_CUDA_RUNTIME}" > /etc/ld.so.conf.d/isaac-cuda-runtime.conf && \
    ldconfig

ENV LD_LIBRARY_PATH="/opt/amazon/ofi-nccl/lib:/opt/amazon/efa/lib:${LD_LIBRARY_PATH}"
ENV PATH="/opt/amazon/efa/bin:${PATH}"

# Clone Isaac Lab v2.3.2
RUN git clone --depth 1 --branch v2.3.2 \
    https://github.com/isaac-sim/IsaacLab.git /workspace/IsaacLab

WORKDIR /workspace/IsaacLab

# Fix: flatdict==4.0.1 (source-only) fails to build with setuptools>=82 (pkg_resources removed).
# Bump to 4.1.0 which ships a wheel. See: https://github.com/isaac-sim/IsaacLab/issues/5388
RUN sed -i 's/"flatdict==4.0.1"/"flatdict==4.1.0"/' source/isaaclab/setup.py

# Pin the loose/unpinned entries in isaaclab/setup.py to specific versions
# for reproducible builds.
RUN sed -i \
    -e 's/"numpy<2"/"numpy==1.26.0"/' \
    -e 's/"torch>=2.7"/"torch==2.7.0"/' \
    -e 's/"onnx>=1.18.0"/"onnx==1.21.0"/' \
    -e 's/"toml"/"toml==0.10.2"/' \
    -e 's/"trimesh"/"trimesh==4.5.1"/' \
    -e 's/"pyglet<2"/"pyglet==1.5.31"/' \
    -e 's/"einops"/"einops==0.8.2"/' \
    -e 's/"warp-lang"/"warp-lang==1.12.1"/' \
    -e 's/"pytest"/"pytest==9.0.3"/' \
    -e 's/"pytest-mock"/"pytest-mock==3.15.1"/' \
    -e 's/"junitparser"/"junitparser==5.0.0"/' \
    -e 's/"flaky"/"flaky==3.8.1"/' \
    -e 's/"packaging"/"packaging==23.0"/' \
    source/isaaclab/setup.py

# Install Isaac Lab into the Isaac Sim Python environment
RUN ln -s /isaac-sim _isaac_sim && \
    ./isaaclab.sh -i

# Pin skrl to 1.x (Isaac Lab v2.3.2 scripts were written against skrl 1.4.x;
# the newer 2.x API is incompatible).
RUN /isaac-sim/python.sh -m pip install "skrl[torch]==1.4.3"

# MLflow client (mlflow-skinny) plus the SageMaker MLflow plugin that resolves
# MLflow tracking ARNs (arn:aws:sagemaker:...:mlflow-app/... or .../mlflow-tracking-server/...)
# to a signed HTTPS endpoint. pynvml powers MLflow's GPU system-metrics sampler.
RUN /isaac-sim/python.sh -m pip install \
    "mlflow-skinny==3.4.0" \
    "sagemaker-mlflow==0.3.0" \
    "pynvml==11.5.3"

# MLflow integration: a hook module + thin entrypoint shim. The hook
# monkey-patches SummaryWriter.add_scalar (mirrors TensorBoard scalars) and
# argparse.ArgumentParser.parse_args (captures CLI args as run params) at
# runtime - no line-coupling to upstream train.py. Activated when
# MLFLOW_TRACKING_URI is set.
COPY scripts/mlflow_isaaclab.py /workspace/IsaacLab/mlflow_isaaclab.py
COPY scripts/run_train.py       /workspace/IsaacLab/run_train.py

# Verify isaaclab installed correctly
RUN /isaac-sim/python.sh -c "import isaaclab; print(f'isaaclab installed: {isaaclab.__file__}')"

# Copy custom AWS entrypoints and scripts
COPY scripts/sm-train-entrypoint.sh /workspace/IsaacLab/sm-train-entrypoint.sh
RUN chmod +x /workspace/IsaacLab/sm-train-entrypoint.sh

ENTRYPOINT [""]
CMD ["/bin/bash"]
