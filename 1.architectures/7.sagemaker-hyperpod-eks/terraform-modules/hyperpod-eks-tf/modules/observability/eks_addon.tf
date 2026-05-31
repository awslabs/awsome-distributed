# Verify cluster exists
data "aws_eks_cluster" "hyperpod" {
  name = var.eks_cluster_name
}

# Basic EKS Addon - created first with only Prometheus configuration
resource "aws_eks_addon" "hyperpod_observability_basic" {
  cluster_name                = var.eks_cluster_name
  addon_name                  = "amazon-sagemaker-hyperpod-observability"
  resolve_conflicts_on_update = "OVERWRITE"

  configuration_values = jsonencode({
    ampWorkspace = {
      prometheusEndpoint = local.prometheus_workspace_endpoint
      arn                = local.prometheus_workspace_arn
    }
    metricsProvider = {
      trainingMetrics = {
        level          = var.training_metric_level
        scrapeInterval = 30
      }
      inferenceMetrics = {
        level          = "BASIC"
        scrapeInterval = 30
      }
      taskGovernanceMetrics = {
        level          = var.task_governance_metric_level
        scrapeInterval = 30
      }
      scalingMetrics = {
        level          = var.scaling_metric_level
        scrapeInterval = 30
      }
      customMetrics = {
        level          = var.cluster_metric_level
        scrapeInterval = 30
      }
      nodeMetrics = {
        level          = var.node_metric_level
        scrapeInterval = 30
      }
      acceleratedComputeMetrics = {
        level          = var.accelerated_compute_metric_level
        scrapeInterval = 30
      }
      networkMetrics = {
        level          = var.network_metric_level
        scrapeInterval = 30
      }
    }
    logging = {
      enabled = var.logging_enabled
    }
  })

  pod_identity_association {
    role_arn        = local.observability_role_arn
    service_account = "hyperpod-observability-operator-otel-collector"
  }

  tags = {
    SageMaker = "true"
  }

  depends_on = [
    aws_prometheus_workspace.hyperpod
  ]

  lifecycle {
    ignore_changes = [configuration_values]
  }
}

# Use terraform_data to update addon configuration when Grafana is ready
resource "terraform_data" "addon_update_with_grafana" {
  count = local.is_amg_allowed ? 1 : 0

  input = {
    cluster_name = var.eks_cluster_name
    addon_name   = "amazon-sagemaker-hyperpod-observability"
    configuration_values = jsonencode({
      ampWorkspace = {
        prometheusEndpoint = local.prometheus_workspace_endpoint
        arn                = local.prometheus_workspace_arn
      }
      amgWorkspace = {
        workspaceName = local.grafana_workspace_name
        arn           = local.grafana_workspace_arn
      }
      metricsProvider = {
        trainingMetrics = {
          level          = var.training_metric_level
          scrapeInterval = 30
        }
        inferenceMetrics = {
          level          = "BASIC"
          scrapeInterval = 30
        }
        taskGovernanceMetrics = {
          level          = var.task_governance_metric_level
          scrapeInterval = 30
        }
        scalingMetrics = {
          level          = var.scaling_metric_level
          scrapeInterval = 30
        }
        customMetrics = {
          level          = var.cluster_metric_level
          scrapeInterval = 30
        }
        nodeMetrics = {
          level          = var.node_metric_level
          scrapeInterval = 30
        }
        acceleratedComputeMetrics = {
          level          = var.accelerated_compute_metric_level
          scrapeInterval = 30
        }
        networkMetrics = {
          level          = var.network_metric_level
          scrapeInterval = 30
        }
      }
      logging = {
        enabled = var.logging_enabled
      }
    })
  }

  provisioner "local-exec" {
    command = <<-EOT
      aws eks update-addon \
        --cluster-name ${self.input.cluster_name} \
        --addon-name ${self.input.addon_name} \
        --configuration-values '${self.input.configuration_values}' \
        --resolve-conflicts OVERWRITE \
        --region ${var.aws_region}
    EOT
  }

  depends_on = [
    aws_eks_addon.hyperpod_observability_basic,
    aws_grafana_workspace.hyperpod
  ]

  lifecycle {
    ignore_changes = [input]
  }
}
