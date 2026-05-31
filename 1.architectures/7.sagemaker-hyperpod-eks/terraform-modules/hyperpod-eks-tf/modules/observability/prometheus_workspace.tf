
resource "aws_prometheus_workspace" "hyperpod" {
  count = var.create_prometheus_workspace ? 1 : 0

  alias = local.prometheus_workspace_name

  # ignore timestamp_suffix changes in alias after initial deployment
  lifecycle {
    ignore_changes = [alias]
  }

  tags = {
    SageMaker = "true"
  }
}
