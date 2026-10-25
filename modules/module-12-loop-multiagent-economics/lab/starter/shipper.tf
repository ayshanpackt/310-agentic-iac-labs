# Config file the log-shipper sidecar reads at boot.
resource "local_file" "shipper_config" {
  filename = "${path.module}/rendered/shipper.yaml"
  content  = <<-EOT
    region: ap-south-1
    bucket: kiranakart-access-logs
    access_key_id: AKIAZ7Q4R2M8N5T1W3Y6
  EOT
}
