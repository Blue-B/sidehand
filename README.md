<p align="center">
  <img src="assets/logo.png" width="104" alt="Sidehand logo">
</p>

<h1 align="center">Sidehand</h1>

<p align="center"><b>Your AI agent works in your Windows apps. You keep the keyboard.</b></p>

<p align="center">
  <a href="https://www.npmjs.com/package/sidehand"><img src="https://img.shields.io/npm/v/sidehand?color=2563eb" alt="npm"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-PolyForm%20Shield%201.0.0-2563eb" alt="PolyForm Shield 1.0.0 license"></a>
  <img src="https://img.shields.io/badge/Windows-10%20%7C%2011-2563eb" alt="Windows 10 and 11">
  <img src="https://img.shields.io/badge/MCP-server-2563eb" alt="MCP server">
</p>

<p align="center"><b>English</b> | <a href="README.ko.md">한국어</a> | <a href="README.zh-CN.md">简体中文</a></p>

![Three AI agents fill in three apps hidden behind your note at the same time, while you keep typing in it](assets/demo.gif)

Sidehand lets Claude, Codex, Cursor or any MCP client read and operate Windows apps behind the window you are using. It types, clicks, picks from lists and reads the screen as text without moving your mouse or taking your keyboard.

## Why Sidehand

- In the benchmark task your note kept the keyboard the whole time: 0 s lost, no window came forward, the cursor never moved.
- It works in windows covered by yours, so you can keep using the one in front.
- One short line per control: the task took 277 tokens, against 2,488 to 13,425 for the other tools. Reading a window takes about 4 to 5 times fewer tokens than agent-desktop on typical apps, and about 20 times fewer on an Edge page.
- It finished the task in 2.0 s. Windows-MCP and Terminator, the other tools that finished it, took 65.5 s and 68.0 s.

## Quick start

You need Windows 10 or 11 and Node 18.3+. Add the server to your MCP client:

```json
{
  "mcpServers": {
    "sidehand": { "command": "npx", "args": ["-y", "sidehand", "mcp"] }
  }
}
```

| Client | Where |
|---|---|
| Claude Code | `claude mcp add sidehand -- npx -y sidehand mcp` |
| Cursor | `~/.cursor/mcp.json` |
| Codex | `codex mcp add sidehand -- npx -y sidehand mcp` |
| Claude Desktop | Settings › Developer › Edit Config |
| pi | `pi install git:github.com/Blue-B/sidehand` |

On native Windows, Claude Desktop, Cursor and Codex need `cmd /c npx`. That, the Codex TOML, the CLI, the Claude Code guard hook and `SIDEHAND_ALLOW` are in [docs/setup.md](docs/setup.md).

Or paste this to your AI agent and it sets itself up:

```text
Install Sidehand (https://github.com/Blue-B/sidehand) for yourself: add an MCP server named "sidehand"
with command "npx" and args ["-y", "sidehand", "mcp"] to your own MCP settings.
If you are Claude Code, also run `npm install -g sidehand` and add the `sidehand guard`
PreToolUse hook from docs/setup.md in that repo. Then tell me whether I need to restart you.
```

Run `sidehand doctor` (or `npx -y sidehand doctor`) to check your setup.

## How it compares

| | Sidehand | [Claude computer use](https://code.claude.com/docs/en/desktop#let-claude-use-your-computer) | [ChatGPT computer use](https://developers.openai.com/codex/app/computer-use) | [agent-desktop](https://github.com/vercel-labs/agent-desktop) |
|---|:-:|:-:|:-:|:-:|
| You keep typing while it works | ✅ | ❌ hides your other windows on Windows | ❌ moves the pointer and takes the foreground on Windows | ❌ 4 windows came forward |
| Works on covered windows | ✅ | ❌ on Windows | ❌ on Windows | ✅ |
| Reads apps as text | ✅ | screenshots | screenshots | ✅ |

Sidehand and agent-desktop were measured ([docs/benchmark.md](docs/benchmark.md)); the computer use cells come from the linked vendor pages. More tools and all sources: [docs/comparison.md](docs/comparison.md).

## Usage

```console
$ sidehand tree "Contoso Orders"
window: Contoso Orders  (18 elements)
  e4 Edit "Customer"
  e12 Button "Submit order"

$ sidehand act e4 type "Blue-B Studio"
$ sidehand act e12 click
```

| Command | What it does |
|---|---|
| `tree <title>` | the window's controls as text, each with a ref (`e4`) |
| `act <ref> <action> [value]` | `type`, `click`, `select`, `check`, `press`, `wheel`, `drag` and more |
| `ocr <title>` | text of custom-drawn windows (games, Qt, canvas) via Windows OCR, with refs (`t1`) that `act` can click |
| `wait <title> <text>` | wait until a control with that text appears (or `--gone`) |
| `window`, `launch` | move, resize, restore or close a window; start an app without taking your focus |
| `capture`, `mask` | screenshot a covered window; black out, pixelate or blur regions |
| `doctor` | check your setup |

MCP and pi expose the same operations as tools (`ui_tree`, `ui_ocr`, `ui_act`, ...). Every command and option: [docs/usage.md](docs/usage.md).

## What works in the background

| | Win32, WinForms | WPF | Chrome, Edge | VS Code |
|---|:-:|:-:|:-:|:-:|
| Type, click, check, select, expand | ✅ | ✅ | ✅ except `<select>` | ✅ click |
| Wheel, double-click | ✅ | ✅ through UI Automation | ✅ | - |
| Right-click, hover, drag | ✅ | ❌ | ✅ | - |
| Keys and shortcuts | ✅ | Enter on a button or link; others with consent | Enter on a button or link; others with consent | with consent |

"With consent" means `--allow-foreground`, your permission to take the foreground.
Games that read raw mouse input ignore posted clicks, but `capture` and `ocr` still work.
Apps running as administrator need an agent running as administrator. Details: [docs/usage.md](docs/usage.md#what-works-in-the-background).

## Troubleshooting

Run `sidehand doctor` first. It checks Node, WSL, PowerShell, the execution policy, the engine and OCR languages, and touches no window.

- `spawn npx ENOENT` on native Windows: start the server with `cmd /c npx` ([docs/setup.md](docs/setup.md#native-windows-claude-desktop-cursor-codex)).
- Codex startup timeout: add `startup_timeout_sec = 60` under `[mcp_servers.sidehand]`.
- "running scripts is disabled on this system": Group Policy sets the execution policy; only your administrator can change it.
- `ocr` says no language is installed: add a Windows OCR language pack.
- An app running as administrator does not respond: run your agent as administrator too.

More: [docs/troubleshooting.md](docs/troubleshooting.md).

## Security

Text Sidehand reads from other windows goes to your agent, so treat it like web content: a page or message can try to instruct the agent.
`SIDEHAND_ALLOW` limits which windows it sees, and every string it passes to PowerShell is quoted or refused.

## License

[PolyForm Shield 1.0.0](LICENSE). Free for any use, including at work, except building or offering a product that competes with Sidehand or with products Blue-B provides using it, free or paid.
It includes a patent license that ends for anyone who claims Sidehand infringes a patent.
For a commercial license, open an issue.
