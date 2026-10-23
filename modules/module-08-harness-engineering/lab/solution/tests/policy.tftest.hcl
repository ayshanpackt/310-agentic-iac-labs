run "policy_is_read_only" {
  command = plan

  assert {
    condition     = length(data.aws_iam_policy_document.orders_access.statement) == 1
    error_message = "the orders access policy must have exactly one statement"
  }

  assert {
    condition = data.aws_iam_policy_document.orders_access.statement[0].actions == toset([
      "dynamodb:GetItem",
      "dynamodb:BatchGetItem",
      "dynamodb:Query",
      "dynamodb:Scan",
      "dynamodb:DescribeTable",
    ])
    error_message = "policy actions are not exactly the five read-only DynamoDB actions"
  }

  assert {
    condition     = length([for a in data.aws_iam_policy_document.orders_access.statement[0].actions : a if strcontains(a, "*")]) == 0
    error_message = "policy actions must not contain a wildcard"
  }
}
