# Capstone Project: Ship Infrastructure Through a Propose-Verify-Approve-Apply Pipeline

In this project, you will run one real infrastructure change through a full pipeline: an
agent proposes it, Trivy, Checkov, and OPA verify it, a human approves it, and only then does
it apply for real. **The agent proposes, the pipeline decides.**

```
Spec+context → Agent generates → validate (fmt/plan)
  → Trivy + Checkov → OPA/Sentinel → Infracost → plan-diff review
     ↳ failures feed back to the agent
  → HUMAN APPROVAL  ← the only place apply is authorised
  → apply → observe + drift → reopens the spec
```

That diagram names every stage of the course thesis. Counted as things that can stop a
run, the lab's pipeline enforces **seven gates**: `fmt`, `validate`, Trivy, Checkov, the
OPA tags policy, the blast-radius gate, and human approval. Infracost is named where it
would sit and not enforced, because it needs an account this course does not assume.
`rubric.md` has the gate-by-gate table and where each one is implemented.

**What you're building, at a glance:**

- A storage and config module (S3 + DynamoDB) that fails the pipeline on purpose, then a
  fixed version that clears every gate
- A real human-approval gate: `apply` runs only from the saved plan a human approved, and
  refuses any other plan
- Real drift, introduced by hand against the emulated S3 API, caught on the next `plan`
- Kubernetes infrastructure reconciled onto a real `kind` cluster by Argo CD from the
  companion repository, unattended
- Optionally, the same pipeline run once against a real AWS account

See `rubric.md` for the full stage-by-stage mapping: what was built, and which module
taught it first. Or click through it interactively:
[Pipeline Tracer](explainer/sim/pipeline-tracer-sim.html), every stage, every module,
one screen.

## Stage 1: Run the pipeline against Floci (Tier 1, required)

`lab/tier1-floci/`: the full pipeline against a real Floci-backed AWS emulation. No
cloud account, no cost. You need Terraform, Trivy, Checkov, Conftest, `jq`, Docker, and
the AWS CLI (the drift step uses it; the run fails rather than skips without it).

```
cd lab/tier1-floci
./run.sh
```

`run.sh` starts Floci 1.7.0 with the Docker socket mounted and checks its health endpoint
before any plan is made. If port 4566 is already taken on your machine, set
`CAPSTONE_FLOCI_PORT` to a free port. It then runs thirteen numbered steps, and exits
non-zero if any one of them fails. Most of them are proofs that the pipeline refuses to
do something:

1. preflight: tools present, no leftover state
2. Floci up, socket mounted, health verified
3. the blast-radius gate rejects an empty file, invalid JSON, and JSON that is not a plan
4. the blast-radius gate blocks a delete, a six-resource plan, and an IAM role
5. the `starter` module is blocked: Trivy, Checkov and the tags policy all fail, for real
6. a copy of `solution` with one flag flipped (`block_public_acls = false`) is blocked
7. a run with Trivy missing from `PATH` stops at once with `required tool not found`
8. `solution` is blocked at human approval; `pipeline.sh apply` is refused with no record
9. `solution` passes once `CAPSTONE_HUMAN_APPROVED=1` is set; the plan's SHA-256 is recorded
10. `pipeline.sh apply` refuses a plan that changed after approval
11. real apply, from the approved saved plan only; the record is consumed; a second apply is refused
12. real drift, `put-bucket-versioning Suspended`, caught as `"Suspended" -> "Enabled"` on re-plan
13. numbered teardown: `terraform destroy`, remove Floci, clear pipeline state

The latest full run from a clean environment is captured, unedited, in
`lab/tier1-floci/evidence/`.

To walk the same path by hand instead of through `run.sh`, with Floci already running:

```
cd lab/tier1-floci
bash pipeline.sh starter
bash pipeline.sh solution
export CAPSTONE_HUMAN_APPROVED=1
bash pipeline.sh solution
bash pipeline.sh apply solution
aws --endpoint-url=http://localhost:4566 s3api put-bucket-versioning --bucket capstone-app-uploads --versioning-configuration Status=Suspended --region us-east-1
terraform -chdir=solution plan -no-color -input=false
terraform -chdir=solution destroy -auto-approve -no-color
```

**How the approval gate works, exactly.** `pipeline.sh solution` writes its plan to
`.pipeline/solution.tfplan`. When every mechanical gate has passed and
`CAPSTONE_HUMAN_APPROVED=1` is set, the approval gate writes the SHA-256 of that plan file
to `.pipeline/solution.approved.sha256`. `pipeline.sh apply solution` recomputes the hash
of the plan on disk, refuses if it differs from the record or if there is no record,
applies that saved plan and nothing else, then deletes the record. One approval, one
apply. The flag is a stand-in for a human reading the plan summary the gate prints; who
is allowed to run `pipeline.sh apply` at all is an organisational control (repository
permissions, CI environment protection, IAM) that sits outside a lab on one laptop.

**How failures stop the run.** A tool that cannot run stops the pipeline immediately. A
gate that runs and finds something records the failure, the remaining mechanical gates
still report their verdicts, the way a CI run shows every failed check at once, and the
run then stops before human approval with a non-zero exit. No failed run can be approved
or applied.

## Stage 2: Run the pipeline against a real cluster (Tier 2, required)

`lab/tier2-kubernetes/`: the same discipline on a real `kind` cluster: Crossplane v2,
and a real Argo CD reconciling the cluster, unattended, from a path in the companion
repository.

```
cd lab/tier2-kubernetes
./run.sh
```

What Argo CD watches, and where it came from, are two different repositories, and it is
worth being exact about which is which:

- **Canonical, what `run.sh` reconciles today:**
  `capstone/lab/pipeline-demo/xr.yaml` on the default branch of
  `PacktPublishing/The-AI-Driven-Infrastructure-as-Code-Handbook`. It landed in commit
  [`ce4eade`](https://github.com/PacktPublishing/The-AI-Driven-Infrastructure-as-Code-Handbook/commit/ce4eade)
  ("Add the capstone", 2026-10-06), and commit
  [`17cd144`](https://github.com/PacktPublishing/The-AI-Driven-Infrastructure-as-Code-Handbook/commit/17cd144)
  pointed `argocd-application.yaml` at that repository. The workflow
  `.github/workflows/capstone-tier2-demo.yml` there runs the same required-field check on
  any pull request that touches that path. No pull request has touched it yet, so that
  workflow has not run in the companion repository; the file arrived already fixed, in a
  direct commit.
- **Historical context, the CI-gated pull request itself:**
  [PR #3 on `schoolofdevops/310-agentic-iac-labs`](https://github.com/schoolofdevops/310-agentic-iac-labs/pull/3),
  the video course's own labs repository, merged 2026-09-01 as commit `0cadc64`. That is
  where the pull request failed real CI on a real missing field, was fixed, went green,
  and was merged, and it is the sequence Chapter 13's Tier 2 narrative and figure
  describe. The lab does not depend on it: `run.sh` step 1 checks the reference `xr.yaml`
  for the same required fields that CI check enforces.

Real, verified: Argo CD, pointed at the companion repository path, reached real
`Synced`/`Healthy` state and composed a real `ConfigMap` with the merged content.
Numbered teardown removes the Argo CD application and deletes the cluster.

## Stage 3: Run the pipeline against real AWS (Tier 3, optional)

`lab/tier3-aws-optional/`: the same pipeline, the same four resources (an S3 bucket, its
versioning, its public access block, a DynamoDB table), against a real AWS account.
There is no second pipeline there: Tier 1's `pipeline.sh` takes a path, so
`bash pipeline.sh ../tier3-aws-optional` runs the same gates, the same approval record
and the same `apply` rule against it. **Read `lab/tier3-aws-optional/README.md` before
running anything here.** It states three things you need to know before your first real
`apply`: a $5 budget alert, EKS's real cost, and a free-plan AWS account's lifecycle.
Never required to complete the capstone. `terraform destroy` is a numbered step in that
guide, not a footnote.

## Validation

Each stage above runs its own `run.sh`, and each one is the real proof that stage worked, not
a formality:

- Stage 1's `run.sh` proves the gate fails closed, blocks the starter module and a regressed
  copy of the solution, refuses apply without an approval for the exact plan, then applies,
  drifts, and destroys the solution module for real against Floci
- Stage 2's `run.sh` confirms Argo CD's real `Synced`/`Healthy` state on a real `kind`
  cluster, reconciled from the companion repository
- Stage 3, if you run it, ends in its own guide's numbered `terraform destroy`, confirmed
  against your real AWS account

Run all three (Stage 3 optional) before you consider the capstone done.

## Summary

What you built:

- One real spec, deliberately imperfect, run through Trivy, Checkov, and OPA
- A human-approval gate that records the exact plan a human approved, and an `apply` that
  refuses any other plan
- Real drift, introduced on purpose, caught by the pipeline on its own
- A real unattended GitOps apply on Kubernetes, from the companion repository
- Optionally, the same discipline proven once against a real AWS account, then torn down

Twelve modules, one pipeline, seven enforced gates. Every stage above is a real,
independent proof that "the agent proposes, the pipeline decides" holds up end to end, not
just per module.

## The closing exercise

Go back to `modules/module-01-clickops-to-agents/LAB.md`. Find the `notes.md` file
you wrote at the end of Lab 1, the three-line note on what you'd hand to a machine
without watching, what you'd still watch yourself, and why.

Open it again. Add a second, dated entry below your original one. After building
context (M03), a skill (M04), a live connection (M05), a real gate (M06), a spec
(M07), a full harness (M08), a real pipeline (M09), a real cluster (M10), a real
GitOps loop (M11), and a real stopping condition (M12):

- What changed about your answer?
- What's still true, word for word, from Lab 1?
- If it's the same split you wrote in Lab 1, why? If it moved, what specifically
  earned that move, not a general feeling that "the tools got better"?

There's no required answer. The point of the exercise was never to get the split
right the first time. It was to have something written down to compare against,
honestly, after doing the work that either does or doesn't justify moving it.
