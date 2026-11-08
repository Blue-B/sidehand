"""Scores the raw output of `run.ps1 -Bench` (o200k_base tokens, median read time, task totals).

    python3 test/isolated/bench_score.py <bench folder> > test/isolated/bench-results.json
"""
import json
import re
import statistics
import sys
from pathlib import Path

import tiktoken

enc = tiktoken.get_encoding("o200k_base")
d = Path(sys.argv[1])
raw = json.loads((d / "bench.json").read_text(encoding="utf-8-sig"))


def tokens(text: str) -> int:
    return len(enc.encode(text))


def elements(tool: str, text: str) -> int:
    if tool == "sidehand":
        m = re.search(r"\((\d+) elements", text)
        return int(m.group(1)) if m else 0
    m = re.search(r'"ref_count":(\d+)', text)
    return int(m.group(1)) if m else 0


apps = {}
for app, r in raw["reads"].items():
    apps[app] = {}
    for tool in ("sidehand", "agent-desktop"):
        f = d / f"{app}.{tool}.txt"
        if tool not in r or not f.exists():
            continue
        text = f.read_text(encoding="utf-8-sig")
        apps[app][tool] = {"tokens": tokens(text), "refs": elements(tool, text), "ms": int(statistics.median(r[tool]))}

task = {}
for tool, t in raw["task"].items():
    text = (d / f"task.{tool}.txt").read_text(encoding="utf-8-sig")
    task[tool] = {**t, "tokens": tokens(text), "completed": "Jeju" in t["status"] and "express" in t["status"]}

print(json.dumps({"apps": apps, "task": task}, ensure_ascii=False, indent=1))
