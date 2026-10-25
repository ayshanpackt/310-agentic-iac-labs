#!/usr/bin/env bash
# guard-oracle.sh -- PreToolUse hook. The agent may not edit the thing that judges it.
set -uo pipefail
in=$(cat)
path=$(printf '%s' "$in" | python3 -c 'import json,sys; d=json.load(sys.stdin); t=d.get("tool_input",{}); print(t.get("file_path") or t.get("path") or "")')
case "$path" in
  */loop/*|loop/*|*/.claude/*|.claude/*|*/.codex/*|.codex/*|*/.loop/*|.loop/*)
    echo "Blocked: $path is part of the loop's verifier or state. Fix the infrastructure, not the judge." >&2
    exit 2 ;;
esac
exit 0
