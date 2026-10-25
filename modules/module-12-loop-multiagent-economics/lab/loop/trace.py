#!/usr/bin/env python3
"""trace.py <run.jsonl> -- summarise one `claude -p --output-format stream-json --verbose` run.

Prints every tool call in order, every time a Stop hook or /goal evaluator sent the agent
back to work, and the run's turns, duration and cost as Claude Code reported them.
"""
import json, os, sys

def main(path):
    calls = blocks = 0
    for line in open(path, encoding="utf-8"):
        try:
            o = json.loads(line)
        except ValueError:
            continue
        kind = o.get("type")
        if kind == "assistant":
            for c in o["message"].get("content", []):
                if c.get("type") == "tool_use":
                    calls += 1
                    fp = c["input"].get("file_path")
                    arg = c["input"].get("command") or (os.path.basename(fp) if fp else "")
                    print(f"{calls:3}. {c['name']:<6} {str(arg).splitlines()[0][:90] if arg else ''}")
        elif kind == "user":
            content = o["message"].get("content")
            texts = [content] if isinstance(content, str) else [
                c.get("text", "") for c in content or [] if c.get("type") == "text"]
            for t in texts:
                if t.startswith("Stop hook feedback"):
                    blocks += 1
                    first = [l for l in t.splitlines()[1:] if l.strip()][:1]
                    print(f"     >> sent back to work ({blocks}): {first[0][:100] if first else ''}")
        elif kind == "result":
            print(f"turns {o.get('num_turns')}  stop-blocks {blocks}  "
                  f"seconds {o.get('duration_ms', 0) / 1000:.0f}  cost_usd {o.get('total_cost_usd', 0):.4f}")

if __name__ == "__main__":
    main(sys.argv[1])
