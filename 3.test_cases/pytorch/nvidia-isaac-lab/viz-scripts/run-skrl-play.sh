#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# Play back the skrl-trained checkpoint from HyperPod training
# Usage: ./run-skrl-play.sh [checkpoint_path]
# Default: uses the best_agent.pt from the latest training run
CHECKPOINT="${1:-$(find /home/ubuntu/environment/shared-efs/isaaclab-logs -name best_agent.pt 2>/dev/null | head -1)}"
if [ -z "$CHECKPOINT" ]; then
  echo "No checkpoint found. Training may not have synced yet."
  echo "Available .pt files:"
  find /home/ubuntu/environment/shared-efs -name "*.pt" -ls
  exit 1
fi
# Remap to container path
CONTAINER_PATH="${CHECKPOINT/\/home\/ubuntu\/environment\/shared-efs/\/workspace\/IsaacLab\/TrainedModel}"
echo "Starting skrl playback with checkpoint: $CONTAINER_PATH"
cd ~/environment/IsaacLab
xhost +
docker kill isaac-lab 2>/dev/null
docker run --shm-size=60g --name isaac-lab --entrypoint bash -it --gpus all \
  -e "ACCEPT_EULA=Y" --rm --network=host \
  -v /home/ubuntu/environment/shared-efs:/workspace/IsaacLab/TrainedModel \
  -e DISPLAY \
  -e "PRIVACY_CONSENT=Y" \
  ${ISAAC_IMAGE:-isaaclab-sagemaker:5.1.0} \
  -c "cd /workspace/IsaacLab && /isaac-sim/python.sh scripts/reinforcement_learning/skrl/play.py --task=Isaac-Velocity-Rough-H1-v0 --checkpoint $CONTAINER_PATH --num_envs 25"
