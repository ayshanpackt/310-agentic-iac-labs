# Orders storage for the checkout service: PITR on, SSE on, read-only service access.
resource "aws_dynamodb_table" "orders" {
  name         = "checkout-orders"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "order_id"

  attribute {
    name = "order_id"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled = true
  }
}

data "aws_iam_policy_document" "orders_access" {
  statement {
    actions = [
      "dynamodb:GetItem",
      "dynamodb:BatchGetItem",
      "dynamodb:Query",
      "dynamodb:Scan",
      "dynamodb:DescribeTable",
    ]
    resources = [aws_dynamodb_table.orders.arn]
  }
}

resource "aws_iam_policy" "orders_access" {
  name   = "checkout-orders-access"
  policy = data.aws_iam_policy_document.orders_access.json
}
