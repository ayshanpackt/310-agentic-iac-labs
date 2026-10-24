# Capstone Spec: Storage and Config Layer for a Small Web App

## Intent

A small internal web app needs a storage and config layer: a place to keep uploaded
user files, and a place to keep per-environment config values the app reads at
startup. This is the same kind of ask M01's lab and M07's lab used, capstone-sized:
four real resources across two services, one deliberate gap for the pipeline to catch.

## Requirements

- FR-001: An S3 bucket for user-uploaded files, versioned, so a bad upload can be
  rolled back
- FR-002: The bucket blocks public access at the bucket level
- FR-003: A DynamoDB table for app config, one row per environment, on-demand billing
- FR-004: Every resource carries `Environment`, `Owner`, and `ManagedBy` tags
- FR-005: No credential or access key anywhere in the module as a `default`

## Constraints

- CN-001: `aws` provider pinned to `~> 6.0`, matching `labs/shared/floci-spike/provider.tf`
- CN-002: No resource in this module may be a delete-capable dependency of another
  module. This module stands alone
- CN-003: Total managed resource count stays at or below 5, the capstone's own
  blast-radius gate threshold (`MAX_RESOURCES=5` in `blast_radius_gate.sh`)

## Acceptance criteria

- SC-001: `terraform fmt -check` and `terraform validate` both pass
- SC-002: `checkov` reports zero failures on `CKV_AWS_21` (bucket versioning) and
  `CKV_AWS_53`/`CKV_AWS_54`/`CKV_AWS_55`/`CKV_AWS_56` (the four public access block
  settings), and zero `CKV_SECRET_*` findings. These six checks are the Checkov scope
  `pipeline.sh` enforces. An earlier draft of this spec named `CKV_AWS_18` here as
  the versioning check; that was wrong. `CKV_AWS_18` is bucket access logging, which
  would add a second bucket and push this module past CN-003, so it is out of scope,
  along with the other Checkov rules the full ruleset reports on this module (KMS
  encryption, point-in-time recovery, replication, lifecycle, event notifications).
  Out of scope is a recorded decision, not a pass: run `checkov -d solution` without
  the `--check` list to see every one of them
- SC-003: `trivy config` reports zero HIGH/CRITICAL findings, with exactly one
  exception, recorded in `lab/tier1-floci/.trivyignore`: `AVD-AWS-0132` (bucket not
  encrypted with a customer-managed KMS key). Fixing it would add a KMS key resource
  and push this module past CN-003. This is deliberate, the same honest-gap lesson M07
  and M08 taught: a scanner is a permanent gate, not a one-time checklist a spec can
  fully close. Every other HIGH/CRITICAL finding blocks the pipeline
- SC-004: The capstone's own OPA/Conftest policy (every resource has `Environment`,
  `Owner`, `ManagedBy`) passes
- SC-005: The blast-radius gate passes (no deletes, resource count at or below 5, no
  high-radius resource types)
- SC-006: A human approves the exact plan the gates produced (`CAPSTONE_HUMAN_APPROVED=1`
  records its SHA-256), `pipeline.sh apply` applies that saved plan against Floci, and
  `terraform destroy` leaves no orphaned state
