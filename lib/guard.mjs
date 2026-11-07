// Catches an agent working around a failed sidehand action with its own script that moves the
// real mouse, sends keys or brings a window forward: that interrupts the user, the thing sidehand
// exists to avoid. Used by the pi extension (tool_call) and `sidehand guard` (Claude Code hook).
// shortcut: a text heuristic. It sees the command line, PowerShell -EncodedCommand and the script
// files the command names, not files those scripts load in turn, code built at run time, or
// AutoHotkey's own verbs (Click, WinActivate). It stops a tempted agent, not a determined one.
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve, sep } from "node:path";
import { IS_WSL, SCRIPT_DIR } from "./powershell.mjs";

const INTERPRETER =
	/(?:^|[\s;|&('"`/\\])(?:(?:powershell|pwsh|cscript|wscript|rundll32|autohotkey\w*|python[\d.]*|py)(?:\.exe)?|cmd\.exe|cmd(?=\s+\/[ck]))(?=$|[\s;|&)'"`])/i;
const TAKEOVER =
	/\b(?:SetCursorPos|mouse_event|keybd_event|SendInput|SetForegroundWindow|SwitchToThisWindow|BringWindowToTop|AppActivate|SendKeys|SendWait)\b|\bCursor(?:\]::|\.)Position\b/i;
const SCRIPT_EXT = "ps1|vbs|js|ahk|py";
const QUOTED_SCRIPT = new RegExp(`(["'])([^"'\\n]*?\\.(?:${SCRIPT_EXT}))\\1`, "gi");
const BARE_SCRIPT = new RegExp(`[^\\s'"\`;|&<>()]+\\.(?:${SCRIPT_EXT})(?![\\w.])`, "gi");
const ENCODED = /\s-(?:e|ec|enc\w*)\s+([A-Za-z0-9+/=]{8,})/gi;

const sameCase = (p) => (process.platform === "win32" ? p.toLowerCase() : p);
const OWN_SCRIPTS = sameCase(SCRIPT_DIR + sep);

const NETWORK = /^[\\/]{2}/;

// A path as written in the command (C:\.., \\wsl.localhost\<distro>\.., ~/.., relative) -> a path this process can
// read, or null.
function readablePath(p, cwd) {
	const drive = p.match(/^([a-zA-Z]):[\\/](.*)$/);
	if (drive && IS_WSL) return `/mnt/${drive[1].toLowerCase()}/${drive[2].replace(/\\/g, "/")}`;
	const wsl = p.match(/^\\\\wsl(?:\.localhost|\$)\\[^\\]+\\(.*)$/i);
	if (wsl && IS_WSL) return `/${wsl[1].replace(/\\/g, "/")}`;
	// Never a network path (\\host\share, //host/share): opening it makes Windows connect to that host,
	// which may send it the user's credentials before they have approved the command.
	if (NETWORK.test(p)) return null;
	const file = p.startsWith("~/") ? join(homedir(), p.slice(2)) : resolve(cwd, p);
	return NETWORK.test(file) ? null : file;
}

// What the command would use to take the user's mouse, keys or foreground ("SetCursorPos in
// C:\tmp\x.ps1"), or null.
export function findInputTakeover(command, cwd = process.cwd()) {
	if (typeof command !== "string" || !INTERPRETER.test(command)) return null;
	const sources = [["the command", command]];
	for (const [, b64] of command.matchAll(ENCODED)) sources.push(["the encoded command", Buffer.from(b64, "base64").toString("utf16le")]);
	const paths = new Set([...command.matchAll(QUOTED_SCRIPT)].map((m) => m[2]));
	for (const [p] of command.matchAll(BARE_SCRIPT)) paths.add(p);
	for (const p of paths) {
		const file = readablePath(p, cwd);
		if (!file || sameCase(file).startsWith(OWN_SCRIPTS)) continue;
		try {
			sources.push([p, readFileSync(file, "utf8")]);
		} catch {
			/* not a readable file */
		}
	}
	for (const [where, text] of sources) {
		const m = text.match(TAKEOVER);
		if (m) return `${m[0]} in ${where}`;
	}
	return null;
}

export function takeoverReason(hit, actTool) {
	return `Blocked: this command moves the real mouse, sends real keys or brings a window forward (${hit}), which interrupts the user. ` +
		`Use ${actTool} to operate the app in the background; if that fails, tell the user what failed instead of working around it.`;
}

// `sidehand guard`: a Claude Code PreToolUse hook. Reads the hook JSON on stdin; exit 2 blocks the
// call and hands stderr to the agent.
export async function hook() {
	let raw = "";
	for await (const chunk of process.stdin) raw += chunk;
	let event;
	try {
		event = JSON.parse(raw);
	} catch {
		return 0;
	}
	if (event?.tool_name !== "Bash") return 0;
	const hit = findInputTakeover(event.tool_input?.command, event.cwd || process.cwd());
	if (!hit) return 0;
	process.stderr.write(`${takeoverReason(hit, "the sidehand ui_act tool (or `sidehand act`)")}\n`);
	return 2;
}
