#!/usr/bin/env bash
# Capstone pipeline. The agent proposes, this script decides.
#
# Usage:
#   pipeline.sh <module>          run every gate against <module>
#   pipeline.sh apply <module>    apply the plan the gates produced, only if a
#                                 human approved that exact plan
#
# <module> is `starter`, `solution`, or a path to any Terraform directory, for
# example `../tier3-aws-optional`.
#
# Seven enforced gates, in order. Each one can stop the run:
#   1 fmt   2 validate   3 Trivy   4 Checkov   5 OPA/Conftest
#   6 blast radius   7 human approval
# Infracost is named where it would sit (after the blast-radius gate) and is not
# enforced in this lab, because it needs an Infracost account. See rubric.md.
#
# How failures stop the run. A tool that cannot run (missing binary, crash,
# unreadable output) stops the pipeline immediately. A gate that runs and finds
# something records the failure, the remaining mechanical gates still report
# their verdict, the way a CI run shows every failed check at once, and then the
# pipeline stops before human approval with a non-zero exit. No failed run ever
# reaches the approval gate, writes an approval record, or applies.
#
# Approval and apply. When a human sets CAPSTONE_HUMAN_APPROVED=1, the approval
# gate records a SHA-256 of the exact plan file it approved. `pipeline.sh apply`
# refuses to run unless the plan on disk matches that record, applies that saved
# plan and nothing else, then deletes the record: one approval, one apply.
# Who is allowed to run `apply` at all is an organisational control (CI
# permissions, IAM) that sits outside this lab.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"
WORK="$HERE/.pipeline"
mkdir -p "$WORK"

fail(){ echo "PIPELINE BLOCKED: $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || fail "required tool not found: $1"; }
sha256(){ if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

ACTION="run"
if [ "${1:-}" = "apply" ]; then ACTION="apply"; shift; fi
MODULE_ARG="${1:?usage: pipeline.sh [apply] <starter|solution|path>}"
if [ -d "$HERE/$MODULE_ARG" ]; then
  MODULE_DIR="$(cd "$HERE/$MODULE_ARG" && pwd)"
elif [ -d "$MODULE_ARG" ]; then
  MODULE_DIR="$(cd "$MODULE_ARG" && pwd)"
else
  fail "no such module directory: $MODULE_ARG"
fi
NAME="$(basename "$MODULE_DIR")"
PLAN="$WORK/$NAME.tfplan"
PLAN_JSON="$WORK/$NAME.plan.json"
APPROVAL="$WORK/$NAME.approved.sha256"
LOG="$WORK/$NAME"

# Checkov scope comes from spec.md SC-002: versioning, the four public-access
# block settings, and secrets. Every other Checkov rule is outside this module's
# own spec (see spec.md for why).
CHECKOV_CHECKS="CKV_AWS_21,CKV_AWS_53,CKV_AWS_54,CKV_AWS_55,CKV_AWS_56,CKV_SECRET_2"

# The module declares config_api_key as a sensitive variable with no default.
# Against the emulator a stand-in value is fine; in a real run it comes from a
# secret store, never from this file.
export TF_VAR_config_api_key="${TF_VAR_config_api_key:-pipeline-test-key}"

for t in terraform jq; do need "$t"; done

# ---------------------------------------------------------------- apply ------
if [ "$ACTION" = "apply" ]; then
  echo "==> apply: $NAME, from the approved saved plan only"
  [ -f "$PLAN" ] || fail "no plan for $NAME. run: pipeline.sh $MODULE_ARG"
  [ -f "$APPROVAL" ] || fail "no approval record for $NAME. a human has not approved this plan"
  WANT="$(cat "$APPROVAL")"
  HAVE="$(sha256 "$PLAN")"
  [ "$HAVE" = "$WANT" ] || fail "the plan on disk is not the plan that was approved (approved ${WANT:0:12}..., on disk ${HAVE:0:12}...). re-run the pipeline and approve again"
  echo "    approval record matches plan ${HAVE:0:12}..."
  terraform -chdir="$MODULE_DIR" apply -input=false -no-color "$PLAN" 2>&1 | tee "$LOG.apply.log"
  grep -q "Apply complete" "$LOG.apply.log" || fail "apply did not complete, see $LOG.apply.log"
  rm -f "$APPROVAL"
  echo "    approval record consumed: one approval, one apply"
  exit 0
fi

# ---------------------------------------------------------------- gates ------
for t in trivy checkov conftest; do need "$t"; done
rm -f "$APPROVAL" "$PLAN" "$PLAN_JSON"
FAILED=""

echo "==> stage 1: fmt + validate (gates 1 and 2)"
terraform -chdir="$MODULE_DIR" fmt -check -diff >"$LOG.fmt.log" 2>&1 || fail "fmt: $(cat "$LOG.fmt.log")"
terraform -chdir="$MODULE_DIR" init -input=false -no-color >"$LOG.init.log" 2>&1 || fail "init: $(tail -20 "$LOG.init.log")"
terraform -chdir="$MODULE_DIR" validate -no-color >"$LOG.validate.log" 2>&1 || fail "validate: $(cat "$LOG.validate.log")"
echo "    ok"

echo "==> stage 2: trivy, HIGH/CRITICAL (gate 3)"
TRIVY_CODE=0
trivy config --quiet --exit-code 1 --severity HIGH,CRITICAL --ignorefile "$HERE/.trivyignore" "$MODULE_DIR" >"$LOG.trivy.log" 2>&1 || TRIVY_CODE=$?
if grep -qi "FATAL\|panic:" "$LOG.trivy.log" || ! grep -q "Report Summary\|Misconfigurations" "$LOG.trivy.log"; then
  fail "trivy did not run cleanly: $(tail -5 "$LOG.trivy.log")"
fi
if [ "$TRIVY_CODE" -ne 0 ]; then
  echo "    FAILED: $(grep -oE "(AVD-)?AWS-[0-9]{4}" "$LOG.trivy.log" | sort -u | tr '\n' ' ')"
  FAILED="$FAILED trivy"
else
  echo "    ok (AVD-AWS-0132 ignored by .trivyignore, per spec.md SC-003)"
fi

echo "==> stage 3: checkov, spec SC-002 scope (gate 4)"
CHECKOV_CODE=0
checkov -d "$MODULE_DIR" --compact --quiet --check "$CHECKOV_CHECKS" >"$LOG.checkov.log" 2>&1 || CHECKOV_CODE=$?
grep -q "Passed checks:" "$LOG.checkov.log" || fail "checkov did not run cleanly: $(tail -5 "$LOG.checkov.log")"
if [ "$CHECKOV_CODE" -ne 0 ]; then
  echo "    FAILED: $(grep -o "CKV[0-9_A-Z]*" "$LOG.checkov.log" | sort -u | tr '\n' ' ')"
  FAILED="$FAILED checkov"
else
  echo "    ok"
fi

echo "==> stage 4: plan, then OPA/Conftest on the plan (gate 5)"
terraform -chdir="$MODULE_DIR" plan -no-color -input=false -out="$PLAN" >"$LOG.plan.log" 2>&1 || fail "plan: $(tail -20 "$LOG.plan.log")"
terraform -chdir="$MODULE_DIR" show -json "$PLAN" >"$PLAN_JSON" 2>"$LOG.show.log" || fail "show -json: $(cat "$LOG.show.log")"
jq -e '(.format_version | type) == "string"' "$PLAN_JSON" >/dev/null 2>&1 || fail "plan JSON is not readable"
CONFTEST_CODE=0
conftest test --no-color --policy "$HERE/policy" "$PLAN_JSON" >"$LOG.conftest.log" 2>&1 || CONFTEST_CODE=$?
grep -Eq " tests?, " "$LOG.conftest.log" || fail "conftest did not run cleanly: $(cat "$LOG.conftest.log")"
if [ "$CONFTEST_CODE" -ne 0 ]; then
  echo "    FAILED:"
  grep "FAIL" "$LOG.conftest.log" | sed 's/^/      /'
  FAILED="$FAILED opa"
else
  echo "    ok"
fi

echo "==> stage 5: blast-radius gate on the plan (gate 6)"
GATE_CODE=0
bash "$HERE/blast_radius_gate.sh" "$PLAN_JSON" >"$LOG.gate.log" 2>&1 || GATE_CODE=$?
if grep -q "GATE ERROR" "$LOG.gate.log"; then
  fail "blast-radius gate could not read the plan: $(cat "$LOG.gate.log")"
fi
if [ "$GATE_CODE" -ne 0 ]; then
  echo "    FAILED: $(grep BLOCKED "$LOG.gate.log")"
  FAILED="$FAILED blast-radius"
else
  echo "    ok ($(grep '==> gate' "$LOG.gate.log" | sed 's/==> gate: //'))"
fi

echo "==> stage 6: infracost"
echo "    named, not enforced in this lab (needs an Infracost account), see rubric.md"

if [ -n "$FAILED" ]; then
  rm -f "$APPROVAL"
  echo
  echo "PIPELINE STOPPED before human approval -- failed gates:$FAILED"
  echo "nothing from this run can be approved or applied"
  exit 1
fi

echo "==> stage 7: HUMAN APPROVAL -- the only place apply is authorised (gate 7)"
echo "    plan to approve: $(grep '^Plan:' "$LOG.plan.log" || echo 'no changes')"
if [ "${CAPSTONE_HUMAN_APPROVED:-0}" != "1" ]; then
  fail "not approved. set CAPSTONE_HUMAN_APPROVED=1 to simulate a human reading this plan and approving it. the pipeline never sets this itself."
fi
sha256 "$PLAN" > "$APPROVAL"
echo "    approved (CAPSTONE_HUMAN_APPROVED=1), plan $(cut -c1-12 "$APPROVAL")... recorded in .pipeline/$NAME.approved.sha256"

echo
echo "PIPELINE PASSED -- $NAME cleared every gate, human approval recorded for this exact plan"
echo "next: bash pipeline.sh apply $MODULE_ARG"
