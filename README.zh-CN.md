<p align="center">
  <img src="assets/logo.png" width="104" alt="Sidehand 标志">
</p>

<h1 align="center">Sidehand</h1>

<p align="center"><b>AI 智能体在后台操作你的 Windows 应用，键盘始终在你手里。</b></p>

<p align="center">
  <a href="https://www.npmjs.com/package/sidehand"><img src="https://img.shields.io/npm/v/sidehand?color=2563eb" alt="npm"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-FSL--1.1--MIT-2563eb" alt="FSL-1.1-MIT 许可证"></a>
  <img src="https://img.shields.io/badge/Windows-10%20%7C%2011-2563eb" alt="Windows 10 和 11">
  <img src="https://img.shields.io/badge/MCP-server-2563eb" alt="MCP 服务器">
</p>

<p align="center"><a href="README.md">English</a> · <a href="README.ko.md">한국어</a> · <b>简体中文</b></p>

![你在便笺里继续打字的同时，三个 AI 智能体同时填写藏在便笺后面的三个应用](assets/demo.gif)

Sidehand 让 Claude、Codex、Cursor 或任何 MCP 客户端读取并操作你当前窗口后面的 Windows 应用。它可以输入文字、点击、从列表中选择，并把界面读成文本，全程不移动你的鼠标，也不抢你的键盘。

## 为什么用 Sidehand

- **不打扰你。** 它在你的窗口后面工作，从不移动光标。即使某个应用自己跳到前台，你的窗口也会立刻回到最前面。
- **多个智能体同时工作。** 通过 MCP 或 pi 连接的每个智能体都有独立的会话，三个应用可以同时填写。CLI 调用默认共用一个会话，除非每个智能体各自设置不同的 `SIDEHAND_SESSION`。
- **读取成本低。** 每个控件只占一行短文本。在基准测试任务中，Sidehand 用了 277 个 token，其他工具用了 2,488 到 13,425 个。读取同一个窗口时，在常见应用上 token 用量约为 agent-desktop 的 1/4 到 1/5，在 Edge 网页上约为 1/20。
- **小巧、纯本地。** 没有常驻进程，没有遥测，不下载二进制文件。大约 2,800 行代码，一个下午就能读完。

## 快速开始

把 MCP 服务器加到你的客户端。需要 Windows 10 或 11、Node 18.3+ 和 [Git for Windows](https://git-scm.com/download/win)：下面的配置让 `npx` 从 GitHub 获取 Sidehand，这一步要用到 Git。

```json
{
  "mcpServers": {
    "sidehand": { "command": "npx", "args": ["-y", "github:Blue-B/sidehand", "mcp"] }
  }
}
```

| 客户端 | 配置位置 |
|---|---|
| Claude Desktop | 设置 › 开发者 › 编辑配置 |
| Claude Code | `claude mcp add sidehand -- npx -y github:Blue-B/sidehand mcp`（原生 Windows 上也一样，不需要 `cmd /c`） |
| Cursor | `~/.cursor/mcp.json` |
| Codex | `codex mcp add sidehand -- npx -y github:Blue-B/sidehand mcp`，或 `~/.codex/config.toml` 中的 `[mcp_servers.sidehand]`（[示例](#限制可操作的窗口)） |
| pi | `pi install git:github.com/Blue-B/sidehand` |

如果原生 Windows 上的 Claude Desktop、Cursor 或 Codex 无法启动服务器，请看[故障排除](#故障排除)。

不知道客户端的配置文件在哪里？把下面这段话直接发给你的 AI 智能体，它会自己完成设置：

```text
帮你自己安装 Sidehand（https://github.com/Blue-B/sidehand）：在你的 MCP 设置里添加一个名为 "sidehand" 的
MCP 服务器，command 为 "npx"，args 为 ["-y", "github:Blue-B/sidehand", "mcp"]。
如果你是 Claude Code，还要运行 `npm install -g github:Blue-B/sidehand`，并添加 README 里的 `sidehand guard`
PreToolUse 钩子。完成后告诉我是否需要重启你。
```

想用命令行？运行 `npm install -g github:Blue-B/sidehand`，用 `sidehand doctor` 检查环境，然后让智能体使用 `sidehand tree` 和 `sidehand act`（见[用法](#用法)）。

**别让卡住的智能体抢你的鼠标（Claude Code）。** 操作失败时，智能体可能会自己写脚本去移动真实鼠标或把应用拉到前台。安装 CLI 后，在 `.claude/settings.json` 中加入下面的钩子，就能拦截这类 Bash 命令，并让智能体改为询问你（pi 无需设置，会先询问你）：

```json
{
  "hooks": {
    "PreToolUse": [{ "matcher": "Bash", "hooks": [{ "type": "command", "command": "sidehand guard" }] }]
  }
}
```

## 与其他方案对比

| | Sidehand | [Claude computer use](https://code.claude.com/docs/en/desktop#let-claude-use-your-computer) | [ChatGPT computer use](https://developers.openai.com/codex/app/computer-use) | [Cua Driver](https://cua.ai/cua-driver) | [agent-desktop](https://github.com/vercel-labs/agent-desktop) |
|---|:-:|:-:|:-:|:-:|:-:|
| 它工作时你能继续打字 | ✅ 键盘被占用 0 秒 | ❌ 在 Windows 上工作时会隐藏你的其他窗口（后台使用仅限 macOS） | ❌ 在 Windows 上会移动指针并占据前台 | ❌ 0.28.2 每次调用都弹出控制台窗口并占据前台 | ❌ 1.0.2 让窗口跳到前台 4 次，键盘被占用 2.3 秒 |
| 能操作被遮住的窗口 | ✅ | ❌ 在 Windows 上会隐藏遮住应用的窗口 | ❌ 在 Windows 上应用必须保持可见 | ✅ 据其文档 | ✅ |
| 以文本方式读取应用 | ✅ | 截图 | 截图 | ✅ 据其文档 | ✅ |
| 遮盖你指定的区域（黑色、像素化、模糊） | ✅ | – | – | – | – |
| 支持系统 | Windows | macOS、Windows | macOS、Windows | macOS、Windows（预览版）、Linux | macOS、Windows、Linux |

Sidehand 和 agent-desktop 经过实测，见 [docs/benchmark.md](docs/benchmark.md)（英文）。Cua Driver 试用过但没有计分，基准测试文档只记录了它的控制台窗口问题。Claude 和 ChatGPT computer use 没有实测：这些格子以及 Cua Driver 标注“据其文档”的格子，内容来自所链接的厂商页面。– 表示所链接的页面没有提到，也没有测试。

![基准测试：Sidehand 没有占用你的键盘（0 秒），用 2.0 秒、277 个 token 完成任务](assets/benchmark.svg)

各项数据的测量方法见 [docs/benchmark.md](docs/benchmark.md)（英文）。

## 用法

```console
$ sidehand tree "Contoso Orders"
window: Contoso Orders  (18 elements)
  e4 Edit "Customer"
  e8 ComboBox "Region"
  e12 Button "Submit order"

$ sidehand act e4 type "Blue-B Studio"
$ sidehand act e8 select Jeju
$ sidehand act e12 click
$ sidehand wait "Contoso Orders" "Order submitted"
```

| 命令 | 作用 |
|---|---|
| `tree <标题>` | 以文本列出窗口中的控件，每个控件带一个 ref（`e1`、`e2`……） |
| `act <ref> <动作> [值]` | `type <文字>`、`click`、`check`、`uncheck`、`select [项]`、`expand`、`collapse`、`scroll`、`right-click`、`double-click`、`hover`、`wheel [up\|down N]`、`drag <ref\|dx,dy>`、`press <按键>`；`focus` 会占据你的前台窗口，所以需要 `--allow-foreground`（你的同意） |
| `ocr <标题>` | 用 Windows OCR 读取自绘窗口（游戏、Qt、画布应用）中的文字，每行带一个 ref（`t1`、`t2`……） |
| `act <t-ref> <动作>` | 对 OCR ref 可用 `click`、`double-click`、`right-click`、`hover`、`wheel`、`drag`，作用在文字中心；OCR ref 在生成它的 `ocr` 之后 60 秒过期 |
| `wait <标题> <文字>` | 等待包含该文字的控件出现（或用 `--gone` 等它消失） |
| `window <标题> <动作>` | `move`、`resize`、`minimize`、`restore`（放回你的窗口后面）、`close` |
| `launch <应用>` | 启动应用且不抢焦点 |
| `capture <方式>` | 即使窗口被遮住也能截图（`full`、`active`、`monitor`、`region`、`window`）；从 WSL 运行时保存在 `%LOCALAPPDATA%\sidehand\captures`，在 Windows 上保存在 `%TEMP%\sidehand`，超过一天的截图会被删除；网络共享路径上的图片会被拒绝 |
| `mask <png> <x,y,w,h[;...]>` | 分享截图前遮盖你指定的区域，`--style black`、`pixelate` 或 `blur` |
| `windows`、`clipboard` | 列出窗口；读取或设置剪贴板 |
| `doctor`、`--version` | 检查环境（见[故障排除](#故障排除)）；显示版本 |

`<标题>` 可以是窗口标题的一部分、完整标题，或窗口句柄（`sidehand windows` 列出的 `0x...`）。MCP 和 pi 以工具的形式提供同样的功能（`ui_tree`、`ui_ocr`、`ui_act`、`capture`、`mask` 等）。

### 限制可操作的窗口

把 `SIDEHAND_ALLOW` 设为用 `;` 分隔的窗口标题列表（例如 `"Contoso Orders;Notepad"`），其他窗口对它都不可见。此时全屏和区域截图、`launch` 和剪贴板都会关闭。在 MCP 配置中：

```json
"sidehand": { "command": "npx", "args": ["-y", "github:Blue-B/sidehand", "mcp"], "env": { "SIDEHAND_ALLOW": "Notepad" } }
```

在 Codex（`~/.codex/config.toml`）中：

```toml
[mcp_servers.sidehand]
command = "npx"
args = ["-y", "github:Blue-B/sidehand", "mcp"]
env = { SIDEHAND_ALLOW = "Notepad" }
```

或在命令行中：`codex mcp add sidehand --env SIDEHAND_ALLOW=Notepad -- npx -y github:Blue-B/sidehand mcp`（Claude Code 也接受同样的 `--env` 选项）。

## 后台可以做什么

| | Win32、WinForms | WPF | Chrome、Edge | VS Code |
|---|:-:|:-:|:-:|:-:|
| 输入、点击、勾选、选择、展开 | ✅ | ✅ | ✅（`<select>` 除外） | ✅ 点击 |
| 滚轮、双击 | ✅ | ✅ 通过 UI Automation | ✅ | – |
| 右键、悬停、拖动 | ✅ | ❌ | ✅ | – |
| 按键和快捷键 | ✅ | 按钮或链接上的 Enter；其他需要同意 | 按钮或链接上的 Enter；其他需要同意 | 需要同意 |

WPF 会忽略不是来自真实鼠标的鼠标消息，所以在 WPF 上滚轮通过 UI Automation 滚动最近的可滚动列表或视图，双击执行元素的默认操作（Invoke：表格行开始编辑，按钮被点击）；应用自己的双击处理程序不会运行。WPF 上的右键、悬停和拖动会被拒绝：UI Automation 的上下文菜单调用会把窗口带到前台。WPF 和网页只在获得焦点时接收按键，所以按键需要 `--allow-foreground`（用户同意），但按钮或链接上的 Enter 会直接按下它。WPF 不会告诉 UI Automation 哪个是默认按钮，所以文本框里的 Enter 也需要同意。游戏等自绘界面的应用（Qt、画布）不暴露控件：`ocr` 用 Windows 自带的 OCR 读取其中的文字，`act` 用投递的鼠标消息在文字上单击、双击、右键单击、悬停、滚动滚轮或拖动。

### 限制

- WPF：右键、悬停和拖动会被拒绝，应用自己的双击处理程序不会运行。
- WPF：文本框里的 Enter 和其他按键一样，需要你的同意（`--allow-foreground`）。
- Chrome 和 Edge：HTML `<select>` 下拉框无法在后台操作。
- 直接读取原始鼠标输入（raw input）的游戏会忽略投递的点击。`capture` 和 `ocr` 仍然可用。
- 以管理员身份运行的应用需要智能体也以管理员身份运行。
- 最小化的窗口要先用 `window <标题> restore` 恢复，恢复后的窗口位于你的窗口后面。

## 工作原理

Sidehand 是一个 UI Automation 客户端，和屏幕阅读器使用的是同一套接口，首次使用时在你的电脑上编译。传统控件通过普通窗口消息操作（`WM_SETTEXT`、`BM_CLICK` 等），窗口消息不会激活窗口。其他控件在目标窗口被临时标记为“不可激活”的状态下通过 UI Automation 调用，应用因此无法把自己拉到前台。点击和按键投递到应用自己的消息队列，从不经过你的鼠标。如果应用仍然强行跳到前台，Sidehand 会在不碰键盘和鼠标的情况下把前台交还给你的窗口。

**安全。** Sidehand 从其他窗口读到的文字会交给你的智能体，请像对待网页内容一样对待它：网页或消息可能试图向智能体下指令。`SIDEHAND_ALLOW` 可以限制它能看到的窗口；它传给 PowerShell 的每个字符串都会加引号（包括弯引号），否则直接拒绝。

## 故障排除

先运行 `sidehand doctor`（或 `npx -y github:Blue-B/sidehand doctor`），它会检查 Node、WSL 互操作、PowerShell、执行策略（包括组策略）、语言模式、是否以管理员身份运行、引擎以及已安装的 OCR 语言；不会操作任何窗口，有检查失败时以退出码 1 结束。

- **原生 Windows 上的 Claude Desktop、Cursor 或 Codex 无法启动服务器**（例如 `spawn npx ENOENT`）。在 Windows 上 `npx` 是一个 `.cmd` 脚本，不经过 shell 直接启动它的程序会得到 `ENOENT`。改用 `"command": "cmd"` 和 `"args": ["/c", "npx", "-y", "github:Blue-B/sidehand", "mcp"]`（Codex TOML 中为 `command = "cmd"`、`args = ["/c", "npx", ...]`）。Claude Code 直接用 `npx` 即可。
- **Codex 提示启动超时。** Codex 默认等待服务器启动 10 秒。第一次用 `npx` 下载可能更久，请在 `[mcp_servers.sidehand]` 下加上 `startup_timeout_sec = 60`。
- **`sidehand worker exited` 或“在此系统上禁止运行脚本”（running scripts is disabled on this system）。** Sidehand 用 `-ExecutionPolicy Bypass` 启动 PowerShell，但组策略设置的执行策略会覆盖它。`Get-ExecutionPolicy -List` 中会显示为 `MachinePolicy` 或 `UserPolicy`，只有管理员能更改。
- **受限语言模式（Constrained Language Mode）**（由 AppLocker 或 WDAC 设置）：PowerShell 会阻止 `Add-Type`，Sidehand 因此无法构建引擎。不支持这种环境。开启时 `$ExecutionContext.SessionState.LanguageMode` 显示 `ConstrainedLanguage`。
- **WSL**：Sidehand 通过 WSL interop 运行 `powershell.exe`，所以 `/etc/wsl.conf` 中的 interop 和 `appendWindowsPath` 必须保持开启（默认开启）。
- **`ocr` 提示 "Windows OCR has no language installed"。** Windows OCR 需要你的 Windows 配置文件中某种语言的 OCR 语言包。用 `Get-WindowsCapability -Online -Name Language.OCR*` 查看，在管理员 PowerShell 中添加，例如 `Add-WindowsCapability -Online -Name "Language.OCR~~~zh-CN~0.0.1.0"`。
- **以管理员身份运行的应用没有反应。** Windows 不允许普通进程向提升权限的进程发送输入。请也以管理员身份运行智能体。
- **第一次调用较慢。** 第一次调用会把引擎编译到 `%LOCALAPPDATA%\sidehand`，之后直接复用。

## 许可证

[FSL-1.1-MIT](LICENSE)（Functional Source License）。你可以为任何目的使用、修改和分享 Sidehand，包括在工作中使用，但不能把它或基于它构建的产品作为有竞争关系的商业产品或服务提供。例如，允许：公司用 Sidehand 让自己员工的智能体操作内部应用，或顾问为客户部署它。不允许：出售基于 Sidehand、提供相同功能的桌面智能体产品，或以托管服务形式提供。每个版本在发布两年后转为 MIT 许可证。如需商业许可，请提交 issue。
