terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

# Real AWS, not Floci. Requires real credentials (aws configure, or
# AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY). Read Tier 3's README before
# running anything against this file.
provider "aws" {
  region = "us-east-1"
}

variable "config_api_key" {
  description = "API key the app uses to read its own config table. Set via TF_VAR_config_api_key, never a default."
  type        = string
  sensitive   = true
}

locals {
  tags = {
    Environment = "dev"
    Owner       = "platform-team"
    ManagedBy   = "terraform"
  }
}

resource "aws_s3_bucket" "uploads" {
  bucket = "capstone-app-uploads-tier3"
  tags   = local.tags
}

resource "aws_s3_bucket_versioning" "uploads" {
  bucket = aws_s3_bucket.uploads.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "uploads" {
  bucket                  = aws_s3_bucket.uploads.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_dynamodb_table" "config" {
  name         = "capstone-app-config-tier3"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "environment"

  attribute {
    name = "environment"
    type = "S"
  }

  tags = local.tags
}
