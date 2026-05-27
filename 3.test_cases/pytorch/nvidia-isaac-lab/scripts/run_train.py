# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
"""Wrapper that installs the MLflow hook before running Isaac Lab's train.py.

train.py is executed via runpy with run_name="__main__" so its
`if __name__ == "__main__":` guard fires and sys.argv is forwarded
unchanged (--task, --num_envs, --distributed, etc.).
"""

import os
import runpy
import sys

import mlflow_isaaclab

DEFAULT_TRAIN_SCRIPT = "/workspace/IsaacLab/scripts/reinforcement_learning/skrl/train.py"

if __name__ == "__main__":
    train_script = os.environ.get("ISAACLAB_TRAIN_SCRIPT", DEFAULT_TRAIN_SCRIPT)
    print(f"[run_train] starting train.py: {train_script}", flush=True)
    mlflow_isaaclab.install()
    try:
        runpy.run_path(train_script, run_name="__main__")
        print("[run_train] train.py returned cleanly", flush=True)
    finally:
        print("[run_train] finally: calling finalize()", flush=True)
        mlflow_isaaclab.finalize()
        print("[run_train] finalize() done", flush=True)
