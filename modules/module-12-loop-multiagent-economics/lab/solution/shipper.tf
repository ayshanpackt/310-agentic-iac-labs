# Config file the log-shipper sidecar reads at boot. The key arrives at plan or apply time,
# for example as TF_VAR_shipper_access_key_id, never in source.
variable "shipper_access_key_id" {
  description = "AWS access key ID the log-shipper sidecar uses to write to S3"
  type        = string
  sensitive   = true
}

resource "local_file" "shipper_config" {
  filename        = "${path.module}/rendered/shipper.yaml"
  file_permission = "0600"
  content         = <<-EOT
    region: ap-south-1
    bucket: kiranakart-access-logs
    access_key_id: ${var.shipper_access_key_id}
  EOT
}
