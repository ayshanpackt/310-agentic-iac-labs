# Orders Table Production Readiness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Harden the checkout service's `checkout-orders` DynamoDB table with point-in-time recovery, server-side encryption on the AWS-managed key, and a read-only IAM policy, each change proven RED then GREEN by `terraform test`, then applied and destroyed against Floci.

**Architecture:** Two nested blocks are added to the existing `aws_dynamodb_table.orders` resource and the `actions` list of the existing `aws_iam_policy_document.orders_access` is narrowed. Each property gets its own plan-mode `terraform test` file in `tests/`, written and watched failing before the matching edit to `main.tf`. A final task runs every gate for real: all tests, checkov, apply, drift check, destroy, with every output captured to the lab's `evidence/` directory.

**Tech Stack:** Terraform >= 1.6 with `terraform test` (plan mode), AWS provider ~> 6.0, checkov, Floci 1.7.0 on `localhost:4566`.

**Spec:** `docs/superpowers/specs/2026-10-22-orders-table-production-readiness-design.md` (relative to `lab/orders/`). Read it first. All paths below are relative to `modules/module-08-harness-engineering/lab/orders/` unless they start with `../`.

## Global Constraints

- Terraform `>= 1.6`, AWS provider `~> 6.0`, pinned in `provider.tf`. Do not edit `provider.tf`.
- Table name `checkout-orders`, billing mode `PAY_PER_REQUEST`, hash key `order_id` of type `S` stay exactly as they are.
- Encryption is `server_side_encryption { enabled = true }` with **no** `kms_key_arn`. No KMS resources anywhere in the module.
- Policy actions are exactly, and only: `dynamodb:GetItem`, `dynamodb:BatchGetItem`, `dynamodb:Query`, `dynamodb:Scan`, `dynamodb:DescribeTable`. Resource stays `[aws_dynamodb_table.orders.arn]`.
- **No** `deletion_protection_enabled`, **no** `lifecycle { prevent_destroy }`. The lab destroys the table at the end.
- No tags, indexes, TTL, streams, autoscaling, or write-path policy.
- Every test is `command = plan`. Each property has its own `.tftest.hcl` file.
- Every "pass" or "fails for the right reason" claim in the executor's report must sit next to the captured command output. Capture goes to `../evidence/orders-<name>.txt` (designer's naming call; the lab's convention is `evidence/` with a stage prefix).
- The `# TODO: harden before this ships.` comment line is removed once the three changes land.
- Commits go on a branch, not `main`. Note: `lab/orders/` is currently untracked and `lab/.gitignore` ignores `docs/`, so the spec and this plan are not tracked. The author decides whether to lift that ignore; the plan does not.

## Review Focus

Failure modes the spec implies that the per-task tests would not catch on their own. Each has been pinned to a task below.

1. **A second IAM statement granting writes is added later.** A reader expects the policy to stay read-only as a whole, not just in its first statement. Pinned to Task 3: assert `length(statement) == 1`.
2. **A wildcard sneaks back as a pattern, e.g. `dynamodb:Get*`.** Exact-set equality against the five actions already rejects any extra or pattern element. Pinned to Task 3: the set-equality assert is the guard, plus an explicit "no `*` in any action" assert so the failure message names the problem.
3. **Someone "fixes" `CKV_AWS_119` by adding a `kms_key_arn`.** The attribute is computed, so plan mode cannot assert on it. Pinned to Task 4: the checkov step records `CKV_AWS_119` as an expected, accepted failure in the evidence, so a later run where it suddenly passes is a visible change.
4. **The table's identity drifts while hardening it (name, key, billing mode).** A reader expects the hardened table to be the same table. Pinned to Task 1: a `table_shape_unchanged` run block guarding `name`, `hash_key`, and `billing_mode`, placed in the PITR test file.
5. **Floci accepts the config at apply but silently ignores PITR or SSE.** Then `terraform plan` right after `apply` shows drift, and the "production-ready" claim rests on nothing. Pinned to Task 4: `terraform plan -detailed-exitcode` must exit 0 between apply and destroy, and `terraform state show` must read both flags back as `true`.

---

### Task 1: Point-in-time recovery, test first

**Files:**
- Create: `tests/pitr.tftest.hcl`
- Modify: `main.tf:3-12` (the `aws_dynamodb_table.orders` resource)

**Interfaces:**
- Consumes: nothing.
- Produces: `aws_dynamodb_table.orders` with a `point_in_time_recovery` block; the run block name `pitr_enabled` and test file name `tests/pitr.tftest.hcl`, referenced in Task 4.

- [ ] **Step 1: Branch, then initialise the module**

Run: `git switch -c m08-orders-hardening && terraform init -input=false -no-color`
Expected: `Switched to a new branch 'm08-orders-hardening'`, then `Terraform has been successfully initialized!` and a `.terraform.lock.hcl` pinning `hashicorp/aws` 6.x. The `.terraform/` directory and lock file are gitignored.

- [ ] **Step 2: Write the failing test**

`tests/pitr.tftest.hcl`, two run blocks, the regression guard first:

```hcl
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
```

- [ ] **Step 3: Run it and watch it fail for the right reason**

Run: `terraform test -no-color -filter=tests/pitr.tftest.hcl 2>&1 | tee ../evidence/orders-red-pitr.txt`
Expected: `run "table_shape_unchanged"... pass`, then `run "pitr_enabled"... fail` with `Error: Unknown condition value` naming `point_in_time_recovery[0].enabled`, and the summary `Failure! 1 passed, 1 failed.` The "unknown" error is the real RED here: the block is computed when absent from config. Any other error (syntax, provider, init) is not RED and must be fixed before continuing.

- [ ] **Step 4: Add the block to `main.tf`**

Inside `resource "aws_dynamodb_table" "orders"`, after the `attribute` block:

```hcl
  point_in_time_recovery {
    enabled = true
  }
```

- [ ] **Step 5: Run the test and watch it pass**

Run: `terraform fmt -check -no-color && terraform validate -no-color && terraform test -no-color -filter=tests/pitr.tftest.hcl 2>&1 | tee ../evidence/orders-green-pitr.txt`
Expected: `Success! The configuration is valid.` then `Success! 2 passed, 0 failed.`

- [ ] **Step 6: Commit**

```bash
git add main.tf tests/pitr.tftest.hcl
git commit -m "Enable point-in-time recovery on the checkout orders table"
```

---

### Task 2: Server-side encryption on the AWS-managed key, test first

**Files:**
- Create: `tests/sse.tftest.hcl`
- Modify: `main.tf` (the `aws_dynamodb_table.orders` resource, directly after the block Task 1 added)

**Interfaces:**
- Consumes: the resource as left by Task 1.
- Produces: `aws_dynamodb_table.orders` with a `server_side_encryption` block; run block `sse_enabled` in `tests/sse.tftest.hcl`, referenced in Task 4.

- [ ] **Step 1: Write the failing test**

`tests/sse.tftest.hcl`:

```hcl
run "sse_enabled" {
  command = plan

  assert {
    condition     = aws_dynamodb_table.orders.server_side_encryption[0].enabled == true
    error_message = "server-side encryption is not enabled on aws_dynamodb_table.orders"
  }
}
```

No assertion on `kms_key_arn`: it is computed and cannot be evaluated in plan mode (spec, Tests section).

- [ ] **Step 2: Run it and watch it fail for the right reason**

Run: `terraform test -no-color -filter=tests/sse.tftest.hcl 2>&1 | tee ../evidence/orders-red-sse.txt`
Expected: `run "sse_enabled"... fail` with `Error: Unknown condition value` naming `server_side_encryption[0].enabled`, summary `Failure! 0 passed, 1 failed.`

- [ ] **Step 3: Add the block to `main.tf`**

Directly after the `point_in_time_recovery` block:

```hcl
  server_side_encryption {
    enabled = true
  }
```

- [ ] **Step 4: Run the test and watch it pass**

Run: `terraform fmt -check -no-color && terraform validate -no-color && terraform test -no-color -filter=tests/sse.tftest.hcl 2>&1 | tee ../evidence/orders-green-sse.txt`
Expected: `Success! 1 passed, 0 failed.`

- [ ] **Step 5: Commit**

```bash
git add main.tf tests/sse.tftest.hcl
git commit -m "Enable server-side encryption on the checkout orders table"
```

---

### Task 3: Read-only access policy, test first

**Files:**
- Create: `tests/policy.tftest.hcl`
- Modify: `main.tf:1-2` (header comment) and `main.tf` `data "aws_iam_policy_document" "orders_access"` statement

**Interfaces:**
- Consumes: `data.aws_iam_policy_document.orders_access` as it exists today.
- Produces: the same data source with `actions` narrowed; run block `policy_is_read_only` in `tests/policy.tftest.hcl`, referenced in Task 4. `aws_iam_policy.orders_access` is untouched.

- [ ] **Step 1: Write the failing test**

`tests/policy.tftest.hcl`:

```hcl
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
```

Assert on `statement[0].actions`, not on the rendered `json`: `json` is unknown in plan mode because the data source depends on the table ARN (spec, Tests section).

- [ ] **Step 2: Run it and watch it fail for the right reason**

Run: `terraform test -no-color -filter=tests/policy.tftest.hcl 2>&1 | tee ../evidence/orders-red-policy.txt`
Expected: `run "policy_is_read_only"... fail`, a diff block showing actual `["dynamodb:*"]` against the five expected actions, the message `policy actions are not exactly the five read-only DynamoDB actions`, summary `Failure! 0 passed, 1 failed.` The statement-count assert passes; the wildcard assert also fails. Both failure messages appear.

- [ ] **Step 3: Narrow the policy and drop the TODO in `main.tf`**

Replace `actions   = ["dynamodb:*"]` with the five actions in the order listed in Global Constraints, one per line. Replace the two-line header comment with a single line: `# Orders storage for the checkout service: PITR on, SSE on, read-only service access.`

- [ ] **Step 4: Run the test and watch it pass**

Run: `terraform fmt -check -no-color && terraform validate -no-color && terraform test -no-color -filter=tests/policy.tftest.hcl 2>&1 | tee ../evidence/orders-green-policy.txt`
Expected: `Success! 1 passed, 0 failed.`

- [ ] **Step 5: Commit**

```bash
git add main.tf tests/policy.tftest.hcl
git commit -m "Narrow the checkout orders access policy to read-only actions"
```

---

### Task 4: Run every gate for real against Floci

**Files:**
- Create: `../evidence/orders-tests-all.txt`, `../evidence/orders-checkov.txt`, `../evidence/orders-apply.txt`, `../evidence/orders-state.txt`, `../evidence/orders-drift.txt`, `../evidence/orders-destroy.txt`
- Modify: nothing in `main.tf` or `tests/`. If a step here requires a code change, stop and report; do not edit.

**Interfaces:**
- Consumes: `tests/pitr.tftest.hcl`, `tests/sse.tftest.hcl`, `tests/policy.tftest.hcl` and the hardened `main.tf` from Tasks 1 to 3.
- Produces: the evidence files above and the final report.

- [ ] **Step 1: Confirm Floci is up**

Run: `curl -s -m 3 http://localhost:4566/_localstack/health | grep -o '"dynamodb":"[a-z]*"'`
Expected: `"dynamodb":"running"`. If not reachable, start it with the course's pinned command, `docker run -d --name floci -p 4566:4566 floci/floci:1.7.0`, and retry. Floci must be up for Steps 4 to 7; Steps 2 and 3 do not need it.

- [ ] **Step 2: Run the whole test suite**

Run: `terraform test -no-color 2>&1 | tee ../evidence/orders-tests-all.txt`
Expected: three files, each `pass`, summary `Success! 4 passed, 0 failed.` (two run blocks in `pitr`, one each in `sse` and `policy`).

- [ ] **Step 3: Run checkov and record the accepted finding**

Run: `checkov -d . --compact --quiet 2>&1 | tee ../evidence/orders-checkov.txt`
Expected: `Passed checks: 16, Failed checks: 1, Skipped checks: 0`. The one failure is `CKV_AWS_119: "Ensure DynamoDB Tables are encrypted using a KMS Customer Managed CMK"`. It is expected and accepted: the spec chose the AWS-managed key and a CMK is a non-goal. `CKV_AWS_28` (PITR), which failed before Task 1, must now be absent from the failures. Any other failure is a real finding to report.

- [ ] **Step 4: Apply against Floci**

Run: `terraform apply -auto-approve -no-color 2>&1 | tee ../evidence/orders-apply.txt`
Expected: `Apply complete! Resources: 2 added, 0 changed, 0 destroyed.` If Floci rejects PITR or SSE, follow the spec's fallback: keep the config, continue to Step 7 so destroy is still proven, and quote the apply error verbatim in the report.

- [ ] **Step 5: Read both flags back from Floci**

Run: `terraform state show -no-color aws_dynamodb_table.orders 2>&1 | tee ../evidence/orders-state.txt`
Expected: the output contains a `point_in_time_recovery` block with `enabled = true` and a `server_side_encryption` block with `enabled = true`, and `deletion_protection_enabled = false`.

- [ ] **Step 6: Prove there is no drift**

Run:

```bash
terraform plan -detailed-exitcode -no-color > ../evidence/orders-drift.txt 2>&1
echo "exit code: $?" | tee -a ../evidence/orders-drift.txt
cat ../evidence/orders-drift.txt
```

(Not a `tee` pipeline: `$?` after a pipe would report `tee`'s exit code, not Terraform's.)
Expected: `No changes. Your infrastructure matches the configuration.` and `exit code: 0`. Exit code 2 means Floci did not persist one of the flags; that is a finding, quoted verbatim, not something to paper over.

- [ ] **Step 7: Destroy**

Run: `terraform destroy -auto-approve -no-color 2>&1 | tee ../evidence/orders-destroy.txt`
Expected: `Destroy complete! Resources: 2 destroyed.` with no manual intervention and no deletion-protection error.

- [ ] **Step 8: Commit the evidence and report**

```bash
git add ../evidence/orders-*.txt
git commit -m "Capture RED/GREEN, checkov, apply, drift, and destroy evidence for the orders table"
```

The report lists, per gate, the evidence file and the one line from it that proves the result. A gate with no evidence file is reported as not run.
