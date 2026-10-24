#!/usr/bin/env bash
# Pre-apply gate. Blocks a terraform plan based on blast radius, mechanically,
# by reading `terraform show -json` output, not by asking the agent nicely.
#
# Usage: blast_radius_gate.sh <plan.json>
# Exit 0 = pass, safe to apply. Exit 1 = blocked, do not apply.
#
# The gate fails closed. A plan file that is missing, empty, not JSON, or not a
# Terraform plan is an error, not a pass: a gate that cannot read its input must
# never let that input through.
#
# Policy, overridable via env:
#   MAX_RESOURCES      default 5
#   BLOCK_ON_DELETE     default 1 (true)
#   HIGH_RADIUS_TYPES   default "aws_vpc,aws_iam_policy,aws_iam_role"
set -euo pipefail

PLAN_JSON="${1:?usage: blast_radius_gate.sh <plan.json>}"
MAX_RESOURCES="${MAX_RESOURCES:-5}"
BLOCK_ON_DELETE="${BLOCK_ON_DELETE:-1}"
HIGH_RADIUS_TYPES="${HIGH_RADIUS_TYPES:-aws_vpc,aws_iam_policy,aws_iam_role}"

gate_error(){ echo "GATE ERROR: $*" >&2; exit 1; }

[ -f "$PLAN_JSON" ] || gate_error "no such plan file: $PLAN_JSON"
[ -s "$PLAN_JSON" ] || gate_error "plan file is empty: $PLAN_JSON"

# Must parse as JSON, must be an object, must look like `terraform show -json`
# output: a string format_version, and resource_changes either absent (a plan
# with no changes) or an array.
jq -e 'type == "object"
       and (.format_version | type) == "string"
       and ((.resource_changes // []) | type) == "array"' "$PLAN_JSON" >/dev/null 2>&1 \
  || gate_error "not a readable terraform plan JSON: $PLAN_JSON"

TOTAL=$(jq '[(.resource_changes // [])[] | select(.change.actions != ["no-op"])] | length' "$PLAN_JSON")
DELETES=$(jq '[(.resource_changes // [])[] | select(.change.actions | index("delete"))] | length' "$PLAN_JSON")

echo "==> gate: ${TOTAL} resource change(s), ${DELETES} delete(s), max allowed ${MAX_RESOURCES}"

if [ "$BLOCK_ON_DELETE" = "1" ] && [ "$DELETES" -gt 0 ]; then
  echo "BLOCKED: ${DELETES} delete action(s) in this plan. block-on-delete is on." >&2
  jq -r '(.resource_changes // [])[] | select(.change.actions | index("delete")) | "  - delete: \(.type).\(.name)"' "$PLAN_JSON" >&2
  exit 1
fi

if [ "$TOTAL" -gt "$MAX_RESOURCES" ]; then
  echo "BLOCKED: ${TOTAL} resource changes exceeds the max-resources policy of ${MAX_RESOURCES}." >&2
  exit 1
fi

IFS=',' read -ra TYPES <<< "$HIGH_RADIUS_TYPES"
for t in "${TYPES[@]}"; do
  HIT=$(jq --arg t "$t" '[(.resource_changes // [])[] | select(.type == $t) | select(.change.actions != ["no-op"])] | length' "$PLAN_JSON")
  if [ "$HIT" -gt 0 ]; then
    echo "BLOCKED: this plan touches ${HIT} resource(s) of high-radius type '${t}'." >&2
    exit 1
  fi
done

echo "    ok, gate passes"
exit 0
