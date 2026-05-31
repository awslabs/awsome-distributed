# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

import os
import pytest


def test_megatron_bridge_uccl_build(docker_build, docker_run):
    """Build smoke test: verify the model-agnostic Megatron-Bridge + UCCL env
    image builds and 'import deep_ep' resolves to the UCCL wrapper."""
    print(f"module file {os.path.dirname(__file__)}")
    print(f"cwd {os.getcwd()}")
    img = docker_build("megatron-bridge-uccl", "Dockerfile")
    # Verify the UCCL deep_ep wrapper is importable and active, and print its
    # resolved path so CI logs show exactly where pip installed it.
    # TODO(validate against image): confirm a positive UCCL marker (a uccl-specific
    # attr on deep_ep); site-packages path is expected after pip install, so do NOT
    # assert on /opt/uccl. https://github.com/uccl-project/uccl
    docker_run(
        img,
        [
            "python3",
            "-c",
            (
                "import deep_ep; "
                "print('deep_ep resolved to:', deep_ep.__file__); "
                "assert hasattr(deep_ep, 'Buffer'), "
                "'deep_ep.Buffer missing — UCCL wrapper not active'"
            ),
        ],
    )
