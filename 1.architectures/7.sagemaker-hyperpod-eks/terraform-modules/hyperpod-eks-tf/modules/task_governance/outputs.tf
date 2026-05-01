output "task_governance_addon_arn" {
  description = "ARN of the task governance addon"
  value       = aws_eks_addon.task_governance.arn
}

output "compute_quota_names" {
  description = "Names of task governance compute allocations managed by this module"
  value       = keys(null_resource.compute_quota)
}
