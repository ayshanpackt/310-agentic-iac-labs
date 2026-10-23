#!/usr/bin/env python3
"""Print, in order, every tool call an agent made during a `claude -p` run.

Usage:
  claude -p "<intent>" --output-format stream-json --verbose > run.jsonl
  python3 first-actions.py run.jsonl

Reads the stream-json event log Claude Code writes with --output-format stream-json and
prints one line per tool call (tool name plus the command, path or skill it was given),
then the agent's final answer. No model involved: this is a plain read of what happened.
"""
import json
import sys

if len(sys.argv) != 2:
    sys.exit(__doc__)

n = 0
for line in open(sys.argv[1]):
    try:
        event = json.loads(line)
    except ValueError:
        continue
    if event.get("type") == "assistant":
        for block in event["message"].get("content", []):
            if block.get("type") == "tool_use":
                n += 1
                arg = block["input"]
                detail = arg.get("command") or arg.get("file_path") or arg.get("skill") or ""
                print(f"{n:2d}. {block['name']:<6} {detail[:100]}")
    if event.get("type") == "result":
        print("\n--- final answer ---")
        print(event.get("result") or "(no final answer: the run hit its turn limit or timed out)")
