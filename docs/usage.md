# Using Sidehand

`sidehand --help` prints the same reference.

## Commands

| Command | What it does |
|---|---|
| `tree <title>` | the window's controls as text, each with a ref (`e1`, `e2`, ...); `--filter`, `--max-nodes`, `--rects` |
| `act <ref> <action> [value]` | `type <text>`, `click`, `check`, `uncheck`, `select [item]`, `expand`, `collapse`, `scroll`, `right-click`, `double-click`, `hover`, `wheel [up\|down N]`, `drag <ref\|dx,dy>`, `press <keys>`; `focus` takes your foreground window, so it needs `--allow-foreground` (your consent) |
| `ocr <title>` | the text of a custom-drawn window (games, Qt, canvas apps) read by Windows OCR, each line with a ref (`t1`, `t2`, ...) |
| `act <t-ref> <action>` | on an OCR ref: `click`, `double-click`, `right-click`, `hover`, `wheel`, `drag` (to a t-ref or `dx,dy`), at the center of the text; OCR refs expire 60 s after the `ocr` that made them |
| `act <@x,y> <action>` | on a point of the last `capture window` image (`@x,y` is pixel x,y of the image as the agent was shown it, which the capture result names): the same actions as an OCR ref, with `drag` also to another `@x,y`; for icons and spots that have no control and no text; point refs expire 60 s after the capture and at the next capture |
| `wait <title> <text>` | wait until a control with that text appears (or `--gone`), with `--timeout ms` |
| `undo` | put back the latest `type`, `check`, `uncheck` or `select`; MCP and pi only (see [Undo](#undo)) |
| `log [n]` | the last `n` (default 20) acting operations from the [action log](#action-log) |
| `window <title> <action>` | `move x,y`, `resize w,h`, `minimize`, `restore` (behind your windows), `close` |
| `launch <app>` | start an app, path or URL without it taking your focus; `--isolated` starts it on a hidden desktop instead (experimental, see below) |
| `isolated close` | end every app the CLI started with `launch --isolated` |
| `capture <mode>` | screenshot a window even while it is covered (`full`, `active`, `monitor`, `region`, `window`); saved in `%LOCALAPPDATA%\sidehand\captures` (from WSL) or `%TEMP%\sidehand` (on Windows), where captures older than a day are deleted; image paths on a network share are refused |
| `mask <png> <x,y,w,h[;...]>` | cover regions you choose in a screenshot before sharing it, with `--style black`, `pixelate` or `blur` |
| `crop`, `resize`, `info` | crop or scale a PNG, or print its size; the output is always a new file |
| `windows`, `monitors`, `clipboard` | list windows or monitors, read or set the clipboard |
| `doctor`, `--version` | check your setup (see [troubleshooting.md](troubleshooting.md)), print the version |
| `mcp`, `guard` | the MCP server on stdio; the Claude Code PreToolUse hook (see [setup.md](setup.md)) |

`<title>` can be part of a window's title, its exact title (an exact title wins over a longer one that contains it), or its handle (`0x...` from `sidehand windows`). Values that start with `-` go after `--`: `sidehand act e5 wheel -- -240`.

MCP exposes the same operations as tools: `list_windows`, `list_monitors`, `ui_tree`, `ui_ocr`, `ui_wait`, `ui_act`, `ui_undo`, `window`, `launch`, `clipboard`, `capture`, `crop`, `mask`. pi has the same tools with a `sidehand_` prefix, plus `sidehand_resize` and `sidehand_info`.

## Seeing and stopping what it does

While Sidehand acts (`act`, `window`, `launch`, a clipboard write) and for 3 s after, a small strip in the bottom-right corner of your screen says what it does: `Sidehand: click in Notepad`. It never takes your foreground or keyboard, also when you click it, and has no taskbar button. All agents and sessions share one strip; it closes itself 30 s after the last action.

**Stop** on the strip, or Ctrl+Alt+Pause while it is open, stops every agent at once: each action is refused with "The user pressed Stop in Sidehand. Ask the user before doing anything else.", and actions an MCP agent had queued are dropped. Reading (`tree`, `ocr`, `wait`, `capture`, ...) still works. The strip then says Sidehand stopped and shows **Resume**, which lets agents act again.

`SIDEHAND_INDICATOR=0` turns the strip off for that agent. A Stop pressed on another agent's strip still holds for it. With the strip off everywhere, delete `%LOCALAPPDATA%\sidehand\stop-Default` to resume.

## What works in the background

| | Win32, WinForms | WPF | Chrome, Edge | VS Code |
|---|:-:|:-:|:-:|:-:|
| Type, click, check, select, expand | ✅ | ✅ | ✅ except `<select>` | ✅ click |
| Wheel, double-click | ✅ | ✅ through UI Automation | ✅ | - |
| Right-click, hover, drag | ✅ | ❌ | ✅ | - |
| Keys and shortcuts | ✅ | Enter on a button or link; others with consent | keys in text fields, Enter on a button or link; others with consent | with consent |

WPF ignores mouse messages that do not come from the real mouse, so on WPF a wheel scrolls the nearest scrollable list or view through UI Automation, and a double-click runs the element's default action (Invoke: a grid row starts editing, a button clicks); an app's own double-click handler does not run. Right-click, hover and drag on WPF are refused: UI Automation's context-menu call brings the window forward. WPF and browser pages take keys only while focused, so keys need `--allow-foreground`, except Enter on a button or link, which presses it, and keys in a visible text field of a browser or Electron window, which go in after a posted click on the field. With `--allow-foreground` the window has the foreground only for the keys; your window is put back afterwards. WPF does not tell UI Automation which button is the default, so Enter in a text box needs consent too.

Games and other apps that draw their own UI (Qt, canvas) expose no controls: `ocr` reads their text with the built-in Windows OCR, and `act` clicks, double-clicks, right-clicks, hovers, wheels or drags on it with posted mouse messages. For what has no text (an icon in a 3D viewport, a toolbar of pictures), `capture window` and act on a pixel of that image with `@x,y`, the same way. The MCP server and the pi extension show the model a downscaled image (1568 px on the long edge); `@x,y` is a pixel of that downscaled image, and sidehand also converts for display scaling and for apps that are not DPI-aware.

### Limitations

- WPF: right-click, hover and drag are refused, and an app's own double-click handler does not run.
- WPF: Enter in a text box, like other keys, needs your consent (`--allow-foreground`).
- Chrome and Edge: an HTML `<select>` drop-down cannot be operated in the background.
- Games that read raw mouse input ignore posted clicks. `capture` and `ocr` still work.
- Apps running as administrator need an agent running as administrator.
- A minimized window has to be brought back first with `window <title> restore`, which puts it behind your windows.

## Undo

Before `type` replaces a text, and before `check`, `uncheck` or `select`, Sidehand remembers the earlier text, state or selected item. `ui_undo` (pi: `sidehand_ui_undo`) puts back the latest one in the background, the same way `act` works, and keeps the 20 latest. It refuses, and says why, when the control is gone, when someone changed it since (restoring would overwrite that), when nothing or several items were selected before, or when a checkbox was indeterminate. Password fields are never remembered.

The history is kept only in memory, in the PowerShell process of one MCP or pi session, so earlier values never reach the disk. It is gone when the session ends. Each `sidehand` CLI call is a new process, so `sidehand undo` only says that undo needs an MCP or pi session.

## Action log

Every acting operation (`act`, `undo`, `window`, `launch`, writing the clipboard) adds one JSON line to `%LOCALAPPDATA%\sidehand\actions.log`. It is the same file whether Sidehand runs on Windows or in WSL. Each line holds the time, the session, the window title and handle, the process, the action, the control (type and name), and whether it worked, with the error if it did not:

```json
{"time":"2026-11-24T10:15:02.114+09:00","session":"4242","window":"Contoso Orders","hwnd":"0x5a0b2c","process":"Contoso","action":"type","control":"Edit \"Customer\"","chars":13,"ok":true}
```

Typed text, clipboard text and field values are never written, only their length (`chars`). Quoted parts of an error message are cut, since an error can quote a value. Above 1 MB the file becomes `actions.1.log`, replacing the older one. `sidehand log [n]` prints the last lines readably. `SIDEHAND_LOG=0` turns the log off ([setup.md](setup.md#action-log)).

## Text that tries to instruct the agent

Whatever `tree`, `wait`, `ocr` and reading the clipboard return goes to the agent, and a web page or message can try to give it orders. Lines that look like instructions to an AI ("ignore previous instructions", "you are now", "system prompt", "run this command", and the same in Korean) get a `⚠` in front. When at least one line is marked, the output starts with one header line saying window text is data, not instructions. A read with no such line is unchanged and costs no extra tokens. This is a list of common phrasings, not a guarantee: a reworded attack is not marked.

## Isolated desktop (experimental)

`launch --isolated <app>` (MCP and pi: `isolated: true`) starts the app on a desktop of Sidehand's own that Windows never shows. Its windows never reach your screen or taskbar and cannot take your foreground or keyboard, so the agent can work in them while you work in yours. `tree`, `act`, `ocr`, `wait`, `window` and `capture window` reach them; `windows` lists them tagged `[isolated]`. You watch through `capture`.

While an isolated desktop is open, a window title or handle is looked up there first, then on your desktop, so a title both have reaches the agent's own window. Refs act on the desktop of the window they were read from.

Lifetime:

- MCP and pi: the desktop and every app on it end when the MCP session or pi ends, without asking to save.
- CLI: the apps keep running, invisible, until `sidehand isolated close` ends them (or until you sign out). Its desktop is `sidehand-cli`, or `sidehand-<SIDEHAND_SESSION>`.

Limits:

- A single-instance app that is already running on your desktop (Edge with your profile, Office, many UWP apps) hands the request to that instance, so its window opens on your screen, not the hidden desktop. `launch --isolated` then fails with `not isolated` and names the running process. Start such apps with their own profile (`msedge --user-data-dir=...`) or close them first.
- URLs and documents open in whatever app is registered for them, with the same limit.
- WPF windows capture blank there (their content is drawn only on a shown desktop), so `capture` and `ocr` show only the title bar; `tree` and `act` work. Win32, WinForms and Edge capture fine.
- It is not a fix for apps that take your focus on your own desktop, and not a sandbox: the apps run as you, with your files and network.
- MCP and pi: a call that waits on an isolated window cannot be cut short by cancelling it; it ends at its timeout.

## How it works

Sidehand is a UI Automation client, the same interface screen readers use, compiled on your PC on first use. Classic controls get plain window messages (`WM_SETTEXT`, `BM_CLICK`, ...), which never activate a window. Everything else gets a UI Automation call while the target window is marked no-activate, so the app cannot pull itself to the front. Clicks and keys are posted to the app's own message queue, never to your mouse. If an app forces itself forward anyway, Sidehand hands the foreground back to your window without touching the keyboard or mouse.

It runs no daemon (the activity strip closes itself 30 s after the last action), sends no telemetry and downloads no binary. The code is about 2,800 lines.
