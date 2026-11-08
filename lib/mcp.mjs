// `sidehand mcp`: a Model Context Protocol server on stdio, so Claude Desktop, Claude Code, Cursor,
// Codex and other MCP clients can use sidehand without any extra package. Newline-delimited
// JSON-RPC 2.0; stdout carries protocol messages only.
import { readFileSync } from "node:fs";
import { createInterface } from "node:readline";
import * as cmd from "./commands.mjs";
import { useWorker } from "./powershell.mjs";

const VERSION = JSON.parse(readFileSync(new URL("../package.json", import.meta.url), "utf8")).version;
const PROTOCOLS = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"];
const EMBED_MAX_EDGE = Number(process.env.SIDEHAND_EMBED_MAX_EDGE) || 1568;

const INSTRUCTIONS = `sidehand reads and operates Windows desktop apps in the background while the user keeps working.
Read a window with ui_tree (compact text, a ref per control), act on refs with ui_act, use ui_wait instead of sleeping.
Prefer ui_tree over capture: it costs a few hundred tokens instead of an image. If ui_tree shows almost nothing (games, custom-drawn apps), ui_ocr reads the text with clickable refs.
Never take the user's focus: pass allow_foreground or bring_to_front only after the user agreed.
If a result ends with WARNING (the app came forward anyway), tell the user and do not repeat that action while they are busy.`;

const str = (description) => ({ type: "string", description });
const int = (description) => ({ type: "integer", description });
const bool = (description) => ({ type: "boolean", description });
const obj = (properties, required = []) => ({ type: "object", properties, required, additionalProperties: false });
const title = str("part of the window title (case-insensitive; an exact title wins) or a handle from list_windows (0x...)");
// MCP tool annotations: hints for clients deciding what to confirm with the user.
const READ = { readOnlyHint: true, openWorldHint: false };
const WRITE = { readOnlyHint: false, destructiveHint: false, openWorldHint: false };
const DESTROY = { readOnlyHint: false, destructiveHint: true, openWorldHint: false };

// name: [description, input schema, handler(args) -> result of a commands.mjs operation, annotations]
const TOOLS = {
	list_windows: ["List visible top-level windows (handle, size, title).", obj({}), () => cmd.windows(), READ],
	list_monitors: ["List monitors with their virtual-desktop coordinates.", obj({}), () => cmd.monitors(), READ],
	ui_tree: [
		"A window's controls as compact text, one line per control with a ref (e12). Long lists show 25 items; " +
			"filter prints matching lines only (refs still cover the window); rects adds screen rectangles. " +
			"If it shows almost nothing (games, Qt, canvas apps), use ui_ocr.",
		obj({ title, filter: str("only lines containing this text"), max_nodes: int("default 300"), rects: bool("add @x,y wxh") }, ["title"]),
		(a) => cmd.tree({ title: a.title, filter: a.filter, maxNodes: a.max_nodes, rects: a.rects }),
		READ,
	],
	ui_ocr: [
		"Only when ui_tree shows almost nothing (games, Qt, Sciter, canvas UIs): the window's text read by Windows OCR, " +
			"one line per text with a ref (t3) and screen rect. ui_act takes a t-ref for click, double-click, right-click, hover, wheel " +
			"and drag, posted at the text's center as mouse messages (no real cursor, no focus change). About 0.5 to 2 s; works while covered. t-refs expire after 60 s.",
		obj({ title }, ["title"]),
		(a) => cmd.ocr({ title: a.title }),
		READ,
	],
	ui_wait: [
		"Poll a window until a control containing text appears (or, with gone, disappears). Use instead of sleeping.",
		obj({ title, text: str("text to wait for"), gone: bool("wait for it to disappear"), timeout_ms: int("default 10000") }, ["title", "text"]),
		(a) => cmd.wait({ title: a.title, text: a.text, gone: a.gone, timeoutMs: a.timeout_ms }),
		READ,
	],
	ui_act: [
		"Act on a ref from the latest ui_tree/ui_wait/ui_ocr without moving the mouse or the user's focus. " +
			"click | type (replace text) | check | uncheck | select (value=<item> inside a list/combo) | expand | collapse | scroll | " +
			"right-click | double-click | hover | wheel (value 'down 3') | drag (value=<ref> or 'dx,dy') | press (value 'Enter', 'ctrl+a', 'Down Down Enter'). " +
			"focus, and press on WPF/browser controls (except Enter on a button or link), take the user's foreground: only with allow_foreground after the user agreed. " +
			"If an action fails, never fall back to moving the real mouse or bringing the window forward yourself; tell the user. " +
			"Refs expire when a window is read again.",
		obj(
			{
				ref: str("e.g. e12, or t3 from ui_ocr (click, double-click, right-click, hover, wheel, drag)"),
				action: { type: "string", enum: cmd.ACTIONS },
				value: str("text for type, item for select, keys for press, target ref (e or t) or 'dx,dy' for drag, direction for wheel"),
				allow_foreground: bool("permit taking the user's foreground window"),
			},
			["ref", "action"],
		),
		(a) => cmd.act({ ref: a.ref, action: a.action, value: a.value, allowForeground: a.allow_foreground }),
		DESTROY, // a click can press any button, Delete included
	],
	window: [
		"Move ('x,y'), resize ('w,h'), minimize, restore (back behind the user's windows) or close a window without activating it.",
		obj({ title, action: { type: "string", enum: cmd.WINDOW_ACTIONS }, value: str("x,y or w,h") }, ["title", "action"]),
		(a) => cmd.window({ title: a.title, action: a.action, value: a.value }),
		DESTROY, // close
	],
	launch: [
		"Start an app, document or URL without it taking the user's focus.",
		obj({ app: str("path, App Paths name (notepad, excel), document or URL"), args: str("command-line arguments") }, ["app"]),
		(a) => cmd.launch({ app: a.app, args: a.args }),
		{ ...WRITE, openWorldHint: true }, // URLs
	],
	clipboard: [
		"Read the clipboard text, or replace it with text (that overwrites what the user copied; prefer ui_act type).",
		obj({ text: str("omit to read") }),
		(a) => cmd.clipboard({ text: a.text }),
		DESTROY, // writing replaces what the user copied
	],
	capture: [
		"Screenshot: full, monitor, region, active or window (PrintWindow, works while covered). Returns the image. " +
			"Capturing a minimized window restores it, so it needs bring_to_front after the user agreed.",
		obj(
			{
				mode: { type: "string", enum: ["full", "monitor", "region", "active", "window"] },
				title,
				monitor: int("monitor index for mode=monitor"),
				x: int("region left"),
				y: int("region top"),
				w: int("region width"),
				h: int("region height"),
				bring_to_front: bool("restore and activate the window first (takes the user's focus)"),
			},
			["mode"],
		),
		(a) => cmd.capture({ mode: a.mode, title: a.title, monitor: a.monitor, x: a.x, y: a.y, w: a.w, h: a.h, bringToFront: a.bring_to_front }),
		READ, // writes only its own PNG in sidehand's captures folder
	],
	crop: [
		"Crop a PNG to a rectangle in image pixels. Returns the image.",
		obj({ in: str("PNG path"), x: int(""), y: int(""), w: int(""), h: int("") }, ["in", "x", "y", "w", "h"]),
		(a) => cmd.crop({ in: a.in, x: a.x, y: a.y, w: a.w, h: a.h }),
		{ ...WRITE, idempotentHint: true }, // writes <in>_crop.png
	],
	mask: [
		"Hide private information in a PNG before sharing it: black, pixelate or blur rectangles. Returns the image.",
		obj(
			{
				in: str("PNG path"),
				regions: { type: "array", items: obj({ x: int(""), y: int(""), w: int(""), h: int("") }, ["x", "y", "w", "h"]) },
				style: { type: "string", enum: ["black", "pixelate", "blur"] },
			},
			["in", "regions"],
		),
		(a) => cmd.mask({ in: a.in, regions: a.regions, style: a.style }),
		{ ...WRITE, idempotentHint: true }, // writes <in>_masked.png
	],
};

// Images go back downscaled to what models use anyway; the full PNG stays on disk.
async function imageContent(path) {
	const { details } = await cmd.info({ in: path });
	let file = path;
	if (Math.max(details.w, details.h) > EMBED_MAX_EDGE) {
		const opts = details.w >= details.h ? { maxW: EMBED_MAX_EDGE } : { maxH: EMBED_MAX_EDGE };
		file = (await cmd.resize({ in: path, out: path.replace(/\.png$/i, "_embed.png"), ...opts })).path;
	}
	return { type: "image", data: readFileSync(file).toString("base64"), mimeType: "image/png" };
}

async function call(name, args) {
	const tool = TOOLS[name];
	if (!tool) return { content: [{ type: "text", text: `unknown tool ${name}` }], isError: true };
	try {
		const r = await tool[2](args ?? {});
		const content = [{ type: "text", text: r.text }];
		if (r.path) content.push(await imageContent(r.path));
		return { content };
	} catch (e) {
		return { content: [{ type: "text", text: e.message }], isError: true };
	}
}

// Tool calls run one at a time, in order (the PowerShell worker takes one request at a time anyway).
// A call that has not started yet is dropped when the client cancels it, and answered with an error
// instead of run when the client closes stdin: a stopped agent must not keep clicking.
const waiting = new Map(); // request id -> { params, answer }, in arrival order: calls not started yet
let running; // id of the call in progress
const cancelled = new Set(); // request ids that get no reply (MCP: none for a cancelled request)

function queueCall(id, params) {
	return new Promise((answer) => {
		waiting.set(id, { params, answer });
		next();
	});
}

async function next() {
	if (running !== undefined || !waiting.size) return;
	const [id, { params, answer }] = waiting.entries().next().value;
	waiting.delete(id);
	running = id;
	try {
		answer(await call(params?.name, params?.arguments));
	} finally {
		running = undefined;
		next();
	}
}

function cancel(id) {
	if (!waiting.has(id) && running !== id) return;
	cancelled.add(id);
	waiting.get(id)?.answer(null);
	waiting.delete(id);
}

function refuseWaiting() {
	for (const [id, { answer }] of waiting) {
		waiting.delete(id);
		answer({ content: [{ type: "text", text: "not run: the client closed the connection before this call started" }], isError: true });
	}
}

async function handle(msg) {
	switch (msg.method) {
		case "initialize": {
			const asked = msg.params?.protocolVersion;
			return {
				protocolVersion: PROTOCOLS.includes(asked) ? asked : PROTOCOLS[0],
				capabilities: { tools: {} },
				serverInfo: { name: "sidehand", version: VERSION },
				instructions: INSTRUCTIONS,
			};
		}
		case "ping":
			return {};
		case "tools/list":
			return { tools: Object.entries(TOOLS).map(([name, [description, inputSchema, , annotations]]) => ({ name, description, inputSchema, annotations })) };
		case "tools/call":
			return queueCall(msg.id, msg.params);
		default:
			throw Object.assign(new Error(`method not found: ${msg.method}`), { code: -32601 });
	}
}

export async function serve() {
	useWorker(true);
	const send = (m) => process.stdout.write(`${JSON.stringify(m)}\n`);
	const rl = createInterface({ input: process.stdin });
	// When stdin closes, the call already running finishes and is answered; the queued ones are refused.
	const pending = new Set();
	rl.on("line", (line) => {
		const p = onLine(line);
		pending.add(p);
		p.finally(() => pending.delete(p));
	});
	rl.on("close", async () => {
		refuseWaiting();
		await Promise.allSettled(pending);
		useWorker(false);
		process.exit(0);
	});
	async function onLine(line) {
		if (!line.trim()) return;
		let msg;
		try {
			msg = JSON.parse(line);
		} catch {
			return send({ jsonrpc: "2.0", id: null, error: { code: -32700, message: "parse error" } });
		}
		if (msg.id === undefined) {
			if (msg.method === "notifications/cancelled") cancel(msg.params?.requestId);
			return; // notification
		}
		try {
			const result = await handle(msg);
			if (cancelled.delete(msg.id)) return;
			send({ jsonrpc: "2.0", id: msg.id, result });
		} catch (e) {
			send({ jsonrpc: "2.0", id: msg.id, error: { code: e.code ?? -32603, message: e.message } });
		}
	}
}
