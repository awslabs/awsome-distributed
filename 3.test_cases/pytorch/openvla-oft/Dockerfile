# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# OpenVLA-OFT fine-tuning image
#
# Base: AWS Deep Learning Container (DLC) PyTorch training image. The DLC
# ships a tested matrix of PyTorch + NCCL + EFA + libfabric + aws-ofi-nccl
# pinned together, so collectives go over EFA on AWS GPU instances without
# the ABI mismatches you can hit when stacking PyPI torch wheels on top of
# a base image with its own NCCL build (e.g. the `nccl-tests` image, which
# yields `undefined symbol: ncclDevCommDestroy` at import time).
#
# DLC tag matrix: pytorch-training:<torch>-gpu-py<py>-cu<cuda>-ubuntu<ubuntu>-ec2.
# We build against PyTorch 2.8 / py3.12 / CUDA 12.9 (tag
# `2.8.0-gpu-py312-cu129-ubuntu22.04-ec2`). The newer 2.9.0 / CUDA 13.0
# DLC also exists, but `flash-attn` (pulled in transitively by the
# moojink/transformers-openvla-oft fork via `transformers`) is shipped as
# a prebuilt wheel linked against CUDA 12 and asks the loader for
# `libcudart.so.12` at import time. On a CUDA 13 base that file is
# missing and `import flash_attn` fails with
# `libcudart.so.12: cannot open shared object file`. Staying on the
# CUDA 12.9 DLC avoids that entirely without us having to install a
# second CUDA runtime side-by-side. Override AWS_REGION at build time
# to keep the pull in-region with your cluster.
#
# `--platform=linux/amd64` is required because openvla-oft's transitive
# deps include `tensorflow-graphics==2021.12.3` -> `tensorflow-addons`
# (archived 2026, no aarch64 wheels). We strip the `tensorflow_graphics`
# dependency below, but the platform pin still matters because some
# transitive wheels remain x86_64-only and AWS GPU instances are all
# x86_64 anyway.
ARG AWS_REGION=us-west-2
FROM --platform=linux/amd64 763104351884.dkr.ecr.${AWS_REGION}.amazonaws.com/pytorch-training:2.8.0-gpu-py312-cu129-ubuntu22.04-ec2 AS base

ARG OPENVLA_OFT_REPO=https://github.com/moojink/openvla-oft.git
# Pin to a specific upstream commit so this image is reproducible. Bumping
# OPENVLA_OFT_COMMIT is intentional: do it deliberately and re-run the
# end-to-end test (LIBERO Download Job + Training Job to first loss line)
# before merging, since upstream openvla-oft changes can rename modules,
# alter pyproject.toml line shapes (which our patches grep against), or
# add new tensorflow_graphics import sites.
ARG OPENVLA_OFT_COMMIT=e4287e94541f459edc4feabc4e181f537cd569a8

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    TOKENIZERS_PARALLELISM=false

# DLC ships git, git-lfs, ca-certificates pre-installed. nvtop is the only
# extra useful debug tool from the previous nccl-tests-based recipe.
RUN apt-get update \
 && apt-get install -y --no-install-recommends nvtop \
 && rm -rf /var/lib/apt/lists/*

# Clone openvla-oft and its dlimp dependency, patch both for
# Python 3.12 + the DLC's PyTorch, then install in the right order.
#
# pyproject.toml patches (openvla-oft):
#
#   1. tensorflow==2.15.0 → tensorflow>=2.16,<2.17. TF 2.15 has no py312
#      wheels (it was the last py3.11-only release). 2.16 is the first
#      py312-capable version. openvla-oft does not use tf.keras or
#      tf.compat.v1 (verified) — only core tf.* and tfds APIs — so the
#      Keras-3 default switch in TF 2.16 has no effect on this codebase.
#   2. tensorflow_datasets==4.9.3 → tensorflow_datasets>=4.9.4. The 4.9.3
#      pin is incompatible with TF 2.16; tfds 4.9.4+ supports both. The
#      project uses only `tfds.builder()`, stable across the bump.
#   3. tensorflow_graphics removed entirely. The 2021.12.3 release is
#      the last published wheel (project archived March 2026) and it has
#      no py312 wheels at all. The package is only used by three
#      OpenXEmbodiment transforms (furniture_bench, iamlab_pick_insert,
#      cmu_playing_with_food) and the DROID dataset utility module —
#      none of which the LIBERO recipe touches.
#   4. torch / torchvision / torchaudio pins dropped. The DLC base ships
#      PyTorch 2.8 already version-pinned with NCCL 2.22+, EFA, libfabric,
#      and aws-ofi-nccl. Letting upstream's torch==2.2.0 pin install would
#      shadow the DLC's binaries and resurrect the ncclDevCommDestroy ABI
#      mismatch we built this image to avoid.
#   5. dlimp git URL replaced with a local-directory install at
#      `file:///opt/dlimp`. We pre-clone moojink/dlimp_openvla, patch its
#      setup.py to relax the same TF pin, and rewrite openvla-oft's
#      `dlimp @ git+...` reference so pip uses our patched copy. Without
#      this, dlimp's own `tensorflow==2.15.0` pin clashes with our
#      relaxed openvla-oft pin and pip aborts with ResolutionImpossible.
#
# setup.py patch (dlimp):
#
#   Same TF pin relaxation. dlimp uses only core tf.* and tfds APIs
#   (verified — no tf.keras, no compat.v1), so 2.16 is a drop-in for the
#   dataset-pipeline code paths LIBERO exercises.
#
# droid_utils.py patches (openvla-oft):
#
#   The eager top-of-file `import tensorflow_graphics ...` line breaks
#   the LIBERO import chain (datasets.py → oxe → configs → droid_utils)
#   when tensorflow_graphics is not installed. We delete the eager
#   import and add a lazy one inside each of the four functions that
#   actually reference `tfg`. LIBERO never calls these functions; if a
#   future user runs DROID, they get a clear ImportError at the call
#   site naming the optional package.
#
# openvla_utils.py patch (openvla-oft):
#
#   `check_model_logic_mismatch()` walks `./prismatic/` (relative path)
#   to find the current `modeling_prismatic.py` and copy it into the
#   downloaded Hub snapshot, so `trust_remote_code=True` loads the
#   local-tree class instead of the older Hub stub. The cwd at finetune
#   time is `/openvla-oft` (the vendored script), but the actual
#   prismatic package lives at `/opt/openvla-oft/prismatic/` (where we
#   `pip install -e`). The relative walk silently finds nothing, the
#   Hub stub stays in place, and you get
#   `'PrismaticVisionBackbone' object has no attribute
#   'set_num_images_in_input'` after model load. We rewrite the relative
#   path to the absolute install location.
#
# All patches are applied with `sed -i`. If a future OPENVLA_OFT_REF or
# upstream dlimp bump changes the line shapes, the build fails at
# `pip install` with a clear pin-reappearing message rather than
# silently regressing.
ARG DLIMP_REPO=https://github.com/moojink/dlimp_openvla.git
# Pin dlimp to a specific upstream commit too — same reproducibility
# rationale as OPENVLA_OFT_COMMIT. The two pins move independently;
# bump them deliberately when you bump openvla-oft.
ARG DLIMP_COMMIT=040105d256bd28866cc6620621a3d5f7b6b91b46
RUN --mount=type=cache,target=/root/.cache/pip \
    set -eux \
 && mkdir -p /opt && cd /opt \
 && git -c advice.detachedHead=false clone --filter=blob:none ${OPENVLA_OFT_REPO} openvla-oft \
 && git -C openvla-oft checkout ${OPENVLA_OFT_COMMIT} \
 && git -c advice.detachedHead=false clone --filter=blob:none ${DLIMP_REPO} dlimp \
 && git -C dlimp checkout ${DLIMP_COMMIT} \
 && sed -i \
       -e 's|"tensorflow==2.15.0",|"tensorflow>=2.16,<2.17",|' \
       dlimp/setup.py \
 && cd openvla-oft \
 && sed -i \
       -e 's|"tensorflow==2.15.0",|"tensorflow>=2.16,<2.17",|' \
       -e 's|"tensorflow_datasets==4.9.3",|"tensorflow_datasets>=4.9.4",|' \
       -e '/"tensorflow_graphics==2021.12.3",/d' \
       -e '/"torch==2.2.0",/d' \
       -e '/"torchvision==0.17.0",/d' \
       -e '/"torchaudio==2.2.0",/d' \
       -e 's|"dlimp @ git+https://github.com/moojink/dlimp_openvla",|"dlimp @ file:///opt/dlimp",|' \
       pyproject.toml \
 && sed -i \
       -e '/^import tensorflow_graphics/d' \
       -e '/^def rmat_to_euler(/a\    import tensorflow_graphics.geometry.transformation as tfg  # lazy: DROID-only' \
       -e '/^def euler_to_rmat(/a\    import tensorflow_graphics.geometry.transformation as tfg  # lazy: DROID-only' \
       -e '/^def invert_rmat(/a\    import tensorflow_graphics.geometry.transformation as tfg  # lazy: DROID-only' \
       -e '/^def velocity_act_to_wrist_frame(/a\    import tensorflow_graphics.geometry.transformation as tfg  # lazy: DROID-only' \
       prismatic/vla/datasets/rlds/oxe/utils/droid_utils.py \
 && grep -n 'tfg' prismatic/vla/datasets/rlds/oxe/utils/droid_utils.py \
 && sed -i \
       -e 's|os.walk("./prismatic/")|os.walk("/opt/openvla-oft/prismatic/")|' \
       experiments/robot/openvla_utils.py \
 && grep -n 'os.walk' experiments/robot/openvla_utils.py \
 && pip install --no-cache-dir -e /opt/openvla-oft

# Copy our vendored training script.
RUN mkdir -p /openvla-oft /checkpoints
COPY src/ /openvla-oft/

# Sanity check — fail the build if torch can't import, NCCL is missing,
# the flash-attn CUDA runtime is mismatched (libcudart.so.X), or the
# LIBERO import chain regresses (e.g. tensorflow_graphics sneaks back in
# via a future ref bump).
RUN python -c "import torch; print('torch', torch.__version__, 'cuda', torch.version.cuda); \
print('nccl', torch.cuda.nccl.version()); \
from torch.distributed.run import main; \
import flash_attn; print('flash_attn', flash_attn.__version__); \
import tensorflow as tf; print('tf', tf.__version__); \
import tensorflow_datasets as tfds; print('tfds', tfds.__version__); \
from prismatic.vla.datasets import RLDSDataset; \
print('LIBERO import chain OK')"

WORKDIR /openvla-oft

# HyperPod-specific image with elastic agent (optional, mirrors FSDP/Dockerfile).
FROM base AS hpto
RUN pip install --no-cache-dir hyperpod-elastic-agent
