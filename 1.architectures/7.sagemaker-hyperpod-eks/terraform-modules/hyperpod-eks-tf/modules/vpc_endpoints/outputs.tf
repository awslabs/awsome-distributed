output "s3_vpc_endpoint_id" {
  description = "The ID of the S3 VPC endpoint"
  value       = length(aws_vpc_endpoint.s3) > 0 ? aws_vpc_endpoint.s3[0].id : null
}

output "s3_vpc_endpoint_state" {
  description = "The state of the S3 VPC endpoint"
  value       = length(aws_vpc_endpoint.s3) > 0 ? aws_vpc_endpoint.s3[0].state : null
}

# EKS Critical Endpoints
output "ec2_vpc_endpoint_id" {
  description = "The ID of the EC2 VPC endpoint (CRITICAL for AWS CNI)"
  value       = length(aws_vpc_endpoint.ec2) > 0 ? aws_vpc_endpoint.ec2[0].id : null
}

output "ecr_api_vpc_endpoint_id" {
  description = "The ID of the ECR API VPC endpoint"
  value       = length(aws_vpc_endpoint.ecr_api) > 0 ? aws_vpc_endpoint.ecr_api[0].id : null
}

output "ecr_dkr_vpc_endpoint_id" {
  description = "The ID of the ECR DKR VPC endpoint"
  value       = length(aws_vpc_endpoint.ecr_dkr) > 0 ? aws_vpc_endpoint.ecr_dkr[0].id : null
}

output "sts_vpc_endpoint_id" {
  description = "The ID of the STS VPC endpoint"
  value       = length(aws_vpc_endpoint.sts) > 0 ? aws_vpc_endpoint.sts[0].id : null
}

output "logs_vpc_endpoint_id" {
  description = "The ID of the CloudWatch Logs VPC endpoint"
  value       = length(aws_vpc_endpoint.logs) > 0 ? aws_vpc_endpoint.logs[0].id : null
}

output "monitoring_vpc_endpoint_id" {
  description = "The ID of the CloudWatch Monitoring VPC endpoint"
  value       = length(aws_vpc_endpoint.monitoring) > 0 ? aws_vpc_endpoint.monitoring[0].id : null
}

# SSM Endpoints
output "ssm_vpc_endpoint_id" {
  description = "The ID of the SSM VPC endpoint"
  value       = length(aws_vpc_endpoint.ssm) > 0 ? aws_vpc_endpoint.ssm[0].id : null
}

output "ssmmessages_vpc_endpoint_id" {
  description = "The ID of the SSM Messages VPC endpoint"
  value       = length(aws_vpc_endpoint.ssmmessages) > 0 ? aws_vpc_endpoint.ssmmessages[0].id : null
}

output "ec2messages_vpc_endpoint_id" {
  description = "The ID of the EC2 Messages VPC endpoint"
  value       = length(aws_vpc_endpoint.ec2messages) > 0 ? aws_vpc_endpoint.ec2messages[0].id : null
}

# RIG Mode Endpoints (conditional)
output "lambda_vpc_endpoint_id" {
  description = "The ID of the Lambda VPC endpoint"
  value       = length(aws_vpc_endpoint.lambda) > 0 ? aws_vpc_endpoint.lambda[0].id : null
}

output "lambda_vpc_endpoint_state" {
  description = "The state of the Lambda VPC endpoint"
  value       = length(aws_vpc_endpoint.lambda) > 0 ? aws_vpc_endpoint.lambda[0].state : null
}

output "sqs_vpc_endpoint_id" {
  description = "The ID of the SQS VPC endpoint"
  value       = length(aws_vpc_endpoint.sqs) > 0 ? aws_vpc_endpoint.sqs[0].id : null
}

output "sqs_vpc_endpoint_state" {
  description = "The state of the SQS VPC endpoint"
  value       = length(aws_vpc_endpoint.sqs) > 0 ? aws_vpc_endpoint.sqs[0].state : null
}

# Summary output
output "vpc_endpoints_summary" {
  description = "Summary of all VPC endpoints created"
  value = {
    gateway_endpoints = {
      s3 = length(aws_vpc_endpoint.s3) > 0 ? aws_vpc_endpoint.s3[0].id : "not created"
    }
    interface_endpoints = {
      ec2         = length(aws_vpc_endpoint.ec2) > 0 ? aws_vpc_endpoint.ec2[0].id : "not created"
      ecr_api     = length(aws_vpc_endpoint.ecr_api) > 0 ? aws_vpc_endpoint.ecr_api[0].id : "not created"
      ecr_dkr     = length(aws_vpc_endpoint.ecr_dkr) > 0 ? aws_vpc_endpoint.ecr_dkr[0].id : "not created"
      sts         = length(aws_vpc_endpoint.sts) > 0 ? aws_vpc_endpoint.sts[0].id : "not created"
      logs        = length(aws_vpc_endpoint.logs) > 0 ? aws_vpc_endpoint.logs[0].id : "not created"
      monitoring  = length(aws_vpc_endpoint.monitoring) > 0 ? aws_vpc_endpoint.monitoring[0].id : "not created"
      ssm         = length(aws_vpc_endpoint.ssm) > 0 ? aws_vpc_endpoint.ssm[0].id : "not created"
      ssmmessages = length(aws_vpc_endpoint.ssmmessages) > 0 ? aws_vpc_endpoint.ssmmessages[0].id : "not created"
      ec2messages = length(aws_vpc_endpoint.ec2messages) > 0 ? aws_vpc_endpoint.ec2messages[0].id : "not created"
      lambda      = length(aws_vpc_endpoint.lambda) > 0 ? aws_vpc_endpoint.lambda[0].id : "not created"
      sqs         = length(aws_vpc_endpoint.sqs) > 0 ? aws_vpc_endpoint.sqs[0].id : "not created"
    }
  }
}
