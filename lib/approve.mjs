// Asks the user before sidehand first acts on an app, and before an action that looks sensitive
// (a click or Enter on Delete, Send, Pay, ...; a window close). Used by the MCP server and the pi
// extension; the CLI never asks (an agent runs it). Gated: ui_act, window, launch and clipboard
// writes, the tools that change something the user sees or owns; reading and capturing is not.
// SIDEHAND_CONFIRM: unset = ask when the client can, else act as before; strict = refuse what needs
// the user when the client cannot ask; off = never ask. "Always block" holds in every mode.
import { mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import * as cmd from "./commands.mjs";

// Control names that make click, double-click, Enter and Space ask first. Keep it short: every hit is a prompt.
// A point ref (@x,y) names no control, so it never matches.
const SENSITIVE = /\b(?:delete|remove|send|pay|purchase|buy|check[ -]?out|sign[ -]?in|log[ -]?in|share|publish|submit order)\b|삭제|보내기|전송|결제|구매|로그인|공유|게시/i;

export function isSensitive(action, value, control) {
	const pressing = action === "click" || action === "double-click" || (action === "press" && /\b(?:enter|return|space)\b/i.test(value ?? ""));
	return pressing && SENSITIVE.test(control ?? "");
}

export const APP_CHOICES = ["Don't allow", "Allow once (this session)", "Always allow", "Always block"];
export const CONFIRM_CHOICES = ["Yes", "No"];

// { allow: ["notepad.exe"], block: [...] }: the user's Always answers, shared by WSL and Windows.
export function approvalsFile() {
	return join(process.env.SIDEHAND_CONFIG_DIR || cmd.appDir(), "approvals.json");
}

function load() {
	let text;
	try {
		text = readFileSync(approvalsFile(), "utf8");
	} catch {
		return { allow: [], block: [] }; // none yet
	}
	// Unreadable: refuse rather than drop the user's Always block (and overwrite their list on the next answer).
	try {
		const s = JSON.parse(text);
		return { allow: Array.isArray(s.allow) ? s.allow : [], block: Array.isArray(s.block) ? s.block : [] };
	} catch {
		throw new Error(`Not run: ${approvalsFile()} is not valid JSON, so the user's Always block list cannot be checked. Tell the user to fix or delete it.`);
	}
}

function remember(list, app) {
	const file = approvalsFile();
	const s = load(); // re-read: another sidehand may have written since
	s.allow = s.allow.filter((a) => a !== app);
	s.block = s.block.filter((a) => a !== app);
	s[list].push(app);
	mkdirSync(join(file, ".."), { recursive: true });
	const tmp = `${file}.${process.pid}.tmp`; // two sessions may answer at once
	writeFileSync(tmp, `${JSON.stringify(s, null, 2)}\n`);
	renameSync(tmp, file);
}

const allowedOnce = new Set(); // "Allow once (this session)": this process only

function describe(tool, o, t) {
	if (tool === "clipboard") return "replace the clipboard text";
	if (tool === "launch") return `launch ${o.app}${o.args ? ` with the arguments ${o.args}` : ""} (${t.app})`;
	if (tool === "window") return `${o.action} the window "${t.window}" (${t.app})`;
	const what = o.action === "press" ? `press ${o.value}` : o.action;
	return `${what} on ${t.type} "${t.control}" in "${t.window}" (${t.app})`;
}

// Resolves when the action may run, throws when it may not. ask(question, choices) returns the chosen
// choice, or null when the user declined or dismissed the question; null ask = this client cannot ask.
export async function approve(tool, o, ask, signal) {
	if (tool === "clipboard" && o.text == null) return; // reading
	const mode = process.env.SIDEHAND_CONFIRM;
	const saved = load();
	if ((mode === "off" || (!ask && mode !== "strict")) && !saved.block.length) return; // as before: no extra call
	// The clipboard has no app to look up, but the lookup also refuses while the user has pressed Stop.
	const t = await cmd.target(tool === "clipboard" ? { clipboard: true } : tool === "ui_act" ? { ref: o.ref } : tool === "window" ? { title: o.title } : { app: o.app }, signal);
	// The window asked about is the one acted on, even if another with that title shows up while the user answers.
	if (tool === "window" && t.hwnd) o.title = t.hwnd;
	const what = describe(tool, o, t);
	if (saved.block.includes(t.app))
		throw new Error(`Not run: the user chose Always block for ${t.app} (in ${approvalsFile()}). Do not retry or work around it; tell the user.`);
	if (mode === "off") return;
	const known = saved.allow.includes(t.app) || allowedOnce.has(t.app);
	// A launch with arguments, or of a program by path, is confirmed even for an allowed app: "Always allow
	// notepad.exe" must not cover `powershell -c ...` or a downloaded notepad.exe.
	const sensitive =
		tool === "window" ? o.action === "close" : tool === "launch" ? !!o.args || /[\\/]/.test(o.app) : tool === "ui_act" && isSensitive(o.action, o.value, t.control);
	if (known && !sensitive) return;
	if (!ask) {
		if (mode !== "strict") return;
		const how = known ? "they can do it themselves" : `they can do it themselves, or add "${t.app}" to "allow" in ${approvalsFile()}`;
		throw new Error(`Not run: ${what} needs the user's approval, and this client cannot ask them (SIDEHAND_CONFIRM=strict). Ask the user; ${how}.`);
	}
	const declined = new Error(`Not run: the user did not allow ${what}. Do not retry or work around it; ask the user what to do.`);
	if (!known) {
		// One question for both: the user sees the action, so allowing the app confirms it too.
		const subject = t.app === "clipboard" ? "replace your clipboard" : `operate ${t.app}`;
		const choice = await ask(`Allow sidehand to ${subject}?\nIt wants to: ${what}${sensitive ? "\nThis action may be hard to undo." : ""}`, APP_CHOICES);
		if (choice === "Always allow") remember("allow", t.app);
		else if (choice === "Always block") remember("block", t.app);
		if (choice === APP_CHOICES[1] || choice === "Always allow") return void allowedOnce.add(t.app);
		throw declined;
	}
	if ((await ask(`sidehand is about to ${what}.\nThis may be hard to undo. Go ahead?`, CONFIRM_CHOICES)) !== "Yes") throw declined;
}
