# Canonical Tier-1 provider stub. Every Tier-1 lab in this course uses this shape.
#
# NOTE: Floci's README shows `endpoint_url`, which is not AWS-provider syntax.
# Use the `endpoints {}` block plus the skip_* flags below — this is what actually works.
terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}
variable "endpoint" {
  type    = string
  default = "http://localhost:4566"
}
provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
  skip_region_validation      = true
  s3_use_path_style           = true
  endpoints {
    ec2            = var.endpoint
    s3             = var.endpoint
    iam            = var.endpoint
    sts            = var.endpoint
    rds            = var.endpoint
    lambda         = var.endpoint
    dynamodb       = var.endpoint
    sqs            = var.endpoint
    sns            = var.endpoint
    kms            = var.endpoint
    logs           = var.endpoint
    secretsmanager = var.endpoint
    elbv2          = var.endpoint
    autoscaling    = var.endpoint
  }
}
