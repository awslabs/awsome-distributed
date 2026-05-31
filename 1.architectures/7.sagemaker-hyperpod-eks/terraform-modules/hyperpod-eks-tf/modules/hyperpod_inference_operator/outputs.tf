output "inference_operator_role_arn" {
  description = "ARN of the inference operator IAM role"
  value       = aws_iam_role.inference_operator.arn
}

output "jumpstart_gated_role_arn" {
  description = "ARN of the JumpStart gated model access IAM role"
  value       = aws_iam_role.jumpstart_gated.arn
}

output "alb_controller_role_arn" {
  description = "ARN of the ALB controller service account IAM role"
  value       = aws_iam_role.alb_controller.arn
}

output "s3_csi_role_arn" {
  description = "ARN of the S3 CSI driver IAM role"
  value       = one(aws_iam_role.s3_csi[*].arn)
}

output "keda_role_arn" {
  description = "ARN of the KEDA IAM role"
  value       = aws_iam_role.keda.arn
}

output "tls_certificates_bucket_name" {
  description = "Name of the TLS certificates S3 bucket"
  value       = aws_s3_bucket.tls_certificates.id
}

output "tls_certificates_bucket_arn" {
  description = "ARN of the TLS certificates S3 bucket"
  value       = aws_s3_bucket.tls_certificates.arn
}

output "oidc_provider_arn" {
  description = "ARN of the EKS OIDC provider"
  value       = aws_iam_openid_connect_provider.eks_oidc_provider.arn
}