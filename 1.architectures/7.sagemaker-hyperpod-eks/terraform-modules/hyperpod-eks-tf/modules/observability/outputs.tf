output "grafana_vpc_endpoint_id" {
  description = "Grafana VPC Endpoint ID"
  value       = local.is_amg_allowed ? aws_vpc_endpoint.grafana[0].id : null
}

output "prometheus_vpc_endpoint_id" {
  description = "Prometheus VPC Endpoint ID"
  value       = aws_vpc_endpoint.prometheus.id
}

output "prometheus_workspace_name" {
  description = "Prometheus Workspace Name"
  value       = local.prometheus_workspace_name
}

output "prometheus_workspace_id" {
  description = "Prometheus Workspace ID"
  value       = local.prometheus_workspace_id
}

output "prometheus_workspace_arn" {
  description = "Prometheus Workspace ARN"
  value       = local.prometheus_workspace_arn
}

output "prometheus_workspace_endpoint" {
  description = "Prometheus Workspace Endpoint"
  value       = local.prometheus_workspace_endpoint
}

output "observability_role_arn" {
  description = "HyperPod Observability IAM Role ARN"
  value       = aws_iam_role.hyperpod_observability_addon.arn
}

output "grafana_workspace_role_arn" {
  description = "HyperPod Observability Grafana IAM Role ARN"
  value       = local.is_amg_allowed && var.create_grafana_workspace ? aws_iam_role.grafana_workspace[0].arn : null
}

output "grafana_workspace_name" {
  description = "Grafana Workspace Name"
  value       = local.grafana_workspace_name
}

output "grafana_workspace_id" {
  value = local.grafana_workspace_id
}

output "grafana_workspace_arn" {
  value = local.grafana_workspace_arn
}

output "grafana_workspace_endpoint" {
  value = local.grafana_workspace_endpoint
}

output "grafana_service_account_token" {
  value     = local.is_amg_allowed ? aws_grafana_workspace_service_account_token.hyperpod[0].key : null
  sensitive = true
}

