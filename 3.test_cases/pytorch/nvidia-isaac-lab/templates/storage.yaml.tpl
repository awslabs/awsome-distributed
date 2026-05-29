# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# ============================================================================
# Kubernetes Storage: FSx for Lustre PV/PVC
# Generated from config.yaml -- do not edit directly
# ============================================================================
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: isaaclab-fsx-pv
spec:
  capacity:
    storage: ${FSX_CAPACITY}
  accessModes:
    - ReadWriteMany
  storageClassName: ""
  mountOptions:
    - flock
  csi:
    driver: fsx.csi.aws.com
    volumeHandle: ${FSX_FILE_SYSTEM_ID}
    volumeAttributes:
      dnsname: ${FSX_DNS_NAME}
      mountname: ${FSX_MOUNT_NAME}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${FSX_PVC_NAME}
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: ""
  resources:
    requests:
      storage: ${FSX_CAPACITY}
  volumeName: isaaclab-fsx-pv
