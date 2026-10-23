run "table_shape_unchanged" {
  command = plan

  assert {
    condition     = aws_dynamodb_table.orders.name == "checkout-orders" && aws_dynamodb_table.orders.hash_key == "order_id" && aws_dynamodb_table.orders.billing_mode == "PAY_PER_REQUEST"
    error_message = "the orders table's name, hash key, or billing mode changed; hardening must not alter the table's identity"
  }
}

run "pitr_enabled" {
  command = plan

  assert {
    condition     = aws_dynamodb_table.orders.point_in_time_recovery[0].enabled == true
    error_message = "point-in-time recovery is not enabled on aws_dynamodb_table.orders"
  }
}
