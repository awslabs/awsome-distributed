kubernetes_version    = "1.33"
eks_cluster_name      = "tf-eks-cluster"
hyperpod_cluster_name = "tf-hp-cluster"
resource_name_prefix  = "tf-eks-test"
aws_region            = "us-east-1"
instance_groups = [
  {
    name                      = "accelerated-instance-group-1"
    instance_type             = "ml.g5.8xlarge",
    instance_count            = 2,
    availability_zone_id      = "use1-az2",
    ebs_volume_size_in_gb     = 100,
    threads_per_core          = 1,
    enable_stress_check       = false,
    enable_connectivity_check = false,
    lifecycle_script          = "on_create.sh"
  }
]
create_observability_module               = true
network_metric_level                      = "ADVANCED"
logging_enabled                           = true
create_task_governance_module             = true
create_hyperpod_training_operator_module  = true
create_hyperpod_inference_operator_module = true
enable_guardduty_cleanup                  = true
create_new_fsx_filesystem                 = true
