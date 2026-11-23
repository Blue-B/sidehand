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
| `window <title> <action>` | `move x,y`, `resize w,h`, `minimize`, `restore` (behind your windows), `close` |
| `launch <app>` | start an app, path or URL without it taking your focus |
| `capture <mode>` | screenshot a window even while it is covered (`full`, `active`, `monitor`, `region`, `window`); saved in `%LOCALAPPDATA%\sidehand\captures` (from WSL) or `%TEMP%\sidehand` (on Windows), where captures older than a day are deleted; image paths on a network share are refused |
| `mask <png> <x,y,w,h[;...]>` | cover regions you choose in a screenshot before sharing it, with `--style black`, `pixelate` or `blur` |
| `crop`, `resize`, `info` | crop or scale a PNG, or print its size; the output is always a new file |
| `windows`, `monitors`, `clipboard` | list windows or monitors, read or set the clipboard |
| `doctor`, `--version` | check your setup (see [troubleshooting.md](troubleshooting.md)), print the version |
| `mcp`, `guard` | the MCP server on stdio; the Claude Code PreToolUse hook (see [setup.md](setup.md)) |

`<title>` can be part of a window's title, its exact title (an exact title wins over a longer one that contains it), or its handle (`0x...` from `sidehand windows`). Values that start with `-` go after `--`: `sidehand act e5 wheel -- -240`.

MCP exposes the same operations as tools: `list_windows`, `list_monitors`, `ui_tree`, `ui_ocr`, `ui_wait`, `ui_act`, `window`, `launch`, `clipboard`, `capture`, `crop`, `mask`. pi has the same tools with a `sidehand_` prefix, plus `sidehand_resize` and `sidehand_info`.

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

## How it works

Sidehand is a UI Automation client, the same interface screen readers use, compiled on your PC on first use. Classic controls get plain window messages (`WM_SETTEXT`, `BM_CLICK`, ...), which never activate a window. Everything else gets a UI Automation call while the target window is marked no-activate, so the app cannot pull itself to the front. Clicks and keys are posted to the app's own message queue, never to your mouse. If an app forces itself forward anyway, Sidehand hands the foreground back to your window without touching the keyboard or mouse.

It runs no daemon, sends no telemetry and downloads no binary. The code is about 2,800 lines.
