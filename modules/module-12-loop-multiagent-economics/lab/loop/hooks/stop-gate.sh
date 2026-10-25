#!/usr/bin/env bash
# stop-gate.sh -- Stop hook. The agent may stop only when verify.sh says DONE.
# Runs in Claude Code and Codex alike: both send JSON on stdin and treat exit 2 as
# "do not stop; here is why" with the reason on stderr.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STATE="$ROOT/.loop/state.md"
MAX_BLOCKS="${LOOP_MAX_BLOCKS:-5}"
mkdir -p "$ROOT/.loop"
cat >/dev/null   # the hook input; this gate decides from the repo, not from the transcript
blocks=$(grep -c '^- blocked' "$STATE" 2>/dev/null || true); blocks=${blocks:-0}
verdict=$("$ROOT/loop/verify.sh" 2>&1); code=$?
stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
case "$code" in
  0) echo "- done $stamp: $(echo "$verdict" | head -1)" >> "$STATE"; exit 0 ;;
  1) if [ "$blocks" -ge "$MAX_BLOCKS" ]; then
       echo "- budget exhausted $stamp after $blocks blocks, escalate to a human" >> "$STATE"
       echo "Loop budget exhausted after $blocks blocks. Stopping without DONE; a human must look." >&2
       exit 0
     fi
     echo "- blocked $stamp: $(echo "$verdict" | grep -c 'FAILED for resource\|checkov:skip') finding(s)" >> "$STATE"
     echo "verify.sh says the work is not done. Fix these, then stop again:" >&2
     echo "$verdict" >&2
     exit 2 ;;
  *) echo "- no verdict $stamp: $(echo "$verdict" | tail -1)" >> "$STATE"
     echo "verify.sh could not reach a verdict ($verdict). Stopping; a human must look." >&2
     exit 0 ;;
esac
