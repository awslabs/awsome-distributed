#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# Launch the H1 Locomotion Interactive Demo (uses pre-trained rsl_rl checkpoint)
# This is the workshop Module 3 demo - click robots, control with arrow keys
echo "Starting H1 Locomotion Interactive Demo..."
echo "Controls: UP=forward, DOWN=stop, LEFT=turn left, RIGHT=turn right, C=camera toggle"
cd ~/environment/IsaacLab
xhost +
docker kill isaac-lab 2>/dev/null
docker run --shm-size=60g --name isaac-lab --entrypoint bash -it --gpus all \
  -e "ACCEPT_EULA=Y" --rm --network=host \
  -v /home/ubuntu/environment/shared-efs:/workspace/IsaacLab/TrainedModel \
  -e DISPLAY \
  -e "PRIVACY_CONSENT=Y" \
  ${ISAAC_IMAGE:-isaaclab-sagemaker:5.1.0} \
  -c "cd /workspace/IsaacLab && /isaac-sim/python.sh scripts/demos/h1_locomotion.py"
