#!/usr/bin/env bash
# install.sh <working-copy> -- wire the loop into a working copy for Claude Code and Codex.
#   loop/verify.sh            the stopping condition (deterministic)
#   loop/hooks/stop-gate.sh   Stop hook: the agent may stop only when verify.sh says DONE
#   loop/hooks/guard-oracle.sh PreToolUse hook: the agent may not edit the loop itself
#   .claude/settings.json     registers both hooks in Claude Code
#   .codex/hooks.json         registers both hooks in Codex (trust them once with /hooks)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DEST="${1:?usage: install.sh <working-copy>}"
[ -f "$DEST/main.tf" ] || { echo "install.sh: no main.tf in $DEST" >&2; exit 1; }
mkdir -p "$DEST/loop/hooks" "$DEST/.claude" "$DEST/.codex"
cp "$HERE/verify.sh" "$DEST/loop/verify.sh"
cp "$HERE/hooks/stop-gate.sh" "$HERE/hooks/guard-oracle.sh" "$DEST/loop/hooks/"
cp "$HERE/claude-settings.json" "$DEST/.claude/settings.json"
cp "$HERE/codex-hooks.json" "$DEST/.codex/hooks.json"
chmod +x "$DEST/loop/verify.sh" "$DEST/loop/hooks/"*.sh
echo "loop installed in $DEST: verifier, Stop gate, verifier guard, Claude Code and Codex hook config"
