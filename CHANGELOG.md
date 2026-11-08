# Changelog

## 0.5.1 (2026-11-08)

### License

- Sidehand 0.5.1 moves from MIT to the PolyForm Shield License 1.0.0. It is free for any use, including at work, except building or offering a product that competes with Sidehand or with products Blue-B provides using it, free or paid. It includes a patent license that ends for anyone who claims Sidehand infringes a patent. Earlier versions keep their MIT license.

### Security

- Strings handed to PowerShell (text to type, window titles, filters, paths) could end their quote at a typographic apostrophe (‘ ’ ‚ ‛), so the text after it ran as PowerShell code. A web page or message an agent copied could run commands as the user, and plain English like "don’t" broke the call. `psQuote` now doubles those characters too (`test/quote.mjs`).
- Numbers, the capture `mode` and the mask `style` went into the PowerShell command unquoted, so an MCP client that does not check the schema could pass code there. They are now quoted or refused when not a number.
- The MCP `crop` tool passed on an undeclared `out` path, which let it overwrite any file the user can write; it now takes only its declared arguments.
- `sidehand guard` (and the pi guard) opened script files named in a proposed command even on a network path (`\\host\share\x.ps1`, `//host/share/x.ps1`), which on Windows can send the user's credentials to that host before they approve the command. Network paths are no longer opened (`test/guard.mjs`).
- Under WSL, screenshots went to `C:\tmp\sidehand`, which inherits the drive root's ACL (read for all local users, modify for Authenticated Users). They now go to `%LOCALAPPDATA%\sidehand\captures`, which takes the user profile's ACL (on a default install only the user, SYSTEM and Administrators; `test/outdir.mjs` fails on a Users, Authenticated Users or Everyone entry); the direct-script default `C:\tmp\sidehand.png` moved there too. Old captures in `C:\tmp\sidehand` are not moved or deleted.
- `launch` and its 3 s background watch treated any window that came to the front while the app started (Start, a credential prompt, an app the user opened) as the launched app and pulled the foreground back to the user's earlier window, so the user's next keys went there. Now only a window of the launched process, or of a process running the same executable, counts; anything else means the user switched and is left alone (and no longer gives a `WARNING`).
- On native Windows, `powershell.exe` was started by bare name, which Windows looks up in the working directory first: a `powershell.exe` planted in a folder the agent was opened in could run. It now starts `%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe` (under WSL it stays on PATH through interop; `test/paths.mjs`). The pi extension no longer runs `ffmpeg -version` when pi loads it: it probes on the first image, and runs ffmpeg from the home folder.
- `sidehand mcp` still ran queued calls (a click, a window close) after the client cancelled them or closed stdin. A cancelled call that has not started is dropped without a reply (`notifications/cancelled`); when stdin closes, calls that have not started are answered "not run", and only the call already running finishes (`test/mcp.mjs`, with a stand-in PowerShell).
- `crop`, `mask` and `resize` without an output path wrote over the input when it was not a `.png` (`photo.jpg` became a PNG). The output is now always a new `<name>_crop.png` / `_masked.png` / `_resized.png`, and an output equal to the input is refused (`test/paths.mjs`).
- `crop`, `mask`, `resize`, `info` and `capture --out` opened network paths (`\\host\share`, `//host/share`) chosen by the model, which can send the user's credentials to that host, even under `SIDEHAND_ALLOW`. They are now refused (`\\wsl.localhost\` stays allowed).
- OCR refs are only a point on the window and never expired: content that moved in later took the click. `act` now refuses a t-ref 60 s after the `ocr` that made it and says to run `ocr` again (`test/ocr-expiry.mjs`).
- `select` with an item name could, when the element did not contain it, pick a same-named item in another window of the same app, including one `SIDEHAND_ALLOW` hides. It now looks only in popups owned by the target window (Chromium drop-downs are); new hidden-desktop case `select item of another window refused`.

### Changed

- README: shorter in all three languages. Setup details, the full command reference, troubleshooting and the comparison sources moved to `docs/setup.md`, `docs/usage.md`, `docs/troubleshooting.md` and `docs/comparison.md`.
- `launch` returns once the app's window is there, about 3 s sooner (5.0-5.3 s to 2.1-2.6 s for a small WinForms app). The 3 s watch that puts the user's window back if the app comes forward late now runs in a hidden PowerShell (`uia.ps1 -Op watch`), started right after the app; the result says so.

### Added

- `ocr <title>` (MCP `ui_ocr`, pi `sidehand_ui_ocr`): for custom-drawn windows (games, Qt, Sciter, canvas UIs) whose UI Automation tree is nearly empty, the window is captured in the background (PrintWindow) and read by the built-in, offline Windows OCR in the user's language. Each text line gets a ref (`t1`, `t2`, ...) and its screen rect. `act <t-ref> click|double-click|right-click|hover|wheel|drag` posts mouse messages at the text's center: the cursor does not move and the window is not activated. 0.5 s for a small window, 1.2 to 1.7 s for a 1600x900 one (warm worker). New hidden-desktop cases `OCR click`, `OCR double-click`, `OCR right-click`, `OCR hover` on a custom-drawn test window.
- `server.json` and `mcpName` for the official MCP Registry, `glama.json` for Glama, and `.mcp.json` so directories and MCP clients can pick up the server from the repo.
- README: a short security note (text read from other windows reaches the agent; `SIDEHAND_ALLOW`; quoting).
- Simplified Chinese README (`README.zh-CN.md`).
- `sidehand doctor`: plain-English pass/fail lines for the Node version, WSL interop, powershell.exe, the execution policy (including Group Policy), the language mode, whether the shell is elevated, compiling and loading the engine, and the installed OCR languages. It touches no window.
- `sidehand --version`.
- A window title can be a handle from `list_windows` (`0x...`), and an exact title wins over a longer one that contains it, so agents with same-titled windows each reach their own (`test/select-window.mjs`).
- MCP tool annotations: `readOnlyHint` on the list, tree, OCR, wait and capture tools; `destructiveHint` on `ui_act`, `window` (close) and `clipboard` (write); crop and mask write a new file. `test/mcp.mjs` checks the tool list, schemas and annotations without PowerShell and runs in `npm test`.
- `server.json` declares the optional `SIDEHAND_ALLOW` variable (validated against the 2025-12-11 server schema); npm keywords `mcp`, `mcp-server`, `model-context-protocol`, `ocr`, `wpf`.
- `drag` from an OCR ref takes another t-ref as its target (`value=t5`), not only `"dx,dy"`. New hidden-desktop cases `OCR wheel` and `OCR drag to a t-ref`.

- WPF without real input: `wheel` scrolls the element's nearest scrollable list or view through UI Automation (ScrollPattern), and `double-click` runs the element's default action (Invoke, after selecting it; a DataGrid row starts editing). The result says which. New hidden-desktop cases `mouse wheel (scroll)` and `double-click (default action)`.
- `press Enter` on a WPF or browser button or link presses it through UI Automation (Invoke) instead of being refused without `allow_foreground`. Enter in a WPF text box stays refused: WPF does not expose its default (IsDefault) button to UI Automation, and posted keys reach an inactive WPF window not at all. New case `press Enter on a button`.

### Fixed

- WPF `right-click`, `hover` and `drag` reported success although WPF ignores posted mouse messages; they are now refused. UI Automation's ShowContextMenu brought the WPF window forward in testing and opened no menu, and WM_CONTEXTMENU is ignored, so a WPF context menu needs real input (new case `right-click refused`).
- Posted mouse input (`right-click`, `double-click`, `hover`, `wheel`, `drag`) landed at 80% of the intended position in DPI-unaware apps at 125% scaling (67% at 150%): coordinates were converted to logical pixels and Windows converted them again. They now go as physical pixels and Windows does the conversion once. The existing cases missed it because the test pad takes the message wherever it lands; OCR clicks need the exact point.
- The hidden-desktop test uses its own ref cache and stops only its own test apps, so two `npm test` runs at the same time no longer break each other.
- `sidehand mcp` answers calls that are still running when the client closes stdin, instead of exiting without a reply.
- Window titles with `[` or `]` (VS Code's `... [WSL: Ubuntu] - Visual Studio Code`) did not match, and an unbalanced `[` failed with a wildcard error: titles are now matched as plain text in `tree`, `wait`, `ocr`, `window` and `capture`.
- The CLI kept only the first word of an unquoted value: `act e5 wheel down 3`, `press Down Down Enter`, `type Blue-B Studio` now pass the whole rest of the line.
- An unknown CLI option or a value starting with `-` ended in a Node stack trace; it now prints the help and says to put `--` before such values.
- When PowerShell could not start (execution policy set by Group Policy, Constrained Language Mode, no powershell.exe) the MCP server and the pi extension said only `sidehand worker exited`. The error now carries the last 2 KB of PowerShell's error output, and a missing powershell.exe says sidehand needs Windows or WSL with interop. A write to a worker that just died no longer crashes the MCP server (EPIPE).
- `list_windows` with no window to show (all hidden by `SIDEHAND_ALLOW`) failed with `could not parse JSON output`; it now prints `(no windows)`.
- Captures piled up in `%LOCALAPPDATA%\sidehand\captures` (on Windows `%TEMP%\sidehand`): each new capture now deletes PNGs there older than a day, the MCP server's downscaled `_embed.png` copies included.
- Minimized windows: the skill said both to restore the window and to ask the user to; messages said "until the user restores it". All now say to run `window restore`, which puts the window back behind the user's and does not activate it.
- OCR timing in the tool descriptions and skill: 0.5 to 2 s (was 0.5 to 1.5 s).
- The CLI help says that CLI calls share one ref cache unless `SIDEHAND_SESSION` is set.

## 0.5.0 (2026-11-07)

### Added

- `sidehand mcp`: an MCP server on stdio for Claude Desktop, Claude Code, Cursor, Codex and other MCP clients. Screenshots come back as images, downscaled to 1568 px.
- `SIDEHAND_ALLOW`: limit sidehand to the windows you name; screen captures, the clipboard and launching apps are then off.
- Guard against an agent taking the user's mouse or front window: the pi extension asks the user before a bash command runs a Windows script that moves the real mouse, sends keys or brings a window forward (`SetCursorPos`, `SendInput`, `SetForegroundWindow`, `SendKeys`, ...), and blocks it when there is no one to ask. `sidehand guard` does the same as a Claude Code `PreToolUse` hook.
- `act` and `launch` give the foreground back: when the app being operated or launched comes forward anyway (an already running AdGuard did on `launch`), the user's window returns to the front and the app goes just behind it, even while the user is typing. `launch` keeps watching for 3 s after the window shows. The result says `note: ... came forward; the user's window was put back in front`; the `WARNING` remains when that fails.
- Controls without a UI Automation id (custom-drawn UIs such as Sciter, used by AdGuard) can be acted on: they are found again by type, name and position instead of failing with "no stable UIA id".
- README: a prompt to paste to an AI agent so it adds the MCP server itself.
- New demo: three agents fill in three apps at once behind the user's note, with a live view of the covered windows (`demo/agent.mjs`, `demo/record.ps1`).
- `demo/compare.ps1`: the same order task with Sidehand, agent-desktop, Terminator and Windows-MCP on the real desktop while the user types; the benchmark chart comes from it.
- Benchmark: seven real apps and one full task against agent-desktop (`npm test -- -Bench`, `test/isolated/bench_score.py`).

### Changed

- The MCP server and the pi extension keep one PowerShell running (`scripts/worker.ps1`): after the first call a small window reads in about 0.15 s instead of 0.7 s.
- Reading a window asks the app for all children of a container at once (lists, grids, tables and trees are still walked one by one so long lists stay bounded): about 1.5 to 2 times faster, same output.
- The small Win32 helper types are compiled once into `%LOCALAPPDATA%\sidehand` instead of on every call, so a call never starts `csc.exe`.
- The MCP server and the pi extension keep their refs in a cache of their own (`SIDEHAND_SESSION`), so several agents can work side by side; the CLI keeps the shared cache.
- A failed `act`, the `ui_act` tool description and the skill tell the agent not to fall back to its own script that moves the real mouse or activates the window.
- `launch` takes about 3 s longer (see the foreground give-back above).
- README: the Terminator and Windows-MCP table is gone (they stay in the chart and docs/benchmark.md).
- Cua Driver is measured only when passed explicitly (`-Cua <exe>`): its telemetry runs `cmd /c ver` on every call and that console window takes the foreground.

### Fixed

- `press` lands every key once: single characters were typed twice (`a` as `aa`, `B` as `Bb`, `@` as `@2`), and Enter, Tab, Backspace and space twice.
- PowerShell is started with `windowsHide`, so an agent without a console (a desktop app or IDE) never flashes a console window.

## 0.4.0 (2026-11-03)

- Background mouse gestures and keys: `right-click`, `double-click`, `hover`, `wheel`, `drag` and `press` (keys and shortcuts such as `ctrl+a`). They are posted to the window under the element, so the cursor never moves; shortcuts mark Ctrl/Shift/Alt as held in the target thread only.
- `window` (move, resize, minimize, restore behind your windows, close), `launch` (start an app without it taking the focus) and `clipboard`.
- Measured on a real desktop: Edge and VS Code can be read and operated in the background (type, click, check, double-click, right-click) without changing the foreground. New `demo/measure.ps1`.
- Physical pixels everywhere: coordinates and screenshots were scaled down on displays above 100%.
- Browser checkboxes no longer toggle twice; a selection the app ignores is reported as a failure.
- A synthetic pen pointer was tried and dropped: Windows moved the user's cursor and WPF ignored it.

## 0.3.0 (2026-11-03)

- UI Automation actions run with the target window marked `WS_EX_NOACTIVATE` (idea from Cua Driver), so WPF controls and tree items no longer bring their app to the front. Measured on a real Windows 11 desktop: 10 of 10 actions on background WinForms and WPF apps, zero foreground changes. UIA actions also got about three times faster.
- `npm test` and `demo/record.ps1` measure Cua Driver next to agent-desktop when it is installed; every Sidehand action now has to keep the foreground to pass.
- Demo re-recorded with Recordly (`demo/record.ps1 -Recordly`).
- Korean README.

## 0.2.0 (2026-11-03)

First release as Sidehand (previously `pi-winshot` inside pi-custom-packages).

- Native UI Automation engine (`IUIAutomation` COM) replaces the managed `System.Windows.Automation` client, which missed most Win32, WinForms and Chromium controls.
- Actions on classic Win32 and WinForms controls use window messages and never activate the target window. Other controls use UIA, and the result reports when the target took the foreground.
- New actions: `check`, `uncheck`, `select` (item by name), `expand`, `collapse`, `scroll`; new `wait` command; `tree --filter`; long lists fold after 25 items.
- `focus` requires an explicit consent flag; capturing a minimized window is refused instead of restoring it.
- `sidehand` CLI for any agent with a shell, on Windows or inside WSL.
- `npm test` measures focus behaviour on a hidden desktop; `demo/record.ps1` records the demo and measures it on the real desktop.
