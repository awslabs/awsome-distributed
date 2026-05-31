# EKS Addon for Cert Manager (required for HPTO and HPIO)
resource "aws_eks_addon" "cert_manager" {
  count         = var.enable_cert_manager ? 1 : 0
  cluster_name  = var.eks_cluster_name
  addon_name    = "cert-manager"
  addon_version = var.cert_manager_version

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  configuration_values = jsonencode({
    replicaCount = 1
    tolerations = [
      {
        operator = "Exists"
        effect   = "NoSchedule"
      },
      {
        operator = "Exists"
        effect   = "NoExecute"
      },
      {
        operator = "Exists"
        effect   = "PreferNoSchedule"
      }
    ]
    webhook = {
      replicaCount = 1
      tolerations = [
        {
          operator = "Exists"
          effect   = "NoSchedule"
        },
        {
          operator = "Exists"
          effect   = "NoExecute"
        },
        {
          operator = "Exists"
          effect   = "PreferNoSchedule"
        }
      ]
    }
    cainjector = {
      replicaCount = 1
      tolerations = [
        {
          operator = "Exists"
          effect   = "NoSchedule"
        },
        {
          operator = "Exists"
          effect   = "NoExecute"
        },
        {
          operator = "Exists"
          effect   = "PreferNoSchedule"
        }
      ]
    }
  })
  depends_on = [null_resource.wait_for_hyperpod_nodes]
}

# Wait for cert-manager to be ready
resource "null_resource" "wait_for_cert_manager" {
  count = var.enable_cert_manager ? 1 : 0

  provisioner "local-exec" {
    command = <<-EOT
      aws eks update-kubeconfig --region ${data.aws_region.current.region} --name ${var.eks_cluster_name}
      echo "Waiting for cert-manager deployments to be ready..."
      kubectl wait --for=condition=available deployment/cert-manager -n cert-manager --timeout=300s
      kubectl wait --for=condition=available deployment/cert-manager-cainjector -n cert-manager --timeout=300s
      kubectl wait --for=condition=available deployment/cert-manager-webhook -n cert-manager --timeout=300s
      echo "All cert-manager deployments are ready"
    EOT
  }

  depends_on = [aws_eks_addon.cert_manager]
}