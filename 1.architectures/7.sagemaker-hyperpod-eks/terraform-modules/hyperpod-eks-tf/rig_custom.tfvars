kubernetes_version    = "1.32"
eks_cluster_name      = "tf-eks-cluster-rig"
hyperpod_cluster_name = "tf-hp-cluster-rig"
resource_name_prefix  = "tf-eks-test-rig"
aws_region            = "us-east-1"
rig_input_s3_bucket   = "my-tf-rig-test-input-bucket"
rig_output_s3_bucket  = "my-tf-rig-test-output-bucket"
restricted_instance_groups = [
  {
    name                             = "rig-1"
    instance_type                    = "ml.p5.48xlarge",
    instance_count                   = 2,
    availability_zone_id             = "use1-az6",
    ebs_volume_size_in_gb            = 850,
    threads_per_core                 = 2,
    enable_stress_check              = false,
    enable_connectivity_check        = false,
    fsxl_per_unit_storage_throughput = 250,
    fsxl_size_in_gi_b                = 4800
  }
]
