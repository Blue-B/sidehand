"""Draws assets/benchmark.svg and assets/benchmark.ko.svg from the measured numbers.

Sources: demo/compare-results.json (demo/compare.ps1 + compare_score.py: the same order task with
four tools on the real desktop while the user types), test/isolated/bench-results.json (run.ps1
-Bench + bench_score.py: seven apps on the hidden test desktop), o200k_base tokens, npm unpacked
size / binary size. Run: python3 demo/benchmark_chart.py
"""
import json
from pathlib import Path

root = Path(__file__).resolve().parent.parent
bench = json.loads((root / "test/isolated/bench-results.json").read_text(encoding="utf-8"))
apps = bench["apps"]
cmp = json.loads((root / "demo/compare-results.json").read_text(encoding="utf-8"))
SH, AD, CUA, TM, WM = "Sidehand", "agent-desktop 1.0.2", "Cua Driver 0.28.2", "Terminator 0.24.28", "Windows-MCP 0.8.8"
NAMES = {"sidehand": SH, "agent-desktop": AD, "terminator": TM, "windows-mcp": WM}
SIZE_KB = 135  # npm pack: unpacked size


def total(tool, key):
    return sum(a[tool][key] for a in apps.values())


read_tok = {t: total(t, "tokens") for t in ("sidehand", "agent-desktop")}
read_ms = {t: round(total(t, "ms") / len(apps)) for t in ("sidehand", "agent-desktop")}
# Other tools in the order of the first panel (least time without a keyboard first).
order = sorted(cmp, key=lambda t: (t != "sidehand", cmp[t]["note_without_keyboard_s"]))


def k(n):
    return f"{n:,}"


away_max = max(c["note_without_keyboard_s"] for c in cmp.values())
task_max = max(c["task_s"] for c in cmp.values())
tok_max = max(c["tokens"] for c in cmp.values())
next_tok = min(c["tokens"] for t, c in cmp.items() if t != "sidehand")


# Each panel: title, note, badge, rows of (tool, bar fraction, label). Fractions are 0..1.
def panels(ko: bool):
    def T(en, kr):
        return kr if ko else en

    return [
        (T("Your keyboard stays in your note", "내 키보드를 지켰는가"),
         T("Real desktop, the same order form behind your note: seconds your note had no keyboard. Lower is better",
           "실제 화면, 내 메모 뒤에 있는 같은 주문서: 내 메모가 키보드를 잃은 시간. 낮을수록 좋음"),
         T("only one at 0 s", "유일하게 0초"),
         [(NAMES[t], cmp[t]["note_without_keyboard_s"] / away_max,
           T(f"{cmp[t]['note_without_keyboard_s']:.1f} s" + (f", {cmp[t]['foreground_changes']} window{'s' if cmp[t]['foreground_changes'] > 1 else ''} came to the front" if cmp[t]["foreground_changes"] else "")
             + (f", cursor moved {cmp[t]['cursor_moves']}x" if cmp[t]["cursor_moves"] else ""),
             f"{cmp[t]['note_without_keyboard_s']:.1f}초" + (f", 다른 창이 {cmp[t]['foreground_changes']}번 앞으로" if cmp[t]["foreground_changes"] else "")
             + (f", 커서 {cmp[t]['cursor_moves']}번 움직임" if cmp[t]["cursor_moves"] else "")))
          for t in order]),
        (T("The same task: fill in and submit the order form", "같은 작업: 주문서 채우고 제출"),
         T("Read, 4 fields, submit, check the result, the way each tool's instructions say. Lower is better",
           "읽기, 입력 4칸, 제출, 결과 확인까지 각 도구 안내대로. 낮을수록 좋음"),
         T("fastest, and done", "가장 빠르고 완료"),
         [(NAMES[t], cmp[t]["task_s"] / task_max,
           T(f"{cmp[t]['task_s']:.1f} s, " + ("done" if cmp[t]["completed"] else "region not set"),
             f"{cmp[t]['task_s']:.1f}초, " + ("완료" if cmp[t]["completed"] else "지역 선택 실패")))
          for t in order]),
        (T("Tokens for that task", "그 작업에 든 토큰"),
         T("Everything the agent had to read. Windows-MCP reads every window on the desktop. Lower is better",
           "에이전트가 읽어야 했던 출력 전체. Windows-MCP는 데스크톱의 모든 창을 읽음. 낮을수록 좋음"),
         T(f"{next_tok / cmp['sidehand']['tokens']:.0f}x fewer", f"{next_tok / cmp['sidehand']['tokens']:.0f}배 적음"),
         [(NAMES[t], cmp[t]["tokens"] / tok_max, k(cmp[t]["tokens"])) for t in order]),
        (T(f"Tokens to read {len(apps)} real apps", f"실제 앱 {len(apps)}개를 읽는 데 든 토큰"),
         T("WinForms, WPF, order form, Character Map, System Information, Edge, VS Code. Lower is better",
           "WinForms, WPF, 주문서, 문자표, 시스템 정보, Edge, VS Code 합계. 낮을수록 좋음"),
         T(f"{read_tok['agent-desktop'] / read_tok['sidehand']:.1f}x fewer", f"{read_tok['agent-desktop'] / read_tok['sidehand']:.1f}배 적음"),
         [(SH, read_tok["sidehand"] / read_tok["agent-desktop"], k(read_tok["sidehand"])),
          (AD, 1.0, k(read_tok["agent-desktop"]))]),
        (T("Time to read a window", "창 하나 읽는 시간"),
         T(f"Average over the same {len(apps)} apps; Sidehand was faster on every one. Lower is better",
           f"같은 앱 {len(apps)}개 평균, 7개 모두 Sidehand가 더 빠름. 낮을수록 좋음"),
         T(f"{read_ms['agent-desktop'] / read_ms['sidehand']:.1f}x faster", f"{read_ms['agent-desktop'] / read_ms['sidehand']:.1f}배 빠름"),
         [(SH, read_ms["sidehand"] / read_ms["agent-desktop"], f"{read_ms['sidehand']} ms"),
          (AD, 1.0, f"{read_ms['agent-desktop']} ms")]),
        (T("Install size", "설치 크기"), T("Lower is better", "낮을수록 좋음"),
         T(f"{31 * 1024 // SIZE_KB // 10 * 10}x smaller", f"{31 * 1024 // SIZE_KB // 10 * 10}배 이상 작음"),
         [(SH, SIZE_KB / (31 * 1024), f"{SIZE_KB} KB"), (CUA, 1.0, "31 MB"), (AD, 29 / 31, "29 MB")]),
    ]


W, PAD, LABEL_W, BAR_H, GAP = 960, 40, 210, 28, 12
FONT = "'Segoe UI', -apple-system, 'Apple SD Gothic Neo', 'Malgun Gothic', 'Noto Sans KR', Helvetica, Arial, sans-serif"
ACCENT, OTHER, TRACK = "#2563eb", "#9ca3af", "#f3f4f6"


def esc(s: str) -> str:
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def draw(ko: bool) -> str:
    out, y = [], PAD
    title = "Sidehand 벤치마크" if ko else "Sidehand benchmark"
    sub = ("같은 Windows 11 PC. 작업은 실제 화면에서 메모에 계속 입력하며, 앱 읽기는 보이지 않는 테스트 데스크톱에서"
           if ko else "Same Windows 11 PC. The task on the real desktop while typing in a note; app reads on the hidden test desktop")
    out.append(f'<text x="{PAD}" y="{y + 26}" font-size="28" font-weight="700" fill="#111827">{esc(title)}</text>')
    out.append(f'<text x="{PAD}" y="{y + 54}" font-size="15" fill="#6b7280">{esc(sub)}</text>')
    y += 92
    bar_x, bar_w = PAD + LABEL_W, W - 2 * PAD - LABEL_W
    for head, note, badge, rows in panels(ko):
        out.append(f'<line x1="{PAD}" y1="{y}" x2="{W - PAD}" y2="{y}" stroke="#e5e7eb"/>')
        y += 34
        out.append(f'<text x="{PAD}" y="{y}" font-size="19" font-weight="700" fill="#111827">{esc(head)}</text>')
        out.append(f'<text x="{PAD}" y="{y + 22}" font-size="13.5" fill="#6b7280">{esc(note)}</text>')
        out.append(f'<text x="{W - PAD}" y="{y + 4}" font-size="24" font-weight="800" text-anchor="end" fill="{ACCENT}">{esc(badge)}</text>')
        y += 40
        for tool, frac, label in rows:
            mine = tool == SH
            weight = "700" if mine else "400"
            out.append(f'<text x="{PAD}" y="{y + BAR_H * 0.68}" font-size="15" font-weight="{weight}" fill="#111827">{esc(tool)}</text>')
            out.append(f'<rect x="{bar_x}" y="{y}" width="{bar_w}" height="{BAR_H}" rx="6" fill="{TRACK}"/>')
            w = max(frac * bar_w, 4)
            out.append(f'<rect x="{bar_x}" y="{y}" width="{w:.1f}" height="{BAR_H}" rx="6" fill="{ACCENT if mine else OTHER}"/>')
            # Value inside the bar when it fits, otherwise just after it.
            inside = w > 0.55 * bar_w
            tx = bar_x + w - 12 if inside else bar_x + w + 10
            fill = "#ffffff" if inside else ("#1d4ed8" if mine else "#374151")
            anchor = "end" if inside else "start"
            out.append(f'<text x="{tx:.1f}" y="{y + BAR_H * 0.68}" font-size="15" font-weight="{weight}" text-anchor="{anchor}" fill="{fill}">{esc(label)}</text>')
            y += BAR_H + GAP
        y += 8
    h = y + PAD - 10
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{h}" viewBox="0 0 {W} {h}" font-family="{FONT}">'
        f'<rect x="0.5" y="0.5" width="{W - 1}" height="{h - 1}" rx="14" fill="#ffffff" stroke="#e5e7eb"/>'
        + "".join(out) + "</svg>\n"
    )


(root / "assets/benchmark.svg").write_text(draw(False), encoding="utf-8")
(root / "assets/benchmark.ko.svg").write_text(draw(True), encoding="utf-8")
