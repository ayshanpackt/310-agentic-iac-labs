# Project 12: Build a Self-Healing Compliance Loop With a GitHub Actions Trigger

**Tier 0** · ~20 min · no cloud, no cluster, no new account. Reuses the same small Terraform
module from Project 01, this time run under a loop instead of by hand.

In this project, you will build a small unattended loop: a script that checks one exact
condition, fixes it if it isn't met, does nothing once it already is, and refuses to touch
anything when one of its own tools fails. Then you will write the GitHub Actions workflow that
would run it on a schedule, and validate that workflow the same way you validated the loop.

**What you're building, at a glance:**

- A stopping-condition script that checks exactly one thing: does `checkov` exit 0
- A real fix, applied automatically the moment the condition isn't met: a hardcoded secret
  pulled out of a Terraform variable
- Three real runs against the same working copy, three different outcomes: continue-and-fix,
  stop, stay stopped
- A fourth run where `terraform init` fails on purpose, proving the loop exits without a
  verdict and leaves `main.tf` byte-identical
- A GitHub Actions `schedule:` workflow, linted with `actionlint`, kept as a design example
  that runs on `workflow_dispatch` and is not enabled in the companion repository
- A FinOps gate that checks resource count, tags, and instance type straight from
  `terraform show -json`, walks nested modules, refuses a plan it cannot read, and has its own
  unit tests, no Infracost API key required

## Pre Requisites

- `terraform` and `checkov`, same as every earlier Tier 0/1 project in this course
- `python3` and `PyYAML` (installed per Environment Setup) to validate the trigger config
- `actionlint` is optional. `brew install actionlint` on a Mac. If it is missing, `run.sh`
  skips that one check and says so

## The starter module

`file: modules/module-12-loop-multiagent-economics/lab/starter/main.tf`
```
terraform {
  required_providers {
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

variable "log_shipper_key" {
  description = "AWS key for the sidecar that ships access logs to S3"
  type        = string
  default     = "AKIAABCDEFGHIJKLMNOP"
}

resource "local_file" "log_shipper_env" {
  filename = "${path.module}/rendered/log-shipper.env"
  content  = "AWS_ACCESS_KEY_ID=${var.log_shipper_key}\n"
}
```

Same starter as Project 01's, the same hardcoded key, on purpose. This time you are not fixing
it by hand. You are writing a loop that fixes it.

## Step 1: Write the stopping condition

A real stopping condition is a script that answers exactly one question: has the target state
been reached, yes or no, checkably. It also has to know when it cannot answer. Here's the
whole thing:

`file: lab/solution/loop.sh`
```
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="${1:-$HERE/work}"

# Exit codes, one meaning each:
#   0  STOPPED   stopping condition met, nothing to do
#   1  CONTINUE  stopping condition not met, the fix was applied, re-trigger
#   2  ERROR     a tool failed or is missing, so there is no verdict and main.tf is untouched
die() { echo "ERROR: $*" >&2; exit 2; }

for tool in terraform checkov python3; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool not on PATH, cannot evaluate the stopping condition"
done

if [ ! -d "$WORK_DIR" ]; then
  cp -r "$HERE/../starter" "$WORK_DIR"
fi

cd "$WORK_DIR"
[ -f main.tf ] || die "no main.tf in $WORK_DIR, nothing to check"
terraform init -backend=false -input=false -no-color >/dev/null 2>&1 \
  || die "terraform init failed in $WORK_DIR, cannot evaluate the stopping condition"
terraform validate -no-color >/dev/null 2>&1 \
  || die "terraform validate failed in $WORK_DIR, cannot evaluate the stopping condition"

CHECKOV_OUT=$(checkov -d . --compact --quiet 2>&1)
CHECKOV_CODE=$?

if [ "$CHECKOV_CODE" -eq 0 ]; then
  echo "STOPPED: stopping condition met, checkov exits 0"
  exit 0
fi

# checkov exits 1 only for failed checks. Any other code, or a 1 with no failed
# check in the output, is a scanner problem, not a verdict on main.tf.
if [ "$CHECKOV_CODE" -ne 1 ] || ! echo "$CHECKOV_OUT" | grep -q "FAILED for resource"; then
  die "checkov exited $CHECKOV_CODE without a verdict: $(echo "$CHECKOV_OUT" | tail -1)"
fi

echo "CONTINUE: stopping condition not met yet, checkov still failing"
```

Read the check. `checkov -d .` on the current working copy, and its exit code, nothing else. An
exit code either is 0 or it isn't. A human deciding something "looks done" doesn't enter into it.

Now read what sits around the check. Three exit codes, one meaning each. The tools are
confirmed on `PATH` before anything runs. `terraform init` and `terraform validate` have to
succeed before `checkov` is even asked, because a scanner pointed at a directory it cannot
parse has nothing to say about that directory. Any one of those failing ends the run with exit
code 2 and no verdict. A missing tool is a reason to stop and tell a human. It is never a reason
to edit `main.tf`.

**Run it once**, from a fresh copy:

```
bash lab/solution/loop.sh /tmp/m12-try
```

`[ Expected output ]`
```
CONTINUE: stopping condition not met yet, checkov still failing
```

Exactly what you'd expect. The starter still has the hardcoded key. The loop noticed, and said
so, in a form a machine can act on.

## Step 2: Give the loop something to do when it continues

A loop that only reports "not done yet" needs something to act on that report. In a real setup
that's an agent, gated by the plan-review-approve-apply harness M06 built. For this project,
wire in the exact fix you already know from Project 01, real code, applied for real when the
condition isn't met:

`edit file: lab/solution/loop.sh`
```
echo "CONTINUE: stopping condition not met yet, checkov still failing"
if grep -q 'default     = "AKIA' main.tf 2>/dev/null; then
  python3 -c "
h = open('main.tf').read()
h = h.replace('  default     = \"AKIAABCDEFGHIJKLMNOP\"\n', '  sensitive   = true\n')
open('main.tf','w').write(h)
"
  echo "  (applied the real fix: pulled the hardcoded key, marked the variable sensitive)"
fi
exit 1
```

The fix sits after every tool check and after the verdict. The script can only reach this
block once `checkov` has run to completion and reported a failed check. There is no path from
"a tool broke" to "edit the file".

## Step 3: Run it three times, watch it change state each time

The same command you already ran, run again against the **same** working copy this time,
`solution/work` instead of a throwaway `/tmp` path:

```
rm -rf lab/solution/work
bash lab/solution/loop.sh lab/solution/work
```

`[ Expected output ]`
```
CONTINUE: stopping condition not met yet, checkov still failing
  (applied the real fix: pulled the hardcoded key, marked the variable sensitive)
```

Run **the exact same command again**, no other change:

```
bash lab/solution/loop.sh lab/solution/work
```

`[ Expected output ]`
```
STOPPED: stopping condition met, checkov exits 0
```

Run it a **third** time:

```
bash lab/solution/loop.sh lab/solution/work
```

`[ Expected output ]`
```
STOPPED: stopping condition met, checkov exits 0
```

Same command, three real runs, three different outcomes: continue-and-fix, stop, stop-again.
That third run is the one people forget to test. A trigger that fires after the work is already
done should notice that immediately and do nothing, not re-run the fix, not error out.
`echo $?` after each run: `1`, then `0`, then `0`.

## Step 4: Break a tool, prove the loop keeps its hands off main.tf

A loop that runs unattended will, sooner or later, run on a night when a tool is broken: a
provider registry is down, a scanner upgrade changed its exit codes, a runner image lost a
binary. The question is what the loop does on that night. Prove the answer. Copy the starter,
break the provider block so `terraform init` cannot succeed, and record a checksum of
`main.tf` before the run:

```
rm -rf /tmp/m12-broken
cp -r lab/starter /tmp/m12-broken
sed -i.bak 's#hashicorp/local#hashicorp/no-such-provider-m12#' /tmp/m12-broken/main.tf
shasum -a 256 /tmp/m12-broken/main.tf
bash lab/solution/loop.sh /tmp/m12-broken; echo "exit $?"
shasum -a 256 /tmp/m12-broken/main.tf
```

`[ Expected output ]`
```
6edfa1da7fe7e4bb4d4f489089eff16b23ac01bbfc53986552181aa7d2d7281b  /tmp/m12-broken/main.tf
ERROR: terraform init failed in /tmp/m12-broken, cannot evaluate the stopping condition
exit 2
6edfa1da7fe7e4bb4d4f489089eff16b23ac01bbfc53986552181aa7d2d7281b  /tmp/m12-broken/main.tf
```

Exit code 2, no `CONTINUE`, no `STOPPED`, and the two checksums match. The hardcoded key is
still in the file, because the loop never earned the right to remove it. `run.sh` repeats this
with two more broken tools: a `PATH` that has no `checkov` on it, and a `checkov` that crashes
mid-scan. All three leave `main.tf` byte-identical.

## Step 5: Write the trigger as a design example

The loop only runs when something re-invokes it. Here is a complete GitHub Actions workflow
that would do that nightly. Read the comment at the top before anything else: this file is a
**design example**. It is not installed under `.github/workflows/` in the companion
repository, so nothing runs on its schedule there. To run it, copy it into
`.github/workflows/` of a repository with the same layout and fire it by hand from the Actions
tab, which is what `workflow_dispatch` is for.

`file: lab/solution/trigger-workflow.example.yml`
```
# Design example. This file is NOT installed under .github/workflows/ in the
# companion repository, so nothing runs on the schedule below. To try it, copy
# it to .github/workflows/ in a repository with the same layout and run it by
# hand from the Actions tab (workflow_dispatch). The schedule line shows what a
# nightly trigger looks like; it only takes effect once the file is installed.
#
# Paths are relative to the companion repository root.
name: m12-loop-trigger-example

on:
  workflow_dispatch: {}
  schedule:
    - cron: "0 2 * * *"

permissions:
  contents: read

env:
  LOOP: modules/module-12-loop-multiagent-economics/lab/solution/loop.sh
  WORK: m12-work

jobs:
  run-loop:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: 1.14.8
          terraform_wrapper: false

      - uses: actions/setup-python@v5
        with:
          python-version: "3.12"

      - name: install checkov, pinned
        run: pip install checkov==3.3.30

      # Cross-run state. The loop's state is its working copy. The first run copies
      # the starter module; every later run restores the copy the previous run
      # left behind, so run 2 sees the fix run 1 applied. restore-keys matches the
      # newest cache whose key starts with the prefix; the exact key is unique per
      # run so the post-job save always writes a fresh snapshot.
      - name: restore the working copy from the previous run
        uses: actions/cache@v4
        with:
          path: ${{ env.WORK }}
          key: m12-work-${{ github.run_id }}
          restore-keys: |
            m12-work-

      - name: run the stopping-condition loop once
        shell: bash
        run: |
          set +e
          bash "$LOOP" "$GITHUB_WORKSPACE/$WORK"
          code=$?
          case "$code" in
            0) echo "::notice::STOPPED, stopping condition met, nothing to do" ;;
            1) echo "::notice::CONTINUE, fix applied, the next trigger re-checks" ;;
            *) echo "::error::loop exited $code without a verdict, escalate to a human"
               exit 1 ;;
          esac
```

Four things to notice, each one a question the loop itself already answered:

- `0 2 * * *`, every night at two in the morning, with `workflow_dispatch` alongside it, so you
  can fire the loop by hand while testing, without waiting for 2am to prove it works.
- The tool install steps pin exact versions. A nightly job that pulls `latest` will one day run
  a different scanner from the one you tested.
- The working copy is the loop's state, and `actions/cache` carries it from one run to the next.
  Without that step, every night would start from the starter again, re-apply the fix, and
  print `CONTINUE` forever.
- Only exit code 2 turns the job red. `CONTINUE` and `STOPPED` are the loop doing its job. A
  tool failure is the exception a human needs to hear about.

Lint it the way the loop was tested, with a tool that fails on a real mistake:

```
actionlint lab/solution/trigger-workflow.example.yml && echo "actionlint clean"
```

`[ Expected output ]`
```
actionlint clean
```

## Step 6: Wire a FinOps gate

The pipeline in Module 9 ran Trivy, Checkov, and OPA against the plan before anything applied.
This step adds one more deterministic check to that same family: a FinOps gate. It reads
`terraform show -json` directly and fails on three things: too many resources, missing required
tags, and an instance type outside an allowed list. No Infracost API key, no account, no live
pricing lookup. It checks policy against a plan you already have on disk, not cost.

`file: lab/finops/gate.py`
```
#!/usr/bin/env python3
"""FinOps gate: fails on resource-count, tag, or instance-type violations, read
straight from `terraform show -json`. No Infracost API key required, this checks
policy, not live pricing.

Exit codes: 0 within policy, 1 policy violations, 2 the file is not a plan the
gate can evaluate (missing, unreadable, or not `terraform show -json` output).
A plan the gate cannot read is never a pass."""
import json
import sys

MAX_RESOURCES = 10
REQUIRED_TAGS = ["Environment", "Owner", "ManagedBy"]
ALLOWED_INSTANCE_TYPES = {"t3.micro", "t3.small", "t3.medium"}
# Resource types from these providers must carry the required tags. A local_file
# or null_resource has no tags field by design and is not a FinOps violation.
TAGGED_TYPE_PREFIXES = ("aws_",)


class PlanError(Exception):
    """The file is not a `terraform show -json` plan the gate can evaluate."""


def load_plan(plan_path):
    try:
        with open(plan_path, encoding="utf-8") as fh:
            plan = json.load(fh)
    except FileNotFoundError:
        raise PlanError(f"file not found: {plan_path}")
    except (OSError, ValueError) as exc:
        raise PlanError(f"not valid JSON: {plan_path}: {exc}")
    if not isinstance(plan, dict):
        raise PlanError("top level is not an object")
    if not isinstance(plan.get("format_version"), str):
        raise PlanError("missing format_version, not terraform show -json output")
    planned = plan.get("planned_values")
    if not isinstance(planned, dict):
        raise PlanError("missing planned_values")
    root = planned.get("root_module")
    if not isinstance(root, dict):
        raise PlanError("missing planned_values.root_module")
    return root


def walk_resources(module):
    """Yield every managed resource in this module and, recursively, its child modules."""
    resources = module.get("resources") or []
    if not isinstance(resources, list):
        raise PlanError("resources is not a list")
    for r in resources:
        if not isinstance(r, dict) or "address" not in r or "type" not in r:
            raise PlanError("resource entry missing address or type")
        if r.get("mode", "managed") == "managed":
            yield r
    children = module.get("child_modules") or []
    if not isinstance(children, list):
        raise PlanError("child_modules is not a list")
    for child in children:
        if not isinstance(child, dict):
            raise PlanError("child module entry is not an object")
        yield from walk_resources(child)


def check(plan_path):
    root = load_plan(plan_path)
    resources = list(walk_resources(root))
    violations = []
    if len(resources) > MAX_RESOURCES:
        violations.append(f"resource count {len(resources)} exceeds max {MAX_RESOURCES}")
    for r in resources:
        values = r.get("values") or {}
        if not isinstance(values, dict):
            raise PlanError(f"{r['address']}: values is not an object")
        if r["type"].startswith(TAGGED_TYPE_PREFIXES):
            # tags_all carries provider default_tags merged in; fall back to tags.
            # A missing field means no tags at all, which fails every required tag.
            tags = values.get("tags_all") or values.get("tags") or {}
            missing = [t for t in REQUIRED_TAGS if t not in tags]
            if missing:
                violations.append(f"{r['address']}: missing tags {missing}")
        instance_type = values.get("instance_type")
        if instance_type and instance_type not in ALLOWED_INSTANCE_TYPES:
            violations.append(
                f"{r['address']}: instance_type {instance_type} not in {sorted(ALLOWED_INSTANCE_TYPES)}"
            )
    return violations


def main():
    if len(sys.argv) != 2:
        print("usage: gate.py <path-to-terraform-plan-json>", file=sys.stderr)
        return 2

    try:
        violations = check(sys.argv[1])
    except PlanError as exc:
        print(f"FINOPS GATE ERROR: cannot evaluate {sys.argv[1]}: {exc}")
        return 2
    if violations:
        print("FINOPS GATE FAILED:")
        for v in violations:
            print(" -", v)
        return 1
    print(f"FinOps gate passed: {sys.argv[1]} within policy.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

Three decisions in that file are the ones a reviewer will ask about, so read them before
running it:

- **A plan the gate cannot read is an error, never a pass.** `load_plan` insists on
  `format_version` and `planned_values.root_module`, the two fields every `terraform show
  -json` plan carries. An empty file, a `{}`, or a plan with the wrong top-level structure
  exits 2 with `FINOPS GATE ERROR`, the same "no verdict" code the loop uses.
- **Nested modules count.** `walk_resources` recurses into `child_modules`, so a resource that
  lives three modules deep is counted against `MAX_RESOURCES` and checked for tags with its full
  `module.a.module.b.` address. The old version only looked at the root module.
- **A missing `tags` field is missing tags.** For any `aws_` resource, no `tags` field means
  no tags at all, and all three required tags are reported missing. A `local_file` carries no
  tags by design, so the rule is keyed on the resource type, not on whether the field happens
  to be present.

This module's own starter is Tier 0, `local_file` only, no `tags`, no `instance_type`. Proving
the tag and instance-type dimensions needs a resource type that actually carries those fields, so
those two dimensions run here against illustrative fixtures, each a real
`terraform show -json` plan for `aws_instance` resources.

`file: lab/finops/plan-over-budget.json`
```json
{
  "format_version": "1.2",
  "planned_values": {
    "root_module": {
      "resources": [
        {
          "address": "aws_instance.worker[0]",
          "type": "aws_instance",
          "values": {
            "instance_type": "m5.24xlarge",
            "tags": {"Environment": "lab"}
          }
        },
        {
          "address": "aws_instance.worker[1]",
          "type": "aws_instance",
          "values": {
            "instance_type": "t3.micro",
            "tags": {"Environment": "lab", "Owner": "m12-lab", "ManagedBy": "loop-agent"}
          }
        }
      ]
    }
  }
}
```

`worker[0]` seeds two real violations: an instance type outside the allowed set, and missing
`Owner`/`ManagedBy` tags. Run the gate against it:

```
cd modules/module-12-loop-multiagent-economics/lab
python3 finops/gate.py finops/plan-over-budget.json
```

`[ Expected output ]`
```
FINOPS GATE FAILED:
 - aws_instance.worker[0]: missing tags ['Owner', 'ManagedBy']
 - aws_instance.worker[0]: instance_type m5.24xlarge not in ['t3.medium', 't3.micro', 't3.small']
```

Exit code 1, both violations printed, both true. Now the fixed fixture:

`file: lab/finops/plan-in-budget.json`
```json
{
  "format_version": "1.2",
  "planned_values": {
    "root_module": {
      "resources": [
        {
          "address": "aws_instance.worker[0]",
          "type": "aws_instance",
          "values": {
            "instance_type": "t3.small",
            "tags": {"Environment": "lab", "Owner": "m12-lab", "ManagedBy": "loop-agent"}
          }
        },
        {
          "address": "aws_instance.worker[1]",
          "type": "aws_instance",
          "values": {
            "instance_type": "t3.micro",
            "tags": {"Environment": "lab", "Owner": "m12-lab", "ManagedBy": "loop-agent"}
          }
        }
      ]
    }
  }
}
```

```
python3 finops/gate.py finops/plan-in-budget.json
```

`[ Expected output ]`
```
FinOps gate passed: finops/plan-in-budget.json within policy.
```

Now the two cases a gate is most often wrong about. First, a plan that is not a plan at all.
`plan-empty.json` is the two characters `{}`:

```
python3 finops/gate.py finops/plan-empty.json; echo "exit $?"
```

`[ Expected output ]`
```
FINOPS GATE ERROR: cannot evaluate finops/plan-empty.json: missing format_version, not terraform show -json output
exit 2
```

Second, a violation hidden inside a child module. `plan-nested.json` has a clean
`aws_instance.bastion` at the root, and inside `module.workers` an `m5.24xlarge` with no `tags`
field at all, plus a correctly tagged bucket one module deeper:

```
python3 finops/gate.py finops/plan-nested.json; echo "exit $?"
```

`[ Expected output ]`
```
FINOPS GATE FAILED:
 - module.workers.aws_instance.worker[0]: missing tags ['Environment', 'Owner', 'ManagedBy']
 - module.workers.aws_instance.worker[0]: instance_type m5.24xlarge not in ['t3.medium', 't3.micro', 't3.small']
exit 1
```

The full address, all three tags reported missing because the field was absent, and the
tagged bucket two levels down raised nothing. The gate's unit tests in `finops/test_gate.py`
cover those cases and more: invalid JSON, a missing file, a missing `root_module`, eleven
resources spread across two nested modules, `tags_all` from provider `default_tags`, data
sources not counting as resources, and both fixtures above behaving as printed.

```
python3 finops/test_gate.py
```

`[ Expected output ]`
```
...............
----------------------------------------------------------------------
Ran 15 tests in 0.249s

OK
```

Now run the resource-count dimension for real, against this module's own real plan. The tag and
instance-type dimensions stay illustrative, this module has neither field to check, but resource
count applies to any resource type, so this is the one dimension proven against a real plan:

```
cd starter
terraform init -backend=false -input=false
terraform plan -out=tfplan.bin
terraform show -json tfplan.bin > ../finops/plan-real.json
cd ..
python3 finops/gate.py finops/plan-real.json
```

`[ Expected output ]`
```
FinOps gate passed: finops/plan-real.json within policy.
```

Real result, captured for real: `terraform plan` here shows `Plan: 1 to add, 0 to change, 0 to
destroy`, one `local_file.log_shipper_env` resource, well under `MAX_RESOURCES`. That resource
has no `tags`/`instance_type` fields, and `local_file` is not an `aws_` type, so the other two
dimensions have nothing to flag. That's expected and correct, not a gap in the gate. Those two
dimensions were already proven against the fixtures above.

#### Exercise

Write the two-line escalation note this module's reading asked for:

- If this loop ran every night for a month and never once printed `STOPPED`, who finds out, and
  how fast?
- What's the one thing that would tell you the stopping condition itself is broken, not just
  slow?

There's no wrong answer. Keep the note, the capstone asks you to compare it against your own
answer from Project 01's exercise.

## Validation

Run the full check yourself, all three loop outcomes, the three tool-failure runs, the trigger
config, and the FinOps gate:

```
cd modules/module-12-loop-multiagent-economics/lab
./run.sh
```

`run.sh` checks:

- The trigger config is a real, valid cron expression with `workflow_dispatch` alongside it,
  its `LOOP` path resolves to a file in this repository, and `actionlint` passes it (skipped
  with a message if `actionlint` is not installed)
- Run 1 prints `CONTINUE` and applies the real fix
- Run 2, same working copy, prints `STOPPED`
- Run 3, same working copy again, is still `STOPPED`, proving the loop is idempotent
- With no `checkov` on `PATH`, with a broken provider block, and with a `checkov` that
  crashes: exit code 2, no verdict printed, `main.tf` byte-identical before and after
- The FinOps gate rejects `plan-over-budget.json`, accepts `plan-in-budget.json`, refuses
  `plan-empty.json` with exit 2, and reports the child-module violation in `plan-nested.json`
- The gate's 15 unit tests pass

## Summary

What you built:

- A stopping-condition script with exactly one checkable question: does `checkov` exit 0
- A real fix, applied automatically, not by hand, and only after every tool it depends on has
  run to completion
- Three real runs proving three states: continue-and-fix, stop, stay stopped, and three more
  proving a broken tool leaves `main.tf` untouched
- A GitHub Actions `schedule:` workflow, pinned, linted, carrying its state between runs, kept
  as a design example that runs on `workflow_dispatch`
- A FinOps gate that fails a plan on resource count, missing tags, or a disallowed instance
  type, refuses a plan it cannot read, walks nested modules, and has its own tests, no paid API

That's the loop layer, the third one from Module 1, closed. Every earlier module built context
or harness. This project is the one that finally runs one of them on its own, and knows both
when to quit and when it has no business deciding at all.
