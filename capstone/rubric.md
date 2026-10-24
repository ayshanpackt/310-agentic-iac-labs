# Capstone rubric: the pipeline diagram, staged

Every stage of the course thesis pipeline, the one Module 1 states and every module
since has built one more piece of, mapped to what this capstone actually built and which
module taught it first.

```
Spec+context → Agent generates → validate (fmt/plan)
  → Trivy + Checkov → OPA/Sentinel → Infracost → plan-diff review
     ↳ failures feed back to the agent
  → HUMAN APPROVAL  ← the only place apply is authorised
  → apply → observe + drift → reopens the spec
```

## The seven enforced gates

A gate is something that can stop the run on its own. The diagram above has more boxes
than that, because it also names the steps that produce the thing the gates read
(spec, generation, plan) and the stages the pipeline names without enforcing. Counted
honestly, `lab/tier1-floci/pipeline.sh` enforces seven gates:

| # | Gate | Implemented in | Stops the run when |
|---|---|---|---|
| 1 | `terraform fmt -check` | `pipeline.sh` stage 1 | any file is not canonically formatted |
| 2 | `terraform validate` | `pipeline.sh` stage 1 | the module does not validate (or `init` fails) |
| 3 | Trivy, HIGH/CRITICAL | `pipeline.sh` stage 2, `--exit-code 1`, `.trivyignore` | any HIGH/CRITICAL finding other than the one recorded exception (SC-003) |
| 4 | Checkov, spec scope | `pipeline.sh` stage 3, `--check` list from `spec.md` SC-002 | any of the six spec'd checks fails |
| 5 | OPA/Conftest | `pipeline.sh` stage 4, `policy/tags.rego`, on the plan JSON | any taggable resource lacks `Environment`, `Owner`, `ManagedBy` |
| 6 | Blast radius | `pipeline.sh` stage 5, `blast_radius_gate.sh`, on the plan JSON | any delete, more than 5 changes, any high-radius type, or a plan file it cannot read |
| 7 | Human approval | `pipeline.sh` stage 7 | `CAPSTONE_HUMAN_APPROVED=1` is not set. When it is, the SHA-256 of the exact plan is recorded, and `pipeline.sh apply` refuses any other plan |

Not a gate, named on purpose: **Infracost** (stage 6) prints where it would sit and does
not enforce anything, because it needs an Infracost account this lab does not assume.
**Plan-diff review** is what the human reads at gate 7, not a separate mechanical check.

Tool errors are not findings. A scanner that is missing, crashes, or produces unreadable
output stops the pipeline immediately. A scanner that runs and finds something records the
failure, the remaining mechanical gates still report their verdicts, and the run then
stops before gate 7 with a non-zero exit. Nothing from a failed run can be approved or
applied. `run.sh` steps 3 to 10 prove each of those refusals, every run.

## Stage by stage

| Stage | Taught in | Built in the capstone as |
|---|---|---|
| Spec | M07 | `spec.md`, requirements/constraints/acceptance-criteria for the storage-and-config task |
| Context | M03 | `AGENTS.md` |
| Skill | M04 | `.claude/skills/capstone-conventions/SKILL.md` |
| Agent generates | M01, M02 | `lab/tier1-floci/starter/main.tf` and `solution/main.tf` |
| validate (fmt/plan) | M01 | Gates 1 and 2, stage 1 of `pipeline.sh`; the plan itself is produced in stage 4 and read by gates 5 and 6 |
| Trivy + Checkov | M09 | Gates 3 and 4, stages 2 and 3 of `pipeline.sh`, real findings on `starter`, real pass on `solution`'s own spec'd scope |
| OPA/Sentinel | M09 | Gate 5, stage 4, `policy/tags.rego`, real deny on `starter`, real pass on `solution` |
| plan-diff review / blast radius | M06 | Gate 6, stage 5, `blast_radius_gate.sh`; the plan summary is printed at gate 7 for the human to read |
| Infracost | M09 | Not enforced here (same honest gap M07/M08 reported: no non-interactive Infracost auth in this environment); stage 6 names where it would sit |
| HUMAN APPROVAL | M06, M11, M12 (step 4/5) | Gate 7, stage 7, `CAPSTONE_HUMAN_APPROVED=1`, records the approved plan's hash; the only thing that lets `pipeline.sh apply` run |
| apply | all Tier 1/2 modules | `pipeline.sh apply solution`: checks the approval record against the plan on disk, applies that saved plan only, consumes the record (`lab/tier1-floci/run.sh` step 11). Real Kubernetes apply via Argo CD from the companion repository (`lab/tier2-kubernetes/run.sh`) |
| observe + drift, reopens the spec | M10, M11, M12 | Real drift: `aws s3api put-bucket-versioning ... Suspended`, caught on the next `terraform plan` (`run.sh` step 12, required, the run fails without it); Argo CD's own self-heal loop, taught in M11, is the Kubernetes-side equivalent |
| MCP (context on demand) | M05 | Named in `AGENTS.md`/`README.md`; the same Terraform MCP server from M05 is available to the agent generating this module, optional, not required for the pipeline itself |
| Harness (assembled discipline) | M08 | The whole of `pipeline.sh` is the harness: skill + gates + human approval, assembled, not separate lessons |
| GitOps loop | M10, M11 | `lab/tier2-kubernetes/`: real `kind`, real Crossplane v2, real Argo CD reading `capstone/lab/pipeline-demo` from the companion repository, real Synced/Healthy state. The CI-gated pull request that first produced that file ran in the course's own labs repository; see `README.md` Stage 2 for which is which |
| Loop / step 6 | M12 | Not attempted here on purpose. The capstone runs step 4/5 (gated apply, then unattended reconcile after a human merge), the same ceiling M11/M12 taught as the safe default |

**Who may run `apply` is not something this lab can enforce.** The pipeline proves that an
apply cannot happen without an approval record for the exact plan. Restricting which people
or CI identities are allowed to run `pipeline.sh apply` at all (repository permissions,
CI environment protection, IAM) is an organisational control that sits outside a lab
that runs on one laptop.

**No stage on this list is untested prose.** Every row above that says "real" was run in
this environment and its output captured: `lab/tier1-floci/run.sh` (latest full run in
`lab/tier1-floci/evidence/`) and `lab/tier2-kubernetes/run.sh`, both of which exit non-zero
on any regression.
