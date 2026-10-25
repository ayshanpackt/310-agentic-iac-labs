#!/usr/bin/env bash
# run.sh -- validates Project 12 for real, without calling an agent by default.
#
#   ./run.sh                     verifier, Stop gate, guard, budget cap, FinOps gate, workflow lint
#   M12_LIVE_AGENT=1 ./run.sh    also runs one real gated Claude Code session on the starter
#
# Requires terraform, checkov, python3 with PyYAML. actionlint is used when present.
set -uo pipefail
cd "$(dirname "$0")"
LAB="$PWD"
TMP=$(mktemp -d)
fail(){ echo "FAIL: $*" >&2; rm -rf "$TMP"; exit 1; }
sha(){ shasum -a 256 "$1" | cut -d' ' -f1; }
newcopy(){ # newcopy <name> <source-dir>: a fresh git working copy with the loop installed
  cp -r "$2" "$TMP/$1" && bash loop/install.sh "$TMP/$1" >/dev/null || fail "install.sh failed for $1"
  (cd "$TMP/$1" && git init -q && git add -A && git -c user.email=lab@example.com -c user.name=lab commit -qm base) \
    || fail "git init failed for $1"
}

for t in terraform checkov python3 git; do
  command -v "$t" >/dev/null 2>&1 || fail "$t is not on PATH"
done

echo "==> 1. verifier on the starter: NOT DONE, both hardcoded keys named"
newcopy starter starter
OUT=$("$TMP/starter/loop/verify.sh" 2>&1); CODE=$?
[ "$CODE" -eq 1 ] || fail "expected exit 1 on the starter, got $CODE: $OUT"
echo "$OUT" | grep -q "/main.tf:" || fail "verifier did not name the key in main.tf"
echo "$OUT" | grep -q "/shipper.tf:" || fail "verifier did not name the key in shipper.tf"
echo "    ok, exit 1, main.tf and shipper.tf both reported"

echo "==> 2. verifier on the solution: DONE"
newcopy solution solution
OUT=$("$TMP/solution/loop/verify.sh" 2>&1); CODE=$?
[ "$CODE" -eq 0 ] || fail "expected exit 0 on the solution, got $CODE: $OUT"
echo "    ok, exit 0"

echo "==> 3. a suppression is not a fix: checkov:skip on the solution must be NOT DONE"
newcopy skipped starter
python3 - "$TMP/skipped/main.tf" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
s = s.replace('variable "log_shipper_key" {', 'variable "log_shipper_key" {\n  #checkov:skip=CKV_SECRET_2:release cut', 1)
open(p, "w").write(s)
PY
OUT=$("$TMP/skipped/loop/verify.sh" 2>&1); CODE=$?
[ "$CODE" -eq 1 ] || fail "expected exit 1 with a checkov:skip comment, got $CODE: $OUT"
echo "$OUT" | grep -q "suppression, not a fix" || fail "verifier did not name the suppression"
echo "    ok, exit 1, suppression named"

echo "==> 4. no verdict: a broken provider block must exit 2, not 0 or 1"
newcopy broken starter
sed -i.bak 's#hashicorp/local#hashicorp/no-such-provider-m12#' "$TMP/broken/main.tf" && rm "$TMP/broken/main.tf.bak"
OUT=$("$TMP/broken/loop/verify.sh" 2>&1); CODE=$?
[ "$CODE" -eq 2 ] || fail "expected exit 2 on a broken provider, got $CODE: $OUT"
echo "$OUT" | grep -q "^NO VERDICT: terraform init failed" || fail "expected a no-verdict message, got: $OUT"
echo "    ok, exit 2"

echo "==> 5. Stop gate on the starter: blocks with exit 2, names the findings, records the block"
OUT=$(echo '{"hook_event_name":"Stop","stop_hook_active":false}' | "$TMP/starter/loop/hooks/stop-gate.sh" 2>&1); CODE=$?
[ "$CODE" -eq 2 ] || fail "expected the gate to block with exit 2, got $CODE"
echo "$OUT" | grep -q "shipper.tf" || fail "gate reason did not carry the verifier's findings"
grep -q "^- blocked " "$TMP/starter/.loop/state.md" || fail "gate did not record the block in .loop/state.md"
echo "    ok, exit 2, findings passed back, block recorded"

echo "==> 6. Stop gate on the solution: lets the agent stop, records DONE"
echo '{}' | "$TMP/solution/loop/hooks/stop-gate.sh" >/dev/null 2>&1; CODE=$?
[ "$CODE" -eq 0 ] || fail "expected the gate to allow stopping on the solution, got $CODE"
grep -q "^- done " "$TMP/solution/.loop/state.md" || fail "gate did not record DONE"
echo "    ok, exit 0, done recorded"

echo "==> 7. budget cap: after LOOP_MAX_BLOCKS blocks the gate stops the loop without DONE"
for i in 1 2; do echo '{}' | LOOP_MAX_BLOCKS=2 "$TMP/starter/loop/hooks/stop-gate.sh" >/dev/null 2>&1; done
OUT=$(echo '{}' | LOOP_MAX_BLOCKS=2 "$TMP/starter/loop/hooks/stop-gate.sh" 2>&1); CODE=$?
[ "$CODE" -eq 0 ] || fail "expected the gate to release at the cap, got $CODE"
tail -1 "$TMP/starter/.loop/state.md" | grep -q "^- budget exhausted" || fail "cap not recorded as budget exhausted"
echo "    ok, released at the cap, recorded as budget exhausted, never as done"

echo "==> 8. Stop gate with no verdict: lets the session end and records it, never as done"
echo '{}' | "$TMP/broken/loop/hooks/stop-gate.sh" >/dev/null 2>&1; CODE=$?
[ "$CODE" -eq 0 ] || fail "expected the gate to end the session on no verdict, got $CODE"
tail -1 "$TMP/broken/.loop/state.md" | grep -q "^- no verdict" || fail "no-verdict not recorded"
echo "    ok"

echo "==> 9. guard: the agent may edit main.tf but not the verifier, the hooks or the loop state"
for p in loop/verify.sh loop/hooks/stop-gate.sh .claude/settings.json .codex/hooks.json .loop/state.md; do
  printf '{"tool_input":{"file_path":"%s"}}' "$TMP/starter/$p" | "$TMP/starter/loop/hooks/guard-oracle.sh" 2>/dev/null
  [ $? -eq 2 ] || fail "guard allowed an edit to $p"
done
printf '{"tool_input":{"file_path":"%s"}}' "$TMP/starter/main.tf" | "$TMP/starter/loop/hooks/guard-oracle.sh" || fail "guard blocked main.tf"
echo "    ok, five protected paths blocked, main.tf allowed"

echo "==> 10. trace.py reads a real captured run"
python3 loop/trace.py evidence/stage3-hook.jsonl | tail -1 | grep -q "^turns " || fail "trace.py could not read evidence/stage3-hook.jsonl"
echo "    ok"

echo "==> 11. FinOps gate: fixtures"
python3 finops/gate.py finops/plan-over-budget.json >/dev/null && fail "gate should have rejected plan-over-budget.json"
python3 finops/gate.py finops/plan-in-budget.json >/dev/null || fail "gate should have accepted plan-in-budget.json"
python3 finops/gate.py finops/plan-empty.json >/dev/null 2>&1; [ $? -eq 2 ] || fail "gate should refuse plan-empty.json with exit 2"
python3 finops/gate.py finops/plan-nested.json >/dev/null; [ $? -eq 1 ] || fail "gate should reject the child-module violation"
python3 finops/test_gate.py >/dev/null 2>&1 || fail "finops/test_gate.py failed"
echo "    ok, rejects, accepts, refuses an invalid plan, walks child modules, unit tests pass"

echo "==> 12. nightly workflow example: valid YAML, real cron, manual dispatch, paths resolve"
python3 - <<'PY' || fail "workflow example invalid"
import os, yaml
d = yaml.safe_load(open("solution/trigger-workflow.example.yml"))
on = d[True]
assert len(on["schedule"][0]["cron"].split()) == 5 and "workflow_dispatch" in on
root = os.path.abspath("../../..")
for key in ("LAB", "TARGET"):
    assert os.path.isdir(os.path.join(root, d["env"][key])), key + " does not resolve"
print("    ok, cron:", on["schedule"][0]["cron"])
PY
if command -v actionlint >/dev/null 2>&1; then
  actionlint solution/trigger-workflow.example.yml || fail "actionlint rejected the workflow"
  echo "    ok, actionlint clean"
else
  echo "    (actionlint not installed, lint skipped)"
fi

if [ "${M12_LIVE_AGENT:-0}" = "1" ]; then
  echo "==> 13. live: one gated Claude Code session on the starter must end with DONE"
  command -v claude >/dev/null || fail "claude not on PATH"
  newcopy live starter
  (cd "$TMP/live" && claude -p "The log shipper's AWS key is hardcoded as the variable default in main.tf. Take it out of main.tf." \
     --permission-mode acceptEdits \
     --allowedTools "Read,Edit,Write,Bash(terraform *),Bash(checkov *),Bash(loop/verify.sh*),Bash(git diff*)" \
     --output-format stream-json --verbose > run.jsonl 2>&1)
  python3 loop/trace.py "$TMP/live/run.jsonl" | tail -1
  tail -1 "$TMP/live/.loop/state.md" | grep -q "^- done " || fail "live loop did not end with DONE: $(tail -1 "$TMP/live/.loop/state.md")"
  "$TMP/live/loop/verify.sh" >/dev/null 2>&1 || fail "live loop recorded DONE but verify.sh disagrees"
  echo "    ok, the gate recorded DONE and an independent verify.sh agrees"
fi

rm -rf "$TMP"
echo
echo "LAB PASSED -- verifier: two findings, done, suppression refused, no verdict; Stop gate blocks, releases, caps, records; guard protects the loop; FinOps gate and workflow example valid"
