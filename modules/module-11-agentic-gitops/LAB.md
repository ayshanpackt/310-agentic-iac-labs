# Project 11: Ship an Agent's Change to Production Using a Pipeline and GitOps

**Tier 2** · ~30 min · a real GitHub Actions workflow, two real agent-opened pull requests, a
real Argo CD install reconciling a real `kind` cluster. Docker required, same as every earlier
Tier 1/2 lab. Numbered teardown at the end.

In this project, you will wire an automated CI gate onto a real GitHub repo, let an agent open a
real pull request on its own, watch the gate catch a real mistake in that agent's commit, send a
second agent in to fix the real cause, merge the result, then ship a second change through the
same gate to the directory a GitOps controller watches, and watch that controller apply the
merge to a `kind` cluster, unattended.

**What you're building, at a glance:**

- An automated CI gate on GitHub pull requests: fmt, validate, Trivy, Checkov, covering both the
  Terraform and the Kubernetes manifests in this module
- A real pull request, opened by an agent, no human touching the diff first
- A real CI failure, caught by the gate, on the agent's own hardcoded secret
- A second agent fixing the real cause, from the CI output alone
- A second agent-opened pull request to the directory Argo CD watches, gated, merged, and
  applied to the cluster by the controller, with no `kubectl apply` anywhere
- A real Argo CD install self-healing a manual tamper on its own

GitOps mechanics, stage 4 below, are the easy part of this project, not the point. The point is
what makes an agent's production change safe to ship without a human reading every line: an
automated gate that catches the agent's own mistake, a second agent that fixes the cause once it
sees the gate's output, and a human who reviews one outcome instead of a diff. GitOps applies the
result afterward, unattended and correctly. It's the last link in the chain, not the whole
subject. M10 stood up a cluster and requested a namespaced resource by hand, this project is
where that same cluster starts receiving changes an agent proposed.

## Pre Requisites

- `kind`, `kubectl`, `helm`, `docker`, and `gh` all on `PATH`, and `gh auth status` logged in.
  Check with:

```
kind version
kubectl version --client
helm version
docker info
gh auth status
```

If `docker info` hangs or errors, stop and fix Docker first, same as every earlier lab.

- A GitHub repository you can push branches to. The commands and outputs below ran against the
  book's companion repository, `PacktPublishing/The-AI-Driven-Infrastructure-as-Code-Handbook`,
  with its maintainer's access. If you don't have that access, fork it first and work in the fork:

```
gh repo fork PacktPublishing/The-AI-Driven-Infrastructure-as-Code-Handbook --clone
```

Then, wherever a command or file below names `PacktPublishing/...`, use your fork's name instead,
including `repoURL` in `lab/solution/argocd-app.yaml`. Argo CD reads a public fork over plain
HTTPS with no credential. GitHub disables Actions on a fresh fork until you open its Actions tab
once and enable them, so do that before stage 2. Your fork's `main` starts wherever the
companion repository was when you forked it, so the version numbers you see in stage 4 may
start higher than the ones captured here.

## The intent

> Take the checkov-style gate from M09 and make it run on its own, on every pull request. Once a
> pull request merges, a real controller should reconcile a real cluster to match, with nobody
> running `kubectl apply`.

## Stage 1: Wire the automated gate onto pull requests

### Step 1: Read the workflow the gate runs

The companion repository runs this workflow from `.github/workflows/m11-pipeline-demo.yml`. A
byte-identical copy ships with this module at `lab/ci/m11-pipeline-demo.yml`, so the file is in
the module's own download even though GitHub only runs it from `.github/workflows/`.

`file: lab/ci/m11-pipeline-demo.yml`
```
name: M11 pipeline demo

on:
  pull_request:
    paths:
      - 'modules/module-11-agentic-gitops/lab/pipeline-demo/**'
      - 'modules/module-11-agentic-gitops/lab/gitops-demo/**'

jobs:
  gate:
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: modules/module-11-agentic-gitops/lab/pipeline-demo
    steps:
      - uses: actions/checkout@v4
      - uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: 1.9.8
      - name: terraform fmt
        run: terraform fmt -check -diff
      - name: terraform init
        run: terraform init -backend=false -input=false
      - name: terraform validate
        run: terraform validate
      - name: trivy
        uses: aquasecurity/trivy-action@v0.36.0
        with:
          scan-type: config
          scan-ref: modules/module-11-agentic-gitops/lab
          severity: HIGH,CRITICAL
          exit-code: 1
      - name: checkov (terraform)
        uses: bridgecrewio/checkov-action@v12
        with:
          directory: modules/module-11-agentic-gitops/lab/pipeline-demo
          quiet: true
          compact: true
      - name: checkov (manifests)
        uses: bridgecrewio/checkov-action@v12
        with:
          directory: modules/module-11-agentic-gitops/lab/gitops-demo
          framework: kubernetes,secrets
          quiet: true
          compact: true
```

The `paths:` filter matters. Without it, every pull request in the repo would trigger this
workflow, including ones that never touch this module. Two directories are listed on purpose.
`pipeline-demo/` holds the Terraform the gate was first built for. `gitops-demo/` holds the
manifests Argo CD reconciles in stage 4, so a change to what the controller applies cannot
reach `main` without passing the same gate. The first version of this workflow covered only
`pipeline-demo/`, and the moment Checkov was pointed at the manifests it failed `CKV_K8S_21`:
the demo ConfigMap lived in the `default` namespace. It now lives in its own namespace, which
the Application in stage 4 creates on sync.

This is the same fmt/validate/Trivy/Checkov sequence as M09's `pipeline.sh`, minus the policy
and cost stages, which need a `policy/` directory and an Infracost API key this toy module
doesn't carry. Worth saying plainly: this module's `local_file` resources and one ConfigMap have
nothing Trivy's cloud/container checks look for, so it runs clean here, 0 findings, every time.
That is not a wasted stage. It is the same command M09 ran against real AWS resources and found
7 HIGH/CRITICAL findings, wired to run automatically now, on infrastructure that happens not to
trip it. Checkov is what actually catches this lab's findings.

### Step 2: Require the gate before anything can merge

A workflow that runs on every pull request is a check. It only becomes a gate when the
repository refuses to merge without it, and that is a repository setting, a ruleset, not
anything in the workflow file. Without the ruleset, a red `gate` is advice: anyone with push
access can click merge anyway, or push to `main` directly and skip the pull request.

`file: lab/ci/main-ruleset.json`
```
{
  "name": "main: pull request plus passing gate",
  "target": "branch",
  "enforcement": "active",
  "conditions": {
    "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] }
  },
  "rules": [
    { "type": "deletion" },
    { "type": "non_fast_forward" },
    {
      "type": "pull_request",
      "parameters": {
        "required_approving_review_count": 0,
        "dismiss_stale_reviews_on_push": false,
        "require_code_owner_review": false,
        "require_last_push_approval": false,
        "required_review_thread_resolution": false
      }
    },
    {
      "type": "required_status_checks",
      "parameters": {
        "strict_required_status_checks_policy": false,
        "required_status_checks": [ { "context": "gate" } ]
      }
    }
  ]
}
```

Four rules. No deleting `main`, no force-pushing it, every change arrives as a pull request
(zero approvals required, so a solo learner can still merge their own), and the check named
`gate` must pass first. **Apply** it to the repository you are working in, then **read back**
the rules now active on `main`:

```
gh api -X POST "repos/$(gh repo view --json nameWithOwner -q .nameWithOwner)/rulesets" --input lab/ci/main-ruleset.json
gh api "repos/$(gh repo view --json nameWithOwner -q .nameWithOwner)/rules/branches/main" --jq '.[].type'
```

`[ Expected output ]`
```
deletion
non_fast_forward
pull_request
required_status_checks
```

Creating a ruleset needs admin on the repository. On your own fork you have it. On the
companion repository the author holds maintain, not admin, and as of this build nobody has
applied the ruleset there. **Check** for yourself:

```
gh api repos/PacktPublishing/The-AI-Driven-Infrastructure-as-Code-Handbook/rules/branches/main
```

`[ Expected output ]`
```
[]
```

Empty. So on the companion repository the gate is a recommended design, not an enforced one:
the merges captured below went through because the gate was green and a human chose to wait
for it, not because GitHub would have refused otherwise. On your fork, with the ruleset
applied, the refusal is real. Keep that distinction in mind every time this module says "the
gate". The agent sessions below are the other half of the same control: they run with
`--allowedTools "Read,Edit,Bash(git *),Bash(gh *)"`, so neither one has `kubectl`,
`terraform`, or any cluster credential. Their only path to the cluster is a pull request.

## Stage 2: Let an agent open the pull request

### Step 1: Ask the agent to make the change and open a PR

Every earlier lab in this course had you drive the agent through each step yourself. This one
is different on purpose: the thing being tested is whether a *pipeline*, not a human proofreading
a diff, catches a mistake the agent makes on its own. So the agent opens this pull request, not
you.

**Ask** Claude Code, from this repo, to make a real, ordinary-sounding change and open a real PR
for it:

```
claude -p "Add a new Terraform variable named signing_key_id to
modules/module-11-agentic-gitops/lab/pipeline-demo/main.tf. Type string, described as 'Key ID
used to sign outbound webhook payloads', default value a fake but realistic AWS access key ID
literal, the way a developer in a hurry might write it. Add a local_file resource named
webhook_signing_config that writes SIGNING_KEY_ID=\${var.signing_key_id} to
\${path.module}/rendered/signing.env, matching the existing pipeline_config resource's pattern.
Commit on the current branch, push, and open a real PR against
PacktPublishing/The-AI-Driven-Infrastructure-as-Code-Handbook with gh pr create." \
  --permission-mode acceptEdits --allowedTools "Read,Edit,Bash(git *),Bash(gh *)"
```

`[ Expected output ]`
```
PR is open: https://github.com/PacktPublishing/The-AI-Driven-Infrastructure-as-Code-Handbook/pull/2

- Commit: d919925 on m11-agent-proposed-demo, pushed to origin. It's the only change in
  modules/module-11-agentic-gitops/lab/pipeline-demo/main.tf.
- signing_key_id: a string with the description you gave. The default is
  "AKIA4QWXR7NZ2KD5PLMB", which I made up in the shape of an AWS access key ID (AKIA plus
  16 characters). It is not a real key. I didn't use AWS's official example key
  (AKIAIOSFODNN7EXAMPLE) because secret scanners like gitleaks often ignore it, and then
  the pipeline wouldn't flag anything.
- PR text: describes the change the way a normal pull request would. It doesn't mention
  that the hardcoded default is there on purpose for the demo.
```

Read that last line again, because it is the whole chapter in one sentence. The agent
understood the problem completely. It knew the value looked like a credential. It even
picked that pattern deliberately, rejecting AWS's own published example key on the grounds
that scanners ignore that one and the pipeline would then catch nothing. Then it wrote a pull
request description that reads like any other pull request description, and said so, to
us, in a reply a reviewer will never see.

Nothing here is deception. The agent did exactly what it was asked and reported honestly
to the person who asked. The gap is structural: the place it was candid is not the place
a reviewer looks. That is the gap a gate closes and a disclaimer does not.

### Step 2: Watch the gate catch the mistake

**Ask** the real pull request for its real CI result. Your PR number will differ from the one
below, so use your own:

```
gh pr checks 2
```

`[ Expected output ]`
```
gate	fail	30s	https://github.com/PacktPublishing/The-AI-Driven-Infrastructure-as-Code-Handbook/actions/runs/37410964401/job/112099081575
contract	pass	6s	https://github.com/PacktPublishing/The-AI-Driven-Infrastructure-as-Code-Handbook/actions/runs/37410964429/job/112099081451
```

Two checks ran, not one. `gate` is this module's workflow and it failed. `contract` is the
companion repository's own book-contract gate, unrelated to this module, and it passed. Piped
anywhere other than a terminal, `gh` prints one line per check; run interactively it draws the
same rows as a table, and `--watch` holds the terminal until they finish.

Inside that failing job every earlier step passed: `terraform fmt`, `terraform init`,
`terraform validate`, and `trivy`. Only `checkov` failed. **Ask** the run what it found, using
the run ID from the URL above:

```
gh run view 37410964401 --log-failed
```

`[ Expected output ]`
```
Passed checks: 0, Failed checks: 1, Skipped checks: 0

Check: CKV_SECRET_2: "AWS Access Key"
	FAILED for resource: af103e9737060eff5424b90170ce5e62e0b86f90
	File: /main.tf:19-20
```

Nobody ran `checkov` by hand, and nobody reviewed the agent's diff before it went out. A pull
request did the reviewing, automatically. It failed for a real reason: the same `CKV_SECRET_2`
finding this course has used since Project 1, this time on an agent's own commit, named down to
the two lines it sits on.

## Stage 3: Send the failure back to the agent and merge

### Step 1: Ask a second agent to fix the real cause

**Ask** a second, separate agent session to fix it, prompted with the real CI failure text plus
the pre-diagnosed cause and prescribed fix:

```
claude -p "You are on git branch m11-agent-proposed-demo, PR
PacktPublishing/The-AI-Driven-Infrastructure-as-Code-Handbook#2. Its CI just failed: checkov reported CKV_SECRET_2 'AWS
Access Key' against modules/module-11-agentic-gitops/lab/pipeline-demo/main.tf. Read that file,
find the cause (signing_key_id has a hardcoded default), fix it: remove the default, mark it
sensitive = true, update the description to say how it should actually be set. Do not touch the
unrelated webhook_token variable. Commit and push." \
  --permission-mode acceptEdits --allowedTools "Read,Edit,Bash(git *)"
```

`[ Expected output ]`
```
I fixed the hardcoded key in signing_key_id, committed it as b9a1276, and pushed it to
m11-agent-proposed-demo (PR #2). CI hasn't re-run yet.

Cause: signing_key_id had default = "AKIA4QWXR7NZ2KD5PLMB". That is an AWS access key ID,
so checkov's CKV_SECRET_2 rule caught it.

Fix in modules/module-11-agentic-gitops/lab/pipeline-demo/main.tf:16-20:
- Removed the default.
- Added sensitive = true.
- Changed the description to: "Set via TF_VAR_signing_key_id, never a default."
- webhook_token is unchanged.

Warning: The key is still in git history. Commit d919925 was already pushed, so anyone who
can read the repo can still find it there. If it's a real key, rotate it in AWS now.
Removing it from the file doesn't make it safe.
```

### Step 2: Watch the gate pass

**Ask** the same PR for its result again:

```
gh pr checks 2
```

`[ Expected output ]`
```
contract	pass	3s	https://github.com/PacktPublishing/The-AI-Driven-Infrastructure-as-Code-Handbook/actions/runs/37411098456/job/112099490683
gate	pass	34s	https://github.com/PacktPublishing/The-AI-Driven-Infrastructure-as-Code-Handbook/actions/runs/37411098459/job/112099490724
```

Same gate, same scanner, same module. One commit changed, and the stage that failed now
passes.

### Step 3: Merge

This is the one manual step left in the whole loop, and notice what you're actually reviewing:
not `terraform fmt`, not the trivy run, not the checkov run, not even the diff line by line.
You're reviewing the outcome, a pull request that went from failing to passing for a documented
reason, and deciding whether that's good enough to ship:

```
gh pr merge 2 --squash --delete-branch
gh pr view 2 --json state,mergeCommit -q '[.state, .mergeCommit.oid] | @tsv'
```

`[ Expected output ]`
```
MERGED	c8cafcd0ee3496f290af5a1b7c3bd661cd5e4969
```

`gh pr merge` prints its confirmation line only to a terminal, so the second command is how a
scripted run, or a reader following along in a log, checks the same thing.

Two agent sessions proposed and fixed this change. Zero human edits touched the Terraform. One
human read a passing pull request and clicked merge. An agent's mistake reached a pipeline
before it reached a person, the pipeline caught it and said exactly why, a second agent session
fixed the actual cause instead of the symptom, and the only judgment call left for a human was
"is this diff, now that it's green, the right thing to ship."

Be precise about what that merge did and did not do. It changed `pipeline-demo/main.tf`, a
Terraform file. No controller watches that directory, and nothing applied it: in this module
its only job was to show the gate catching an agent's mistake. The directory Argo CD watches is
`gitops-demo/`, and stage 4 ships a second change to it, through the same gate, so you can see
one change travel the whole chain from pull request to running cluster.

## Stage 4: Ship a change end to end, from pull request to running cluster

### Step 1: Stand up the cluster and install Argo CD

`file: lab/starter/kind-config.yaml`
```
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: m11-lab
nodes:
  - role: control-plane
    image: kindest/node:v1.31.0@sha256:25a3504b2b340954595fa7a6ed1575ef2edadf5abd83c0776a4308b64bf47c93
```

```
kind create cluster --name m11-lab --config lab/starter/kind-config.yaml
kubectl --context kind-m11-lab create namespace argocd
kubectl --context kind-m11-lab apply -n argocd --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.5.6/manifests/install.yaml
kubectl --context kind-m11-lab -n argocd wait --for=condition=available --timeout=300s \
  deployment/argocd-repo-server deployment/argocd-server
```

The install manifest is pinned to a numbered Argo CD release, the one this lab was tested
with, listed in the module README's version table. Argo CD also publishes a `stable` branch
that moves with every release; an install from it would change under this lab without anyone
changing the lab, which is the same reason M10 pins the `kind` node image by digest.

`--server-side --force-conflicts` isn't decoration either. Argo CD's own install manifest is
big enough that a plain client-side `kubectl apply` fails outright with an annotation-size
error the first time.

`--context kind-m11-lab` on every command from here on isn't decoration either. `kind create
cluster` changes your kubeconfig's current-context globally, so if you (or an earlier module)
still have another kind cluster around, creating this one can silently leave `kubectl` pointed
at the wrong cluster. Pinning the context makes every command below correct regardless of what
else is running on your machine.

### Step 2: Point Argo CD at the repository

`file: lab/solution/argocd-app.yaml`
```
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: m11-gitops-demo
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/PacktPublishing/The-AI-Driven-Infrastructure-as-Code-Handbook.git
    targetRevision: main
    path: modules/module-11-agentic-gitops/lab/gitops-demo
  destination:
    server: https://kubernetes.default.svc
    namespace: m11-gitops-demo
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

This is a real, public repo: the book's own companion repository, the one you cloned to get
this lab. `lab/gitops-demo/` is a plain `ConfigMap` manifest that lives in it. Argo CD reads
it over plain HTTPS with no credential, because the repository is public. `CreateNamespace=true`
lets the controller create `m11-gitops-demo` on the first sync, so the ConfigMap can stay out
of `default`, which is what the gate's `CKV_K8S_21` check demands.

```
kubectl --context kind-m11-lab apply -f lab/solution/argocd-app.yaml
```

**Verify** it goes `Synced` and `Healthy`:

```
kubectl --context kind-m11-lab get application m11-gitops-demo -n argocd
```

`[ Expected output ]`
```
NAME              SYNC STATUS   HEALTH STATUS
m11-gitops-demo   Synced        Healthy
```

**Record** which commit the controller synced, and what the `ConfigMap` says right now. You
will compare both against the merge in step 5:

```
kubectl --context kind-m11-lab get application m11-gitops-demo -n argocd -o jsonpath='{.status.sync.status} {.status.sync.revision}{"\n"}'
kubectl --context kind-m11-lab get configmap m11-gitops-demo -n m11-gitops-demo -o jsonpath='{.data.version}{"\n"}'
```

`[ Expected output ]`
```
Synced ca58aec64a82d5062959d88457e49fc17a87527f
v1
```

The revision is the commit at the tip of `main` when the controller synced. On the build's run
that was the merge of PR 3, the one that extended the gate to this directory. Yours will be
whatever your `main` is at.

### Step 3: Ask the agent to change what the controller watches

Now the connecting piece. The pull request in stages 2 and 3 never touched anything a
controller applies. This one does, and it goes through the same gate. **Ask** an agent to make
a small, ordinary release change to the manifest Argo CD is watching:

```
claude -p "In modules/module-11-agentic-gitops/lab/gitops-demo/configmap.yaml, bump data.version from v1 to v2 and add a data key named release_note with the value 'shipped through the gate, applied by the controller'. Change nothing else in the repository. Create a branch named m11-gitops-release-v2, commit, push, and open a real PR against PacktPublishing/The-AI-Driven-Infrastructure-as-Code-Handbook with gh pr create." \
  --permission-mode acceptEdits --allowedTools "Read,Edit,Bash(git *),Bash(gh *)"
```

`[ Expected output ]`
```
Done. PR open: https://github.com/PacktPublishing/The-AI-Driven-Infrastructure-as-Code-Handbook/pull/4

What changed:
- Branch `m11-gitops-release-v2` off `main`, one commit `ab117d6`.
- Only `modules/module-11-agentic-gitops/lab/gitops-demo/configmap.yaml` touched. Version `v1` → `v2`, new key `release_note: "shipped through the gate, applied by the controller"`. Diff: 2 insertions, 1 deletion, no other files.
- No PR template in repo. Body has summary plus test plan (gate passes, controller reconciles ConfigMap after merge).

Next: watch M11 gate check on PR #4. Merge when green.
```

One file, one commit, a pull request nobody reviewed before it went out. Same as stage 2,
except this time the change is to the one directory in the repository that a controller will
act on the moment it merges.

### Step 4: Watch the gate pass

**Ask** the pull request for its checks. Your PR number will differ:

```
gh pr checks 4
```

`[ Expected output ]`
```
contract	pass	4s	https://github.com/PacktPublishing/The-AI-Driven-Infrastructure-as-Code-Handbook/actions/runs/39913710097/job/120282330168
gate	pass	38s	https://github.com/PacktPublishing/The-AI-Driven-Infrastructure-as-Code-Handbook/actions/runs/39913710067/job/120282330039
```

The `paths:` filter from stage 1 is why `gate` ran at all on a manifest-only change. Inside it,
the `checkov (manifests)` step scanned the ConfigMap with the kubernetes and secrets frameworks
and passed it: a version bump and a plain-text note, in a namespace of its own, nothing to
flag. Had the agent put a credential in that ConfigMap, this is the step that would have gone
red, the same way `CKV_SECRET_2` did in stage 2.

### Step 5: Merge, then watch the controller apply it

Before you merge, look at the cluster one more time. It is `Synced` at the old revision, and
the `ConfigMap` still says `v1`. Then merge, the one manual step, and immediately read the
controller's state again:

```
gh pr merge 4 --squash --delete-branch
gh pr view 4 --json state,mergeCommit -q '[.state, .mergeCommit.oid] | @tsv'
```

`[ Expected output ]`
```
MERGED	71050e92602972df9775e2ede1f08838df570f36
```

```
kubectl --context kind-m11-lab get application m11-gitops-demo -n argocd -o jsonpath='{.status.sync.status} {.status.sync.revision}{"\n"}'
kubectl --context kind-m11-lab get configmap m11-gitops-demo -n m11-gitops-demo -o jsonpath='{.data.version}{"\n"}'
```

`[ Expected output ]`
```
Synced ca58aec64a82d5062959d88457e49fc17a87527f
v1
```

Still the old revision, still `v1`, and still reported as `Synced`, because the controller has
not looked at the repository since the merge. Argo CD polls the repository every three minutes
by default. **Do nothing.** Run no `kubectl apply`, no `argocd app sync`, no refresh. Wait, then
run the same two commands again:

```
kubectl --context kind-m11-lab get application m11-gitops-demo -n argocd -o jsonpath='{.status.sync.status} {.status.sync.revision}{"\n"}'
kubectl --context kind-m11-lab get configmap m11-gitops-demo -n m11-gitops-demo -o jsonpath='{.data.version}{"\n"}'
kubectl --context kind-m11-lab get configmap m11-gitops-demo -n m11-gitops-demo -o jsonpath='{.data.release_note}{"\n"}'
```

`[ Expected output ]`
```
Synced 71050e92602972df9775e2ede1f08838df570f36
v2
shipped through the gate, applied by the controller
```

On the build's run this took 92 seconds from merge to reconciled. The revision the controller
reports is now the merge commit `gh pr view` printed. The `ConfigMap` in the cluster carries the
agent's change. Nobody typed `kubectl apply`. That is the whole chain, connected: an agent
proposed a change, a gate checked it, a human merged it, a controller applied it.

### Step 6: Watch self-heal for real

**Tamper** with the resource directly, the way someone might by accident:

```
kubectl --context kind-m11-lab patch configmap m11-gitops-demo -n m11-gitops-demo --type merge \
  -p '{"data":{"message":"manually tampered, should get corrected"}}'
kubectl --context kind-m11-lab get configmap m11-gitops-demo -n m11-gitops-demo -o jsonpath='{.data.message}{"\n"}'
```

`[ Expected output ]`
```
manually tampered, should get corrected
```

**Wait** a few seconds, and **check** again:

```
kubectl --context kind-m11-lab get configmap m11-gitops-demo -n m11-gitops-demo -o jsonpath='{.data.message}{"\n"}'
```

`[ Expected output ]`
```
reconciled by GitOps, not kubectl apply
```

On the build's run the correction landed 3 seconds after the tamper. Nobody ran anything the
second time. The controller noticed the drift and corrected it on its own. That's the
mechanical difference from Terraform's one-shot model, felt directly instead of just read
about.

## Teardown

**1. Remove the Argo CD application:**

```
kubectl --context kind-m11-lab delete -f lab/solution/argocd-app.yaml
```

**2. Delete the cluster:**

```
kind delete cluster --name m11-lab
```

**Confirm** no orphan container is left behind:

```
docker ps -a --filter "name=m11-lab"
```

Empty output means clean.

#### Exercise

Point Argo CD's `syncPolicy` at manual instead of automated (`syncPolicy: {}` with no
`automated:` block), tamper with the ConfigMap the same way, and watch nothing get corrected
until you run `argocd app sync` yourself. Explain, in your own words, why `automated.selfHeal`
is what actually makes this step 5 rather than a still-manual step 4 with extra steps.

## Validation

Run the full check yourself against a real `kind` cluster. The pull-request half of this
project happened once, for real, on the companion repository, and the script verifies the
state those three merges left in the lab files. The cluster half it re-runs from scratch.
This is what catches a regression if the pinned Argo CD release, the `kind` node image, or the
CI workflow's action versions ever change:

```
cd modules/module-11-agentic-gitops/lab
./run.sh
```

`run.sh` checks:

- `kind`, `kubectl`, and `docker` are on `PATH` and the Docker daemon answers
- The merged evidence is real: `pipeline-demo/main.tf` carries both `sensitive = true`
  variables with no hardcoded default, `ci/m11-pipeline-demo.yml` gates both directories,
  `gitops-demo/configmap.yaml` is at `v2` in its own namespace, and the Argo CD release pinned
  here matches the one in this page
- `.gitignore` covers `rendered/`, state files, and plan files, so a local apply can't commit
  token values
- A real `kind` cluster comes up, node image pinned by digest
- Argo CD installs clean, from the pinned upstream manifest
- Argo CD points at the real, merged repo, creates the namespace, and reconciles the `v2`
  `ConfigMap`
- A direct tamper on the resource gets corrected on its own, self-heal, for real
- Teardown removes the application and deletes the cluster, no orphan containers left behind

## Summary

What you built:

- An automated CI gate on GitHub pull requests: fmt, validate, Trivy, Checkov, covering the
  Terraform and the manifests, running whether or not anyone is watching, and a ruleset that
  makes it a requirement rather than advice
- A real pull request, opened by an agent, no human touching the diff first
- A real CI failure, caught by the gate, on the agent's own hardcoded secret
- A second agent fixing the real cause, from the CI output alone, not a guess
- A second agent-opened pull request to the directory the controller watches, gated, merged by
  you, and applied to the cluster by Argo CD 92 seconds later with no `kubectl apply`
- A real self-heal, the controller correcting a manual tamper on its own

This is step 5 on the autonomy ladder, supervised autonomy, for real: you reviewed outcomes,
propose and merge, not each gate, each fix, or each sync event in between. M12 asks what happens
when the loop itself, not just one pipeline, runs across many agents at once.
