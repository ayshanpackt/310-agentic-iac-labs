#!/usr/bin/env bash
# M09 reference pipeline: five stages, cheapest first, every stage able to stop the run.
# Fails closed: any tool that exits non-zero, including `terraform show -json`, blocks the
# pipeline. Evidence is written to a fresh directory on every run so a stale plan from an
# earlier run can never be mistaken for this one.
set -euo pipefail
cd "$(dirname "$0")"
TARGET="${1:-module}"
ENDPOINT="${ENDPOINT:-http://localhost:4566}"
OUT="${M09_OUT:-/tmp/m09-pipeline}"
rm -rf "$OUT" && mkdir -p "$OUT"

echo "==> stage 1/5: fmt + validate"
terraform -chdir="$TARGET" init -backend=false -input=false -no-color >"$OUT/init.log" 2>&1 || { cat "$OUT/init.log"; echo "BLOCKED at init"; exit 1; }
terraform -chdir="$TARGET" fmt -check -diff || { echo "BLOCKED at fmt"; exit 1; }
terraform -chdir="$TARGET" validate -no-color || { echo "BLOCKED at validate"; exit 1; }

echo "==> stage 2/5: trivy"
trivy config --quiet --exit-code 1 --severity HIGH,CRITICAL "$TARGET" || { echo "BLOCKED at trivy"; exit 1; }
echo "    trivy: no HIGH/CRITICAL findings"

echo "==> stage 3/5: checkov"
# No --skip-check here. Every waiver lives inline on the one resource it covers, as a
# #checkov:skip=CKV_...:reason comment in the .tf file, so it is scoped to that resource
# and reviewed next to the code. A CLI-wide skip would silence the same check for every
# resource in the target. Checkov counts inline waivers under "Skipped checks".
checkov -d "$TARGET" --compact --quiet --framework terraform --skip-download || { echo "BLOCKED at checkov"; exit 1; }
echo "    checkov: no unreviewed findings"

echo "==> stage 4/5: conftest (org policy: every aws_s3_bucket needs tags.Owner)"
terraform -chdir="$TARGET" plan -no-color -out="$OUT/plan.bin" -var="endpoint=${ENDPOINT}" >"$OUT/plan.log" 2>&1 || { cat "$OUT/plan.log"; echo "BLOCKED at plan"; exit 1; }
# The policy reads the plan as JSON. If this conversion fails, or produces something that
# is not a complete plan, there is no evidence to evaluate and the run stops here. Without
# this check an empty file would sail through conftest with zero failures.
terraform -chdir="$TARGET" show -json "$OUT/plan.bin" >"$OUT/plan.json" || { echo "BLOCKED at plan-json (terraform show -json failed)"; exit 1; }
python3 - "$OUT/plan.json" <<'PY' || { echo "BLOCKED at plan-json (not a complete Terraform plan)"; exit 1; }
import json, sys
plan = json.load(open(sys.argv[1]))
assert plan.get("format_version"), "no format_version"
assert "planned_values" in plan, "no planned_values"
print(f"    plan json: format {plan['format_version']}, {len(plan.get('resource_changes', []))} resource changes")
PY
conftest test --policy policy "$OUT/plan.json" || { echo "BLOCKED at conftest"; exit 1; }

echo "==> stage 5/5: cost gate (infracost)"
if [ -n "${INFRACOST_API_KEY:-}" ]; then
  infracost breakdown --path "$TARGET" --format json >"$OUT/infracost.json" 2>"$OUT/infracost.err" || { cat "$OUT/infracost.err"; echo "BLOCKED at cost stage (infracost error)"; exit 1; }
  echo "    infracost ran, see $OUT/infracost.json for the real estimate"
else
  echo "    SKIPPED: no INFRACOST_API_KEY set. Run 'infracost auth login' once (free, no card)"
  echo "    to enable this stage for real. See reading/reference.md."
fi

echo
echo "PIPELINE PASSED for $TARGET: every stage that could run, ran for real and passed"
