data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
  # URL prefix to pull alert rules and dashboard templates from 
  github_base_url                   = "https://raw.githubusercontent.com/aws/sagemaker-hyperpod-cluster-setup/refs/heads/main/eks/cloudformation/resources/observability-assets-creation"
  use_existing_prometheus_workspace = !var.create_prometheus_workspace && var.prometheus_workspace_id != ""
  use_existing_grafana_workspace    = !var.create_grafana_workspace && var.grafana_workspace_id != ""

  amg_allowed_regions = [
    "us-east-1", "us-east-2", "us-west-2",
    "ap-northeast-1", "ap-southeast-1", "ap-southeast-2",
    "eu-central-1", "eu-west-1", "eu-west-2"
  ]
  # used in count, so requires direct reference to region at plan time
  is_amg_allowed = contains(local.amg_allowed_regions, var.aws_region)
}

data "aws_prometheus_workspace" "existing" {
  count        = local.use_existing_prometheus_workspace ? 1 : 0
  workspace_id = var.prometheus_workspace_id
}

data "aws_grafana_workspace" "existing" {
  count        = local.is_amg_allowed && local.use_existing_grafana_workspace ? 1 : 0
  workspace_id = var.grafana_workspace_id
}

# Fetch alert rules from GitHub
data "http" "alert_rules" {
  url = "${local.github_base_url}/alerts/alert-rules.yaml"
}

# Fetch dashboard templates from GitHub
data "http" "cluster_dashboard" {
  url = "${local.github_base_url}/dashboards/templates/cluster.json"
}

data "http" "efa_dashboard" {
  url = "${local.github_base_url}/dashboards/templates/efa.json"
}

data "http" "training_dashboard" {
  url = "${local.github_base_url}/dashboards/templates/training.json"
}

data "http" "inference_dashboard" {
  url = "${local.github_base_url}/dashboards/templates/inference.json"
}

data "http" "tasks_dashboard" {
  url = "${local.github_base_url}/dashboards/templates/tasks.json"
}

locals {
  dashboard_templates = {
    cluster   = data.http.cluster_dashboard.response_body
    efa       = data.http.efa_dashboard.response_body
    training  = data.http.training_dashboard.response_body
    inference = data.http.inference_dashboard.response_body
    tasks     = data.http.tasks_dashboard.response_body
  }

  # Extract dashboard content
  dashboard_content = {
    for key, template in local.dashboard_templates :
    key => lookup(jsondecode(template), "dashboard", jsondecode(template))
  }

  alert_rules = yamldecode(data.http.alert_rules.response_body).groups[0].rules

  # Timestamp for unique workspace names
  timestamp_suffix = formatdate("YYYYMMDD'T'HHmmss", timestamp())

  # Prometheus workspace values
  prometheus_workspace_name     = local.use_existing_prometheus_workspace ? null : coalesce(var.prometheus_workspace_name, "hyperpod-prometheus-workspace-${local.timestamp_suffix}")
  prometheus_workspace_id       = local.use_existing_prometheus_workspace ? var.prometheus_workspace_id : aws_prometheus_workspace.hyperpod[0].id
  prometheus_workspace_endpoint = trimsuffix(local.use_existing_prometheus_workspace ? data.aws_prometheus_workspace.existing[0].prometheus_endpoint : aws_prometheus_workspace.hyperpod[0].prometheus_endpoint, "/")
  prometheus_workspace_arn      = local.use_existing_prometheus_workspace ? data.aws_prometheus_workspace.existing[0].arn : aws_prometheus_workspace.hyperpod[0].arn

  # Grafana workspace values
  grafana_workspace_name     = local.is_amg_allowed ? (local.use_existing_grafana_workspace ? data.aws_grafana_workspace.existing[0].name : coalesce(var.grafana_workspace_name, "hyperpod-grafana-workspace-${local.timestamp_suffix}")) : null
  grafana_workspace_id       = local.is_amg_allowed ? (local.use_existing_grafana_workspace ? var.grafana_workspace_id : aws_grafana_workspace.hyperpod[0].id) : null
  grafana_workspace_endpoint = local.is_amg_allowed ? (local.use_existing_grafana_workspace ? data.aws_grafana_workspace.existing[0].endpoint : aws_grafana_workspace.hyperpod[0].endpoint) : null
  grafana_workspace_arn      = local.is_amg_allowed ? (local.use_existing_grafana_workspace ? data.aws_grafana_workspace.existing[0].arn : aws_grafana_workspace.hyperpod[0].arn) : null

  # Observability role
  observability_role_arn = aws_iam_role.hyperpod_observability_addon.arn
}
