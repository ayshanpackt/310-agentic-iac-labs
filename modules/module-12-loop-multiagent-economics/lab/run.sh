set -uo pipefail
cd "$(dirname "$0")"
fail(){ echo "FAIL: $*" >&2; rm -rf solution/work solution/work-broken; exit 1; }
sha(){ shasum -a 256 "$1" | cut -d' ' -f1; }

rm -rf solution/work solution/work-broken

echo "==> 1. trigger config: valid workflow, real 5-field cron, workflow_dispatch, loop path resolves"
python3 -c "
import os, yaml
d = yaml.safe_load(open('solution/trigger-workflow.example.yml'))
cron = d[True]['schedule'][0]['cron']
parts = cron.split()
assert len(parts) == 5, 'not a real 5-field cron expression'
assert 'workflow_dispatch' in d[True]
loop = d['env']['LOOP']
repo_root = os.path.abspath(os.path.join(os.getcwd(), '..', '..', '..'))
assert os.path.isfile(os.path.join(repo_root, loop)), 'workflow points at a loop.sh that does not exist: ' + loop
print('    ok, cron:', cron, '| loop path:', loop)
" || fail "trigger config invalid"
if command -v actionlint >/dev/null 2>&1; then
  actionlint solution/trigger-workflow.example.yml || fail "actionlint rejected the workflow"
  echo "    ok, actionlint clean"
else
  echo "    (actionlint not installed, skipping the workflow lint)"
fi

echo "==> 2. run 1: stopping condition not yet met, must CONTINUE"
OUT1=$(bash solution/loop.sh solution/work 2>&1)
echo "$OUT1" | grep -q "^CONTINUE:" || fail "run 1 should have printed CONTINUE, got: $OUT1"
echo "    ok"

echo "==> 3. run 2: same work dir, real fix now applied, must STOP"
OUT2=$(bash solution/loop.sh solution/work 2>&1)
echo "$OUT2" | grep -q "^STOPPED:" || fail "run 2 should have printed STOPPED, got: $OUT2"
echo "    ok"

echo "==> 4. run 3: already stopped, re-trigger must be idempotent, still STOPPED"
OUT3=$(bash solution/loop.sh solution/work 2>&1)
echo "$OUT3" | grep -q "^STOPPED:" || fail "run 3 should still be STOPPED, got: $OUT3"
echo "    ok"

rm -rf solution/work

echo "==> 5. negative: PATH without checkov, loop must exit 2 and leave main.tf alone"
SHIM=$(mktemp -d)
for t in bash terraform python3 cp grep dirname shasum cut; do
  ln -s "$(command -v $t)" "$SHIM/$t"
done
cp -r starter solution/work
BEFORE=$(sha solution/work/main.tf)
OUT5=$(PATH="$SHIM" bash solution/loop.sh solution/work 2>&1); CODE5=$?
rm -rf "$SHIM"
[ "$CODE5" -eq 2 ] || fail "expected exit 2 without checkov, got $CODE5: $OUT5"
echo "$OUT5" | grep -q "^ERROR: checkov not on PATH" || fail "expected a checkov-missing error, got: $OUT5"
echo "$OUT5" | grep -qE "^(CONTINUE|STOPPED):" && fail "loop gave a verdict without checkov: $OUT5"
[ "$(sha solution/work/main.tf)" = "$BEFORE" ] || fail "main.tf changed although checkov was missing"
echo "    ok, exit 2, main.tf byte-identical"
rm -rf solution/work

echo "==> 6. negative: broken provider block, terraform init fails, loop must exit 2 and leave main.tf alone"
cp -r starter solution/work-broken
sed -i.bak 's#hashicorp/local#hashicorp/no-such-provider-m12#' solution/work-broken/main.tf && rm solution/work-broken/main.tf.bak
BEFORE=$(sha solution/work-broken/main.tf)
OUT6=$(bash solution/loop.sh solution/work-broken 2>&1); CODE6=$?
[ "$CODE6" -eq 2 ] || fail "expected exit 2 on a broken provider block, got $CODE6: $OUT6"
echo "$OUT6" | grep -q "^ERROR: terraform init failed" || fail "expected a terraform init error, got: $OUT6"
echo "$OUT6" | grep -qE "^(CONTINUE|STOPPED):" && fail "loop gave a verdict although init failed: $OUT6"
[ "$(sha solution/work-broken/main.tf)" = "$BEFORE" ] || fail "main.tf changed although terraform init failed"
grep -q 'default     = "AKIA' solution/work-broken/main.tf || fail "the hardcoded key was removed despite the tool error"
echo "    ok, exit 2, main.tf byte-identical, hardcoded key still in place"
rm -rf solution/work-broken

echo "==> 7. negative: checkov crashes mid-scan, loop must exit 2 and leave main.tf alone"
SHIM=$(mktemp -d)
printf '#!/bin/sh\necho "Traceback (most recent call last): simulated checkov crash" >&2\nexit 3\n' > "$SHIM/checkov"
chmod +x "$SHIM/checkov"
cp -r starter solution/work
BEFORE=$(sha solution/work/main.tf)
OUT7=$(PATH="$SHIM:$PATH" bash solution/loop.sh solution/work 2>&1); CODE7=$?
rm -rf "$SHIM"
[ "$CODE7" -eq 2 ] || fail "expected exit 2 on a checkov crash, got $CODE7: $OUT7"
echo "$OUT7" | grep -q "^ERROR: checkov exited 3 without a verdict" || fail "expected a no-verdict error, got: $OUT7"
[ "$(sha solution/work/main.tf)" = "$BEFORE" ] || fail "main.tf changed although checkov crashed"
echo "    ok, exit 2, main.tf byte-identical"
rm -rf solution/work

echo "==> 8. FinOps gate: fixtures"
python3 finops/gate.py finops/plan-over-budget.json && fail "gate should have rejected plan-over-budget.json"
python3 finops/gate.py finops/plan-in-budget.json || fail "gate should have accepted plan-in-budget.json"
python3 finops/gate.py finops/plan-empty.json; [ $? -eq 2 ] || fail "gate should have refused to evaluate plan-empty.json with exit 2"
python3 finops/gate.py finops/plan-nested.json; [ $? -eq 1 ] || fail "gate should have rejected the child-module violation in plan-nested.json"
echo "    ok, gate rejects over-budget, accepts in-budget, refuses empty, walks child modules"

echo "==> 9. FinOps gate: unit tests (invalid structure, child modules, absent tags field, passing case)"
python3 finops/test_gate.py 2>&1 | tail -3
[ "${PIPESTATUS[0]}" -eq 0 ] || fail "finops/test_gate.py failed"
echo "    ok"

echo
echo "LAB PASSED -- stopping-condition loop: run 1 continues and applies the real fix, run 2 stops, run 3 is idempotent; three tool-failure runs exit 2 with main.tf untouched; FinOps gate rejects, accepts, refuses an invalid plan, and walks child modules"
