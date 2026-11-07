**English** | [한국어](benchmark.ko.md)

# How Sidehand was measured

All numbers come from one Windows 11 PC (2560x1440, 100% scale). Tokens are counted with `o200k_base`.

## The same task with every tool

A note window holds the keyboard and receives simulated typing for the whole run. Behind it sits an order form (WinForms). Each tool fills it in the way its own instructions say: read the window, type a customer and a quantity, pick a region from a drop-down, tick a box, submit, read the result. A monitor records the foreground window and the real cursor. One run per tool, on the real desktop.

| Tool | Done | Note without keyboard | Windows that came forward | Cursor moves | Time | Tokens |
|---|:-:|--:|--:|--:|--:|--:|
| Sidehand | ✅ | 0 s | 0 | 0 | 2.0 s | 277 |
| agent-desktop 1.0.2 | ❌ region not set | 2.3 s | 4 | 0 | 2.7 s | 3,411 |
| Windows-MCP 0.8.8 | ✅ | 49.7 s | 1 | 6 | 65.5 s | 13,425 |
| Terminator 0.24.28 | ✅ | 67.9 s | 8 | 2 | 68.0 s | 2,488 |

- agent-desktop: `select` and `expand` on the drop-down returned `ACTION_NOT_SUPPORTED`.
- Terminator: `select_option` did not find the drop-down, so it clicked it open; `click_element` moves the real cursor and puts it back.
- Windows-MCP: brings the app forward (`App` switch) and clicks with the real mouse. Its snapshot lists every window on the desktop, so its token count grows with what you have open.
- Cua Driver 0.28.2 is not in this task: its telemetry opens a console window on every call, and that window takes the foreground.

Scripts: [demo/compare.ps1](../demo/compare.ps1) runs it, [demo/compare-task.mjs](../demo/compare-task.mjs) holds each tool's calls, [demo/compare_score.py](../demo/compare_score.py) writes [demo/compare-results.json](../demo/compare-results.json).

## Reading seven apps

On a hidden test desktop, each tool reads the same window three times (median time). Terminator and Windows-MCP cannot read on a hidden desktop: Windows-MCP needs a real cursor for its control overlay and refuses every call without one.

| App | Tokens (Sidehand / agent-desktop) | Elements found | Read time |
|---|--:|--:|--:|
| WinForms test app | 250 / 1,289 | 27 / 21 | 559 / 726 ms |
| WPF test app | 221 / 968 | 26 / 17 | 544 / 867 ms |
| Order form (demo) | 161 / 740 | 18 / 11 | 539 / 739 ms |
| Character Map | 268 / 1,069 | 24 / 17 | 505 / 814 ms |
| System Information | 1,215 / 4,632 | 105 / 70 | 618 / 1849 ms |
| Edge, a web page | 436 / 8,662 | 37 / 117 | 626 / 1114 ms |
| VS Code | 1,925 / 7,538 | 169 / 107 | 844 / 1519 ms |

Elements found counts what each tool lists as a ref. agent-desktop found more on the Edge page (it lists the browser's own toolbar buttons); Sidehand found more everywhere else.

## Reproduce

```bash
npm test                           # hidden desktop, nothing appears on screen, a few minutes
npm test -- -Bench                 # the seven-app reads, scored by test/isolated/bench_score.py
powershell -File demo/compare.ps1  # real desktop: the same task with every tool, about 4 minutes idle
powershell -File demo/measure.ps1  # real desktop: focus and cursor in WinForms, Edge and VS Code, about 3 minutes idle
powershell -File demo/record.ps1 -Recordly [-Lang ko]   # the demo video, about 3 minutes idle
python3 demo/benchmark_chart.py    # redraws assets/benchmark.svg
```

The real-desktop scripts stop by themselves if someone uses the PC, and every process they start is closed with them.
