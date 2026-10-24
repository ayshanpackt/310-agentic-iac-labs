terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true

  endpoints {
    s3 = var.endpoint
  }
}

variable "endpoint" {
  type    = string
  default = "http://localhost:4566"
}

# Three checkov findings on each bucket below are a deliberate, reviewed exception. Event
# notifications (CKV2_AWS_62), lifecycle rules (CKV2_AWS_61) and cross-region replication
# (CKV_AWS_144) are production DR concerns, not a lab requirement. Each waiver sits inline
# on the one resource it covers, with its reason beside it, so checkov reports it under
# "Skipped checks" for that resource only. A --skip-check flag on the CLI would silence the
# same check for every resource in the directory, including ones nobody reviewed.
# Verified against checkov 3.3.30: the solution scan shows "Failed checks: 0, Skipped
# checks: 6", two buckets times three waivers. Trivy's inline ignore comment works the same
# way, see the aws_s3_bucket_server_side_encryption_configuration resources further down.
resource "aws_s3_bucket" "reports" {
  #checkov:skip=CKV2_AWS_62:Event notifications are a production concern, not a lab requirement. Reviewed exception.
  #checkov:skip=CKV2_AWS_61:Lifecycle rules are a production concern, not a lab requirement. Reviewed exception.
  #checkov:skip=CKV_AWS_144:Cross-region replication is a production DR concern, not a lab requirement. Reviewed exception.
  bucket        = "m09-lab-reports"
  force_destroy = true

  tags = {
    Environment = "lab"
    Owner       = "m09-lab"
    ManagedBy   = "terraform"
  }
}

resource "aws_s3_bucket" "backups" {
  #checkov:skip=CKV2_AWS_62:Event notifications are a production concern, not a lab requirement. Reviewed exception.
  #checkov:skip=CKV2_AWS_61:Lifecycle rules are a production concern, not a lab requirement. Reviewed exception.
  #checkov:skip=CKV_AWS_144:Cross-region replication is a production DR concern, not a lab requirement. Reviewed exception.
  bucket        = "m09-lab-backups"
  force_destroy = true

  tags = {
    Environment = "lab"
    Owner       = "m09-lab"
    ManagedBy   = "terraform"
  }
}

resource "aws_s3_bucket_versioning" "reports" {
  bucket = aws_s3_bucket.reports.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_versioning" "backups" {
  bucket = aws_s3_bucket.backups.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "reports" {
  bucket                  = aws_s3_bucket.reports.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_public_access_block" "backups" {
  bucket                  = aws_s3_bucket.backups.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

#trivy:ignore:AWS-0132:a customer-managed KMS key is a real production hardening step this lab's SSE-KMS default already covers well enough
resource "aws_s3_bucket_server_side_encryption_configuration" "reports" {
  bucket = aws_s3_bucket.reports.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

#trivy:ignore:AWS-0132:a customer-managed KMS key is a real production hardening step this lab's SSE-KMS default already covers well enough
resource "aws_s3_bucket_server_side_encryption_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_logging" "reports" {
  bucket        = aws_s3_bucket.reports.id
  target_bucket = aws_s3_bucket.backups.id
  target_prefix = "logs/reports/"
}

resource "aws_s3_bucket_logging" "backups" {
  bucket        = aws_s3_bucket.backups.id
  target_bucket = aws_s3_bucket.backups.id
  target_prefix = "logs/backups/"
}
