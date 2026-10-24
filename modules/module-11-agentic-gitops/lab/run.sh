#!/usr/bin/env bash
# Project 11 validation. Re-runs the repeatable half of the project for real: kind cluster up,
# Argo CD installed from a pinned release, the Application synced against the companion
# repository's merged main, a self-heal tamper test, then a numbered teardown.
#
# The pull-request half happened once, for real, on the companion repository: PR 2 (an agent's
# hardcoded key caught by the gate, fixed, merged), PR 3 (the gate extended to the manifests the
# controller watches) and PR 4 (an agent's ConfigMap change shipped through the gate and
# reconciled by the controller). Step 1 verifies the state those merges left in the lab files.
set -uo pipefail
cd "$(dirname "$0")"

ARGOCD_VERSION="v3.5.6"
ARGOCD_MANIFEST="https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"
CLUSTER_NAME="m11-lab-verify"
KCTX="kind-${CLUSTER_NAME}"
APP_NS="m11-gitops-demo"
LOG_DIR="$(mktemp -d)"

kctl(){ kubectl --context "$KCTX" "$@"; }
fail(){
  echo "FAIL: $*" >&2
  kctl delete -f solution/argocd-app.yaml >/dev/null 2>&1
  kind delete cluster --name "$CLUSTER_NAME" >/dev/null 2>&1
  exit 1
}

echo "==> 0. tools on PATH"
for t in kind kubectl docker; do
  command -v "$t" >/dev/null 2>&1 || fail "$t not found on PATH"
done
docker info >/dev/null 2>&1 || fail "docker daemon not reachable, start Docker first"
echo "    ok: kind, kubectl, docker"

echo "==> 1. merged pull-request evidence in the lab files"
# PR 2: the agent-proposed variable, hardcoded default removed, both variables sensitive
[ "$(grep -c 'sensitive   = true' pipeline-demo/main.tf)" = "2" ] || fail "pipeline-demo/main.tf should carry 2 sensitive variables (webhook_token, signing_key_id), the post-merge state of PR 2"
grep -q "AKIAABCDEFGHIJKLMNOP" pipeline-demo/main.tf && fail "pipeline-demo/main.tf still has the original hardcoded secret"
grep -qE '^\s*default\s*=' pipeline-demo/main.tf && fail "pipeline-demo/main.tf still has a variable default, a hardcoded value may remain"
grep -q "signing_key_id" pipeline-demo/main.tf || fail "pipeline-demo/main.tf missing signing_key_id, the variable PR 2 added"
# PR 3: the gate covers the directory the controller watches, and the manifest left the default namespace
grep -q "lab/gitops-demo/\*\*" ci/m11-pipeline-demo.yml || fail "ci/m11-pipeline-demo.yml does not trigger on lab/gitops-demo, the gate misses what the controller applies"
grep -q "framework: kubernetes,secrets" ci/m11-pipeline-demo.yml || fail "ci/m11-pipeline-demo.yml has no Checkov step for the manifests"
grep -q "namespace: ${APP_NS}" gitops-demo/configmap.yaml || fail "gitops-demo/configmap.yaml not in its own namespace (CKV_K8S_21 would fail the gate)"
grep -q "CreateNamespace=true" solution/argocd-app.yaml || fail "solution/argocd-app.yaml missing CreateNamespace=true"
# PR 4: the change the controller actually reconciled
grep -q 'version: "v2"' gitops-demo/configmap.yaml || fail "gitops-demo/configmap.yaml not at v2, the state PR 4 merged"
grep -q "release_note" gitops-demo/configmap.yaml || fail "gitops-demo/configmap.yaml missing release_note, the key PR 4 added"
# drift guards between this script and the prose
grep -q "argo-cd/${ARGOCD_VERSION}/manifests" ../LAB.md || fail "LAB.md pins a different Argo CD release than run.sh (${ARGOCD_VERSION})"
for rule in 'rendered/' '*.tfstate' '*.tfstate.*' '*.tfplan'; do
  grep -qxF "$rule" .gitignore || fail ".gitignore missing rule: $rule"
done
echo "    ok: PR 2, PR 3 and PR 4 evidence present, Argo CD pin and ignore rules consistent"

echo "==> 2. kind cluster up, node image pinned by digest"
kind delete cluster --name "$CLUSTER_NAME" >/dev/null 2>&1 || true
kind create cluster --name "$CLUSTER_NAME" --config starter/kind-config.yaml >"$LOG_DIR/kind.log" 2>&1 \
  || { cat "$LOG_DIR/kind.log"; fail "kind create cluster"; }
kctl get nodes | grep -q "$CLUSTER_NAME" || fail "node not present"
echo "    ok"

echo "==> 3. argo cd ${ARGOCD_VERSION}, pinned upstream manifest"
kctl create namespace argocd >/dev/null 2>&1
kctl apply -n argocd --server-side --force-conflicts -f "$ARGOCD_MANIFEST" >"$LOG_DIR/argocd.log" 2>&1 \
  || { cat "$LOG_DIR/argocd.log"; fail "argocd install"; }
kctl -n argocd wait --for=condition=available --timeout=300s \
  deployment/argocd-repo-server deployment/argocd-server >/dev/null 2>&1 || fail "argocd server never became available"
echo "    ok"

echo "==> 4. point argo cd at the merged companion repository"
kctl apply -f solution/argocd-app.yaml >/dev/null || fail "application apply"
SYNC=""; HEALTH=""
for i in $(seq 1 36); do
  SYNC=$(kctl get application m11-gitops-demo -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null)
  HEALTH=$(kctl get application m11-gitops-demo -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null)
  [ "$SYNC" = "Synced" ] && [ "$HEALTH" = "Healthy" ] && break
  sleep 5
done
[ "$SYNC" = "Synced" ] && [ "$HEALTH" = "Healthy" ] || fail "application never went Synced/Healthy (sync=$SYNC health=$HEALTH)"
kctl get namespace "$APP_NS" >/dev/null 2>&1 || fail "controller did not create namespace $APP_NS"
kctl get configmap m11-gitops-demo -n "$APP_NS" -o jsonpath='{.data.message}' | grep -q "reconciled by GitOps" || fail "configmap missing expected message"
[ "$(kctl get configmap m11-gitops-demo -n "$APP_NS" -o jsonpath='{.data.version}')" = "v2" ] || fail "configmap not at v2, the controller did not reconcile PR 4's merge"
echo "    ok: Synced/Healthy, ConfigMap v2 reconciled into $APP_NS from the merged repository"

echo "==> 5. self-heal: tamper directly, confirm the controller corrects it"
kctl patch configmap m11-gitops-demo -n "$APP_NS" --type merge -p '{"data":{"message":"tampered"}}' >/dev/null || fail "patch"
HEALED=0
for i in $(seq 1 20); do
  MSG=$(kctl get configmap m11-gitops-demo -n "$APP_NS" -o jsonpath='{.data.message}' 2>/dev/null)
  [ "$MSG" = "reconciled by GitOps, not kubectl apply" ] && { HEALED=1; break; }
  sleep 4
done
[ "$HEALED" = "1" ] || fail "self-heal never corrected the tampered configmap"
echo "    ok: self-heal confirmed"

echo "==> 6. numbered teardown: remove application, delete cluster"
kctl delete -f solution/argocd-app.yaml >/dev/null || fail "application delete"
kind delete cluster --name "$CLUSTER_NAME" >/dev/null 2>&1 || fail "cluster delete"
docker ps -a --filter "name=$CLUSTER_NAME" --format '{{.Names}}' | grep -q "$CLUSTER_NAME" && fail "orphan cluster container remains"
rm -rf "$LOG_DIR"
echo "    ok: application removed, cluster deleted, no orphans"

echo
echo "LAB PASSED: merged PR evidence present, kind cluster, argo cd ${ARGOCD_VERSION} synced/healthy at v2, self-heal, teardown clean"
