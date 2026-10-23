run "sse_enabled" {
  command = plan

  assert {
    condition     = aws_dynamodb_table.orders.server_side_encryption[0].enabled == true
    error_message = "server-side encryption is not enabled on aws_dynamodb_table.orders"
  }
}
