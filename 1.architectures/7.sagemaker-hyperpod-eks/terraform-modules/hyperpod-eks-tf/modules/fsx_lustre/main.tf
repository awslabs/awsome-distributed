data "aws_region" "current" {}

locals {
  wait_for_fsx_csi_driver = var.create_new_filesystem || var.inference_operator_enabled
}

# IAM role for FSx CSI driver
resource "aws_iam_role" "fsx_csi_driver_role" {
  name = "${var.resource_name_prefix}-fsx-csi-driver-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "pods.eks.amazonaws.com"
        }
        Action = [
          "sts:AssumeRole",
          "sts:TagSession"
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "fsx_csi_driver_policy" {
  role       = aws_iam_role.fsx_csi_driver_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonFSxFullAccess"
}

# FSx CSI driver addon
resource "aws_eks_addon" "fsx_lustre_csi_driver" {
  cluster_name                = var.eks_cluster_name
  addon_name                  = "aws-fsx-csi-driver"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  pod_identity_association {
    role_arn        = aws_iam_role.fsx_csi_driver_role.arn
    service_account = "fsx-csi-controller-sa"
  }
}

# Wait for FSx CSI driver to be available (required for the HPIO and PVC binding)
resource "null_resource" "wait_for_fsx_csi_driver" {
  count = local.wait_for_fsx_csi_driver ? 1 : 0

  provisioner "local-exec" {
    command = <<-EOT
      aws eks update-kubeconfig --region ${data.aws_region.current.region} --name ${var.eks_cluster_name}
      kubectl wait --for=condition=available deployment/fsx-csi-controller -n kube-system --timeout=300s 
    EOT
  }

  depends_on = [aws_eks_addon.fsx_lustre_csi_driver]
}

# New FSxL filesystem 
resource "aws_fsx_lustre_file_system" "fsx" {
  count = var.create_new_filesystem ? 1 : 0

  storage_capacity            = var.storage_capacity
  subnet_ids                  = [var.subnet_id]
  security_group_ids          = [var.security_group_id]
  deployment_type             = "PERSISTENT_2"
  per_unit_storage_throughput = var.throughput
  data_compression_type       = var.data_compression_type
  file_system_type_version    = var.file_system_type_version

  tags = {
    Name = "${var.resource_name_prefix}-fsx"
  }
}

# StorageClass for static provisioning with new FSxL filesystem
resource "kubernetes_storage_class_v1" "fsx_sc" {
  count = var.create_new_filesystem ? 1 : 0

  metadata {
    name = "fsx-sc"
  }
  storage_provisioner = "fsx.csi.aws.com"

  depends_on = [null_resource.wait_for_fsx_csi_driver]
}

# PersistentVolume for static provisioning with new FSxL filesystem
resource "kubernetes_persistent_volume_v1" "fsx_pv" {
  count = var.create_new_filesystem ? 1 : 0

  metadata {
    name = "fsx-pv"
  }
  spec {
    capacity = {
      storage = "${var.storage_capacity}Gi"
    }
    access_modes                     = ["ReadWriteMany"]
    storage_class_name               = kubernetes_storage_class_v1.fsx_sc[0].metadata[0].name
    persistent_volume_reclaim_policy = "Retain"
    persistent_volume_source {
      csi {
        driver        = "fsx.csi.aws.com"
        volume_handle = aws_fsx_lustre_file_system.fsx[0].id
        volume_attributes = {
          dnsname   = aws_fsx_lustre_file_system.fsx[0].dns_name
          mountname = aws_fsx_lustre_file_system.fsx[0].mount_name
        }
      }
    }
  }
}

resource "kubernetes_namespace_v1" "fsx_namespace" {
  count = var.create_new_filesystem && var.fsx_pvc_namespace != "default" && var.create_fsx_pvc_namespace ? 1 : 0

  metadata {
    name = var.fsx_pvc_namespace
  }
}

# PersistentVolumeClaim for static provisioning with new FSxL filesystem
resource "kubernetes_persistent_volume_claim_v1" "fsx_pvc" {
  count = var.create_new_filesystem ? 1 : 0

  metadata {
    name      = "fsx-claim"
    namespace = var.fsx_pvc_namespace
  }
  spec {
    access_modes       = ["ReadWriteMany"]
    storage_class_name = kubernetes_storage_class_v1.fsx_sc[0].metadata[0].name
    volume_name        = kubernetes_persistent_volume_v1.fsx_pv[0].metadata[0].name
    resources {
      requests = {
        storage = "${var.storage_capacity}Gi"
      }
    }
  }
  depends_on = [kubernetes_namespace_v1.fsx_namespace]
}
