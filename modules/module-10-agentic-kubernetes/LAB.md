# Project 10: Build a Database-as-a-Service Capability Using Helm, Manifests, and Crossplane v2

**Tier 2** · ~45 min · a `kind` cluster, Helm 4, Crossplane v2, one Postgres database
delivered three ways. Docker required, same as every Tier 1 lab in this course. Numbered
teardown at the end.

In this project, you will build a self-service way to get a Postgres database on Kubernetes,
the same database delivered three ways: raw manifests, a Helm chart, and a namespaced
Crossplane resource. You will also have an agent propose a new database request on its own,
reading only the schema you already applied.

**What you're building, at a glance:**

- A namespaced Crossplane XR warm-up: request a `ConfigMap` with no claim object, to see
  Crossplane v2's pattern before anything harder
- A real Postgres database, delivered three ways: raw Kubernetes manifests, a Helm chart, and
  a namespaced Crossplane XR
- Three real Crossplane failures, hit and fixed for real: a missing transform field, a missing
  RBAC grant, a readiness check that does not apply to a `StatefulSet`
- An agent proposing a second database request on its own, reading only the schema, no
  `kubectl` access
- A numbered teardown: cluster deleted, no orphan containers left behind

Everything up to this module ran against Terraform. This project uses the same discipline,
propose, read the diff, apply, on a different substrate: a real Kubernetes control plane. No
Backstage, no catalog UI, this stays at the level a platform team actually operates: charts,
manifests, and Kubernetes-native custom resources.

## Pre Requisites

- `kind`, `kubectl`, `helm`, and `docker` all on `PATH`. Check with:

```
kind version
kubectl version --client
helm version
docker info
```

`helm version` must print a `v4.` version. This lab pins Helm 4, and `lab/run.sh` refuses to
start on Helm 3. If `docker info` hangs or errors, stop and fix Docker first, same as every
earlier Tier 1 lab.

- Claude Code on `PATH` for Stage 2, Step 4 only. The three delivery layers and the
  validation script's default run need no agent at all.

## Start the cluster

`file: lab/starter/kind-config.yaml`
```
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: m10-lab
nodes:
  - role: control-plane
    image: kindest/node:v1.31.0@sha256:25a3504b2b340954595fa7a6ed1575ef2edadf5abd83c0776a4308b64bf47c93
```

**Create** the cluster from that config, not a bare `kind create cluster`:

```
kind create cluster --config lab/starter/kind-config.yaml
```

`[ Expected output ]`
```
Creating cluster "m10-lab" ...
 ✓ Ensuring node image (kindest/node:v1.31.0)
 ✓ Preparing nodes
 ✓ Writing configuration
 ✓ Starting control-plane
 ✓ Installing CNI
 ✓ Installing StorageClass
Set kubectl context to "kind-m10-lab"
```

**Verify** it's real, not a mock:

```
kubectl get nodes
```

`[ Expected output ]`
```
NAME                    STATUS   ROLES           AGE   VERSION
m10-lab-control-plane   Ready    control-plane   27s   v1.31.0
```

That digest in the config isn't decoration. Run `docker pull kindest/node:v1.31.0` yourself
and read the `Digest:` line it prints, it's the same one. `latest` and even a version tag can
move under you; a digest can't.

`kind` runs each cluster on its own `kubectl` context (`kind-m10-lab`). If you're running other
labs or clusters in parallel, pin every command in this lab to `--context kind-m10-lab`, don't
rely on whichever context happened to be current, another tool switching context out from under
you is a real, sharp-edged failure mode, not a hypothetical.

## Install Crossplane v2

```
helm repo add crossplane-stable https://charts.crossplane.io/stable
helm repo update
kubectl --context kind-m10-lab create namespace crossplane-system
helm install crossplane crossplane-stable/crossplane \
  --kube-context kind-m10-lab --namespace crossplane-system --version 2.4.0 --wait --timeout 300s
```

`[ Expected output ]`
```
NAME: crossplane
LAST DEPLOYED: ...
NAMESPACE: crossplane-system
STATUS: deployed
Chart Version: 2.4.0
Chart Application Version: 2.4.0
```

`--timeout 300s`, not the 120s you'll see in some Crossplane docs. On a cold cache the
`crossplane` and `crossplane-rbac-manager` images alone can take past two minutes to pull.
Time out too early and `helm` reports the release `failed` even though the pods come up fine a
minute later, a real false negative this lab hit while being built.

**Confirm** it's really v2, not v1, before doing anything else:

```
helm list --kube-context kind-m10-lab -n crossplane-system
```

The `APP VERSION` column should read `2.4.0`. If it starts with `1.`, you added the wrong
repo.

## Add a Composition Function

Crossplane v2 compositions run as a pipeline of functions. This lab uses one:

`edit file: (apply directly, no local file needed)`
```
kubectl --context kind-m10-lab apply -f - <<'EOF'
apiVersion: pkg.crossplane.io/v1
kind: Function
metadata:
  name: function-patch-and-transform
spec:
  package: xpkg.upbound.io/crossplane-contrib/function-patch-and-transform:v0.9.0
EOF
```

**Wait** for it to report healthy:

```
kubectl --context kind-m10-lab get functions.pkg.crossplane.io
```

`[ Expected output ]`
```
NAME                            INSTALLED   HEALTHY   PACKAGE
function-patch-and-transform    True        True      xpkg.upbound.io/crossplane-contrib/function-patch-and-transform:v0.9.0
```

## Stage 1: Request a namespaced resource with no claim object

Before building a real database, request something trivial, a `ConfigMap`, so you can see
how Crossplane v2 behaves without a real workload's failure modes in the way.

`file: lab/solution/xrd.yaml`
```
apiVersion: apiextensions.crossplane.io/v2
kind: CompositeResourceDefinition
metadata:
  name: xappconfigs.platform.m10.example.org
spec:
  scope: Namespaced
  group: platform.m10.example.org
  names:
    kind: XAppConfig
    plural: xappconfigs
  versions:
    - name: v1alpha1
      served: true
      referenceable: true
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              properties:
                appName:
                  type: string
                environment:
                  type: string
              required: [appName, environment]
          required: [spec]
```

`spec.scope: Namespaced` is the whole v2 change, in one line. There is no `claimNames` field
anywhere in this XRD. A namespaced XR doesn't need one.

`file: lab/solution/composition.yaml`
```
apiVersion: apiextensions.crossplane.io/v1
kind: Composition
metadata:
  name: xappconfigs.platform.m10.example.org
spec:
  compositeTypeRef:
    apiVersion: platform.m10.example.org/v1alpha1
    kind: XAppConfig
  mode: Pipeline
  pipeline:
    - step: patch-and-transform
      functionRef:
        name: function-patch-and-transform
      input:
        apiVersion: pt.fn.crossplane.io/v1beta1
        kind: Resources
        resources:
          - name: app-configmap
            base:
              apiVersion: v1
              kind: ConfigMap
              metadata: {}
              data: {}
            readinessChecks:
              - type: None
            patches:
              - type: FromCompositeFieldPath
                fromFieldPath: metadata.name
                toFieldPath: metadata.name
              - type: FromCompositeFieldPath
                fromFieldPath: metadata.namespace
                toFieldPath: metadata.namespace
              - type: FromCompositeFieldPath
                fromFieldPath: spec.appName
                toFieldPath: data.appName
              - type: FromCompositeFieldPath
                fromFieldPath: spec.environment
                toFieldPath: data.environment
```

`readinessChecks: [{type: None}]` matters here: a plain `ConfigMap` carries no status
condition Crossplane can watch, so without this the XR sits stuck at `READY False` forever,
waiting for a signal that will never come. Hold that thought, PART II hits the same wall for a
different, more interesting reason.

**Apply** both, request the XR, no claim object:

```
kubectl --context kind-m10-lab apply -f lab/solution/xrd.yaml
kubectl --context kind-m10-lab apply -f lab/solution/composition.yaml
kubectl --context kind-m10-lab apply -f lab/solution/xr.yaml
```

**Verify** it goes `Ready`, then read the composed `ConfigMap`:

```
kubectl --context kind-m10-lab get xappconfig checkout-service -n default
kubectl --context kind-m10-lab get configmap checkout-service -n default -o yaml
```

`[ Expected output ]`
```
NAME               SYNCED   READY   COMPOSITION                            AGE
checkout-service   True     True    xappconfigs.platform.m10.example.org   43s
```

Delete the XR before moving on, PART II reuses this cluster:

```
kubectl --context kind-m10-lab delete -f lab/solution/xr.yaml
```

## Stage 2: Deliver a database three ways

A platform team's actual job is rarely "write one YAML file." It's "give every team a
self-service way to get a database, at whatever level of hand-holding that team needs." Some
teams want the raw manifests to read and tweak. Some want a chart with sane defaults. Some just
want to ask for a database and get one. Build all three, on the same underlying Postgres, so you
can see exactly what each layer buys you over the one below it.

### Step 1: Write the raw manifests by hand

This is what every layer above eventually resolves to. Write it once, understand it, and every
abstraction after this is honest about what it's hiding.

`file: lab/manifests/postgres-secret.yaml`
```
apiVersion: v1
kind: Secret
metadata:
  name: postgres-creds
  namespace: dbaas-manual
type: Opaque
stringData:
  POSTGRES_USER: appuser
  POSTGRES_PASSWORD: lab-only-not-a-real-secret
  POSTGRES_DB: appdb
```

`file: lab/manifests/postgres-statefulset.yaml`
```
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres
  namespace: dbaas-manual
spec:
  serviceName: postgres
  replicas: 1
  selector:
    matchLabels: { app: postgres }
  template:
    metadata:
      labels: { app: postgres }
    spec:
      containers:
        - name: postgres
          image: postgres:16-alpine
          ports: [{ containerPort: 5432 }]
          envFrom: [{ secretRef: { name: postgres-creds } }]
          volumeMounts:
            - { name: data, mountPath: /var/lib/postgresql/data, subPath: pgdata }
          readinessProbe:
            exec: { command: ["pg_isready", "-U", "appuser", "-d", "appdb"] }
            initialDelaySeconds: 5
            periodSeconds: 3
  volumeClaimTemplates:
    - metadata: { name: data }
      spec:
        accessModes: ["ReadWriteOnce"]
        resources: { requests: { storage: 512Mi } }
```

`where,` the `subPath: pgdata` on the volume mount matters more than it looks. Postgres refuses
to initialize `PGDATA` on a directory that already has a `lost+found` folder in it, which some
CSI drivers create at the volume root. Mounting a subdirectory sidesteps that entirely.

`file: lab/manifests/postgres-service.yaml`
```
apiVersion: v1
kind: Service
metadata:
  name: postgres
  namespace: dbaas-manual
spec:
  selector: { app: postgres }
  ports: [{ port: 5432, targetPort: 5432 }]
  clusterIP: None
```

**Apply** and **wait** for real readiness, not a fixed sleep:

```
kubectl --context kind-m10-lab create namespace dbaas-manual
kubectl --context kind-m10-lab apply -f lab/manifests/postgres-secret.yaml \
  -f lab/manifests/postgres-service.yaml -f lab/manifests/postgres-statefulset.yaml
kubectl --context kind-m10-lab -n dbaas-manual rollout status statefulset/postgres --timeout=120s
```

**Confirm** it's a real, connectable database:

```
kubectl --context kind-m10-lab -n dbaas-manual exec postgres-0 -- \
  psql -U appuser -d appdb -c "SELECT 1 AS real_query;"
```

`[ Expected output ]`
```
 real_query
------------
          1
(1 row)
```

### Step 2: Package the manifests as a Helm chart

Every field you just hardcoded (`appdb`, `appuser`, `512Mi`) becomes a value. This is the exact
same Postgres, now installable by anyone on the team without reading or editing YAML.

`file: lab/charts/postgres-db/values.yaml`
```
dbName: appdb
dbUser: appuser
dbPassword: lab-only-not-a-real-secret
storageSize: 512Mi
image: postgres:16-alpine
```

`file: lab/charts/postgres-db/templates/statefulset.yaml` (excerpt)
```
        readinessProbe:
          exec:
            command: ["pg_isready", "-U", "{{ .Values.dbUser }}", "-d", "{{ .Values.dbName }}"]
```

The full chart is in `lab/charts/postgres-db/`, three templates plus `Chart.yaml` and
`values.yaml`, read them, they're the layer-1 manifests with every hardcoded value swapped for
a `{{ .Values.* }}` reference.

**Install** a second, independent instance, this time for a real named team database:

```
helm install billing-db ./lab/charts/postgres-db --kube-context kind-m10-lab \
  -n dbaas-helm --create-namespace --set dbName=billing_service --wait --timeout 90s
```

`--kube-context kind-m10-lab` is Helm's spelling of `kubectl`'s `--context`. Leave it off
and Helm installs into whichever cluster your kubeconfig currently points at, which after a
day of switching between labs is not always the one you think.

**Verify** it's a genuinely separate database:

```
kubectl --context kind-m10-lab -n dbaas-helm exec billing-db-postgres-0 -- \
  psql -U appuser -d billing_service -c "SELECT current_database();"
```

`[ Expected output ]`
```
 current_database
------------------
 billing_service
(1 row)
```

`helm list --kube-context kind-m10-lab -n dbaas-helm` shows a real release,
`helm uninstall billing-db --kube-context kind-m10-lab -n dbaas-helm` would take the whole
thing back out, one command, no hunting for which manifests belong
together.

### Step 3: Request a database as a namespaced Crossplane XR

A chart is still something a human has to know exists and know the right flags for. The last
layer turns "give me a database" into one small Kubernetes object, the same discipline the
warm-up used, applied to something that actually matters.

`file: lab/solution/db-xrd.yaml`
```
apiVersion: apiextensions.crossplane.io/v2
kind: CompositeResourceDefinition
metadata:
  name: xdatabases.platform.m10.example.org
spec:
  scope: Namespaced
  group: platform.m10.example.org
  names:
    kind: XDatabase
    plural: xdatabases
  versions:
    - name: v1alpha1
      served: true
      referenceable: true
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              properties:
                dbName: { type: string }
                storageSize: { type: string, default: 512Mi }
              required: [dbName]
          required: [spec]
```

The Composition, `lab/solution/db-composition.yaml`, patches-and-transforms the same three
objects layer 1 wrote by hand, a `Secret`, a headless `Service`, and a `StatefulSet`, from one
`XDatabase` request. It's long, read the full file, but here's the one line worth stopping on:

```
              - type: FromCompositeFieldPath
                fromFieldPath: metadata.name
                toFieldPath: metadata.name
                transforms:
                  - type: string
                    string:
                      type: Format
                      fmt: "%s-postgres-creds"
```

`string.type: Format` is required on every string transform in this function version. Leave it
out and the whole pipeline step fails with `invalid Function input:
resources[0].patches[1].transforms[0].string.type: Required value`, the kind of error message
that only makes sense once you already know the field is required. This lab hit that for real
while being built, along with two more, worth walking through because they're the kind of thing
no tutorial mentions and every real Crossplane rollout eventually hits:

**Composing a built-in Kubernetes kind needs its own RBAC.** Crossplane's default `crossplane`
`ClusterRole` grants `get/list/create` on `apps/deployments`, and nothing at all on
`apps/statefulsets`. A `Secret` and a `Service` composed fine; the `StatefulSet` failed with
`cannot get existing composed resource: Timeout: failed waiting for *unstructured.Unstructured
Informer to sync`, an error that reads like a caching problem and is actually a permissions
problem. The fix is `lab/solution/db-composer-rbac.yaml`, a small `ClusterRole` granting the
`crossplane` `ServiceAccount` full CRUD on `apps/statefulsets`, bound with a
`ClusterRoleBinding`. Unlike a Terraform provider, which authenticates to a cloud API with its
own credentials, Crossplane composing a native Kubernetes object acts as itself, so it needs
its own grant for exactly what it composes.

**A `StatefulSet`'s own readiness can't be read the obvious way.** The first fix attempt used
`readinessChecks: [{type: MatchCondition, matchCondition: {type: Ready, status: "True"}}]`,
copying the pattern a `Deployment` or a claim-backed resource would use. `StatefulSet` doesn't
carry a `status.conditions[type=Ready]` field at all, only `status.readyReplicas`. The second
attempt, `MatchInteger` against `status.readyReplicas`, looked right and still failed:
`cannot run readiness check at index 0: status.readyReplicas: not a (int64) number`, a real
bug in how this function version parses numbers off unstructured JSON. The actual fix,
matching the warm-up's own `ConfigMap` lesson from PART I: `type: None`, and verify real
readiness the same way you'd verify any Kubernetes workload, `kubectl get statefulset` or a
real query against the pod, not a status field Crossplane can watch. Three real attempts, one
root cause each time, the third one a workaround rather than a fix, because the underlying
function bug isn't yours to patch.

**Apply** both:

```
kubectl --context kind-m10-lab apply -f lab/solution/db-xrd.yaml
kubectl --context kind-m10-lab apply -f lab/solution/db-composer-rbac.yaml
kubectl --context kind-m10-lab apply -f lab/solution/db-composition.yaml
```

`file: lab/solution/db-xr.yaml`
```
apiVersion: platform.m10.example.org/v1alpha1
kind: XDatabase
metadata:
  name: billing
  namespace: default
spec:
  dbName: billing_service
  storageSize: 1Gi
```

**Read the diff, then apply**, the same discipline every module in this course has used since
`terraform plan`:

```
kubectl --context kind-m10-lab diff -f lab/solution/db-xr.yaml
kubectl --context kind-m10-lab apply -f lab/solution/db-xr.yaml
```

**Verify** it goes `Synced` and `Ready`, then confirm the composed database is real:

```
kubectl --context kind-m10-lab get xdatabase billing -n default
kubectl --context kind-m10-lab -n default exec billing-postgres-0 -- \
  psql -U appuser -d billing_service -c "SELECT current_database();"
```

`[ Expected output ]`
```
NAME      SYNCED   READY   COMPOSITION                            AGE
billing   True     True    xdatabases.platform.m10.example.org    14m

 current_database
------------------
 billing_service
(1 row)
```

### Step 4: Have an agent propose a database request

A team doesn't write YAML by reading an XRD's OpenAPI schema by hand every time, an agent that
already knows this repo can. Ask Claude Code to propose a second database, for a different
team, reading only the schema you already applied:

```
claude -p "Read lab/solution/db-xrd.yaml to learn the XDatabase schema (apiVersion \
platform.m10.example.org/v1alpha1, spec.dbName required, spec.storageSize optional). Write a \
new file at lab/requests/analytics-xr.yaml requesting a namespaced XDatabase named \
analytics-db in namespace default, for a team that needs a 2Gi analytics database called \
analytics_events. Only write that one file." \
  --permission-mode acceptEdits --allowedTools "Read,Write"
```

`[ Expected output ]`
```
File wrote: `lab/requests/analytics-xr.yaml`.
```

`file: lab/requests/analytics-xr.yaml` (agent-generated, real, captured from this exact run)
```
apiVersion: platform.m10.example.org/v1alpha1
kind: XDatabase
metadata:
  name: analytics-db
  namespace: default
spec:
  dbName: analytics_events
  storageSize: 2Gi
```

The agent proposed a file. It didn't apply anything, `--allowedTools "Read,Write"` doesn't
include `Bash`, the agent has no path to `kubectl` at all here. Read the diff yourself, the
same gate every module in this course has used, then apply it yourself:

```
kubectl --context kind-m10-lab diff -f lab/requests/analytics-xr.yaml
kubectl --context kind-m10-lab apply -f lab/requests/analytics-xr.yaml
kubectl --context kind-m10-lab get xdatabase analytics-db -n default
```

`[ Expected output ]`
```
NAME           SYNCED   READY   COMPOSITION                            AGE
analytics-db   True     True    xdatabases.platform.m10.example.org    4s
```

Ready in 4 seconds this time, not 14 minutes. The RBAC grant and the function pod were already
warm from the first request, real evidence that most of what felt slow above was one-time setup
cost, not a property of the platform itself.

## Teardown

**1. Delete both XRs**, confirm the composed resources are garbage-collected via their owner
references, no manual cleanup needed:

```
kubectl --context kind-m10-lab delete -f lab/requests/analytics-xr.yaml
kubectl --context kind-m10-lab delete -f lab/solution/db-xr.yaml
kubectl --context kind-m10-lab -n default get statefulset,secret,svc
```

`[ Expected output ]`
```
NAME                 TYPE        CLUSTER-IP   EXTERNAL-IP   PORT(S)   AGE
service/kubernetes   ClusterIP   10.96.0.1    <none>        443/TCP   23m
```

Only the cluster's own `kubernetes` service is left. Both databases, and everything Crossplane
composed for them, are gone.

**2. Uninstall the Helm release:**

```
helm uninstall billing-db --kube-context kind-m10-lab -n dbaas-helm
```

**3. Delete the cluster:**

```
kind delete cluster --name m10-lab
```

`[ Expected output ]`
```
Deleting cluster "m10-lab" ...
Deleted nodes: ["m10-lab-control-plane"]
```

**Confirm** no orphan container is left behind:

```
docker ps -a --filter "name=m10-lab"
```

Empty output means clean.

#### Exercise: Stage 2

Step 1's manifests hardcode `POSTGRES_DB: appdb`. Write a second raw-manifest instance for a
team that wants a database called `inventory`, without touching the Helm chart or Crossplane at
all. What do you have to rename by hand to avoid colliding with the first instance, and how many
of those renames does the Helm chart handle for you automatically?

## Validation

Run the full build yourself, all three delivery layers, against a real `kind` cluster, start
to finish. The default run is deterministic: it calls no agent, so it passes or fails for the
same reason on every machine.

```
cd modules/module-10-agentic-kubernetes/lab
./run.sh
```

`run.sh` checks:

- `kind`, `kubectl`, a Helm 4 binary, `docker` and `python3` are on `PATH`, and Docker answers.
  It fails with a one-line message naming the missing tool before it creates anything
- A real `kind` cluster comes up with the node image pinned by digest
- Crossplane v2.4.0 installs and the composition function goes healthy
- The warm-up XR goes `Ready` and its composed `ConfigMap` carries the real patched data
- Layer 1's raw manifests produce a real, connectable Postgres
- Layer 2's Helm-installed instance is a genuinely separate, queryable database
- Each of the 3 real bugs above is regression-tested for real, not just narrated: a scratch
  copy of the Composition with that specific fix reverted is applied, the exact documented
  error is confirmed to reproduce, then the shipped, fixed Composition is restored
- Layer 3's Crossplane XR goes `Synced` and `Ready`, and the composed Postgres is queryable
- Teardown garbage-collects the composed resources and leaves no orphan cluster container

The default run does **not** check Stage 2, Step 4. There, you are the gate: you read the
`kubectl diff` of the agent's proposal before you apply it, and that reading is the check.

To have the script run the agent step too, set one variable. The script then runs the exact
`claude -p` command printed in Step 4, refuses to continue unless the agent wrote
`lab/requests/analytics-xr.yaml`, confirms every field matches what was asked for and nothing
else was added, requires `kubectl diff` to show exactly one pending create and the API server
to accept the object against the XRD, then applies it, waits for `Synced` and `Ready`, and
runs a real query against the composed database:

```
cd modules/module-10-agentic-kubernetes/lab
M10_LIVE_AGENT=1 ./run.sh
```

`[ Expected output ]` (excerpt, captured from a real run)
```
==> 13. live agent: Claude Code proposes requests/analytics-xr.yaml, this script reads the diff and applies it
    ok, agent wrote requests/analytics-xr.yaml and every field matches the request
    ok, kubectl diff shows exactly the pending create, server-side dry run accepts it
    ok, agent-proposed XDatabase Synced+Ready, real postgres analytics_events queryable
==> 14. teardown
    ok, XR and composed resource gone, cluster deleted, no orphans
```

This check needs Claude Code on `PATH` and a signed-in subscription, so it stays opt-in. An
agent is non-deterministic by nature; if it ever writes a file that does not match the
request, the script fails on the exact field that differs, which is the point.

## Summary

What you built:

- A real Postgres database, delivered three ways: raw manifests, a Helm chart, and a
  namespaced Crossplane XR
- Three real Crossplane failures, fixed for a specific reason each time, not by guessing: a
  missing transform field, a missing RBAC grant, a readiness check that does not apply to a
  `StatefulSet`
- An agent proposing a second database request on its own, reading only the schema, with no
  path to `kubectl`
- A clean, numbered teardown, confirmed by a real `docker ps` check

`kubectl diff` played the same role `terraform plan` has played since M01, read the change
before it lands. M11 picks this same cluster back up and puts a GitOps controller in front of
it, so an agent proposing a change goes through a pull request and a review before anything
reaches this cluster at all.
