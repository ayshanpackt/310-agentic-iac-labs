#!/usr/bin/env bash
# run.sh -- validates Project 10 end to end, for real.
#
#   ./run.sh                    real kind cluster, Crossplane v2, the database three ways,
#                               all three seeded failures reproduced and fixed, teardown
#   M10_LIVE_AGENT=1 ./run.sh   also runs the Claude Code step from LAB.md Stage 2, Step 4:
#                               the agent writes requests/analytics-xr.yaml, the script
#                               reads the diff, applies it, and asserts it goes Ready
#
# Requires kind, kubectl, helm 4, docker (running) and python3 on PATH. Nothing here depends
# on where those binaries live. The live-agent step additionally needs the claude CLI.
set -uo pipefail
cd "$(dirname "$0")"
fail(){ echo "FAIL: $*" >&2; kind delete cluster --name m10-lab >/dev/null 2>&1; exit 1; }

CLUSTER_NAME="m10-lab"
NODE_IMAGE="kindest/node:v1.31.0@sha256:25a3504b2b340954595fa7a6ed1575ef2edadf5abd83c0776a4308b64bf47c93"
LIVE_AGENT="${M10_LIVE_AGENT:-0}"

echo "==> 0. tools on PATH"
for tool in kind kubectl helm docker python3; do
  command -v "$tool" >/dev/null 2>&1 || { echo "FAIL: $tool not found on PATH. Install it, or add its directory to PATH, then re-run." >&2; exit 1; }
done
HELM_MAJOR=$(helm version --template '{{.Version}}' 2>/dev/null | sed -E 's/^v([0-9]+).*/\1/')
[ "$HELM_MAJOR" = "4" ] || { echo "FAIL: this lab pins Helm 4.x, found $(helm version --template '{{.Version}}' 2>/dev/null || echo unknown). Put a Helm 4 binary first on PATH and re-run." >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "FAIL: docker is not reachable. Start Docker (or your Docker-compatible runtime) and re-run." >&2; exit 1; }
if [ "$LIVE_AGENT" = "1" ]; then
  command -v claude >/dev/null 2>&1 || { echo "FAIL: M10_LIVE_AGENT=1 needs the claude CLI on PATH." >&2; exit 1; }
fi
echo "    ok, kind $(kind version | awk '{print $2}'), kubectl $(kubectl version --client -o json | python3 -c 'import json,sys; print(json.load(sys.stdin)["clientVersion"]["gitVersion"])'), helm $(helm version --template '{{.Version}}'), docker reachable"

echo "==> 1. kind cluster up, node image pinned by digest"
kind delete cluster --name "$CLUSTER_NAME" >/dev/null 2>&1 || true
kind create cluster --config starter/kind-config.yaml >/tmp/m10-kind.log 2>&1 || { cat /tmp/m10-kind.log; fail "kind create cluster"; }
kubectl --context "kind-$CLUSTER_NAME" get nodes | grep -q "$CLUSTER_NAME" || fail "node not present"
echo "    ok"

echo "==> 2. crossplane v2 via real helm chart"
helm repo add crossplane-stable https://charts.crossplane.io/stable >/dev/null 2>&1 || true
helm repo update >/dev/null 2>&1
kubectl --context "kind-$CLUSTER_NAME" create namespace crossplane-system >/dev/null 2>&1
helm install crossplane crossplane-stable/crossplane --kube-context "kind-$CLUSTER_NAME" --namespace crossplane-system --version 2.4.0 --wait --timeout 300s >/tmp/m10-helm.log 2>&1 || { cat /tmp/m10-helm.log; fail "crossplane install"; }
CP_VERSION=$(helm list --kube-context "kind-$CLUSTER_NAME" -n crossplane-system -o json | python3 -c "import json,sys; print(json.load(sys.stdin)[0]['app_version'])")
[[ "$CP_VERSION" == 2.* ]] || fail "expected crossplane v2, got $CP_VERSION"
echo "    ok, crossplane $CP_VERSION"

echo "==> 3. function-patch-and-transform"
kubectl --context "kind-$CLUSTER_NAME" apply -f - >/dev/null 2>&1 <<'EOF'
apiVersion: pkg.crossplane.io/v1
kind: Function
metadata:
  name: function-patch-and-transform
spec:
  package: xpkg.upbound.io/crossplane-contrib/function-patch-and-transform:v0.9.0
EOF
for i in $(seq 1 30); do
  H=$(kubectl --context "kind-$CLUSTER_NAME" get functions.pkg.crossplane.io function-patch-and-transform -o jsonpath='{.status.conditions[?(@.type=="Healthy")].status}' 2>/dev/null)
  [ "$H" = "True" ] && break
  sleep 3
done
[ "$H" = "True" ] || fail "function-patch-and-transform never became healthy"
echo "    ok"

echo "==> 4. warm-up: XRD (no claim, v2 namespaced XR) + Composition"
kubectl --context "kind-$CLUSTER_NAME" apply -f solution/xrd.yaml >/dev/null || fail "xrd apply"
EST=""
for i in $(seq 1 20); do
  EST=$(kubectl --context "kind-$CLUSTER_NAME" get xrd xappconfigs.platform.m10.example.org -o jsonpath='{.status.conditions[?(@.type=="Established")].status}' 2>/dev/null)
  [ "$EST" = "True" ] && break
  sleep 3
done
[ "$EST" = "True" ] || fail "xrd not established after 60s"
kubectl --context "kind-$CLUSTER_NAME" apply -f solution/composition.yaml >/dev/null || fail "composition apply"
echo "    ok"

echo "==> 5. warm-up: request the namespaced XR directly (no claim object)"
kubectl --context "kind-$CLUSTER_NAME" apply -f solution/xr.yaml >/dev/null || fail "xr apply"
for i in $(seq 1 20); do
  READY=$(kubectl --context "kind-$CLUSTER_NAME" get xappconfig checkout-service -n default -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
  [ "$READY" = "True" ] && break
  sleep 3
done
[ "$READY" = "True" ] || fail "XR never went Ready"
kubectl --context "kind-$CLUSTER_NAME" get configmap checkout-service -n default -o jsonpath='{.data.appName}' | grep -q "checkout-service" || fail "composed configmap missing expected data"
echo "    ok, XR Ready, composed ConfigMap has real patched data"
kubectl --context "kind-$CLUSTER_NAME" delete -f solution/xr.yaml >/dev/null || fail "warm-up xr delete"

echo "==> 6. layer one: raw manifests, a real Postgres by hand"
kubectl --context "kind-$CLUSTER_NAME" create namespace dbaas-manual >/dev/null 2>&1
kubectl --context "kind-$CLUSTER_NAME" apply -f manifests/postgres-secret.yaml -f manifests/postgres-service.yaml -f manifests/postgres-statefulset.yaml >/dev/null || fail "manual manifests apply"
kubectl --context "kind-$CLUSTER_NAME" -n dbaas-manual rollout status statefulset/postgres --timeout=120s >/dev/null || fail "manual statefulset never ready"
ACCEPTING=0
for i in $(seq 1 12); do
  kubectl --context "kind-$CLUSTER_NAME" -n dbaas-manual exec postgres-0 -- psql -U appuser -d appdb -c "SELECT 1;" >/dev/null 2>&1 && { ACCEPTING=1; break; }
  sleep 5
done
[ "$ACCEPTING" = "1" ] || fail "manual postgres not accepting connections after 60s"
echo "    ok, real postgres:16-alpine accepting connections from raw manifests"

echo "==> 7. layer two: the same capability, packaged as a Helm chart"
helm install billing-db ./charts/postgres-db --kube-context "kind-$CLUSTER_NAME" -n dbaas-helm --create-namespace --set dbName=billing_service --wait --timeout 90s >/dev/null || fail "helm chart install"
# postgres:16's entrypoint runs a temporary server during initdb, then restarts for real. A
# single psql can land in that gap, so poll the real query the same way step 12 does.
QUERYABLE=0
for i in $(seq 1 12); do
  kubectl --context "kind-$CLUSTER_NAME" -n dbaas-helm exec billing-db-postgres-0 -- psql -U appuser -d billing_service -c "SELECT 1;" >/dev/null 2>&1 && { QUERYABLE=1; break; }
  sleep 5
done
[ "$QUERYABLE" = "1" ] || fail "helm-installed postgres not queryable after 60s"
echo "    ok, helm-installed instance real and queryable"

echo "==> 8. layer three: schema for a namespaced database request"
kubectl --context "kind-$CLUSTER_NAME" apply -f solution/db-xrd.yaml >/dev/null || fail "db-xrd apply"
EST=""
for i in $(seq 1 20); do
  EST=$(kubectl --context "kind-$CLUSTER_NAME" get xrd xdatabases.platform.m10.example.org -o jsonpath='{.status.conditions[?(@.type=="Established")].status}' 2>/dev/null)
  [ "$EST" = "True" ] && break
  sleep 3
done
[ "$EST" = "True" ] || fail "db-xrd not established after 60s"
echo "    ok"

# The next three checks each seed one of the three real Crossplane bugs this module's LAB.md
# narrates, hit and fixed for real while this lab was being built: a missing transform field, a
# missing RBAC grant, and a readiness check that does not apply to a StatefulSet. Each check
# applies a scratch, deliberately-broken copy of the shipped composition, confirms the exact
# real failure this course documents actually reproduces, then restores the shipped, fixed
# state before moving on. Without these, the earlier version of this script only ever applied
# the final, already-fixed composition, so none of the 3 fixes were load-bearing.

echo "==> 9. seeded failure 1 of 3: missing transform field must reproduce the real error"
python3 - <<'PY'
p = "solution/db-composition.yaml"
out = "/tmp/m10-seed-transform.yaml"
text = open(p).read()
old = """              - type: FromCompositeFieldPath
                fromFieldPath: metadata.name
                toFieldPath: metadata.name
                transforms:
                  - type: string
                    string:
                      type: Format
                      fmt: "%s-postgres-creds"
"""
new = """              - type: FromCompositeFieldPath
                fromFieldPath: metadata.name
                toFieldPath: metadata.name
                transforms:
                  - type: string
                    string:
                      fmt: "%s-postgres-creds"
"""
count = text.count(old)
if count != 1:
    raise SystemExit(f"expected exactly one db-secret metadata.name Format transform block, found {count}")
open(out, "w").write(text.replace(old, new))
PY
[ -f /tmp/m10-seed-transform.yaml ] || fail "could not generate seeded transform-field composition"
kubectl --context "kind-$CLUSTER_NAME" apply -f /tmp/m10-seed-transform.yaml >/dev/null || fail "seeded transform-field composition apply"
kubectl --context "kind-$CLUSTER_NAME" apply -f - >/dev/null <<'EOF' || fail "seed-transform-test xr apply"
apiVersion: platform.m10.example.org/v1alpha1
kind: XDatabase
metadata:
  name: seed-transform-test
  namespace: default
spec:
  dbName: seed_transform_test
  storageSize: 512Mi
EOF
FOUND=0
for i in $(seq 1 20); do
  # -o json, not -o yaml: yaml output word-wraps long condition messages and
  # splits the exact substring we're checking for across two lines.
  TEXT=$(kubectl --context "kind-$CLUSTER_NAME" get xdatabase seed-transform-test -n default -o json 2>/dev/null)
  echo "$TEXT" | grep -q "string.type: Required value" && { FOUND=1; break; }
  sleep 3
done
[ "$FOUND" = "1" ] || fail "seeded missing-transform-field bug did not reproduce 'string.type: Required value'"
echo "    ok, reproduced: invalid Function input, resources[0].patches[1].transforms[0].string.type: Required value"
kubectl --context "kind-$CLUSTER_NAME" delete xdatabase seed-transform-test -n default >/dev/null 2>&1
kubectl --context "kind-$CLUSTER_NAME" apply -f solution/db-composition.yaml >/dev/null || fail "restore shipped composition after seed 1"
rm -f /tmp/m10-seed-transform.yaml
echo "    ok, shipped composition (transform field present) restored"

echo "==> 10. seeded failure 2 of 3: missing RBAC grant must reproduce the real error"
kubectl --context "kind-$CLUSTER_NAME" apply -f - >/dev/null <<'EOF' || fail "seed-rbac-test xr apply"
apiVersion: platform.m10.example.org/v1alpha1
kind: XDatabase
metadata:
  name: seed-rbac-test
  namespace: default
spec:
  dbName: seed_rbac_test
  storageSize: 512Mi
EOF
FOUND=0
for i in $(seq 1 15); do
  TEXT=$(kubectl --context "kind-$CLUSTER_NAME" get events -n default --field-selector involvedObject.name=seed-rbac-test 2>/dev/null)
  echo "$TEXT" | grep -q "statefulsets" && echo "$TEXT" | grep -q "forbidden" && { FOUND=1; break; }
  sleep 3
done
[ "$FOUND" = "1" ] || fail "seeded missing-RBAC-grant bug did not reproduce a statefulsets/forbidden error"
echo "    ok, reproduced: crossplane ServiceAccount forbidden from patching statefulsets, no db-composer-rbac.yaml applied"
# Keep seed-rbac-test alive here, don't delete it before applying the fix: the point of this
# half of the check is confirming the same stuck XR actually recovers once the RBAC grant
# lands, not just that db-composer-rbac.yaml applies without error.
kubectl --context "kind-$CLUSTER_NAME" apply -f solution/db-composer-rbac.yaml >/dev/null || fail "db-composer-rbac apply (real fix)"
UNBLOCKED=0
for i in $(seq 1 20); do
  LINE=$(kubectl --context "kind-$CLUSTER_NAME" get xdatabase seed-rbac-test -n default --no-headers 2>/dev/null)
  SYNCED=$(echo "$LINE" | awk '{print $2}')
  READY=$(echo "$LINE" | awk '{print $3}')
  [ "$SYNCED" = "True" ] && [ "$READY" = "True" ] && { UNBLOCKED=1; break; }
  sleep 3
done
[ "$UNBLOCKED" = "1" ] || fail "db-composer-rbac.yaml applied but seed-rbac-test never recovered to Synced+Ready"
kubectl --context "kind-$CLUSTER_NAME" delete xdatabase seed-rbac-test -n default >/dev/null 2>&1
echo "    ok, db-composer-rbac.yaml applied, seed-rbac-test recovered to Synced+Ready for real"

echo "==> 11. seeded failure 3 of 3: StatefulSet-incompatible readiness check must reproduce the real error"
python3 - <<'PY'
p = "solution/db-composition.yaml"
out = "/tmp/m10-seed-readiness.yaml"
text = open(p).read()
old = """            connectionDetails:
              - type: FromValue
                name: ready
                value: "true"
            readinessChecks:
              - type: None
"""
new = """            connectionDetails:
              - type: FromValue
                name: ready
                value: "true"
            readinessChecks:
              - type: MatchInteger
                fieldPath: status.readyReplicas
                matchInteger: 1
"""
assert old in text, "expected readinessChecks block not found in db-composition.yaml"
open(out, "w").write(text.replace(old, new))
PY
[ -f /tmp/m10-seed-readiness.yaml ] || fail "could not generate seeded readiness-check composition"
kubectl --context "kind-$CLUSTER_NAME" apply -f /tmp/m10-seed-readiness.yaml >/dev/null || fail "seeded readiness composition apply"
kubectl --context "kind-$CLUSTER_NAME" apply -f - >/dev/null <<'EOF' || fail "seed-readiness-test xr apply"
apiVersion: platform.m10.example.org/v1alpha1
kind: XDatabase
metadata:
  name: seed-readiness-test
  namespace: default
spec:
  dbName: seed_readiness_test
  storageSize: 512Mi
EOF
FOUND=0
for i in $(seq 1 20); do
  TEXT=$(kubectl --context "kind-$CLUSTER_NAME" get events -n default --field-selector involvedObject.name=seed-readiness-test 2>/dev/null)
  echo "$TEXT" | grep -q "not a (int64) number" && { FOUND=1; break; }
  sleep 3
done
[ "$FOUND" = "1" ] || fail "seeded StatefulSet readiness-check bug did not reproduce the real 'not a (int64) number' error"
echo "    ok, reproduced: cannot run readiness check at index 0: status.readyReplicas: not a (int64) number"
kubectl --context "kind-$CLUSTER_NAME" delete xdatabase seed-readiness-test -n default >/dev/null 2>&1
kubectl --context "kind-$CLUSTER_NAME" apply -f solution/db-composition.yaml >/dev/null || fail "restore shipped composition after seed 3"
rm -f /tmp/m10-seed-readiness.yaml
echo "    ok, shipped composition (readinessChecks: type None) restored"

echo "==> 12. layer three: request a database as one namespaced XR, no Helm values, no claim"
kubectl --context "kind-$CLUSTER_NAME" apply -f solution/db-composer-rbac.yaml >/dev/null || fail "db-composer-rbac apply"
kubectl --context "kind-$CLUSTER_NAME" apply -f solution/db-composition.yaml >/dev/null || fail "db-composition apply"
kubectl --context "kind-$CLUSTER_NAME" apply -f solution/db-xr.yaml >/dev/null || fail "db-xr apply"
for i in $(seq 1 30); do
  LINE=$(kubectl --context "kind-$CLUSTER_NAME" get xdatabase billing -n default --no-headers 2>/dev/null)
  SYNCED=$(echo "$LINE" | awk '{print $2}')
  READY=$(echo "$LINE" | awk '{print $3}')
  [ "$SYNCED" = "True" ] && [ "$READY" = "True" ] && break
  sleep 5
done
[ "$SYNCED" = "True" ] && [ "$READY" = "True" ] || fail "XDatabase billing never went Synced+Ready"
# XR Ready only means Crossplane finished composing, not that the postgres process inside the
# pod has started accepting connections, the composition's own readinessChecks are type: None
# (seed 3, above). Poll the real container the same way LAB.md says to: kubectl / a real query,
# not the XR's own status field.
QUERYABLE=0
for i in $(seq 1 12); do
  kubectl --context "kind-$CLUSTER_NAME" -n default exec billing-postgres-0 -- psql -U appuser -d billing_service -c "SELECT 1;" >/dev/null 2>&1 && { QUERYABLE=1; break; }
  sleep 5
done
[ "$QUERYABLE" = "1" ] || fail "crossplane-composed postgres not queryable"
echo "    ok, XDatabase composed a real StatefulSet+Service+Secret, real postgres queryable"

if [ "$LIVE_AGENT" = "1" ]; then
  echo "==> 13. live agent: Claude Code proposes requests/analytics-xr.yaml, this script reads the diff and applies it"
  # The exact command LAB.md prints in Stage 2, Step 4, run from the module root like the learner does.
  rm -f requests/analytics-xr.yaml
  (cd .. && claude -p "Read lab/solution/db-xrd.yaml to learn the XDatabase schema (apiVersion \
platform.m10.example.org/v1alpha1, spec.dbName required, spec.storageSize optional). Write a \
new file at lab/requests/analytics-xr.yaml requesting a namespaced XDatabase named \
analytics-db in namespace default, for a team that needs a 2Gi analytics database called \
analytics_events. Only write that one file." \
  --permission-mode acceptEdits --allowedTools "Read,Write") >/tmp/m10-agent.log 2>&1 || { cat /tmp/m10-agent.log; fail "claude -p exited non-zero"; }
  [ -f requests/analytics-xr.yaml ] || { cat /tmp/m10-agent.log; fail "agent did not write requests/analytics-xr.yaml"; }
  # The proposal must match the request, field by field, before anything reaches the cluster.
  # --dry-run=client parses the file with kubectl itself, so no YAML library is needed here.
  field(){ kubectl --context "kind-$CLUSTER_NAME" apply --dry-run=client -f requests/analytics-xr.yaml -o jsonpath="$1" 2>/dev/null; }
  [ "$(field '{.kind}')" = "XDatabase" ] || fail "proposal kind is '$(field '{.kind}')', expected XDatabase"
  [ "$(field '{.apiVersion}')" = "platform.m10.example.org/v1alpha1" ] || fail "proposal apiVersion is '$(field '{.apiVersion}')'"
  [ "$(field '{.metadata.name}')" = "analytics-db" ] || fail "proposal name is '$(field '{.metadata.name}')', expected analytics-db"
  [ "$(field '{.metadata.namespace}')" = "default" ] || fail "proposal namespace is '$(field '{.metadata.namespace}')', expected default"
  [ "$(field '{.spec.dbName}')" = "analytics_events" ] || fail "proposal spec.dbName is '$(field '{.spec.dbName}')', expected analytics_events"
  [ "$(field '{.spec.storageSize}')" = "2Gi" ] || fail "proposal spec.storageSize is '$(field '{.spec.storageSize}')', expected 2Gi"
  [ "$(field '{.spec.*}' | wc -w | tr -d ' ')" = "2" ] || fail "proposal spec carries fields the request did not ask for"
  echo "    ok, agent wrote requests/analytics-xr.yaml and every field matches the request"
  # The gate: kubectl diff must show one create (exit 1 = differences found), and the API server
  # must accept the object against the XRD schema before the real apply.
  kubectl --context "kind-$CLUSTER_NAME" diff -f requests/analytics-xr.yaml >/tmp/m10-agent-diff.log 2>&1
  DIFF_CODE=$?
  [ "$DIFF_CODE" = "1" ] || { cat /tmp/m10-agent-diff.log; fail "kubectl diff should report a pending create (exit 1), got exit $DIFF_CODE"; }
  grep -q "^+kind: XDatabase" /tmp/m10-agent-diff.log || fail "kubectl diff did not show the XDatabase create"
  kubectl --context "kind-$CLUSTER_NAME" apply --dry-run=server -f requests/analytics-xr.yaml >/dev/null || fail "API server rejected the proposal against the XDatabase schema"
  echo "    ok, kubectl diff shows exactly the pending create, server-side dry run accepts it"
  kubectl --context "kind-$CLUSTER_NAME" apply -f requests/analytics-xr.yaml >/dev/null || fail "analytics-xr apply"
  for i in $(seq 1 30); do
    LINE=$(kubectl --context "kind-$CLUSTER_NAME" get xdatabase analytics-db -n default --no-headers 2>/dev/null)
    SYNCED=$(echo "$LINE" | awk '{print $2}')
    READY=$(echo "$LINE" | awk '{print $3}')
    [ "$SYNCED" = "True" ] && [ "$READY" = "True" ] && break
    sleep 5
  done
  [ "$SYNCED" = "True" ] && [ "$READY" = "True" ] || fail "XDatabase analytics-db never went Synced+Ready"
  QUERYABLE=0
  for i in $(seq 1 12); do
    kubectl --context "kind-$CLUSTER_NAME" -n default exec analytics-db-postgres-0 -- psql -U appuser -d analytics_events -c "SELECT 1;" >/dev/null 2>&1 && { QUERYABLE=1; break; }
    sleep 5
  done
  [ "$QUERYABLE" = "1" ] || fail "agent-proposed postgres not queryable"
  echo "    ok, agent-proposed XDatabase Synced+Ready, real postgres analytics_events queryable"
  kubectl --context "kind-$CLUSTER_NAME" delete -f requests/analytics-xr.yaml >/dev/null || fail "analytics-xr delete"
else
  echo "==> 13. live agent: skipped. Set M10_LIVE_AGENT=1 to run the Claude Code step and gate its proposal here"
fi

echo "==> 14. teardown"
kubectl --context "kind-$CLUSTER_NAME" delete -f solution/db-xr.yaml >/dev/null || fail "db-xr delete"
GC_DONE=0
for i in $(seq 1 20); do
  kubectl --context "kind-$CLUSTER_NAME" -n default get statefulset billing-postgres >/dev/null 2>&1 || { GC_DONE=1; break; }
  sleep 2
done
[ "$GC_DONE" = "1" ] || fail "composed statefulset should have been garbage-collected"
helm uninstall billing-db --kube-context "kind-$CLUSTER_NAME" -n dbaas-helm >/dev/null 2>&1 || true
kind delete cluster --name "$CLUSTER_NAME" >/dev/null 2>&1 || fail "cluster delete"
docker ps -a --filter "name=$CLUSTER_NAME" --format '{{.Names}}' | grep -q "$CLUSTER_NAME" && fail "orphan cluster container remains"
echo "    ok, XR and composed resource gone, cluster deleted, no orphans"

echo
if [ "$LIVE_AGENT" = "1" ]; then
  echo "LAB PASSED -- real kind cluster, real crossplane v2.4.0, a database-as-a-service capability delivered three real ways: raw manifests, a Helm chart, and a namespaced Crossplane XR, all 3 real seeded failures reproduced and fixed, a real agent proposal diffed, applied and verified, teardown clean"
else
  echo "LAB PASSED -- real kind cluster, real crossplane v2.4.0, a database-as-a-service capability delivered three real ways: raw manifests, a Helm chart, and a namespaced Crossplane XR, all 3 real seeded failures reproduced and fixed, teardown clean (agent step skipped, see M10_LIVE_AGENT)"
fi
