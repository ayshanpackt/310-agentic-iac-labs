# Project 09: Build a Scan-and-Policy Pipeline for a Real S3 Module

**Tier 1** · ~20 min · Docker socket mounted, `floci/floci:1.7.0` pinned, provider stub from
`labs/shared/floci-spike/provider.tf`, same Tier 1 rules as every hands-on project since M04.

In this project, you will build the pipeline that decides whether a real Terraform module is
safe to apply, the same sentence you have carried since module one: the agent proposes, the
pipeline decides. The module itself is already written: a reports-and-backups S3 service, two
buckets, both deliberately left unhardened.

**What you're building, at a glance:**

- Both scanners run yourself, against a real 21-resource module and against this project's own
  module, reproducing the exact numbers from the reading
- **A real Checkov finding Trivy never reports**, proof the two tools don't cover the same
  ground
- **A real OPA policy**, written from scratch, for a rule neither scanner can ever know
- **A real cost check**, wired honestly: it runs for real if you have an Infracost key, and
  skips with a clear message if you don't, never a guessed number
- **A five-stage pipeline script** that blocks on the first real failure, cheap checks first
- **A deterministic eval rubric**, run against a real agent's own Terraform output, checking
  the agent's claim rather than the infrastructure

## Pre Requisites

- Docker reachable, same check as every Tier 1 lab:

```
docker info
```

- `trivy`, `checkov`, and `conftest` on your `PATH`, installed per Environment Setup.
  Check with:

```
trivy --version
checkov --version
conftest --version
```

## Step 1: Reproduce the opening demo, live

Before touching this lab's own module, reproduce the number from the reading, on the real
21-resource module already in this repo:

```
cd labs/shared/floci-spike
trivy config --quiet --severity HIGH,CRITICAL .
checkov -d . --compact --quiet --framework terraform --skip-download
```

`[ Expected output ]`
```
Tests: 4 (SUCCESSES: 0, FAILURES: 4)
...
Tests: 1 (SUCCESSES: 0, FAILURES: 1)
...
Tests: 2 (SUCCESSES: 0, FAILURES: 2)
...
terraform scan results:

Passed checks: 60, Failed checks: 25, Skipped checks: 0
```

Add up Trivy's HIGH and CRITICAL failures across its three grouped reports: 4 + 1 + 2 = **7**.
Checkov's own summary line says **25** directly. Same numbers as the reading, reproduced on
your own machine.

## Step 2: Run Trivy and Checkov

**Move** into the lab module, same pattern as every lab since M01:

```
cd modules/module-09-verifying-ai-infra/lab
```

`file: module/main.tf` is a small, two-bucket module, deliberately unhardened.
**Scan** it with both tools:

```
trivy config --quiet --severity HIGH,CRITICAL module
checkov -d module --compact --quiet --framework terraform --skip-download
```

`[ Expected output ]`
```
Tests: 16 (SUCCESSES: 0, FAILURES: 16)
Failures: 16 (LOW: 4, MEDIUM: 2, HIGH: 10, CRITICAL: 0)
...
terraform scan results:

Passed checks: 9, Failed checks: 14, Skipped checks: 0
```

**Read** one Checkov finding Trivy never reported at all:

```
Check: CKV_AWS_144: "Ensure that S3 bucket has cross-region replication enabled"
	FAILED for resource: aws_s3_bucket.reports
```

Search Trivy's 16 findings for anything about replication. There isn't one. Trivy's rule set
for this resource type doesn't encode it. That's the coverage gap from the reading, made
concrete: Checkov's own rule set is the strictly larger one here, and only running Trivy
would have missed this finding entirely.

## Step 3: Write an OPA Policy

Your org has one rule neither Trivy nor Checkov can ever check: every `aws_s3_bucket` must
carry an `Owner` tag. **Write** it as a real OPA policy:

`file: policy/required_tags.rego`
```
package main

import rego.v1

deny contains msg if {
	some rc in input.resource_changes
	rc.type == "aws_s3_bucket"
	tags := object.get(rc.change.after, "tags", {})
	not tags.Owner
	msg := sprintf("%s has no Owner tag: every aws_s3_bucket must carry tags.Owner", [rc.address])
}
```

**Plan** the unhardened module and check it against the policy:

```
terraform -chdir=module init -backend=false -input=false
terraform -chdir=module plan -out=/tmp/plan.bin -var="endpoint=http://localhost:4566"
terraform -chdir=module show -json /tmp/plan.bin > /tmp/plan.json
conftest test --policy policy /tmp/plan.json
```

`[ Expected output ]`
```
FAIL - /tmp/plan.json - main - aws_s3_bucket.reports has no Owner tag: every aws_s3_bucket must carry tags.Owner

1 test, 0 passed, 0 warnings, 1 failure, 0 exceptions
```

`Exit code 1`. `aws_s3_bucket.reports` has no tags at all in the starter module; `backups`
already does. One thing this hand run does not do: check that `terraform show -json` itself
succeeded. If that command fails, `/tmp/plan.json` is empty, `conftest` finds zero resource
changes in it, and reports zero failures. The pipeline you assemble in Step 5 checks the
conversion and the JSON before policy ever runs. **Fix**, re-plan, re-check:

`file: solution/main.tf` already has this fixed, both buckets carry
`Owner = "m09-lab"`. Point `conftest` at the solution's plan instead and it passes clean,
`1 test, 1 passed, 0 warnings, 0 failures, 0 exceptions`.

## Step 4: Wire Infracost

Infracost's own CLI needs a one time, free device login the first time you use it, no card:

```
infracost auth login
```

Once you've done that once, `INFRACOST_API_KEY` (or a saved session) is what turns this
stage on. This lab's own `pipeline.sh` checks for it and does the honest thing either way:
runs the real estimate if you have a key, or skips the stage with a clear message if you
don't, never a guessed number.

## Step 5: Assemble the pipeline

`file: lab/pipeline.sh` in this repo is the reference version, five stages, in the order
the reading argued for: fmt/validate, trivy, checkov, conftest, infracost, each one able to
stop everything after it. It runs under `set -euo pipefail`, writes its evidence to a fresh
`/tmp/m09-pipeline` directory on every run, and treats a failed `terraform show -json`, or a
JSON file that is not a complete plan, as a block, the same as a failed scanner. **Run** it
against the starter module first:

```
./pipeline.sh module
```

`[ Expected output ]`
```
==> stage 1/5: fmt + validate
Success! The configuration is valid.

==> stage 2/5: trivy
...
BLOCKED at trivy
```

`Exit code 1`, stopped at stage 2. Now the solution:

```
./pipeline.sh solution
```

`[ Expected output ]`
```
==> stage 1/5: fmt + validate
Success! The configuration is valid.

==> stage 2/5: trivy
...
    trivy: no HIGH/CRITICAL findings
==> stage 3/5: checkov
terraform scan results:

Passed checks: 25, Failed checks: 0, Skipped checks: 6


    checkov: no unreviewed findings
==> stage 4/5: conftest (org policy: every aws_s3_bucket needs tags.Owner)
    plan json: format 1.2, 10 resource changes

1 test, 1 passed, 0 warnings, 0 failures, 0 exceptions
==> stage 5/5: cost gate (infracost)
    SKIPPED: no INFRACOST_API_KEY set. Run 'infracost auth login' once (free, no card)
    to enable this stage for real. See reading/reference.md.

PIPELINE PASSED for solution: every stage that could run, ran for real and passed
```

`Exit code 0`. Notice `solution/main.tf` still carries a few checkov findings by design,
event notifications, lifecycle, and cross-region replication, all deferred with a written
reason right in the file. Each waiver is an inline `#checkov:skip=CKV_...:reason` comment
inside the one bucket resource it covers. `pipeline.sh` passes no `--skip-check` flag: a
CLI-wide skip silences that check for every resource in the directory, including resources
nobody reviewed, and keeps the reason far from the code. **Read** checkov's summary line in
the output above. `Skipped checks: 6` is two buckets times three waivers, and it is how you
verify a suppression did what you meant instead of assuming the syntax worked.

## Step 6: Evaluate the Agent's Output

Everything so far in this project checks the *infrastructure*. This step checks the
*agent's output* against a rubric, a different question: whether the agent did what it was
actually asked, regardless of whether the bucket it produced happens to be safe.

**Write** a deterministic rubric, plain Python, no model involved, that checks an agent's
Terraform output against M04's own required-tags convention (`Environment`, `Owner`,
`ManagedBy`). It reads the real `tags = { ... }` map of every `aws_s3_bucket`, after
blanking comments and string bodies, so the three names have to be keys of that map. A
comment that lists them, a string that contains them, or a tags block on a neighbouring
resource does not count, and a `tags` value it cannot read statically, `var.x` or
`merge(...)`, fails rather than passes:

`file: eval/rubric.py`
```python
#!/usr/bin/env python3
"""Deterministic rubric: does this Terraform output tag every S3 bucket the way
M04's convention requires? No model involved, exit 0 or 1.

The rubric reads the real `tags = { ... }` attribute of each aws_s3_bucket resource, so
the required names have to appear as keys of that map. A comment that mentions them, a
string value that contains them, or a tags block on a neighbouring resource does not
count. A tags value the rubric cannot read statically (var.x, merge(...), local.tags) is
reported as a violation rather than waved through: the rubric fails closed."""
import re
import sys

REQUIRED_TAGS = ["Environment", "Owner", "ManagedBy"]

# Shadow the source: comments become spaces and string bodies become 'x', so brace
# matching and keyword searches run on a copy that only contains real structure. The
# shadow is the same length as the source, so every index points at the same character
# in both.
def shadow(src):
    out = list(src)
    n = len(src)

    def blank(j):
        if src[j] != "\n":
            out[j] = "x"

    def scan_string(i):
        """i points at an opening quote. Shadow the string body, including any quoted
        strings nested inside ${ } interpolation, and return the index after the closing
        quote."""
        i += 1
        depth = 0
        while i < n:
            ch = src[i]
            if ch == "\\":
                blank(i)
                if i + 1 < n:
                    blank(i + 1)
                i += 2
                continue
            if depth == 0 and ch == '"':
                return i + 1
            if src.startswith("${", i) or src.startswith("%{", i):
                depth += 1
                blank(i)
                blank(i + 1)
                i += 2
                continue
            if depth and ch == '"':
                i = scan_string(i)  # a nested string inside the interpolation
                continue
            if depth and ch == "}":
                depth -= 1
            blank(i)
            i += 1
        return n

    i = 0
    while i < n:
        c = src[i]
        if c == "#" or src.startswith("//", i):
            while i < n and src[i] != "\n":
                out[i] = " "
                i += 1
        elif src.startswith("/*", i):
            end = src.find("*/", i + 2)
            end = n if end < 0 else end + 2
            for j in range(i, end):
                if src[j] != "\n":
                    out[j] = " "
            i = end
        elif c == '"':
            i = scan_string(i)
        else:
            i += 1
    return "".join(out)


def matching_brace(sh, open_idx):
    """Index of the '}' that closes the '{' at open_idx, or -1."""
    depth = 0
    for i in range(open_idx, len(sh)):
        if sh[i] == "{":
            depth += 1
        elif sh[i] == "}":
            depth -= 1
            if depth == 0:
                return i
    return -1


def top_level_spans(sh, start, end):
    """Yield (a, b) spans of sh[start:end] that sit outside any nested { }."""
    depth, a = 0, start
    for i in range(start, end):
        if sh[i] == "{":
            if depth == 0:
                yield (a, i + 1)  # keep the brace: "tags = {" needs it to be recognised
            depth += 1
        elif sh[i] == "}":
            depth -= 1
            if depth == 0:
                a = i + 1
    yield (a, end)


def find_bucket_blocks(src, sh):
    """(name, body_start, body_end) for every aws_s3_bucket resource."""
    blocks = []
    for m in re.finditer(r'resource\s+"(x+)"\s+"(x+)"\s*\{', sh):
        if src[m.start(1):m.end(1)] != "aws_s3_bucket":
            continue
        name = src[m.start(2):m.end(2)]
        open_idx = m.end() - 1
        close_idx = matching_brace(sh, open_idx)
        if close_idx < 0:
            close_idx = len(sh)
        blocks.append((name, open_idx + 1, close_idx))
    return blocks


def tags_attribute(src, sh, start, end):
    """The tags attribute of a resource body. Returns ("map", keys), ("expr", text)
    for a value that is not a literal map, ("dup", None) for a repeated attribute, or
    (None, None) when there is no tags attribute at the top level of the body."""
    found = []
    for a, b in top_level_spans(sh, start, end):
        for m in re.finditer(r"(?m)^[ \t]*tags[ \t]*=[ \t]*(\S)", sh[a:b]):
            found.append((a + m.start(1), m.group(1)))
    if not found:
        return None, None
    if len(found) > 1:
        return "dup", None
    pos, first = found[0]
    if first != "{":
        line_end = sh.find("\n", pos)
        return "expr", src[pos:line_end if line_end >= 0 else len(src)].strip()
    close = matching_brace(sh, pos)
    if close < 0:
        return "expr", "unterminated map"
    keys = {}
    for a, b in top_level_spans(sh, pos + 1, close):
        for m in re.finditer(r'(?:^|[\s,{])("x+"|[A-Za-z_][\w-]*)\s*[=:]\s*([^\n,}]*)', sh[a:b]):
            key = src[a + m.start(1):a + m.end(1)].strip('"')
            value = src[a + m.start(2):a + m.end(2)].strip()
            keys[key] = value
    return "map", keys


def present(value):
    return value not in ("", '""', "null")


def check(path):
    try:
        with open(path, encoding="utf-8") as f:
            src = f.read()
    except FileNotFoundError:
        return False, [f"file not found: {path}"]
    sh = shadow(src)
    blocks = find_bucket_blocks(src, sh)
    if not blocks:
        return False, ["no aws_s3_bucket resource found"]
    violations = []
    for name, start, end in blocks:
        kind, data = tags_attribute(src, sh, start, end)
        if kind == "expr":
            violations.append(
                f"aws_s3_bucket.{name}: tags is not a literal map ({data}), cannot verify statically"
            )
            continue
        if kind == "dup":
            violations.append(f"aws_s3_bucket.{name}: tags attribute appears more than once")
            continue
        keys = data or {}
        missing = [t for t in REQUIRED_TAGS if not present(keys.get(t, ""))]
        if missing:
            violations.append(f"aws_s3_bucket.{name}: missing tags {missing}")
    return (not violations), violations


def main():
    if len(sys.argv) != 2:
        print("usage: rubric.py <path-to-terraform-file>", file=sys.stderr)
        return 2

    ok, violations = check(sys.argv[1])
    if ok:
        print(f"PASS: every bucket in {sys.argv[1]} carries {REQUIRED_TAGS}")
        return 0
    print(f"FAIL: {sys.argv[1]} does not meet the tagging rubric")
    for v in violations:
        print(" -", v)
    return 1


if __name__ == "__main__":
    sys.exit(main())
```

A rubric is itself a claim, so it gets its own tests. `file: eval/test_rubric.py` holds
fifteen: the fixtures below, a commented-out tags block, a block comment, the three names
inside a string value, a `labels` map instead of `tags`, a neighbouring resource's tags, a
`merge(...)` value, empty and `null` values, quoted keys, a single-line map, and comments
with stray braces inside a real block. **Run** them:

```
python3 -m unittest discover -s eval -p 'test_*.py'
```

`[ Expected output ]`
```
...............
----------------------------------------------------------------------
Ran 15 tests in 0.007s

OK
```

**Run** the rubric against a seeded failure first:

```
python3 eval/rubric.py eval/fixture-bad.tf
```

`[ Expected output ]`
```
FAIL: eval/fixture-bad.tf does not meet the tagging rubric
 - aws_s3_bucket.reports: missing tags ['Owner', 'ManagedBy']
 - aws_s3_bucket.backups: missing tags ['Environment', 'Owner', 'ManagedBy']
```

`Exit code 1`. `reports` is missing `Owner` and `ManagedBy`, `backups` has no `tags` block
at all.

**Run** it against the fixture that has the right words in the wrong place:

`file: eval/fixture-comment-only.tf`
```
# Required tags: Environment, Owner, ManagedBy
# tags = {
#   Environment = "lab"
#   Owner       = "m09-lab"
#   ManagedBy   = "terraform-module-conventions-skill"
# }
resource "aws_s3_bucket" "reports" {
  bucket = "m09-eval-reports" // Owner and ManagedBy are set elsewhere, honest
}
```

```
python3 eval/rubric.py eval/fixture-comment-only.tf
```

`[ Expected output ]`
```
FAIL: eval/fixture-comment-only.tf does not meet the tagging rubric
 - aws_s3_bucket.reports: missing tags ['Environment', 'Owner', 'ManagedBy']
```

`Exit code 1`. All three names are in the file. None of them is a key in a `tags` map, so
none of them counts. An agent's explanation of what it tagged is a comment too.

**Run** it against a fixed fixture:

```
python3 eval/rubric.py eval/fixture-good.tf
```

`[ Expected output ]`
```
PASS: every bucket in eval/fixture-good.tf carries ['Environment', 'Owner', 'ManagedBy']
```

`Exit code 0`.

**Ask** a real agent to produce a third fixture, then grade it with the same rubric:

```
claude -p "Write a Terraform aws_s3_bucket resource named 'reports', bucket name m09-eval-reports-live. Tag it Environment=lab, Owner=m09-lab, ManagedBy=terraform-module-conventions-skill. Write only the resource block to eval/fixture-live.tf, nothing else." \
  --permission-mode acceptEdits --allowedTools "Write"

python3 eval/rubric.py eval/fixture-live.tf
```

This is the real result, the rubric run against the agent's actual output:

`[ Expected output ]`
```
PASS: every bucket in eval/fixture-live.tf carries ['Environment', 'Owner', 'ManagedBy']
```

`Exit code 0`. The agent tagged the bucket correctly because the prompt stated the tags
explicitly. The rubric would have caught it either way.

The rubric does not care how convincingly the agent explained its reasoning. It checks the
output against a fixed rule, the same discipline M04's bundled script brought to CIDR
checking, applied here to the agent's own claim about what it built.

#### Exercise

Add a third bucket to `module/main.tf`, on purpose leave its `Owner` tag off, and run
`conftest` again. Confirm it fails on the new bucket by name. Then fix it and confirm a
clean pass.

## Validation

Run the full pipeline yourself, both the starter module and the solution, against a real
Floci container:

```
cd modules/module-09-verifying-ai-infra/lab
./run.sh
```

`run.sh` checks:

- The opening demo reproduces on the real `floci-spike` module: Trivy 7, Checkov 25
- Both scanners run against this project's own module and agree the starter is unhardened
- The OPA policy fails on the starter module and passes on the solution
- `pipeline.sh` blocks at stage 2 on the starter module and passes all five stages on the
  solution, with checkov reporting the six inline waivers as skipped and no `--skip-check`
  flag anywhere in the script
- `conftest` on its own passes an empty plan JSON, which is why `pipeline.sh` checks
  `terraform show -json` and the JSON itself before policy runs
- The rubric's unit tests pass, and the rubric rejects `eval/fixture-bad.tf` and
  `eval/fixture-comment-only.tf` while accepting `eval/fixture-good.tf`

## Summary

What you built:

- Both scanners reproduced against a real module, same numbers as the reading
- A real Checkov finding Trivy never reported, the coverage gap made concrete
- A real OPA policy for the one rule neither scanner can check
- A cost check wired to skip honestly, never to guess
- A five-stage pipeline that blocks on the first real failure, cheap checks first
- A deterministic eval rubric, graded against a real agent's own Terraform output

Scan with two tools because one alone is a coverage gap. Write the policy check for the rule
only your team knows. Check cost honestly instead of guessing at it, the deterministic gate
that fails on a real threshold is M12's, not this one. Assemble all of it in cheap-to-expensive
order, the thesis this course opened with, now real. M10 and M11 put this same pipeline in front
of a real CI system. The capstone puts it in front of everything you build there.
