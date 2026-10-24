set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="${1:-$HERE/work}"

# Exit codes, one meaning each:
#   0  STOPPED   stopping condition met, nothing to do
#   1  CONTINUE  stopping condition not met, the fix was applied, re-trigger
#   2  ERROR     a tool failed or is missing, so there is no verdict and main.tf is untouched
die() { echo "ERROR: $*" >&2; exit 2; }

for tool in terraform checkov python3; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool not on PATH, cannot evaluate the stopping condition"
done

if [ ! -d "$WORK_DIR" ]; then
  cp -r "$HERE/../starter" "$WORK_DIR"
fi

cd "$WORK_DIR"
[ -f main.tf ] || die "no main.tf in $WORK_DIR, nothing to check"
terraform init -backend=false -input=false -no-color >/dev/null 2>&1 \
  || die "terraform init failed in $WORK_DIR, cannot evaluate the stopping condition"
terraform validate -no-color >/dev/null 2>&1 \
  || die "terraform validate failed in $WORK_DIR, cannot evaluate the stopping condition"

CHECKOV_OUT=$(checkov -d . --compact --quiet 2>&1)
CHECKOV_CODE=$?

if [ "$CHECKOV_CODE" -eq 0 ]; then
  echo "STOPPED: stopping condition met, checkov exits 0"
  exit 0
fi

# checkov exits 1 only for failed checks. Any other code, or a 1 with no failed
# check in the output, is a scanner problem, not a verdict on main.tf.
if [ "$CHECKOV_CODE" -ne 1 ] || ! echo "$CHECKOV_OUT" | grep -q "FAILED for resource"; then
  die "checkov exited $CHECKOV_CODE without a verdict: $(echo "$CHECKOV_OUT" | tail -1)"
fi

echo "CONTINUE: stopping condition not met yet, checkov still failing"
if grep -q 'default     = "AKIA' main.tf 2>/dev/null; then
  python3 -c "
h = open('main.tf').read()
h = h.replace('  default     = \"AKIAABCDEFGHIJKLMNOP\"\n', '  sensitive   = true\n')
open('main.tf','w').write(h)
"
  echo "  (applied the real fix: pulled the hardcoded key, marked the variable sensitive)"
fi
exit 1
