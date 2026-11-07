#!/usr/bin/env node
// sidehand CLI: the same operations as the pi tools, for any agent that can run a shell command.
import { readFileSync } from "node:fs";
import { parseArgs } from "node:util";
import * as cmd from "../lib/commands.mjs";

const HELP = `sidehand - let your AI agent use Windows apps while you keep working

<title> is part of a window title (case-insensitive; an exact title wins) or a handle from \`sidehand windows\` (0x...).
Values that start with - go after --:  sidehand act e5 wheel -- -240

Read
  sidehand windows                                list visible windows
  sidehand monitors                               list monitors
  sidehand tree <title> [--filter t] [--max-nodes n] [--rects]
                                                  window controls as text, each with a ref (e1, e2, ...)
  sidehand wait <title> <text> [--gone] [--timeout ms]
                                                  wait until an element containing <text> appears (or disappears)
  sidehand ocr <title>                            text lines read by Windows OCR, each with a ref (t1, t2, ...);
                                                  for games and custom-drawn apps whose tree shows almost nothing
Act (refs come from the last tree/wait/ocr); nothing here takes your focus unless noted
  sidehand act <ref> <action> [value] [--allow-foreground]
      click | type <text> | check | uncheck | select [item] | expand | collapse | scroll
      right-click | double-click | hover | wheel [up|down N] | drag <ref|dx,dy> | press <keys>
        press: Enter, Tab, "Down Down Enter", ctrl+a ... (WPF/browser controls need --allow-foreground, except Enter on a button or link)
      OCR refs (t3) take click, double-click, right-click, hover, wheel and drag (to a t-ref or dx,dy), at the text's center
      focus: takes your foreground window, so it needs --allow-foreground
Windows and apps
  sidehand window <title> <move x,y | resize w,h | minimize | restore | close>
                                                  restore brings a minimized window back behind yours
  sidehand launch <app|path|url> [args]           start an app without it taking your focus
  sidehand clipboard [text]                       read the clipboard, or replace it with text
Capture and edit
  sidehand capture <full|active|monitor|region|window> [--title t] [--monitor n]
                   [--x n --y n --w n --h n] [--out file.png] [--bring-to-front]
  sidehand crop <in.png> <x> <y> <w> <h> [--out file.png]
  sidehand mask <in.png> <x,y,w,h[;x,y,w,h...]> [--style black|pixelate|blur] [--out file.png]
  sidehand resize <in.png> (--scale f | --max-w n | --max-h n) [--out file.png]
  sidehand info <in.png>

Setup
  sidehand doctor                                 check Node, PowerShell, policy, the engine and OCR; touches no window
  sidehand --version
MCP
  sidehand mcp                                    MCP server on stdio (Claude Desktop, Claude Code, Cursor, Codex)
  sidehand guard                                  Claude Code PreToolUse hook: blocks Bash commands that run a
                                                  script moving the real mouse or bringing a window forward
Environment
  SIDEHAND_ALLOW="Notepad;Contoso*"               only these windows can be read, operated or captured;
                                                  screen captures, launch and the clipboard are then off
  SIDEHAND_SESSION=agent1                         own ref cache: without it every CLI call shares one, so two
                                                  agents using the CLI at once overwrite each other's refs

Runs on Windows or inside WSL; needs only powershell.exe.`;

const ARGS = {
	allowPositionals: true,
	options: {
		filter: { type: "string" },
		"max-nodes": { type: "string" },
		rects: { type: "boolean" },
		gone: { type: "boolean" },
		timeout: { type: "string" },
		"allow-foreground": { type: "boolean" },
		title: { type: "string" },
		monitor: { type: "string" },
		x: { type: "string" },
		y: { type: "string" },
		w: { type: "string" },
		h: { type: "string" },
		out: { type: "string" },
		"bring-to-front": { type: "boolean" },
		style: { type: "string" },
		scale: { type: "string" },
		"max-w": { type: "string" },
		"max-h": { type: "string" },
		help: { type: "boolean", short: "h" },
		version: { type: "boolean" },
	},
};
let f, p;
try {
	({ values: f, positionals: p } = parseArgs(ARGS));
} catch (e) {
	console.error(`${HELP}\n\n${e.message}\nPut -- before values that start with -, e.g. sidehand act e5 wheel -- -240`);
	process.exit(2);
}

const num = (v) => (v == null ? undefined : Number(v));
const need = (n, usage) => {
	if (p.length < n + 1) throw new Error(`usage: sidehand ${usage}`);
};

const ops = {
	windows: () => cmd.windows(),
	monitors: () => cmd.monitors(),
	tree: () => (need(1, "tree <title>"), cmd.tree({ title: p[1], filter: f.filter, maxNodes: num(f["max-nodes"]), rects: f.rects })),
	ocr: () => (need(1, "ocr <title>"), cmd.ocr({ title: p[1] })),
	wait: () => (need(2, "wait <title> <text>"), cmd.wait({ title: p[1], text: p[2], gone: f.gone, timeoutMs: num(f.timeout) })),
	act: () => (need(2, "act <ref> <action> [value]"), cmd.act({ ref: p[1], action: p[2], value: p.slice(3).join(" ") || undefined, allowForeground: f["allow-foreground"] })),
	window: () => (need(2, "window <title> <action> [value]"), cmd.window({ title: p[1], action: p[2], value: p.slice(3).join(" ") || undefined })),
	launch: () => (need(1, "launch <app> [args]"), cmd.launch({ app: p[1], args: p.slice(2).join(" ") })),
	clipboard: () => cmd.clipboard({ text: p.length > 1 ? p.slice(1).join(" ") : undefined }),
	capture: () =>
		(need(1, "capture <mode>"),
		cmd.capture({
			mode: p[1],
			title: f.title,
			monitor: num(f.monitor),
			x: num(f.x),
			y: num(f.y),
			w: num(f.w),
			h: num(f.h),
			out: f.out,
			bringToFront: f["bring-to-front"],
		})),
	crop: () => (need(5, "crop <in> <x> <y> <w> <h>"), cmd.crop({ in: p[1], x: num(p[2]), y: num(p[3]), w: num(p[4]), h: num(p[5]), out: f.out })),
	mask: () => {
		need(2, "mask <in> <x,y,w,h[;...]>");
		const regions = p[2].split(";").map((s) => {
			const [x, y, w, h] = s.split(",").map(Number);
			if ([x, y, w, h].some(Number.isNaN)) throw new Error(`bad region "${s}", expected x,y,w,h`);
			return { x, y, w, h };
		});
		return cmd.mask({ in: p[1], regions, style: f.style, out: f.out });
	},
	resize: () => (need(1, "resize <in>"), cmd.resize({ in: p[1], scale: num(f.scale), maxW: num(f["max-w"]), maxH: num(f["max-h"]), out: f.out })),
	info: () => (need(1, "info <in>"), cmd.info({ in: p[1] })),
};

if (f.version) {
	console.log(JSON.parse(readFileSync(new URL("../package.json", import.meta.url), "utf8")).version);
} else if (p[0] === "mcp") {
	await (await import("../lib/mcp.mjs")).serve();
} else if (p[0] === "guard") {
	process.exitCode = await (await import("../lib/guard.mjs")).hook();
} else if (p[0] === "doctor") {
	process.exitCode = await (await import("../lib/doctor.mjs")).doctor();
} else if (f.help || !p[0] || !ops[p[0]]) {
	console.log(HELP);
	process.exit(f.help || !p[0] ? 0 : 2);
} else {
	try {
		console.log((await ops[p[0]]()).text);
	} catch (e) {
		console.error(e.message);
		process.exit(1);
	}
}
