variable "eks_cluster_name" {
  description = "The name of the EKS cluster"
  type        = string
}

variable "aws_region" {
  description = "AWS Region where the HyperPod cluster and compute allocations exist"
  type        = string
}

variable "hyperpod_cluster_arn" {
  description = "ARN of the HyperPod cluster used for compute allocations"
  type        = string
  default     = ""
}

variable "compute_quotas" {
  description = "SageMaker HyperPod task governance compute allocations to create or update"
  type = list(object({
    name             = string
    description      = optional(string, "")
    activation_state = optional(string, "Enabled")
    compute_quota_resources = list(object({
      instance_type = string
      count         = optional(number)
      accelerators  = optional(number)
      vcpu          = optional(number)
      memory_in_gib = optional(number)
      accelerator_partition = optional(object({
        type  = string
        count = number
      }))
    }))
    resource_sharing_config = optional(object({
      strategy     = optional(string, "LendAndBorrow")
      borrow_limit = optional(number)
      absolute_borrow_limits = optional(list(object({
        instance_type = string
        count         = optional(number)
        accelerators  = optional(number)
        vcpu          = optional(number)
        memory_in_gib = optional(number)
        accelerator_partition = optional(object({
          type  = string
          count = number
        }))
      })), [])
    }), {})
    preempt_team_tasks = optional(string, "LowerPriority")
    target = object({
      team_name         = string
      fair_share_weight = optional(number, 0)
    })
  }))
  default = []

  validation {
    condition     = length(var.compute_quotas) == 0 || var.hyperpod_cluster_arn != ""
    error_message = "hyperpod_cluster_arn is required when compute_quotas are configured."
  }

  validation {
    condition = alltrue([
      for quota in var.compute_quotas :
      contains(["Enabled", "Disabled"], quota.activation_state)
    ])
    error_message = "Compute quota activation_state must be Enabled or Disabled."
  }

  validation {
    condition = alltrue([
      for quota in var.compute_quotas :
      contains(["Lend", "DontLend", "LendAndBorrow"], quota.resource_sharing_config.strategy)
    ])
    error_message = "Compute quota resource_sharing_config.strategy must be Lend, DontLend, or LendAndBorrow."
  }

  validation {
    condition = alltrue([
      for quota in var.compute_quotas :
      quota.resource_sharing_config.borrow_limit == null || (quota.resource_sharing_config.borrow_limit >= 1 && quota.resource_sharing_config.borrow_limit <= 500)
    ])
    error_message = "Compute quota resource_sharing_config.borrow_limit must be between 1 and 500 when set."
  }

  validation {
    condition = alltrue([
      for quota in var.compute_quotas :
      contains(["Never", "LowerPriority"], quota.preempt_team_tasks)
    ])
    error_message = "Compute quota preempt_team_tasks must be Never or LowerPriority."
  }

  validation {
    condition = alltrue([
      for quota in var.compute_quotas :
      quota.target.fair_share_weight >= 0 && quota.target.fair_share_weight <= 100
    ])
    error_message = "Compute quota target.fair_share_weight must be between 0 and 100."
  }

  validation {
    condition = alltrue([
      for quota in var.compute_quotas :
      trimspace(quota.name) != "" && trimspace(quota.target.team_name) != ""
    ])
    error_message = "Compute quota name and target.team_name cannot be empty."
  }

  validation {
    condition = alltrue(flatten([
      for quota in var.compute_quotas : [
        for resource in concat(quota.compute_quota_resources, quota.resource_sharing_config.absolute_borrow_limits) :
        trimspace(resource.instance_type) != "" &&
        (resource.count == null || resource.count > 0) &&
        (resource.accelerators == null || resource.accelerators > 0) &&
        (resource.vcpu == null || resource.vcpu > 0) &&
        (resource.memory_in_gib == null || resource.memory_in_gib > 0) &&
        (
          resource.accelerator_partition == null ||
          (
            trimspace(resource.accelerator_partition.type) != "" &&
            resource.accelerator_partition.count > 0
          )
        )
      ]
    ]))
    error_message = "Compute quota resource values must be non-empty and positive when set."
  }

  validation {
    condition = alltrue(flatten([
      for quota in var.compute_quotas : [
        for resource in quota.compute_quota_resources :
        resource.count != null || resource.accelerators != null || resource.vcpu != null || resource.memory_in_gib != null || resource.accelerator_partition != null
      ]
    ]))
    error_message = "Each compute quota resource must set at least one of count, accelerators, vcpu, memory_in_gib, or accelerator_partition."
  }
}
