---
name: sidehand
description: Read and operate Windows desktop apps, and capture or mask screenshots, without taking the user's keyboard or foreground window. Use when the user asks to look at, read, click, fill in or operate a Windows app or window, to screenshot or capture the screen, or to crop or hide private parts of an image, while they keep working (gaming, browsing, typing).
---

# sidehand

The user keeps working while you operate other windows. Their foreground window and keyboard must not move.

## Tools

- `sidehand_list_windows`, `sidehand_list_monitors`: find targets.
- `sidehand_ui_tree`: a window's controls as compact text, each with a ref (`e12`). Long lists show 25 items; `filter` prints only matching lines (refs still cover the window); `rects=true` adds screen rects for region capture or masking. About a second and a few hundred tokens, far cheaper than a screenshot.
- `sidehand_ui_ocr`: only when the tree shows almost nothing (games, Qt, Sciter, canvas UIs): the window's text read by the built-in Windows OCR, one line per text with a ref (`t3`) and its screen rect. `sidehand_ui_act` takes a t-ref for `click`, `double-click`, `right-click`, `hover`, `wheel` and `drag` (to another t-ref or `"dx,dy"`), posted at the text's center. 0.5 to 2 s; OCR can misread a letter, so match loosely. t-refs expire after 60 s (they are only points on the window), so read again before acting later.
- `sidehand_ui_wait`: poll until a control containing `text` appears (or `gone=true`: disappears). Use it instead of sleeping.
- `sidehand_ui_act`: `click`, `type`, `check`, `uncheck`, `select` (or `value=<item>` inside a list or combo box), `expand`, `collapse`, `scroll`, `right-click`, `double-click`, `hover`, `wheel` (`value="down 3"`), `drag` (`value=<ref>` or `"dx,dy"`), `press` (`value="Enter"`, `"ctrl+a"`, `"Down Down Enter"`), `focus`. Refs expire when the tree is read again.
- `sidehand_window`: move, resize, minimize, restore (back behind the user's windows) or close a window without activating it. Run `restore` on a minimized window before operating it.
- `sidehand_launch`: start an app, document or URL without it taking the focus.
- `sidehand_clipboard`: read the clipboard; writing replaces what the user copied, so prefer `type`.
- `sidehand_capture`: `full`, `region`, `monitor`, `active`, `window` (PrintWindow, works while the window is covered).
- `sidehand_crop`, `sidehand_mask` (black, pixelate, blur), `sidehand_resize`, `sidehand_info`.

A `title` is part of a window title (an exact title wins) or a handle from `sidehand_list_windows` (`0x...`); use the handle when several windows share a title.

Outside pi, the same operations are the `sidehand` CLI (`sidehand --help`; `sidehand doctor` checks the setup). CLI calls share one ref cache unless `SIDEHAND_SESSION` is set, so give each agent its own. `sidehand mcp` serves them to MCP clients. If the user set `SIDEHAND_ALLOW`, only those windows are visible; do not try to work around it.

## Never disturb the user

- Reading (`tree`, `wait`, list, capture of a visible window) never changes focus.
- Actions on classic Win32 and WinForms text boxes, buttons, checkboxes, lists and combo boxes go `via window message` and never activate the window.
- Other controls (WPF, UWP, tree items) go `via UI Automation` with the target marked non-activatable, which kept WinForms and WPF apps in the background in testing. If the app being operated still comes forward, sidehand puts the user's window back in front, even while they type, and the result ends with `note: ... came forward; the user's window was put back in front`. If that is not possible, it ends with `WARNING: the target app came to the foreground`: tell the user and do not repeat that action while they are busy. `sidehand_launch` returns once the window is there and keeps watching for 3 s more in the background, putting the user's window back if the new app comes forward late.
- WPF apps ignore background mouse messages. On WPF, `wheel` scrolls the nearest scrollable list or view and `double-click` runs the element's default action (Invoke: a grid row starts editing); both say so in the result, and an app's own double-click handler does not run. Right-click, hover and drag on WPF, and HTML `<select>` drop-downs, are refused or fail: tell the user instead of retrying.
- `press` on WPF or browser controls needs focus, so it is refused without `allow_foreground=true`, except `press Enter` on a button or link, which presses it (`as the element's default action`). Enter in a WPF text box is refused (WPF does not expose its default button); `click` the button instead, and use `type` for text.
- Clicks on OCR refs are posted mouse messages: the real cursor does not move and the window is not activated. Games that read the real mouse (DirectInput, raw input) and apps that check what is under the real cursor ignore them; the result still says `ok`, so read the window again (`sidehand_ui_ocr` or `sidehand_capture`) to confirm, and tell the user instead of retrying.
- `focus` and `bring_to_front` take the foreground by design: the tool refuses `focus` without `allow_foreground=true` and refuses to capture a minimized window without `bring_to_front=true`. Pass them only after the user agreed.
- Minimized windows cannot be operated or read by OCR: run `sidehand_window` `restore` first. It puts the window back behind the user's windows and does not activate it.
- When an action fails, do not work around it with your own script that moves the real mouse or activates the window (`SetCursorPos`, `mouse_event`, `SendInput`, `SetForegroundWindow`, an Alt-key trick). That pulls the app over the user's work and takes their cursor, the exact thing sidehand exists to avoid. Report the failure and ask the user. In pi such a command needs the user's approval; under Claude Code with the `sidehand guard` hook it is blocked.

## Workflow

1. `sidehand_list_windows` to find the title, unless you know it.
2. `sidehand_ui_tree` on that title (add `filter` when you look for one control).
3. `sidehand_ui_act` on the ref; read the returned line to confirm the new value or state.
4. After anything that loads, `sidehand_ui_wait` for the expected text, then act on the fresh refs it prints.
5. When the tree is nearly empty (games, custom-drawn apps), `sidehand_ui_ocr` and act on its t-refs. Use `sidehand_capture` when the visual layout matters or OCR finds no text. Resize big captures (`max_w=1280`) before reasoning over them.

## Screenshots and privacy

- Coordinates for crop and mask are in the original image pixels; `sidehand_info` reports the size.
- Before an image leaves the machine (chat, repo, issue), ask whether anything should be hidden, then `sidehand_mask`: `black` for secrets, `pixelate` for names and faces, `blur` for soft masking.
- DRM video captures as black; that is Windows, not a bug.
