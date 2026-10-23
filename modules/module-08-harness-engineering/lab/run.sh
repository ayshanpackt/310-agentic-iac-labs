#!/usr/bin/env bash
# run.sh -- validates Project 08 end to end, for real.
#
#   ./run.sh                 starter RED, solution GREEN, checkov, real Floci apply + destroy
#   M08_LIVE_AGENT=1 ./run.sh   also runs the Claude Code probe and asserts the bootstrap answered
#
# Requires terraform (1.6+ for `terraform test`), checkov, and Docker reachable at
# /var/run/docker.sock. Floci is started from labs/shared/docker-compose.floci.yml if it is
# not already answering on :4566.
set -uo pipefail
cd "$(dirname "$0")"
fail(){ echo "FAIL: $*" >&2; exit 1; }
ROOT="$(cd ../../.. && pwd)"
W=/tmp/m08-run; rm -rf "$W"; mkdir -p "$W"

echo "==> starter: the tests written in Stage 3 must be RED against the bare table, each for its own reason"
cp -R orders "$W/starter"; mkdir -p "$W/starter/tests"; cp solution/tests/*.tftest.hcl "$W/starter/tests/"
(cd "$W/starter" && terraform init -backend=false -input=false -no-color >/dev/null 2>&1) || fail "starter init"
for f in "$W"/starter/tests/*.tftest.hcl; do
  name=$(basename "$f" .tftest.hcl)
  (cd "$W/starter" && terraform test -no-color -filter="tests/$name.tftest.hcl") >"$W/starter-test-$name.log" 2>&1
  CODE=$?
  [ "$CODE" -ne 0 ] || fail "tests/$name should be RED before the fix"
  grep -q "Reference to undeclared resource" "$W/starter-test-$name.log" && fail "tests/$name: RED must not be an undeclared-resource error"
done
# PITR and SSE are nested blocks: absent from config they are computed, so plan mode reports
# "Unknown condition value" naming the attribute. That is the right RED for a missing block.
# The policy test is a plain assertion failure naming the wildcard.
grep -q "point_in_time_recovery" "$W/starter-test-pitr.log" || fail "pitr RED must name point_in_time_recovery"
grep -q "server_side_encryption" "$W/starter-test-sse.log" || fail "sse RED must name server_side_encryption"
grep -Eiq "read-only|dynamodb:\*|wildcard" "$W/starter-test-policy.log" || fail "policy RED must name the wildcard or read-only rule"
echo "    ok, red for the right reasons"

echo "==> solution: the same tests must be GREEN"
cp -R solution "$W/solution"; rm -rf "$W/solution/docs"
(cd "$W/solution" && terraform init -backend=false -input=false -no-color >/dev/null 2>&1) || fail "solution init"
(cd "$W/solution" && terraform validate -no-color) >"$W/solution-validate.log" 2>&1 || fail "solution validate"
(cd "$W/solution" && terraform test -no-color) >"$W/solution-test.log" 2>&1 || fail "solution tests should be GREEN"
grep -q "Success!" "$W/solution-test.log" || fail "expected a Success! line from terraform test"
echo "    ok, green"

echo "==> solution: checkov must not report the two hardening checks the tests cover"
checkov -d "$W/solution" --framework terraform --compact --quiet >"$W/solution-checkov.log" 2>&1
grep -q "CKV_AWS_28:" "$W/solution-checkov.log" && fail "CKV_AWS_28 (point-in-time recovery) should pass on the solution"
echo "    ok. Other findings may remain and are listed honestly in LAB.md"

echo "==> floci: real apply and destroy of the solution"
if ! curl -fsS http://localhost:4566/_floci/health >/dev/null 2>&1; then
  docker compose -f "$ROOT/labs/shared/docker-compose.floci.yml" up -d >/dev/null 2>&1 || fail "could not start floci"
  for i in $(seq 1 24); do curl -fsS http://localhost:4566/_floci/health >/dev/null 2>&1 && break; sleep 5; done
  curl -fsS http://localhost:4566/_floci/health >/dev/null 2>&1 || fail "floci did not become healthy"
fi
(cd "$W/solution" && terraform init -input=false -no-color >/dev/null 2>&1) || fail "solution init for apply"
(cd "$W/solution" && terraform apply -auto-approve -input=false -no-color) >"$W/apply.log" 2>&1 || { tail -20 "$W/apply.log"; fail "apply"; }
grep -q "Apply complete! Resources: 2 added" "$W/apply.log" || fail "expected 2 resources added"
(cd "$W/solution" && terraform destroy -auto-approve -input=false -no-color) >"$W/destroy.log" 2>&1 || fail "destroy"
grep -q "Destroy complete! Resources: 2 destroyed" "$W/destroy.log" || fail "expected 2 resources destroyed"
echo "    ok, applied and destroyed against floci"

if [ "${M08_LIVE_AGENT:-0}" = "1" ]; then
  echo "==> live agent: the Superpowers bootstrap must answer in Claude Code"
  command -v claude >/dev/null || fail "claude not on PATH"
  claude -p "Do you have superpowers? Answer in one line: yes or no, then list the exact names of the superpowers skills you can invoke, comma separated. Do not invoke any skill." --max-turns 1 >"$W/probe.log" 2>&1
  grep -qi "^yes" "$W/probe.log" || { cat "$W/probe.log"; fail "bootstrap did not answer yes; is superpowers@claude-plugins-official installed and enabled?"; }
  grep -q "verification-before-completion" "$W/probe.log" || fail "probe did not list the skills"
  echo "    ok, bootstrap loaded"
fi

echo "ALL OK"
