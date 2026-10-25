#!/usr/bin/env bash
# verify.sh -- the loop's stopping condition. Deterministic, one question, three answers.
# It lives in loop/ inside the working copy and always checks the working copy's root.
#   exit 0  DONE      terraform validates and checkov reports no failed checks
#   exit 1  NOT DONE  checkov reports failed checks; they are printed on stderr
#   exit 2  NO VERDICT a tool is missing or failed, so nothing can be concluded
set -uo pipefail
cd "$(dirname "$0")/.."   # the working copy this loop owns
no_verdict(){ echo "NO VERDICT: $*" >&2; exit 2; }
for t in terraform checkov; do command -v "$t" >/dev/null 2>&1 || no_verdict "$t not on PATH"; done
# A suppression is not a fix. An agent told "make the scan pass" can reach for a
# checkov:skip comment; this loop does not accept one.
if grep -rn --include='*.tf' 'checkov:skip' . >/dev/null 2>&1; then
  echo "NOT DONE: a checkov:skip comment is a suppression, not a fix. Remove it and fix the finding:" >&2
  grep -rn --include='*.tf' 'checkov:skip' . >&2
  exit 1
fi
terraform init -backend=false -input=false -no-color >/dev/null 2>&1 || no_verdict "terraform init failed"
terraform validate -no-color >/dev/null 2>&1 || no_verdict "terraform validate failed"
out=$(checkov -d . --framework terraform,secrets --compact --quiet 2>&1); code=$?
[ "$code" -eq 0 ] && { echo "DONE: terraform validates, checkov reports no failed checks"; exit 0; }
if [ "$code" -eq 1 ] && echo "$out" | grep -q "FAILED for resource"; then
  echo "NOT DONE: checkov still reports failed checks:" >&2
  echo "$out" | grep -E "^Check: |FAILED for resource|File: " >&2
  exit 1
fi
no_verdict "checkov exited $code without a verdict"
