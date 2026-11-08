"""Scores a demo/compare.ps1 run: numbers only, no tool output (Windows-MCP's output lists every
window on the desktop, so it stays out of the repo).

    python3 demo/compare_score.py <compare folder> > demo/compare-results.json
"""
import json
import re
import sys
from pathlib import Path

import tiktoken

enc = tiktoken.get_encoding("o200k_base")
d = Path(sys.argv[1])
try:
    runs = json.loads((d / "compare.json").read_text(encoding="utf-8-sig"))["runs"]
except (OSError, ValueError, KeyError) as e:
    sys.exit(f"no usable compare.json in {d}: {e}")
out = {}
for r in runs:
    text = (d / f"{r['tool']}.txt").read_text(encoding="utf-8")
    outputs = re.split(r"^=== .*$", text, flags=re.M)  # every answer the agent had to read
    out[r["tool"]] = {
        "completed": r["completed"],
        "foreground_changes": r["foreground_changes"],
        "note_without_keyboard_s": round(r["note_without_keyboard_ms"] / 1000, 1),
        "cursor_moves": r["cursor_moves"],
        "task_s": round(r["task_ms"] / 1000, 1),
        "calls": r["calls"],
        "tokens": sum(len(enc.encode(o.strip())) for o in outputs),
        "errors": [e.split(":")[0] + ": " + e.split('"message":"')[-1].split('"')[0][:90] for e in r["errors"] if e],
    }
print(json.dumps(out, ensure_ascii=False, indent=1))
