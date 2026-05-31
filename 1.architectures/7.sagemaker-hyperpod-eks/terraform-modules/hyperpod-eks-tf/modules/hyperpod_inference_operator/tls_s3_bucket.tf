
resource "aws_s3_bucket" "tls_certificates" {
  bucket = "hyperpod-tls-${random_string.bucket_suffix.result}"
}

resource "random_string" "bucket_suffix" {
  length  = 8
  special = false
  upper   = false
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tls_encryption" {
  bucket = aws_s3_bucket.tls_certificates.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tls_pab" {
  bucket = aws_s3_bucket.tls_certificates.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_logging" "tls_logging" {
  bucket = aws_s3_bucket.tls_certificates.id

  target_bucket = var.access_logs_bucket_name
  target_prefix = "tls-cert-logs/"
}

resource "aws_s3_bucket_policy" "tls_policy" {
  bucket = aws_s3_bucket.tls_certificates.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.tls_certificates.arn,
          "${aws_s3_bucket.tls_certificates.arn}/*"
        ]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      }
    ]
  })
}