# Tier 3, Optional: the same pipeline against a real AWS account

**This part is optional. Nothing in the capstone requires it. Tier 1 (Floci) and Tier 2
(kind + Crossplane v2 + Argo CD) already exercise every stage of the pipeline for
real, at zero cost.** Run this only if you want the extra step of seeing the exact
same discipline hold up against a real cloud account, and only after reading the
three things below.

## Before you touch a real AWS account

**1. Set a billing/budget alert at $5.** Before you type a single `terraform apply`
against real AWS, go to Billing → Budgets in the AWS console and create a budget
alert at **$5**. This is not optional caution, it is the first numbered step. A
misconfigured resource left running can cost real money before you notice.

**2. Know the real cost of what you're about to run.** This module provisions exactly
four resources across two services: an S3 bucket, its versioning configuration, its
public access block, and a DynamoDB table on on-demand billing. No EC2 instance, no
Kubernetes. A short-lived run of those four sits inside the AWS free tier or costs a
fraction of a cent. **Do not extend this to EKS for the capstone.** An EKS control
plane costs **≈$73/month, with no free tier**, regardless of how small the workload
running on it is. If you want to see this course's Kubernetes material against a real
cluster, that is a separate, deliberate decision outside the capstone, not a default
extension of this exercise.

**3. Know your account's lifecycle.** A new AWS free-plan account **auto-closes
after 6 months or when its credits run out**, with a **90-day recovery window**
after closure. If you're running this months after creating a learner AWS account,
check your account status first.

## What this directory contains

One file, `main.tf`. It holds the provider block, the `config_api_key` sensitive
variable (no default, set via `TF_VAR_config_api_key`), the tags local, and the same
four resources as the Tier 1 `solution` module: `aws_s3_bucket.uploads`,
`aws_s3_bucket_versioning.uploads`, `aws_s3_bucket_public_access_block.uploads`, and
`aws_dynamodb_table.config`. The only differences from Tier 1 are the Floci
`endpoints {}` block, removed, and the resource names, suffixed `-tier3` so they cannot
collide with anything the emulator run left behind. There is no separate
`variables.tf`; the variable lives in `main.tf`.

There is no second copy of the pipeline here, on purpose. Tier 1's `pipeline.sh`
accepts a path, so the same script, the same `.trivyignore`, the same `policy/tags.rego`,
the same blast-radius gate and the same approval record run against this directory
unchanged. One pipeline, two targets.

## Numbered steps, if you choose to run this

1. Set the $5 budget alert (above), if you haven't already
2. `aws configure` with a real IAM user that has least-privilege access to S3 and
   DynamoDB only, not an account root key
3. Run the gates. From `capstone/lab/tier1-floci`:

   ```
   cd ../tier1-floci
   bash pipeline.sh ../tier3-aws-optional
   ```

   Stages 1 to 6 run exactly as they do for Tier 1. The plan is made against your real
   account, so this step needs your credentials. Expect the run to stop at stage 7 with
   `not approved`. That is the gate working
4. Read the plan summary the pipeline printed. It should say `4 to add, 0 to change,
   0 to destroy` and nothing else. If it says anything else, stop here
5. Approve that exact plan, and run the gates once more so the approval is recorded
   against it:

   ```
   export CAPSTONE_HUMAN_APPROVED=1
   bash pipeline.sh ../tier3-aws-optional
   ```

6. Apply the approved saved plan, and only that plan:

   ```
   bash pipeline.sh apply ../tier3-aws-optional
   ```

   The apply refuses to run if the plan on disk differs from the one approved in step 5
7. Confirm the bucket and the table exist in the real AWS console
8. **`terraform destroy`**: the closing step, not a footnote:

   ```
   terraform -chdir=../tier3-aws-optional destroy
   ```

   Confirm in the AWS console that the bucket and the table are actually gone before
   you close this out

## What the pipeline can and cannot enforce here

The approval record proves that no apply happens without a human approving the exact
plan. It does not decide **who** is allowed to run `pipeline.sh apply` in the first
place. Against a real account, that is an organisational control: an IAM identity that
can plan but not apply, a CI environment with required reviewers, repository
permissions. Those sit outside this lab and outside this README.

## What was never done for you

This directory's Terraform was written and validated for correct syntax (`terraform
fmt`/`validate` against the real `aws` provider, with `skip_credentials_validation`
disabled so it genuinely requires real credentials) but **was never applied against
a real AWS account** while building this course. Every dollar this section might
cost is yours to decide to spend, not something the course spent on your behalf.
