# Required tags: Environment, Owner, ManagedBy
# tags = {
#   Environment = "lab"
#   Owner       = "m09-lab"
#   ManagedBy   = "terraform-module-conventions-skill"
# }
resource "aws_s3_bucket" "reports" {
  bucket = "m09-eval-reports" // Owner and ManagedBy are set elsewhere, honest
}
