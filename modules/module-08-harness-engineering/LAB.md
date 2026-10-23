# Project 08: Run an IaC Change Through the Superpowers Workflow Harness Using Claude Code and Codex

**Tier 1** · ~35 min · Docker socket mounted, `floci/floci:1.7.0` pinned, provider stub copied from
`labs/shared/floci-spike/provider.tf`, same rules as every Tier 1 lab in this course.

In this project, you will install Superpowers, the open-source workflow harness by Jesse Vincent,
into Claude Code and Codex, prove its bootstrap loaded, and then run one real infrastructure
change through its whole workflow: it asks before it builds, writes a plan you read, writes a
failing `terraform test` before any HCL, proves the result with real output, and applies and
destroys it against Floci. You will finish by adding one infrastructure skill of your own to the
harness.

**What you're building, at a glance:**

- Superpowers installed in both runtimes from the official marketplace, with a one-line probe
  that proves the bootstrap is in the session
- The same vague request run twice, plugin off and plugin on, with the agent's first tool call
  captured each time
- A hardened DynamoDB orders table and a read-only access policy, reached through
  brainstorming, a design doc, a plan, and a test that failed before the fix existed
- A real `terraform test` RED, then GREEN, then Checkov, then `apply` and `destroy` against Floci
- One project skill, `iac-verification`, written with the harness's own `writing-skills` and
  proven to fire

## Pre Requisites

- Docker reachable at `/var/run/docker.sock`. Check with `docker info`
- `terraform` (with the native test runner) and `checkov` on your `PATH`, installed per
  Environment Setup
- Claude Code and Codex signed in, per M02
- Work inside your clone of the companion repository. It carries no `CLAUDE.md`, so what you
  see in this project is the harness and nothing else

## Stage 1: Install the harness and prove it loaded

### Step 1: Ask before installing

**Open** a terminal in `modules/module-08-harness-engineering/lab` and ask Claude Code the
question this whole stage turns on:

```
claude -p "Do you have superpowers? Answer in one line: yes or no, then list the exact names of the superpowers skills you can invoke, comma separated. Do not invoke any skill." --max-turns 1
```

This is what came back, captured for real, with nothing installed:

`[ Expected output ]`
```
No. None of the skills available to me are from the "superpowers" plugin; there are no skills with a `superpowers:` prefix in my list, so the comma-separated list is empty.
```

Keep that answer. In two steps the same question gets a different one, and the difference is
the whole module.

### Step 2: Install Superpowers in Claude Code

Claude Code ships a built-in plugin directory, and a bare `claude plugin install superpowers`
resolves there. On the day this project was captured, that directory carried an older release
than Anthropic's official marketplace on GitHub. **Register** the marketplace from its git
source, so you get the same release in both runtimes, then install:

```
claude plugin marketplace add anthropics/claude-plugins-official
```

`[ Expected output ]`
```
Adding marketplace…Cloning via SSH: git@github.com:anthropics/claude-plugins-official.git
Refreshing marketplace cache (timeout: 120s)…
Cloning repository (timeout: 120s): git@github.com:anthropics/claude-plugins-official.git
Clone complete, validating marketplace…
Cleaning up old marketplace cache…
✔ Successfully added marketplace: claude-plugins-official (declared in user settings)
```

```
claude plugin install superpowers@claude-plugins-official
```

`[ Expected output ]`
```
Installing plugin "superpowers@claude-plugins-official"...✔ Successfully installed plugin: superpowers@claude-plugins-official (scope: user)
```

```
claude plugin list
```

`[ Expected output ]`
```
  ❯ superpowers@claude-plugins-official
    Version: 7.0.0
    Scope: user
    Status: ✔ enabled
```

That is the version this project was captured against. A newer one may be listed by the time
you run this; the lab's behaviour does not change.

### Step 3: Install Superpowers in Codex

Codex can install from the same official marketplace Claude Code uses, which keeps both
runtimes on the same release. **Register** the marketplace once, then add the plugin:

```
codex plugin marketplace add anthropics/claude-plugins-official
```

`[ Expected output ]`
```
Added marketplace `claude-plugins-official` from https://github.com/anthropics/claude-plugins-official.git.
```

```
codex plugin add superpowers@claude-plugins-official
```

`[ Expected output ]`
```
Added plugin `superpowers` from marketplace `claude-plugins-official`.
Installed plugin root: /Users/gshah/.codex/plugins/cache/claude-plugins-official/superpowers/7.0.0
```

```
codex plugin list
```

`[ Expected output ]`
```
superpowers@claude-plugins-official     installed, enabled  7.0.0    https://github.com/obra/superpowers.git, sha `bb92a77741419a4ab5f06e711a283343f1ada0c3`
```

Codex's own curated marketplace also carries Superpowers, from the `/plugins` screen inside
Codex, which is the route the Superpowers README documents. On the day this was captured it
carried an older release, which is why this project uses the shared marketplace.

### Step 4: Probe both runtimes

Same question as Step 1, same flags:

```
claude -p "Do you have superpowers? Answer in one line: yes or no, then list the exact names of the superpowers skills you can invoke, comma separated. Do not invoke any skill." --max-turns 1
```

`[ Expected output ]`
```
Yes.

superpowers:brainstorming, superpowers:diagnosing-superpowers, superpowers:dispatching-parallel-agents, superpowers:executing-plans, superpowers:finishing-a-development-branch, superpowers:receiving-code-review, superpowers:requesting-code-review, superpowers:subagent-driven-development, superpowers:systematic-debugging, superpowers:test-driven-development, superpowers:using-git-worktrees, superpowers:using-superpowers, superpowers:verification-before-completion, superpowers:writing-plans, superpowers:writing-skills
```

Now Codex:

```
codex exec --skip-git-repo-check -s read-only "Do you have superpowers? Answer in one line: yes or no, then list the exact names of the superpowers skills available to you, comma separated. Do not invoke any skill."
```

`[ Expected output ]`
```
Yes, superpowers:brainstorming, superpowers:diagnosing-superpowers, superpowers:dispatching-parallel-agents, superpowers:executing-plans, superpowers:finishing-a-development-branch, superpowers:receiving-code-review, superpowers:requesting-code-review, superpowers:subagent-driven-development, superpowers:systematic-debugging, superpowers:test-driven-development, superpowers:using-git-worktrees, superpowers:using-superpowers, superpowers:verification-before-completion, superpowers:writing-plans, superpowers:writing-skills
```

Fifteen skills, the same fifteen in both runtimes, from one install each.

### Step 5: Read the three files that make it work

Nothing about that answer is magic. **Open** the installed plugin and read the three files
that produce it. The root is `~/.claude/plugins/cache/claude-plugins-official/superpowers/7.0.0`
for Claude Code; the Codex copy sits under `~/.codex/plugins/cache/` at the same relative path.

```
cat ~/.claude/plugins/cache/claude-plugins-official/superpowers/7.0.0/hooks/hooks.json
```

`[ Expected output ]`
```
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup|clear|compact",
        "hooks": [
          {
            "type": "command",
            "command": "\"${CLAUDE_PLUGIN_ROOT}/hooks/run-hook.cmd\" session-start",
            "shell": "bash",
            "async": false
          }
        ]
      }
    ]
  }
}
```

One hook, on `SessionStart`, matching a new session, a `/clear`, and a context compaction. It
runs `hooks/session-start`. **Read** the part of that script that does the work:

```
sed -n 20,25p ~/.claude/plugins/cache/claude-plugins-official/superpowers/7.0.0/hooks/session-start
```

`[ Expected output ]`
```
skill_md="${PLUGIN_ROOT}/skills/using-superpowers/SKILL.md"
if [ -r "$skill_md" ]; then
  using_superpowers_content="$(<"$skill_md")"
else
  using_superpowers_content="Error reading using-superpowers skill"
fi
```

It reads one skill file and, further down, prints it as JSON inside an `<EXTREMELY_IMPORTANT>`
block in whichever field the current runtime reads. That file is the bootstrap. **Read** the
rule it opens with:

```
sed -n 10,16p ~/.claude/plugins/cache/claude-plugins-official/superpowers/7.0.0/skills/using-superpowers/SKILL.md
```

`[ Expected output ]`
```
<EXTREMELY-IMPORTANT>
If you think there is even a 1% chance a skill might apply to what you are doing, you ABSOLUTELY MUST invoke the skill.

IF A SKILL APPLIES TO YOUR TASK, YOU DO NOT HAVE A CHOICE. YOU MUST USE IT.

This is not negotiable. You cannot rationalize your way out of this.
</EXTREMELY-IMPORTANT>
```

Every session starts with that text in context. The other fourteen skills only ever get read
because this one tells the agent to go and check. Codex has no session-start hook; its manifest
declares `hooks` empty on purpose, and the `using-superpowers` skill's own description, "Use when
starting any conversation", is what loads it there.

## Stage 2: Watch the first action change

The question this stage answers is small and specific: when you hand an agent a vague
request, what is the first thing it does? You will run the same request twice, once with the
plugin disabled and once enabled, and read the agent's tool calls in order from the event log
Claude Code writes.

### Step 1: Read the starter

`file: orders/main.tf`
```
# Orders storage for the checkout service. Added in a hurry before the launch.
# TODO: harden before this ships.
resource "aws_dynamodb_table" "orders" {
  name         = "checkout-orders"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "order_id"

  attribute {
    name = "order_id"
    type = "S"
  }
}

data "aws_iam_policy_document" "orders_access" {
  statement {
    actions   = ["dynamodb:*"]
    resources = [aws_dynamodb_table.orders.arn]
  }
}

resource "aws_iam_policy" "orders_access" {
  name   = "checkout-orders-access"
  policy = data.aws_iam_policy_document.orders_access.json
}
```

A bare table, no backups, no encryption, and a policy that grants everything. `provider.tf` is
the Floci stub every Tier 1 lab uses. The request you are about to make says nothing about
which of those problems matters, on purpose.

### Step 2: Run it with the plugin disabled

**Disable** the plugin, **copy** the starter, and **run** the request, saving the full event
stream rather than just the final answer:

```
claude plugin disable superpowers@claude-plugins-official
cp -r orders stage2-off && cd stage2-off
claude -p "Let's make the checkout service's orders table in this module production-ready." --permission-mode acceptEdits --allowedTools "Read,Write,Edit,Bash(terraform *),Bash(checkov *)" --output-format stream-json --verbose > ../evidence/stage2-off.jsonl
```

This takes a few minutes. When it returns, **print** the tool calls in order:

```
python3 ../first-actions.py ../evidence/stage2-off.jsonl
```

This is what came back, captured for real, trimmed to the calls that matter:

`[ Expected output ]`
```
 1. Bash   ls -la && find . -type f | head -50
 2. Read   /Users/gshah/work/courses/310-packt/modules/module-08-harness-engineering/lab/stage2-off/main.tf
 3. Read   /Users/gshah/work/courses/310-packt/modules/module-08-harness-engineering/lab/stage2-off/provider.tf
[...]
12. Bash   terraform init -input=false -no-color 2>&1 | tail -15
13. Write  /Users/gshah/work/courses/310-packt/modules/module-08-harness-engineering/lab/stage2-off/main.tf
14. Write  /Users/gshah/work/courses/310-packt/modules/module-08-harness-engineering/lab/stage2-off/tests/orders.tftest.hcl
15. Bash   terraform fmt -recursive -check -diff -no-color
16. Bash   terraform validate -no-color
17. Bash   terraform test -no-color 2>&1 | tail -30
[...]
--- final answer ---
The checkout orders table in `stage2-off/main.tf` is now hardened, and plan-mode Terraform tests back each change. Everything validates and the tests pass.

**What changed in the table**

- **Encryption at rest** now uses a customer-managed KMS key with yearly rotation and a 30-day deletion window, plus an `alias/checkout-orders` alias.
- **Point-in-time recovery** is enabled so a bad deploy or bad write can be rolled back to any second in the last 35 days.
- **Deletion protection** is on by default via a `deletion_protection` variable, and the resource also carries `prevent_destroy`. Tearing down a lab environment requires setting the variable to false and removing the lifecycle guard.
```

Read call 13. Twelve looks, then the agent rewrote `main.tf`, then wrote a test after the code
it was meant to drive. It never asked what production-ready meant. It decided: a
customer-managed KMS key, deletion protection, a `prevent_destroy` guard. Those are
defensible choices. They are also guesses, and one of them, deletion protection, means this
lab's own `terraform destroy` at the end would be refused. The full log is in
`evidence/stage2-off.jsonl`; `evidence/stage2-off-actions.txt` is the printed version.

### Step 3: Run it with the plugin enabled

**Enable** the plugin and run the identical request against a fresh copy of the starter:

```
cd .. && claude plugin enable superpowers@claude-plugins-official
cp -r orders stage2-on && cd stage2-on
claude -p "Let's make the checkout service's orders table in this module production-ready." --permission-mode acceptEdits --allowedTools "Read,Write,Edit,Bash(terraform *),Bash(checkov *)" --output-format stream-json --verbose > ../evidence/stage2-on.jsonl
python3 ../first-actions.py ../evidence/stage2-on.jsonl
```

`[ Expected output ]`
```
 1. Skill  superpowers:brainstorming
 2. Bash   ls -la && find . -maxdepth 3 -not -path '*/.git/*' | head -80 && cat CLAUDE.md 2>/dev/null; cat .cla
 3. Read   /Users/gshah/work/courses/310-packt/modules/module-08-harness-engineering/lab/stage2-on/main.tf
 4. Read   /Users/gshah/work/courses/310-packt/modules/module-08-harness-engineering/lab/stage2-on/provider.tf
[...]
 9. Read   /Users/gshah/work/courses/310-packt/modules/module-08-harness-engineering/LAB.md

--- final answer ---
I've read the table definition and the surrounding lab. Before building anything, one question, per the brainstorming step.

If you'd rather skip the questions and have me just start, say so and I'll go straight to a test-first pass on the table and its IAM policy.

What does "production-ready" mean for this table in your head: is this about passing a scanner like checkov before launch, about surviving a real incident (a bad deploy deleting the table, a lost record), or about the `dynamodb:*` policy being too broad?
```

Same request, same model, same directory layout. Call 1 is the brainstorming skill. Nine
calls, all of them reads, then one question and no files written. **Check** that for
yourself:

```
ls stage2-on/tests
```

`[ Expected output ]`
```
```

Empty. The agent stopped where the bootstrap told it to stop, at the question it needed
answered before it could build the right thing. Stage 3 answers it.

### What each run tells you

One honest note before moving on. The run without the harness still wrote a test and still
ran `terraform validate` before it claimed anything. A current model does that on a good
day. What the harness changed was the first action and the stopping point: it asked instead
of guessed. That is uniform across runs, runtimes and days, and it is what you are
installing.


## Stage 3: Run one change through the whole workflow

Stage 2 stopped at a question. This stage answers it, in an interactive session, and follows
the harness all the way: design doc, plan, failing test, fix, evidence, apply, destroy. You
type four messages. The harness does the rest, and you read what it produces before it moves on.

### Step 1: Open the session and state the intent

**Open** Claude Code in the starter module with the same tools Stage 2 allowed:

```
cd orders
claude --permission-mode acceptEdits --allowedTools "Read,Write,Edit,Bash(terraform *),Bash(checkov *)"
```

Claude Code asks once whether you trust the folder. Say yes. Then **type** the same intent as
Stage 2:

```
Let's make the checkout service's orders table in this module production-ready.
```

This is what came back, captured from the real session:

`[ Expected output ]`
```
⏺ I'll start by loading the brainstorming skill, since this is a design change and the request is open-ended.
⏺ Skill(superpowers:brainstorming)
  ⎿  Successfully loaded skill
⏺ Let me look at what's in the lab directory first so my question is grounded.
  Read 4 files, listed 1 directory, ran 1 shell command
⏺ I've read the table definition and the lab around it. The table is a single-key DynamoDB table with a dynamodb:* IAM policy and a TODO to harden it before
  launch.
  If you'd rather skip the questions and have me just start, say so and I'll go straight to a test-first hardening pass on the table and its policy.
  What's the failure you most want this table to survive once real orders are flowing through it?
```

One question, and an offer to skip the questions if you would rather it just started. Both
are in the brainstorming skill's own text. Do not skip.

### Step 2: Answer, and ask for the design document

**Type** the answer. It names the three things production-ready means here, says what it does
not mean, and asks the harness to treat this as a project:

```
Production-ready here means three things: point-in-time recovery on, server-side encryption on with the AWS-owned key, and the access policy narrowed to read-only actions (GetItem, BatchGetItem, Query, Scan, DescribeTable). No deletion protection, because this lab destroys the table at the end. Treat this as a project: write the design doc, then stop and show me where it is.
```

The harness writes the design document, dispatches a fresh subagent to review it as a builder
would, and comes back with the one thing that reviewer could not settle:

`[ Expected output ]`
```
⏺ The design doc is written and reviewed. It is at:

  /Users/gshah/work/courses/310-packt/modules/module-08-harness-engineering/lab/orders/docs/superpowers/specs/2026-10-22-orders-table-production-readiness-design.md

  Nothing has been built. One thing to know about the location: the lab's .gitignore
  ignores every docs/ directory, so this file is untracked. Move it or adjust the ignore
  rule if you want it committed.

  One question only you can answer. It changes what gets built.

  The phrase "encryption on with the AWS-owned key" describes the table as it already
  is. DynamoDB always encrypts at rest, and an absent server_side_encryption block
  already means the AWS-owned key. The only change that is visible in HCL, in a plan, in
  a test, and to checkov is enabled = true, and that selects the AWS-managed key
  aws/dynamodb instead. Both cost nothing and neither needs a KMS resource. The design
  currently assumes enabled = true, because that is the only reading under which the
  encryption test can go RED then GREEN. Do you want the AWS-managed key, or do you
  literally want the AWS-owned key and goal 2 becomes "confirm it is already true"?
```

Read that twice. The answer you typed contained a mistake: "the AWS-owned key" is what the
table already uses, so there would be nothing to test. The harness caught it before a line of
HCL existed, which is the entire point of asking first. **Open** the design doc it wrote; the
goals, non-goals and anti-goals sections are the ones to read:

```
sed -n 1,40p docs/superpowers/specs/2026-10-22-orders-table-production-readiness-design.md
```

`[ Expected output ]`
```
# Design: production-ready orders table for the checkout service

Date: 2026-10-22
Scope: `modules/module-08-harness-engineering/lab/orders/` (`main.tf`, `tests/`)
Status: approved by the author, 2026-10-22

## Intent

`main.tf` defines the DynamoDB table the checkout service stores orders in. It was added in a
hurry before launch and carries a TODO to harden it. The table has no point-in-time recovery, no
explicit encryption setting, and an IAM policy that grants `dynamodb:*` on it.
[...]
## Non-goals

- **No deletion protection**, and no `prevent_destroy` lifecycle rule. The lab destroys the
  table at the end, and either one would turn that teardown into a two-step dance. This is an
  explicit author decision, not an oversight.
```

Compare that non-goal with what the un-harnessed run in Stage 2 did on its own: deletion
protection on, plus a `prevent_destroy` guard. Same model. The difference is that this one
asked.

### Step 3: Approve the design and ask for the plan

**Type:**

```
The AWS-managed key, enabled = true. Design approved. Write the plan, then stop and show me where it is.
```

`writing-plans` runs. Before it writes, it does a throwaway run of the tests to learn what RED
looks like on this module, and two findings from that run go into the plan:

`[ Expected output ]`
```
  Two things I learned from a throwaway run that changed the plan. They are now in the
  design doc too.
  - A failing run block makes terraform test skip the rest of its file, so each property
    gets its own test file rather than sharing one.
  - Checkov's CKV_AWS_119 keeps failing after the change, because it demands a
    customer-managed key. The plan records it as an expected, accepted finding. Checkov
    never flagged dynamodb:* at all, so terraform test is the real gate for the policy.

  Checkov counts, before and after the change:

  ┌────────┬────────┬────────┐
  │        │ Passed │ Failed │
  ├────────┼────────┼────────┤
  │ Before │ 15     │ 2      │
  ├────────┼────────┼────────┤
  │ After  │ 16     │ 1      │
  └────────┴────────┴────────┘

  Floci is running with DynamoDB up, so the apply and destroy steps can run as written.

  Please review the plan. Which execution approach would you prefer?

  - Subagent-driven: a fresh subagent implements each task and a fresh reviewer checks
    it before the next starts, then a whole-branch review at the end. Most thorough,
    costs a fresh context per task and per review.
  - Native: I implement every task myself in this session, then one fresh reviewer
    checks the whole branch. Cheapest and fastest, no independent review until the end.

  For this plan I recommend Native, because the four tasks are small, touch one file
  plus a test each, and the throwaway run already confirmed the exact RED and GREEN
  outputs, so a shipped mistake would cost a few lines of HCL. Does the plan capture
  what you want, and which approach should we use?
```

That second finding is worth keeping. Checkov never flagged `dynamodb:*`. A scanner enforces
what it was told to enforce, and for this policy the test you are about to write is the only
gate. **Read** the plan's header and its first task before you answer:

```
sed -n 1,30p docs/superpowers/plans/2026-10-22-orders-table-production-readiness.md
```

`[ Expected output ]`
```
# Orders Table Production Readiness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Harden the checkout service's `checkout-orders` DynamoDB table with point-in-time recovery, server-side encryption on the AWS-managed key, and a read-only IAM policy, each change proven RED then GREEN by `terraform test`, then applied and destroyed against Floci.
[...]
## Global Constraints

- Terraform `>= 1.6`, AWS provider `~> 6.0`, pinned in `provider.tf`. Do not edit `provider.tf`.
- Table name `checkout-orders`, billing mode `PAY_PER_REQUEST`, hash key `order_id` of type `S` stay exactly as they are.
- Encryption is `server_side_encryption { enabled = true }` with **no** `kms_key_arn`. No KMS resources anywhere in the module.
- Policy actions are exactly, and only: `dynamodb:GetItem`, `dynamodb:BatchGetItem`, `dynamodb:Query`, `dynamodb:Scan`, `dynamodb:DescribeTable`. Resource stays `[aws_dynamodb_table.orders.arn]`.
- **No** `deletion_protection_enabled`, **no** `lifecycle { prevent_destroy }`. The lab destroys the table at the end.
```

This is the step 4 human gate. The plan is the document you approve, and every line of HCL that
follows is traceable to a task in it.

### Step 4: Execute the plan, test first

**Type:**

```
Native. Plan approved. Execute it inline with executing-plans. Write the failing terraform test first and show me it failing before you change main.tf. Finish with checkov, then terraform apply and terraform destroy against Floci, and show me the output of each.
```

This runs for about twelve minutes. Every command's output lands in `../evidence/` because the
plan said so. The three moments that matter, from those files:

**RED, for the right reason.** The first test, `tests/pitr.tftest.hcl`, against the bare table:

```
cat ../evidence/orders-red-pitr.txt
```

`[ Expected output ]`
```
tests/pitr.tftest.hcl... in progress
  run "table_shape_unchanged"... pass
  run "pitr_enabled"... fail

Error: Unknown condition value

  on tests/pitr.tftest.hcl line 14, in run "pitr_enabled":
  14:     condition     = aws_dynamodb_table.orders.point_in_time_recovery[0].enabled == true
    ├────────────────
    │ aws_dynamodb_table.orders.point_in_time_recovery[0].enabled is a bool

Condition expression could not be evaluated at this time. This means you have
executed a `run` block with `command = plan` and one of the values your
condition depended on is not known until after the plan has been applied.
[...]
Failure! 1 passed, 1 failed.
```

Read the error before you accept it as RED. A nested block that is absent from the
configuration is computed, so plan mode cannot read it. That is this test failing because the
feature is missing, which is the right reason. A syntax error or an undeclared resource would
not be. The policy test fails as a plain assertion, and it prints the exact diff:

```
cat ../evidence/orders-red-policy.txt
```

`[ Expected output ]`
```
tests/policy.tftest.hcl... in progress
  run "policy_is_read_only"... fail

Error: Test assertion failed

  on tests/policy.tftest.hcl line 10, in run "policy_is_read_only":
  10:     condition = data.aws_iam_policy_document.orders_access.statement[0].actions == toset([
[...]
    │ Diff:
    │ --- actual
    │ +++ expected
    │   [
    │ -   "dynamodb:*"
    │ - ]
    │ +   "dynamodb:BatchGetItem",
    │ +   "dynamodb:DescribeTable",
    │ +   "dynamodb:GetItem",
    │ +   "dynamodb:Query",
    │ +   "dynamodb:Scan"
    │ + ]

policy actions are not exactly the five read-only DynamoDB actions
```

**GREEN, same tests, only `main.tf` changed.** After each fix the agent reran the same file:

```
cat ../evidence/orders-tests-all.txt
```

`[ Expected output ]`
```
tests/pitr.tftest.hcl... in progress
  run "table_shape_unchanged"... pass
  run "pitr_enabled"... pass
tests/pitr.tftest.hcl... tearing down
tests/pitr.tftest.hcl... pass
tests/policy.tftest.hcl... in progress
  run "policy_is_read_only"... pass
tests/policy.tftest.hcl... tearing down
tests/policy.tftest.hcl... pass
tests/sse.tftest.hcl... in progress
  run "sse_enabled"... pass
tests/sse.tftest.hcl... tearing down
tests/sse.tftest.hcl... pass

Success! 4 passed, 0 failed.
```

**The scan, the apply, the drift check, the destroy.** All four captured, all four real:

```
cat ../evidence/orders-checkov.txt
```

`[ Expected output ]`
```
terraform scan results:

Passed checks: 16, Failed checks: 1, Skipped checks: 0

Check: CKV_AWS_119: "Ensure DynamoDB Tables are encrypted using a KMS Customer Managed CMK"
	FAILED for resource: aws_dynamodb_table.orders
	File: /main.tf:2-19
```

One finding left, the one the plan predicted and accepted: Checkov wants a customer-managed
key, and the design said no. A harness enforces what it was told to enforce.

```
tail -3 ../evidence/orders-apply.txt
cat ../evidence/orders-drift.txt
tail -3 ../evidence/orders-destroy.txt
```

`[ Expected output ]`
```
aws_iam_policy.orders_access: Creation complete after 0s [id=arn:aws:iam::000000000000:policy/checkout-orders-access]

Apply complete! Resources: 2 added, 0 changed, 0 destroyed.
aws_dynamodb_table.orders: Refreshing state... [id=checkout-orders]
data.aws_iam_policy_document.orders_access: Reading...
data.aws_iam_policy_document.orders_access: Read complete after 0s [id=2423781511]
aws_iam_policy.orders_access: Refreshing state... [id=arn:aws:iam::000000000000:policy/checkout-orders-access]

No changes. Your infrastructure matches the configuration.

Terraform has compared your real infrastructure against your configuration
and found no differences, so no changes are needed.
exit code: 0
aws_dynamodb_table.orders: Destroying... [id=checkout-orders]
aws_dynamodb_table.orders: Destruction complete after 0s

Destroy complete! Resources: 2 destroyed.
```

The drift check between apply and destroy was the plan's own idea, under "Review Focus":
Floci could accept the flags at apply and silently drop them, and a plan with no changes is
the evidence that it did not. When the agent finished, `finishing-a-development-branch` asked
what to do with the branch it had committed each task to. Keep it; Stage 4 continues in the
same session.

### What the workflow left behind

```
ls docs/superpowers/specs docs/superpowers/plans tests
```

`[ Expected output ]`
```
docs/superpowers/plans:
2026-10-22-orders-table-production-readiness.md

docs/superpowers/specs:
2026-10-22-orders-table-production-readiness-design.md

tests:
pitr.tftest.hcl
policy.tftest.hcl
sse.tftest.hcl
```

A design you approved, a plan you read, one test file per property that failed before the fix,
and a directory of captured output for every claim the agent made. That is what "the agent
proposes" looks like when a workflow harness is doing the proposing.


## Stage 4: Add one IaC skill to the harness

The harness ships with `verification-before-completion`, written for application code: tests
pass, build succeeds, linter clean. Infrastructure claims have their own evidence, and this
stage adds a project skill that says so, using the harness's own `writing-skills` discipline.

### Step 1: Ask the harness to write and test the skill

Still in the Stage 3 session, **type:**

```
Now add one skill of our own to the harness. Use writing-skills to create a project skill at .claude/skills/iac-verification/SKILL.md that adapts verification-before-completion to infrastructure: before any claim such as applied, clean, destroyed, or tests pass, the agent must show the matching evidence in the same message, meaning the terraform test output, the checkov pass and fail counts, the apply summary line, or the destroy summary line. Keep the skill under 40 lines. Test it the way writing-skills says to, with a pressure scenario on a subagent, and show me the result. Do not apply anything to Floci in this step.
```

Claude Code asks once before creating a file under `.claude/`. Say yes. `writing-skills`
runs its own RED and GREEN: a subagent under a pressure scenario without the skill, then
the same scenario with it. This is what came back:

`[ Expected output ]`
```
  No Success! 4 passed line, no Passed checks: line, no FAILED for resource line. That
  is the failure the skill addresses: a summary standing in for the output.

  GREEN, with skill, two reps. Both converged on the same shape. Rep 1, verbatim:
  ▎ 1. Tests pass. Ran terraform test just now in the module:
  ▎ Success! 4 passed, 0 failed.
  ▎ 2. Checkov NOT clean. Ran checkov -d . --compact --quiet just now.
  ▎ Passed checks: 16, Failed checks: 1, Skipped checks: 0
  ▎ Check: CKV_AWS_119: "Ensure DynamoDB Tables are encrypted using a KMS Customer
  ▎ Managed CMK"
  ▎         FAILED for resource: aws_dynamodb_table.orders
  ▎ 3. NOT VERIFIED: applied. I did not run terraform apply. Floci is reserved by
  ▎ payments right now. Mihail said in standup it went fine, but there is no apply
  ▎ output, no state file, and no evidence directory in the module I am working from.
  ▎ 4. NOT VERIFIED: destroyed. Same gap.

  Rep 2 produced the same four items with the same pasted lines. Both said the checkov
  result was the tempting one and that the skill's "clean except one small finding" row
  is what stopped them. Both said nothing in the skill was unclear.
```

The pressure scenario was the harness's own invention: a lead who only wants yes or no, a
teammate who said it "went fine" in standup, an emulator that is busy. Without the skill the
subagent summarized. With it, two reps pasted the lines and wrote `NOT VERIFIED` for the two
claims they could not back. That is a skill tested the way its author says to test one, and
it is a better test than any quiz.

### Step 2: Read what it wrote

```
sed -n 1,22p .claude/skills/iac-verification/SKILL.md
```

`[ Expected output ]`
```
---
name: iac-verification
description: Use when about to say infrastructure is applied, destroyed, clean, passing, green, or ready, or when relaying a teammate's or an earlier run's result, in any message about Terraform, checkov, or Floci.
---

# IaC Verification

Adapts superpowers:verification-before-completion to infrastructure. A claim about
infrastructure is exactly as real as the command output pasted next to it.
**Violating the letter of this rule is violating the spirit of this rule.**

## The rule

Each claim below appears in a message only with its evidence line pasted verbatim, in a
code block, in the same message, from a command you ran in this session:

| Claim | Evidence line that must be pasted |
|---|---|
| "tests pass" | the `terraform test` summary, e.g. `Success! 4 passed, 0 failed.` |
| "checkov clean" / "scan passes" | `Passed checks: N, Failed checks: M, Skipped checks: K` plus every `FAILED for resource` line |
| "applied" | `Apply complete! Resources: N added, M changed, K destroyed.` |
| "destroyed" | `Destroy complete! Resources: N destroyed.` |
```

The `description` is the part that decides whether it ever fires. It names the claims, and it
names relaying someone else's result, which is the case the pressure test was built around.
The same format M04 taught, the same bootstrap M08 installed, and now one more card in the
box. The full file is also at `lab/skills/iac-verification/SKILL.md`.

### Step 3: Prove it fires in a fresh session

Exit the interactive session (the harness asks what to do with the branch it committed to;
keeping it is fine). Then **run** a fresh, non-interactive session in the module and watch
the first call:

```
claude -p "Apply this module against Floci, then destroy it, and tell me when it is done." --permission-mode acceptEdits --allowedTools "Read,Bash(terraform *),Bash(checkov *)" --output-format stream-json --verbose > ../evidence/stage4-proof.jsonl
python3 ../first-actions.py ../evidence/stage4-proof.jsonl
```

`[ Expected output ]`
```
 1. Skill  iac-verification
 2. Bash   ls -la && cat *.tf && ls ../../evidence 2>/dev/null | head -50 && cat CLAUDE.md 2>/dev/null; cat ../
[...]
12. Bash   terraform apply -auto-approve -no-color 2>&1 | tail -40
13. Bash   terraform destroy -auto-approve -no-color 2>&1 | tail -15

--- final answer ---
Done. The orders module was applied against Floci and then destroyed, both in this session.
Apply:
```
Apply complete! Resources: 2 added, 0 changed, 0 destroyed.
```
Destroy:
```
Destroy complete! Resources: 2 destroyed.
```
```

Call 1 is your skill, before any read. The final answer carries both summary lines inside the
message, which is exactly what the skill's table demands. The bootstrap found a skill you
wrote an hour ago the same way it finds the fifteen that shipped, because the mechanism does
not know the difference.

#### Exercise

Pick the one check your own team skips under deadline pressure. Write it as a project skill
with `writing-skills`, pressure-test it on a subagent the way this stage did, and prove it
fires with `first-actions.py`. If the first call in a fresh session is not your skill, the
`description` is the thing to fix.


## Validation

`lab/run.sh` re-runs the whole project for real. It does not need an agent for the
infrastructure checks, and with `M08_LIVE_AGENT=1` it also asks Claude Code the Stage 1
question and asserts the bootstrap answered:

```
cd modules/module-08-harness-engineering/lab
./run.sh
```

`run.sh` checks:

- The starter module, with the Stage 3 tests copied in, fails `terraform test` as assertion
  failures (not as undeclared-resource errors), for the hardening reasons the tests name
- The solution module passes the same tests
- Checkov no longer reports `CKV_AWS_28` (point-in-time recovery) on the solution
- The solution applies and destroys for real against Floci, two resources each way
- With `M08_LIVE_AGENT=1`: the Claude Code probe answers "yes" and lists the skills

## Summary

What you built:

- Superpowers installed in Claude Code and Codex from one official marketplace, with the
  three files that make it work read off disk: the hook, the script, the bootstrap skill
- The same vague request captured twice: without the harness the agent starts writing; with it
  the first tool call is the brainstorming skill
- A design doc and a plan you read before any HCL changed, the step 4 human gate in practice
- A `terraform test` that was RED for the right reason before the fix and GREEN after, then
  Checkov, then a real apply and destroy against Floci
- One project skill, `iac-verification`, added with `writing-skills` and proven to fire

This is what M12 needs to be true before it is safe to let an agent loop: a harness that makes
the agent ask, plan, test and prove, every session, on every runtime.
