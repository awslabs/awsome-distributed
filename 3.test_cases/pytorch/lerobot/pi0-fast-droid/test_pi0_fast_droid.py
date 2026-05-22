# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

import pytest


class TestPi0FastDroid:
    """Tests for the LeRobot pi0-fast-droid test case."""

    def test_docker_build(self, docker_build):
        """Verify the Docker image builds successfully."""
        image = docker_build(".", dockerfile="Dockerfile", tag="lerobot-pi0-fast-droid.test")
        assert image is not None

    def test_docker_run_smoke(self, docker_build, docker_run):
        """Verify the container starts and key imports work."""
        image = docker_build(".", dockerfile="Dockerfile", tag="lerobot-pi0-fast-droid.test")
        result = docker_run(
            image,
            command="python -c 'import torch; import lerobot; print(f\"torch={torch.__version__}, lerobot={lerobot.__version__}\")'",
        )
        assert result.exit_code == 0

    def test_lerobot_train_entrypoint(self, docker_build, docker_run):
        """Verify the lerobot-train CLI entrypoint is available."""
        image = docker_build(".", dockerfile="Dockerfile", tag="lerobot-pi0-fast-droid.test")
        result = docker_run(image, command="which lerobot-train")
        assert result.exit_code == 0

    def test_efa_installed(self, docker_build, docker_run):
        """Verify EFA libraries are installed."""
        image = docker_build(".", dockerfile="Dockerfile", tag="lerobot-pi0-fast-droid.test")
        result = docker_run(image, command="fi_info -p efa")
        assert result.exit_code == 0
