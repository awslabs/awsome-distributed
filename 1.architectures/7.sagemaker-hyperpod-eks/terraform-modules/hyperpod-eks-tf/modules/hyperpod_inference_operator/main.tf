data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

data "aws_eks_cluster" "cluster" {
  name = var.eks_cluster_name
}

locals {
  oidc_provider_url                  = data.aws_eks_cluster.cluster.identity[0].oidc[0].issuer
  oidc_provider_url_without_protocol = replace(local.oidc_provider_url, "https://", "")
}

data "tls_certificate" "eks_oidc_thumbprint" {
  url = local.oidc_provider_url
}

resource "aws_iam_openid_connect_provider" "eks_oidc_provider" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks_oidc_thumbprint.certificates[0].sha1_fingerprint]
  url             = local.oidc_provider_url

  # ignore re-evaluation of data source after initial deployment
  lifecycle {
    ignore_changes = [url, thumbprint_list]
  }

  tags = {
    Name = "${var.resource_name_prefix}-eks-oidc-provider"
  }
}

resource "aws_eks_addon" "s3_csi_driver" {
  count                    = var.enable_s3_csi_driver ? 1 : 0
  cluster_name             = var.eks_cluster_name
  addon_name               = "aws-mountpoint-s3-csi-driver"
  service_account_role_arn = aws_iam_role.s3_csi[0].arn
}

resource "aws_eks_addon" "metrics_server" {
  count        = var.enable_metrics_server ? 1 : 0
  cluster_name = var.eks_cluster_name
  addon_name   = "metrics-server"

  configuration_values = jsonencode({
    tolerations = [
      { operator = "Exists", effect = "NoSchedule" },
      { operator = "Exists", effect = "NoExecute" },
      { operator = "Exists", effect = "PreferNoSchedule" }
    ]
  })
}

resource "aws_eks_addon" "inference_operator" {
  cluster_name                = var.eks_cluster_name
  addon_name                  = "amazon-sagemaker-hyperpod-inference"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  configuration_values = jsonencode({
    executionRoleArn                   = aws_iam_role.inference_operator.arn
    tlsCertificateS3Bucket             = aws_s3_bucket.tls_certificates.id
    hyperpodClusterArn                 = var.hyperpod_cluster_arn
    jumpstartGatedModelDownloadRoleArn = aws_iam_role.jumpstart_gated.arn

    alb = {
      enabled = true
      serviceAccount = {
        create  = true
        roleArn = aws_iam_role.alb_controller.arn
      }
    }

    keda = {
      enabled = true
      auth = {
        aws = {
          irsa = {
            enabled = true
            roleArn = aws_iam_role.keda.arn
          }
        }
      }
    }
  })

  depends_on = [
    aws_eks_addon.s3_csi_driver
  ]
}