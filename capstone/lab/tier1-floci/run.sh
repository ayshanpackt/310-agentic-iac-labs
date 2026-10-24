#!/usr/bin/env bash
# Tier 1 capstone, end to end, for real, against Floci. Exits non-zero on any
# regression. Every step below is a test of the pipeline, including the ones
# that prove it refuses to do things.
#
#   1  preflight: tools present, no leftover state
#   2  Floci up, Docker socket mounted, health endpoint verified, before any plan
#   3  blast-radius gate rejects unreadable input (empty, invalid JSON, not a plan)
#   4  blast-radius gate blocks deletes, oversized plans, high-radius types
#   5  pipeline BLOCKS the starter module (Trivy, Checkov, OPA, all real)
#   6  pipeline BLOCKS a solution copy with one regression (public ACLs allowed)
#   7  pipeline stops immediately when a scanner is missing
#   8  pipeline BLOCKS the solution module without human approval; apply refused
#   9  pipeline PASSES the solution module once approved; records the plan hash
#  10  apply refuses a plan that changed after approval
#  11  real apply, from the approved saved plan only
#  12  real drift, introduced against the emulated S3 API, caught on re-plan
#  13  numbered teardown: terraform destroy, remove Floci, clear pipeline state
#
# Env:
#   CAPSTONE_FLOCI_PORT   host port for Floci, default 4566
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"
PORT="${CAPSTONE_FLOCI_PORT:-4566}"
FLOCI="cap-floci-run"
WORK="$HERE/.pipeline"
RUNLOG="$WORK/run"
FIX="$WORK/fixtures"
mkdir -p "$RUNLOG" "$FIX"
export TF_VAR_endpoint="http://localhost:$PORT"
export TF_VAR_config_api_key="run-sh-test-key"
unset CAPSTONE_HUMAN_APPROVED

cleanup_floci(){ docker rm -f "$FLOCI" >/dev/null 2>&1 || true; }
fail(){ echo "FAIL: $*" >&2; cleanup_floci; exit 1; }
# run <logname> <cmd...>: run, capture, return the exit code without tripping set -e
run(){ local log="$RUNLOG/$1.log"; shift; "$@" >"$log" 2>&1 && return 0 || return $?; }
expect_fail(){ local log="$1"; shift; if run "$log" "$@"; then return 1; fi; return 0; }

echo "==> 1. preflight"
for t in terraform trivy checkov conftest jq docker curl aws; do
  command -v "$t" >/dev/null 2>&1 || fail "required tool not found: $t (the AWS CLI is required for the drift step)"
done
if [ -f solution/terraform.tfstate ] && [ "$(jq '.resources | length' solution/terraform.tfstate)" != "0" ]; then
  fail "solution/terraform.tfstate still holds resources from an earlier run. destroy them or remove the state file, then re-run"
fi
rm -f "$WORK"/*.approved.sha256 "$WORK"/*.tfplan "$WORK"/*.plan.json
echo "    ok"

echo "==> 2. floci up, docker socket mounted, health verified before any plan"
cleanup_floci
if curl -fsS "http://localhost:$PORT/_floci/health" >/dev/null 2>&1; then
  fail "something already answers on port $PORT. stop it, or set CAPSTONE_FLOCI_PORT to a free port"
fi
docker run -d --name "$FLOCI" -p "$PORT:4566" -v /var/run/docker.sock:/var/run/docker.sock floci/floci:1.7.0 >/dev/null || fail "floci start"
for _ in $(seq 1 30); do curl -fsS "http://localhost:$PORT/_floci/health" >"$RUNLOG/floci-health.log" 2>&1 && break; sleep 2; done
curl -fsS "http://localhost:$PORT/_floci/health" >/dev/null 2>&1 || fail "floci never healthy on port $PORT"
docker inspect "$FLOCI" --format '{{range .Mounts}}{{.Source}}{{end}}' | grep -q docker.sock || fail "docker socket is not mounted into floci"
echo "    ok, floci/floci:1.7.0 healthy on :$PORT, socket mounted: $(cat "$RUNLOG/floci-health.log")"

echo "==> 3. blast-radius gate rejects unreadable input"
: > "$FIX/empty.json"
echo '{not json' > "$FIX/invalid.json"
echo '{}' > "$FIX/not-a-plan.json"
echo '[]' > "$FIX/array.json"
for f in empty invalid not-a-plan array missing; do
  expect_fail "gate-$f" bash blast_radius_gate.sh "$FIX/$f.json" || fail "gate accepted $f.json"
  grep -q "GATE ERROR" "$RUNLOG/gate-$f.log" || fail "gate did not report an error for $f.json"
done
echo "    ok, 5 bad inputs, 5 GATE ERRORs"

echo "==> 4. blast-radius gate blocks deletes, oversized plans, high-radius types"
mkplan(){ # mkplan <file> <type> <actions-json> <count>
  jq -n --arg t "$2" --argjson a "$3" --argjson n "$4" \
    '{format_version:"1.2", resource_changes:[range($n) | {address:"\($t).r\(.)", type:$t, name:"r\(.)", change:{actions:$a}}]}' > "$1"
}
mkplan "$FIX/delete.json" aws_s3_bucket '["delete"]' 1
mkplan "$FIX/oversized.json" aws_s3_bucket '["create"]' 6
mkplan "$FIX/high-radius.json" aws_iam_role '["create"]' 1
mkplan "$FIX/clean.json" aws_s3_bucket '["create"]' 4
expect_fail gate-delete bash blast_radius_gate.sh "$FIX/delete.json" || fail "gate passed a delete"
grep -q "BLOCKED: 1 delete" "$RUNLOG/gate-delete.log" || fail "delete not named"
expect_fail gate-oversized bash blast_radius_gate.sh "$FIX/oversized.json" || fail "gate passed 6 changes"
grep -q "BLOCKED: 6 resource changes" "$RUNLOG/gate-oversized.log" || fail "oversize not named"
expect_fail gate-high bash blast_radius_gate.sh "$FIX/high-radius.json" || fail "gate passed aws_iam_role"
grep -q "high-radius type 'aws_iam_role'" "$RUNLOG/gate-high.log" || fail "high-radius type not named"
run gate-clean bash blast_radius_gate.sh "$FIX/clean.json" || fail "gate blocked a clean 4-create plan"
echo "    ok, 3 blocked for the right reason, 1 clean plan passed"

echo "==> 5. pipeline must BLOCK the starter module (trivy, checkov, OPA, all real)"
expect_fail starter bash pipeline.sh starter || fail "starter should not have cleared the pipeline"
grep -q "PIPELINE STOPPED before human approval -- failed gates: trivy checkov opa" "$RUNLOG/starter.log" \
  || fail "expected trivy, checkov and opa to fail on starter: $(tail -3 "$RUNLOG/starter.log")"
[ ! -f "$WORK/starter.approved.sha256" ] || fail "a failed run must never leave an approval record"
expect_fail starter-apply bash pipeline.sh apply starter || fail "apply of the starter must be refused"
echo "    ok"

echo "==> 6. pipeline must BLOCK a solution copy with one regression"
rm -rf "${FIX:?}/regressed"; mkdir -p "$FIX/regressed"
# Flip one flag, block_public_acls, to false: FR-002 broken. Trivy (AWS-0086)
# and Checkov (CKV_AWS_53) must both notice, and the run must stop.
sed 's/block_public_acls       = true/block_public_acls       = false/' solution/main.tf > "$FIX/regressed/main.tf"
grep -q "block_public_acls       = false" "$FIX/regressed/main.tf" || fail "fixture did not flip the flag"
expect_fail regressed bash pipeline.sh "$FIX/regressed" || fail "a module with public ACLs allowed cleared the pipeline"
grep -q "failed gates: trivy checkov" "$RUNLOG/regressed.log" || fail "expected trivy and checkov to catch the flipped flag: $(tail -3 "$RUNLOG/regressed.log")"
[ ! -f "$WORK/regressed.approved.sha256" ] || fail "a failed run must never leave an approval record"
echo "    ok, caught by $(grep -oE 'failed gates:.*' "$RUNLOG/regressed.log")"

echo "==> 7. pipeline must stop immediately when a scanner is missing"
rm -rf "${FIX:?}/bin"; mkdir -p "$FIX/bin"
for t in terraform checkov conftest jq shasum sha256sum bash cat grep sed tail cut sort tr tee rm mkdir dirname basename; do
  p="$(command -v "$t" 2>/dev/null || true)"; [ -n "$p" ] && ln -s "$p" "$FIX/bin/$t"
done
expect_fail no-trivy env PATH="$FIX/bin" bash pipeline.sh solution || fail "pipeline ran without trivy on PATH"
grep -q "required tool not found: trivy" "$RUNLOG/no-trivy.log" || fail "expected a missing-tool stop: $(tail -3 "$RUNLOG/no-trivy.log")"
echo "    ok"

echo "==> 8. pipeline must BLOCK the solution module without human approval"
expect_fail noapproval bash pipeline.sh solution || fail "solution should not clear without CAPSTONE_HUMAN_APPROVED=1"
grep -q "HUMAN APPROVAL" "$RUNLOG/noapproval.log" || fail "expected the approval stage to be the blocker"
grep -q "not approved" "$RUNLOG/noapproval.log" || fail "expected the not-approved message"
[ ! -f "$WORK/solution.approved.sha256" ] || fail "no approval record may exist without approval"
expect_fail noapproval-apply bash pipeline.sh apply solution || fail "apply must be refused without an approval record"
grep -q "no approval record" "$RUNLOG/noapproval-apply.log" || fail "apply refusal did not name the missing record"
echo "    ok"

echo "==> 9. pipeline must PASS the solution module once approved, and record the plan hash"
run approved env CAPSTONE_HUMAN_APPROVED=1 bash pipeline.sh solution || fail "solution should pass once approved: $(cat "$RUNLOG/approved.log")"
grep -q "PIPELINE PASSED" "$RUNLOG/approved.log" || fail "expected an explicit pass message"
[ -f "$WORK/solution.approved.sha256" ] || fail "approval record missing"
echo "    ok, $(grep 'plan to approve' "$RUNLOG/approved.log" | sed 's/^ *//')"

echo "==> 10. apply must refuse a plan that changed after approval"
cp "$WORK/solution.tfplan" "$FIX/approved-plan.bak"
printf 'x' >> "$WORK/solution.tfplan"
expect_fail tampered-apply bash pipeline.sh apply solution || fail "apply ran on a plan that differs from the approved one"
grep -q "not the plan that was approved" "$RUNLOG/tampered-apply.log" || fail "tamper refusal did not say why"
cp "$FIX/approved-plan.bak" "$WORK/solution.tfplan"
echo "    ok"

echo "==> 11. real floci apply, from the approved saved plan only"
run apply bash pipeline.sh apply solution || fail "apply: $(tail -20 "$RUNLOG/apply.log")"
grep -q "Apply complete! Resources: 4 added" "$RUNLOG/apply.log" || fail "expected 4 resources added: $(grep 'Apply complete' "$RUNLOG/apply.log")"
[ ! -f "$WORK/solution.approved.sha256" ] || fail "approval record must be consumed by the apply"
expect_fail second-apply bash pipeline.sh apply solution || fail "a second apply on a consumed approval must be refused"
echo "    ok, 4 resources applied, approval record consumed, second apply refused"

echo "==> 12. real drift, caught on re-plan (required step)"
aws --endpoint-url="http://localhost:$PORT" s3api put-bucket-versioning --bucket capstone-app-uploads --versioning-configuration Status=Suspended --region us-east-1 >"$RUNLOG/drift-inject.log" 2>&1 \
  || fail "could not introduce drift: $(cat "$RUNLOG/drift-inject.log")"
DRIFT_CODE=0
run drift-plan terraform -chdir=solution plan -no-color -input=false -detailed-exitcode || DRIFT_CODE=$?
[ "$DRIFT_CODE" -eq 2 ] || fail "expected plan exit code 2 (changes present), got $DRIFT_CODE: $(tail -5 "$RUNLOG/drift-plan.log")"
grep -q '"Suspended" -> "Enabled"' "$RUNLOG/drift-plan.log" || fail "expected the plan to show Suspended -> Enabled"
grep -q "1 to change" "$RUNLOG/drift-plan.log" || fail "expected exactly one change"
echo "    ok, drift caught: $(grep -o '"Suspended" -> "Enabled"' "$RUNLOG/drift-plan.log" | head -1), $(grep -o 'Plan: .*' "$RUNLOG/drift-plan.log")"

echo "==> 13. numbered teardown: terraform destroy, remove floci, clear pipeline state"
run destroy terraform -chdir=solution destroy -auto-approve -no-color || fail "destroy: $(tail -20 "$RUNLOG/destroy.log")"
grep -q "Destroy complete! Resources: 4 destroyed" "$RUNLOG/destroy.log" || fail "expected 4 resources destroyed: $(grep 'Destroy complete' "$RUNLOG/destroy.log")"
cleanup_floci
rm -rf "$FIX" "$WORK"/*.tfplan "$WORK"/*.plan.json "$WORK"/*.approved.sha256
echo "    ok"

echo
echo "TIER 1 PIPELINE PASSED -- floci verified before planning, gate fails closed on bad input, starter blocked, regression blocked, missing tool stops the run, approval required, apply only from the approved plan, drift caught, destroyed cleanly"
