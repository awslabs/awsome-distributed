locals {
  compute_quota_resources = {
    for quota in var.compute_quotas : quota.name => [
      for resource in quota.compute_quota_resources : merge(
        {
          InstanceType = resource.instance_type
        },
        resource.count != null ? {
          Count = resource.count
        } : {},
        resource.accelerators != null ? {
          Accelerators = resource.accelerators
        } : {},
        resource.vcpu != null ? {
          VCpu = resource.vcpu
        } : {},
        resource.memory_in_gib != null ? {
          MemoryInGiB = resource.memory_in_gib
        } : {},
        resource.accelerator_partition != null ? {
          AcceleratorPartition = {
            Type  = resource.accelerator_partition.type
            Count = resource.accelerator_partition.count
          }
        } : {}
      )
    ]
  }

  compute_quota_absolute_borrow_limits = {
    for quota in var.compute_quotas : quota.name => [
      for resource in quota.resource_sharing_config.absolute_borrow_limits : merge(
        {
          InstanceType = resource.instance_type
        },
        resource.count != null ? {
          Count = resource.count
        } : {},
        resource.accelerators != null ? {
          Accelerators = resource.accelerators
        } : {},
        resource.vcpu != null ? {
          VCpu = resource.vcpu
        } : {},
        resource.memory_in_gib != null ? {
          MemoryInGiB = resource.memory_in_gib
        } : {},
        resource.accelerator_partition != null ? {
          AcceleratorPartition = {
            Type  = resource.accelerator_partition.type
            Count = resource.accelerator_partition.count
          }
        } : {}
      )
    ]
  }

  compute_quota_configs = {
    for quota in var.compute_quotas : quota.name => {
      ComputeQuotaResources = local.compute_quota_resources[quota.name]
      ResourceSharingConfig = merge(
        {
          Strategy = quota.resource_sharing_config.strategy
        },
        quota.resource_sharing_config.borrow_limit != null ? {
          BorrowLimit = quota.resource_sharing_config.borrow_limit
        } : {},
        length(local.compute_quota_absolute_borrow_limits[quota.name]) > 0 ? {
          AbsoluteBorrowLimits = local.compute_quota_absolute_borrow_limits[quota.name]
        } : {}
      )
      PreemptTeamTasks = quota.preempt_team_tasks
    }
  }

  compute_quota_targets = {
    for quota in var.compute_quotas : quota.name => {
      TeamName        = quota.target.team_name
      FairShareWeight = quota.target.fair_share_weight
    }
  }
}

# EKS Addon for Task Governance
resource "aws_eks_addon" "task_governance" {
  cluster_name                = var.eks_cluster_name
  addon_name                  = "amazon-sagemaker-hyperpod-taskgovernance"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
}

resource "null_resource" "wait_for_kueue_webhook" {
  provisioner "local-exec" {
    command = <<-EOT
      echo "Waiting for kueue-controller-manager deployment to be ready..."
      aws eks update-kubeconfig --region ${var.aws_region} --name ${var.eks_cluster_name}
      kubectl wait --for=condition=available deployment/kueue-controller-manager \
        -n kueue-system \
        --timeout=300s
      echo "Kueue controller manager is ready"
    EOT
  }

  depends_on = [aws_eks_addon.task_governance]
}

resource "null_resource" "compute_quota" {
  for_each = { for quota in var.compute_quotas : quota.name => quota }

  triggers = {
    activation_state     = each.value.activation_state
    cluster_arn          = var.hyperpod_cluster_arn
    compute_quota_config = jsonencode(local.compute_quota_configs[each.key])
    compute_quota_target = jsonencode(local.compute_quota_targets[each.key])
    description          = each.value.description != null ? each.value.description : ""
    name                 = each.value.name
    region               = var.aws_region
  }

  provisioner "local-exec" {
    command = "bash ${path.module}/scripts/manage-compute-quota.sh apply"
    environment = {
      ACTIVATION_STATE     = self.triggers.activation_state
      AWS_REGION           = self.triggers.region
      CLUSTER_ARN          = self.triggers.cluster_arn
      COMPUTE_QUOTA_CONFIG = self.triggers.compute_quota_config
      COMPUTE_QUOTA_TARGET = self.triggers.compute_quota_target
      DESCRIPTION          = self.triggers.description
      QUOTA_NAME           = self.triggers.name
    }
  }

  provisioner "local-exec" {
    when    = destroy
    command = "bash ${path.module}/scripts/manage-compute-quota.sh delete"
    environment = {
      ACTIVATION_STATE     = self.triggers.activation_state
      AWS_REGION           = self.triggers.region
      CLUSTER_ARN          = self.triggers.cluster_arn
      COMPUTE_QUOTA_CONFIG = self.triggers.compute_quota_config
      COMPUTE_QUOTA_TARGET = self.triggers.compute_quota_target
      DESCRIPTION          = self.triggers.description
      QUOTA_NAME           = self.triggers.name
    }
  }

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [null_resource.wait_for_kueue_webhook]
}
