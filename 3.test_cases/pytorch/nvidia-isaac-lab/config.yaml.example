# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# ============================================================================
# PyTorchJob: Isaac Lab training (${JOB_INSTANCE_TYPE})
# Generated from config.yaml -- do not edit directly
# ============================================================================
apiVersion: kubeflow.org/v1
kind: PyTorchJob
metadata:
  name: isaaclab-h1
  namespace: default
spec:
  pytorchReplicaSpecs:
    Master:
      replicas: 1
      restartPolicy: OnFailure
      template:
        spec:
          containers:
          - name: pytorch
            image: ${IMAGE}
            command: ["/bin/bash", "-c"]
            args:
            - |
              echo "=== Master Node Info ==="
              echo "Hostname: $$(hostname)"
              echo "MASTER_ADDR: $$MASTER_ADDR"
              echo "MASTER_PORT: $$MASTER_PORT"
              echo "WORLD_SIZE: $$WORLD_SIZE"
              echo "RANK: $$RANK"
              echo "Date: $$(date)"
              nvidia-smi -L

              cd /workspace/IsaacLab
              mkdir -p ${JOB_FSX_LOG_DIR}
              rm -rf /workspace/IsaacLab/logs
              ln -sf ${JOB_FSX_LOG_DIR} /workspace/IsaacLab/logs

              # Auto-resume: find the latest checkpoint on FSx from a previous run
              LATEST_CKPT=$$(find ${JOB_FSX_LOG_DIR} -name "best_agent.pt" -printf "%T@ %p\n" 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2)
              if [ -n "$$LATEST_CKPT" ]; then
                echo "=== RESUMING from checkpoint: $$LATEST_CKPT ==="
                RESUME_FLAG="--checkpoint $$LATEST_CKPT"
              else
                echo "=== Starting fresh (no checkpoint found) ==="
                RESUME_FLAG=""
              fi

              echo "=== Starting Master (${JOB_NUM_NODES}-node, $$((${JOB_GPUS} * ${JOB_NUM_NODES})) GPUs total, ${MAX_ITERATIONS} iterations) ==="
              /isaac-sim/python.sh -m torch.distributed.run \
                --nproc_per_node=${JOB_GPUS} \
                --nnodes=${JOB_NUM_NODES} \
                --node_rank=$$RANK \
                --rdzv_id=isaaclab-job \
                --rdzv_backend=c10d \
                --rdzv_endpoint=$$MASTER_ADDR:$$MASTER_PORT \
                run_train.py \
                --distributed \
                --task=${TASK} \
                --max_iterations=${MAX_ITERATIONS} \
                --headless \
                $$RESUME_FLAG

              echo "=== Training Complete at $$(date) ==="
              find ${JOB_FSX_LOG_DIR} -name "*.pt" -ls 2>/dev/null
            env:
            - name: ACCEPT_EULA
              value: "Y"
            - name: PRIVACY_CONSENT
              value: "Y"
            - name: NVIDIA_VISIBLE_DEVICES
              value: "all"
            - name: NVIDIA_DRIVER_CAPABILITIES
              value: "all"
            - name: ISAACLAB_INIT_LOCK
              value: "/tmp/isaaclab_init.lock"
            - name: ISAACLAB_TRAIN_SCRIPT
              value: "/workspace/IsaacLab/scripts/reinforcement_learning/${FRAMEWORK}/train.py"
            - name: MLFLOW_ARTIFACT_DIR
              value: "${JOB_FSX_LOG_DIR}/${FRAMEWORK}"
            - name: MLFLOW_TRACKING_URI
              value: "${MLFLOW_TRACKING_URI}"
            - name: MLFLOW_EXPERIMENT_NAME
              value: "${MLFLOW_EXPERIMENT_NAME}"
            - name: SAGEMAKER_MLFLOW_ASSUME_ROLE_ARN
              value: "${SAGEMAKER_MLFLOW_ASSUME_ROLE_ARN}"
            - name: MLFLOW_ENABLE_SYSTEM_METRICS_LOGGING
              value: "true"
            - name: MLFLOW_SYSTEM_METRICS_SAMPLING_INTERVAL
              value: "10"
            resources:
              limits:
                nvidia.com/gpu: ${JOB_GPUS}
                vpc.amazonaws.com/efa: ${JOB_EFA_PER_NODE}
                memory: "${JOB_MEM_LIMIT}"
                cpu: "${JOB_CPU_LIMIT}"
              requests:
                nvidia.com/gpu: ${JOB_GPUS}
                vpc.amazonaws.com/efa: ${JOB_EFA_PER_NODE}
                memory: "${JOB_MEM_REQUEST}"
                cpu: "${JOB_CPU_REQUEST}"
            securityContext:
              capabilities:
                add: ["IPC_LOCK"]
            volumeMounts:
            - name: fsx
              mountPath: /fsx
            - name: dshm
              mountPath: /dev/shm
          volumes:
          - name: fsx
            persistentVolumeClaim:
              claimName: ${FSX_PVC_NAME}
          - name: dshm
            emptyDir:
              medium: Memory
              sizeLimit: "${JOB_SHM}"
          nodeSelector:
            ${NODE_HEALTH_LABEL}: ${NODE_HEALTH_VALUE}
            node.kubernetes.io/instance-type: ${JOB_INSTANCE_TYPE}
    Worker:
      replicas: ${WORKER_REPLICAS}
      restartPolicy: OnFailure
      template:
        spec:
          containers:
          - name: pytorch
            image: ${IMAGE}
            command: ["/bin/bash", "-c"]
            args:
            - |
              echo "=== Worker Node Info ==="
              echo "Hostname: $$(hostname)"
              echo "MASTER_ADDR: $$MASTER_ADDR"
              echo "MASTER_PORT: $$MASTER_PORT"
              echo "WORLD_SIZE: $$WORLD_SIZE"
              echo "RANK: $$RANK"
              nvidia-smi -L

              cd /workspace/IsaacLab

              # Auto-resume: find the latest checkpoint on FSx from a previous run
              LATEST_CKPT=$$(find ${JOB_FSX_LOG_DIR} -name "best_agent.pt" -printf "%T@ %p\n" 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2)
              if [ -n "$$LATEST_CKPT" ]; then
                echo "=== RESUMING from checkpoint: $$LATEST_CKPT ==="
                RESUME_FLAG="--checkpoint $$LATEST_CKPT"
              else
                echo "=== Starting fresh (no checkpoint found) ==="
                RESUME_FLAG=""
              fi

              echo "=== Starting Worker ==="
              /isaac-sim/python.sh -m torch.distributed.run \
                --nproc_per_node=${JOB_GPUS} \
                --nnodes=${JOB_NUM_NODES} \
                --node_rank=$$RANK \
                --rdzv_id=isaaclab-job \
                --rdzv_backend=c10d \
                --rdzv_endpoint=$$MASTER_ADDR:$$MASTER_PORT \
                run_train.py \
                --distributed \
                --task=${TASK} \
                --max_iterations=${MAX_ITERATIONS} \
                --headless \
                $$RESUME_FLAG

              echo "=== Worker Complete at $$(date) ==="
            env:
            - name: ACCEPT_EULA
              value: "Y"
            - name: PRIVACY_CONSENT
              value: "Y"
            - name: NVIDIA_VISIBLE_DEVICES
              value: "all"
            - name: NVIDIA_DRIVER_CAPABILITIES
              value: "all"
            - name: ISAACLAB_INIT_LOCK
              value: "/tmp/isaaclab_init.lock"
            - name: ISAACLAB_TRAIN_SCRIPT
              value: "/workspace/IsaacLab/scripts/reinforcement_learning/${FRAMEWORK}/train.py"
            - name: MLFLOW_ARTIFACT_DIR
              value: "${JOB_FSX_LOG_DIR}/${FRAMEWORK}"
            - name: MLFLOW_TRACKING_URI
              value: "${MLFLOW_TRACKING_URI}"
            - name: MLFLOW_EXPERIMENT_NAME
              value: "${MLFLOW_EXPERIMENT_NAME}"
            - name: SAGEMAKER_MLFLOW_ASSUME_ROLE_ARN
              value: "${SAGEMAKER_MLFLOW_ASSUME_ROLE_ARN}"
            - name: MLFLOW_ENABLE_SYSTEM_METRICS_LOGGING
              value: "true"
            - name: MLFLOW_SYSTEM_METRICS_SAMPLING_INTERVAL
              value: "10"
            resources:
              limits:
                nvidia.com/gpu: ${JOB_GPUS}
                vpc.amazonaws.com/efa: ${JOB_EFA_PER_NODE}
                memory: "${JOB_MEM_LIMIT}"
                cpu: "${JOB_CPU_LIMIT}"
              requests:
                nvidia.com/gpu: ${JOB_GPUS}
                vpc.amazonaws.com/efa: ${JOB_EFA_PER_NODE}
                memory: "${JOB_MEM_REQUEST}"
                cpu: "${JOB_CPU_REQUEST}"
            securityContext:
              capabilities:
                add: ["IPC_LOCK"]
            volumeMounts:
            - name: fsx
              mountPath: /fsx
            - name: dshm
              mountPath: /dev/shm
          volumes:
          - name: fsx
            persistentVolumeClaim:
              claimName: ${FSX_PVC_NAME}
          - name: dshm
            emptyDir:
              medium: Memory
              sizeLimit: "${JOB_SHM}"
          nodeSelector:
            ${NODE_HEALTH_LABEL}: ${NODE_HEALTH_VALUE}
            node.kubernetes.io/instance-type: ${JOB_INSTANCE_TYPE}
