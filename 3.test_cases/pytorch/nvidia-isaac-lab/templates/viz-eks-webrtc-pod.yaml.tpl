# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

apiVersion: v1
kind: Pod
metadata:
  name: isaacsim-webrtc
  namespace: default
  labels:
    app: isaacsim-webrtc
spec:
  nodeSelector:
    node.kubernetes.io/instance-type: ${VIZ_GPU_INSTANCE_TYPE}
  containers:
  - name: isaacsim
    image: ${IMAGE}
    workingDir: /workspace/IsaacLab
    command: ["/bin/bash", "-c"]
    args:
    - |
      # Note: best_agent.pt is the default checkpoint name for the skrl framework.
      # For other frameworks (rsl_rl, rl_games, sb3), adjust the filename pattern.
      CKPT=$$(find ${VIZ_FSX_LOG_DIR} -name best_agent.pt -printf "%T@ %p\n" | sort -n | tail -1 | cut -d' ' -f2)
      echo "Using checkpoint: $$CKPT"
      exec /isaac-sim/python.sh scripts/reinforcement_learning/skrl/play.py \
        --task=${TASK} \
        --checkpoint $$CKPT \
        --num_envs ${VIZ_NUM_ENVS} \
        --livestream 2
    env:
    - name: ACCEPT_EULA
      value: "Y"
    - name: PRIVACY_CONSENT
      value: "Y"
    ports:
    - containerPort: 49100
      protocol: TCP
      name: signaling
    - containerPort: 47998
      protocol: UDP
      name: media
    resources:
      requests:
        memory: "16Gi"
        cpu: "8"
        nvidia.com/gpu: "1"
      limits:
        memory: "32Gi"
        cpu: "16"
        nvidia.com/gpu: "1"
    volumeMounts:
    - name: shm
      mountPath: /dev/shm
    - name: isaac-cache
      mountPath: /isaac-sim/.cache
    - name: isaac-logs
      mountPath: /isaac-sim/.nvidia-omniverse/logs
    - name: fsx
      mountPath: /fsx
  - name: web-viewer
    image: node:22-slim
    command: ["/bin/sh", "-c"]
    args:
    - |
      # Build the NVIDIA WebRTC viewer at startup.
      # For production, bake this into a custom image to avoid the runtime download.
      echo '@nvidia:registry=https://edge.urm.nvidia.com/artifactory/api/npm/omniverse-client-npm/' >> ~/.npmrc
      npx @nvidia/create-ov-web-rtc-app@1.14.2 --name viewer --sample local-sample --outputDir /app
      cd /app/viewer
      # Point the viewer at the Isaac Sim container (same pod = 127.0.0.1)
      sed -i "s/signalingServer: [^,]*/signalingServer: '127.0.0.1'/" src/main.ts
      sed -i "/signalingServer:/a\\    signalingPort: 49100,\n    mediaServer: '127.0.0.1',\n    mediaPort: 47998,\n    forceWSS: false," src/main.ts
      npm install --ignore-scripts
      npm run build
      echo "WebRTC viewer ready at http://localhost:8210"
      exec npx vite preview --host --port 8210
    ports:
    - containerPort: 8210
      protocol: TCP
      name: web-viewer
    resources:
      requests:
        memory: "512Mi"
        cpu: "250m"
      limits:
        memory: "1Gi"
        cpu: "1"
  volumes:
  - name: shm
    emptyDir:
      medium: Memory
      sizeLimit: 8Gi
  - name: isaac-cache
    emptyDir:
      sizeLimit: 50Gi
  - name: isaac-logs
    emptyDir:
      sizeLimit: 5Gi
  - name: fsx
    persistentVolumeClaim:
      claimName: ${FSX_PVC_NAME}
