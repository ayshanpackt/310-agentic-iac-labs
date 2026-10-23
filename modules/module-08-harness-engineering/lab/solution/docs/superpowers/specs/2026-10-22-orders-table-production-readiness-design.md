# Design: production-ready orders table for the checkout service

Date: 2026-10-22
Scope: `modules/module-08-harness-engineering/lab/orders/` (`main.tf`, `tests/`)
Status: approved by the author, 2026-10-22

## Intent

`main.tf` defines the DynamoDB table the checkout service stores orders in. It was added in a
hurry before launch and carries a TODO to harden it. The table has no point-in-time recovery, no
explicit encryption setting, and an IAM policy that grants `dynamodb:*` on it.

This project closes those three gaps and nothing else. The module is a Tier-1 lab exercise: it
is applied against Floci (a local AWS emulator on `localhost:4566`) and destroyed at the end of
the lab, so it must stay cheap to apply and trivial to tear down.

## Goals

Three changes, as decided by the author:

1. **Point-in-time recovery on.** A bad deploy or bad write can be rolled back without a
   separate backup job.
2. **Server-side encryption on, using the AWS-managed key `aws/dynamodb`**
   (`server_side_encryption { enabled = true }`, no key ARN). No customer-managed key, no KMS
   resources, no key policy. Confirmed by the author on 2026-10-22.
3. **Access policy narrowed to read-only actions.** Exactly these five, no others:
   `dynamodb:GetItem`, `dynamodb:BatchGetItem`, `dynamodb:Query`, `dynamodb:Scan`,
   `dynamodb:DescribeTable`.

Success means: a test fails against the current `main.tf` for each of the three gaps, the same
test passes after the change, `terraform apply` and `terraform destroy` both succeed against
Floci, and the evidence for all of that is captured, not described.

## Non-goals

- **No deletion protection**, and no `prevent_destroy` lifecycle rule. The lab destroys the
  table at the end, and either one would turn that teardown into a two-step dance. This is an
  explicit author decision, not an oversight.
- No customer-managed KMS key, no key rotation, no alias.
- No write-path policy. The service's write access, if it needs one, is a separate concern that
  this project does not touch.
- No secondary indexes, no TTL, no streams, no autoscaling, no tags beyond what exists.
- No changes to `provider.tf`. It is the canonical Tier-1 stub shared across the course.

## Anti-goals

These would make the work a failure even if the three changes landed:

- A completion claim ("tests pass", "checkov is clean") without the real command output next to
  it. This module exists to teach verification before claiming.
- A test that passes before the fix. Each assertion must be watched failing for the right reason
  first (M08 Stage 2 discipline: RED before GREEN).
- Anything that breaks `terraform destroy -auto-approve` against Floci.
- Scope creep into "everything checkov knows about DynamoDB". The harness enforces what it was
  told to enforce (same lesson as M07's spec-scope).

## Constraints

- Terraform `>= 1.6`, AWS provider `~> 6.0`, as pinned in `provider.tf`.
- Apply and destroy run against Floci via the `endpoints {}` block in `provider.tf`. Whatever is
  built must be accepted by Floci's DynamoDB and IAM emulation. Do not assume real-AWS-only
  behaviour such as asynchronous PITR enablement.
- No new providers and no new external tools. `terraform`, `checkov`, and Floci are already in
  the lab environment.
- `tests/` is currently empty. Tests go there.

## The design

### Table (`aws_dynamodb_table.orders`)

Keep the table exactly as it is (name, billing mode, hash key, single `order_id` attribute) and
add two blocks:

```hcl
point_in_time_recovery {
  enabled = true
}

server_side_encryption {
  enabled = true
}
```

**Why `enabled = true`, resolved.** The AWS provider's
`server_side_encryption` block does not map one-to-one onto the console's key choices:

| HCL | Key DynamoDB uses | Console label |
|---|---|---|
| block absent, or `enabled = false` | AWS-owned key | DEFAULT |
| `enabled = true`, no `kms_key_arn` | AWS-managed key `aws/dynamodb` | KMS |
| `enabled = true` + `kms_key_arn` | customer-managed key | KMS, custom |

So the literal phrase "encryption on with the AWS-owned key" describes the table's current state
(DynamoDB always encrypts at rest, and the absent block already means the AWS-owned key). The
only change that is *visible* in HCL, in `terraform plan`, in `terraform test`, and to checkov
(`CKV_AWS_119`) is `enabled = true`, which selects the AWS-managed key `aws/dynamodb` instead.
Both are free to the account and neither needs a KMS resource in this module. The author chose
`enabled = true` (AWS-managed key) because that is the only reading under which there is
something to test RED then GREEN.

### Policy (`data.aws_iam_policy_document.orders_access`)

Replace `actions = ["dynamodb:*"]` with the five read-only actions, in this order so the diff
reads cleanly:

```hcl
actions = [
  "dynamodb:GetItem",
  "dynamodb:BatchGetItem",
  "dynamodb:Query",
  "dynamodb:Scan",
  "dynamodb:DescribeTable",
]
```

`resources` stays `[aws_dynamodb_table.orders.arn]`. There are no indexes, so no `/index/*` ARN
is needed. `aws_iam_policy.orders_access` is unchanged.

### Tests (`tests/*.tftest.hcl`)

Three `terraform test` files, plan-mode only (`command = plan`), so they run with no Floci and
no AWS account. One file per goal, because a failing `run` block makes `terraform test` skip the
remaining run blocks in the same file, and all three RED results must be observable at once.
Files are run independently, so three files give three independent verdicts:

1. `pitr_enabled`: `aws_dynamodb_table.orders.point_in_time_recovery[0].enabled == true`.
2. `sse_enabled`: `aws_dynamodb_table.orders.server_side_encryption[0].enabled == true`.
   No assertion on `kms_key_arn`: that attribute is computed, so it is unknown in plan mode and
   `terraform test` cannot evaluate a condition on it. The "no customer-managed key" rule is
   enforced by the non-goal and by review, not by this test.
3. `policy_is_read_only`: assert
   `data.aws_iam_policy_document.orders_access.statement[0].actions` equals exactly the set of
   five read-only actions, and that no element contains `*`. Do not decode the rendered `json`
   attribute: the data source depends on the table ARN, which is unknown before apply, so `json`
   is unknown in plan mode.

Each run block fails against today's `main.tf`. The first two fail with an "unknown condition
value" error, because both nested blocks are computed when absent from the config. The third
fails because `["dynamodb:*"]` is not the expected set. All three are real RED results. The
builder watches all three fail, with output captured, before touching `main.tf`.

### Verification sequence

The builder executes and captures, in this order:

1. `terraform init -input=false` in `orders/`.
2. `terraform test` against the unchanged `main.tf`. Expected: 3 failed. Capture output.
3. Edit `main.tf` as above.
4. `terraform fmt -check`, `terraform validate`, `terraform test`. Expected: 3 passed. Capture.
5. `checkov -d . --compact --quiet`. Before the change the module reports 15 passed, 2 failed
   (`CKV_AWS_28` PITR, `CKV_AWS_119` KMS CMK). After the change: 16 passed, 1 failed.
   `CKV_AWS_28` newly passes. `CKV_AWS_119` keeps failing, because it demands a
   customer-managed key and this design deliberately uses the AWS-managed key. That finding is
   reported honestly and left alone. Note that checkov never flagged `dynamodb:*`, so checkov
   is not the test for the policy change; `terraform test` is. (Numbers confirmed in a
   throwaway run on 2026-10-22 against the pinned provider and checkov on this machine.)
6. `terraform apply -auto-approve` then `terraform destroy -auto-approve` against Floci.
   Capture both. Destroy must succeed with no manual steps.

A step whose output is not captured did not happen.

**If Floci rejects PITR or SSE at apply time.** Nothing in the course has yet exercised
DynamoDB continuous backups or `SSESpecification` against Floci 1.7.0, and PITR is a second API
call after `CreateTable`. If either is rejected, the builder keeps the HCL and the tests as
designed, runs `destroy` to confirm the partial table still tears down, and records the apply
error verbatim as a finding for the author. The builder does not silently drop the feature from
the config to make apply go green. (Designer's call; the author may prefer to treat it as a
blocker instead.)

## What is left to the builder

- Exact wording of test assertion `error_message` strings.
- Whether to keep the two-line header comment in `main.tf` or replace it with one line that
  states the hardened posture. Either is fine; the TODO line must go.
- Where to save the captured outputs. The lab's convention is `lab/evidence/`, named by stage.

## Decisions made by the designer, for the author to check

- Tests are plan-mode `terraform test`, not shell scripts around checkov, because the three
  properties are all visible in the plan and the test needs no running emulator. Checkov runs as a
  secondary gate, not as the test.
- Action order in the policy follows the author's list verbatim.
- The `kms_key_arn` guard was dropped from the encryption test after a builder review showed it
  cannot evaluate in plan mode (computed attribute). The non-goal carries that rule instead.
- A Floci rejection of PITR or SSE at apply time is recorded as a finding, not worked around.
