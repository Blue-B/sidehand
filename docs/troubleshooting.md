# Troubleshooting

Run `sidehand doctor` (or `npx -y github:Blue-B/sidehand doctor`) first. It checks Node, WSL interop, PowerShell, the execution policy (including Group Policy), the language mode, whether the shell is elevated, the engine and the installed OCR languages. It touches no window and exits 1 if a check fails.

## The server does not start in Claude Desktop, Cursor or Codex on native Windows

For example `spawn npx ENOENT`. On Windows `npx` is a `.cmd` script, and a program that starts it without a shell gets `ENOENT`. Use `"command": "cmd"` with `"args": ["/c", "npx", "-y", "github:Blue-B/sidehand", "mcp"]` (in Codex TOML: `command = "cmd"`, `args = ["/c", "npx", ...]`). Claude Code starts plain `npx` fine. Full snippets are in [setup.md](setup.md#native-windows-claude-desktop-cursor-codex).

## Codex reports a startup timeout

Codex waits 10 seconds for a server to start. The first `npx` download can take longer; add `startup_timeout_sec = 60` under `[mcp_servers.sidehand]`.

## `npx` or `npm install` cannot fetch `github:Blue-B/sidehand`

Installing from GitHub needs Git. Install [Git for Windows](https://git-scm.com/download/win) and restart your client.

## `sidehand worker exited` or "running scripts is disabled on this system"

Sidehand starts PowerShell with `-ExecutionPolicy Bypass`, but an execution policy set by Group Policy overrides that. `Get-ExecutionPolicy -List` shows it as `MachinePolicy` or `UserPolicy`; only your administrator can change it.

## Constrained Language Mode

When AppLocker or WDAC turns it on, PowerShell blocks `Add-Type`, so Sidehand cannot build its engine. This is not supported. `$ExecutionContext.SessionState.LanguageMode` shows `ConstrainedLanguage` when it is on.

## WSL

Sidehand runs `powershell.exe` through WSL interop, so interop and `appendWindowsPath` must stay on in `/etc/wsl.conf` (they are on by default).

## `ocr` says "Windows OCR has no language installed"

Windows OCR needs an OCR language pack for a language in your Windows profile. List them with `Get-WindowsCapability -Online -Name Language.OCR*` and add one from an administrator PowerShell, for example `Add-WindowsCapability -Online -Name "Language.OCR~~~en-US~0.0.1.0"` (`ko-KR`, `zh-CN` and so on for other languages).

## An app running as administrator does not respond

Windows blocks a normal process from sending input to an elevated one. Run your agent as administrator too.

## The first call is slow

The first call compiles the engine into `%LOCALAPPDATA%\sidehand`; later calls reuse it.
