# Setting up Sidehand

You need Windows 10 or 11 and Node 18.3+. The install lines below fetch Sidehand from npm. Sidehand runs on Windows or inside WSL and needs only `powershell.exe`.

## MCP clients

The server entry is the same everywhere:

```json
{
  "mcpServers": {
    "sidehand": { "command": "npx", "args": ["-y", "sidehand", "mcp"] }
  }
}
```

| Client | Where |
|---|---|
| Claude Code | `claude mcp add sidehand -- npx -y sidehand mcp` (also on native Windows, no `cmd /c` needed) |
| Cursor | `~/.cursor/mcp.json` |
| Codex | `codex mcp add sidehand -- npx -y sidehand mcp`, or `~/.codex/config.toml` (below) |
| Claude Desktop | Settings › Developer › Edit Config |
| pi | `pi install git:github.com/Blue-B/sidehand` |

Codex in `~/.codex/config.toml`:

```toml
[mcp_servers.sidehand]
command = "npx"
args = ["-y", "sidehand", "mcp"]
startup_timeout_sec = 60
```

Codex waits 10 seconds for a server to start by default, and the first `npx` download can take longer, so `startup_timeout_sec = 60` avoids a startup timeout.

### Native Windows: Claude Desktop, Cursor, Codex

On Windows `npx` is a `.cmd` script, and a program that starts it without a shell gets `spawn npx ENOENT`. Start it through `cmd`:

```json
"sidehand": { "command": "cmd", "args": ["/c", "npx", "-y", "sidehand", "mcp"] }
```

```toml
[mcp_servers.sidehand]
command = "cmd"
args = ["/c", "npx", "-y", "sidehand", "mcp"]
```

Claude Code starts plain `npx` fine.

## CLI

```bash
npm install -g sidehand
sidehand doctor
```

Then tell your agent to use `sidehand tree` and `sidehand act` (see [usage.md](usage.md)). `sidehand --help` lists every command.

Each agent connected through MCP or pi gets its own session, so several agents can work in different apps at the same time. CLI calls share one ref cache: if two agents use the CLI at once, give each its own `SIDEHAND_SESSION` (for example `SIDEHAND_SESSION=agent1`), or they overwrite each other's refs.

## Keep a stuck agent off your mouse (Claude Code)

When an action fails, an agent may write its own script that moves the real mouse or pulls the app forward. With the CLI installed, this hook in `.claude/settings.json` blocks such Bash commands and tells the agent to ask you instead:

```json
{
  "hooks": {
    "PreToolUse": [{ "matcher": "Bash", "hooks": [{ "type": "command", "command": "sidehand guard" }] }]
  }
}
```

pi does this on its own and asks you first.

## Limit what it can touch

Set `SIDEHAND_ALLOW` to a list of window titles separated by `;` (for example `"Contoso Orders;Notepad"`), and every other window disappears from its view. Full-screen and region captures, `launch` and the clipboard are then off.

In an MCP config:

```json
"sidehand": { "command": "npx", "args": ["-y", "sidehand", "mcp"], "env": { "SIDEHAND_ALLOW": "Notepad" } }
```

In Codex (`~/.codex/config.toml`):

```toml
[mcp_servers.sidehand]
command = "npx"
args = ["-y", "sidehand", "mcp"]
env = { SIDEHAND_ALLOW = "Notepad" }
```

On the command line: `codex mcp add sidehand --env SIDEHAND_ALLOW=Notepad -- npx -y sidehand mcp`. Claude Code takes the same `--env` option.
