/**
 * sidehand pi extension: the CLI's operations as pi tools.
 *
 *   sidehand_list_windows / sidehand_list_monitors   find targets
 *   sidehand_ui_tree / sidehand_ui_wait / sidehand_ui_act   read and operate controls without taking the user's focus
 *   sidehand_ui_ocr                                          text of custom-drawn windows, with refs ui_act can click
 *   sidehand_window / sidehand_launch / sidehand_clipboard   windows, apps and the clipboard
 *   sidehand_capture / _crop / _mask / _resize / _info     screenshots and privacy masking
 *
 * Zero external dependencies: powershell.exe and .NET, which ship with Windows.
 */
import { execFileSync } from "node:child_process";
import { readFileSync, unlinkSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { type ExtensionAPI, isToolCallEventType } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import * as cmd from "../../lib/commands.mjs";
import { findInputTakeover, takeoverReason } from "../../lib/guard.mjs";
import { useWorker } from "../../lib/powershell.mjs";

// Downscale images before embedding them: a full-resolution PNG in the context costs
// megabytes, while models downscale to ~1568px anyway. The full PNG stays on disk.
// SIDEHAND_EMBED_MAX_EDGE overrides the edge; SIDEHAND_NO_DOWNSCALE=1 disables it.
// Probed on the first image, not when pi loads the extension, and always run from the home folder: on
// Windows a bare "ffmpeg" is looked up in the working directory first, which may be an untrusted project.
const TRUSTED_CWD = homedir();
let FFMPEG: string | null | undefined;
function ffmpeg(): string | null {
	if (FFMPEG !== undefined) return FFMPEG;
	FFMPEG = null;
	for (const p of [join(homedir(), ".local", "bin", "ffmpeg"), "ffmpeg"]) {
		try {
			execFileSync(p, ["-version"], { stdio: "ignore", windowsHide: true, cwd: TRUSTED_CWD });
			return (FFMPEG = p);
		} catch {
			/* try next */
		}
	}
	return FFMPEG;
}
const EMBED_MAX_EDGE = Number(process.env.SIDEHAND_EMBED_MAX_EDGE) || 1568;

function image(path: string) {
	const ff = process.env.SIDEHAND_NO_DOWNSCALE !== "1" ? ffmpeg() : null;
	if (ff) {
		const out = join(tmpdir(), `sidehand_embed_${Date.now()}_${Math.random().toString(36).slice(2, 8)}.jpg`);
		try {
			const fit = `scale=w=min(${EMBED_MAX_EDGE}\\,iw):h=min(${EMBED_MAX_EDGE}\\,ih):force_original_aspect_ratio=decrease`;
			execFileSync(ff, ["-y", "-loglevel", "error", "-i", resolve(path), "-vf", fit, "-q:v", "5", out], { stdio: ["ignore", "ignore", "pipe"], windowsHide: true, cwd: TRUSTED_CWD });
			return { type: "image" as const, data: readFileSync(out).toString("base64"), mimeType: "image/jpeg" };
		} catch {
			// Never lose a capture over a failed downscale: fall back to the original.
		} finally {
			try {
				unlinkSync(out);
			} catch {
				/* not created */
			}
		}
	}
	return { type: "image" as const, data: readFileSync(path).toString("base64"), mimeType: "image/png" };
}

type Result = { text: string; path?: string; details: Record<string, unknown> };

function reply(r: Result, withImage = false) {
	const content: Array<{ type: "text"; text: string } | ReturnType<typeof image>> = [{ type: "text", text: r.text }];
	if (withImage && r.path) content.push(image(r.path));
	return { content, details: r.details };
}

const title = Type.String({ description: "part of the window title (case-insensitive; an exact title wins) or a handle from sidehand_list_windows (0x...)" });
const returnImage = Type.Optional(Type.Boolean({ default: true, description: "embed the image in the result" }));
const out = Type.Optional(Type.String({ description: "output path (WSL or Windows form)" }));

export default function sidehand(pi: ExtensionAPI): void {
	// pi stays up for the whole session: keep one PowerShell warm instead of starting one per call.
	useWorker(true);

	// An agent whose sidehand action failed may reach for its own SetCursorPos/SetForegroundWindow
	// script; the user decides, and without a UI to ask it is blocked.
	pi.on("tool_call", async (event, ctx) => {
		if (!isToolCallEventType("bash", event)) return;
		const hit = findInputTakeover(event.input.command, ctx.cwd);
		if (!hit) return;
		const question = `This command moves the real mouse or brings a window forward (${hit}), which interrupts the user. Allow it?`;
		if (ctx.hasUI && (await ctx.ui.confirm("sidehand", question))) return;
		return { block: true, reason: takeoverReason(hit, "sidehand_ui_act") };
	});

	pi.registerTool({
		name: "sidehand_list_windows",
		label: "List windows",
		description: "List visible top-level Windows windows (handle, size, minimized flag, title).",
		parameters: Type.Object({}),
		executionMode: "parallel",
		execute: async (_id, _p, signal) => reply(await cmd.windows(signal)),
	});

	pi.registerTool({
		name: "sidehand_list_monitors",
		label: "List monitors",
		description: "List connected monitors with virtual-desktop coordinates and the primary flag.",
		parameters: Type.Object({}),
		executionMode: "parallel",
		execute: async (_id, _p, signal) => reply(await cmd.monitors(signal)),
	});

	pi.registerTool({
		name: "sidehand_ui_tree",
		label: "Read window controls",
		description:
			"Read a Windows window as compact text via native UI Automation: buttons, inputs (with values), checkboxes, " +
			"list and tree items, each with a ref (e1, e2, ...). Far cheaper than a screenshot; try this first for desktop apps " +
			"(Explorer, Settings, Office, Win32, WinForms, WPF, Electron). Long lists show 25 items; pass filter to find one. " +
			"Reading never changes focus. Games and custom-drawn apps expose almost nothing: use sidehand_ui_ocr. " +
			"For web pages prefer a browser tool.",
		parameters: Type.Object({
			title,
			filter: Type.Optional(Type.String({ description: "only print lines containing this text; refs still cover the window" })),
			max_nodes: Type.Optional(Type.Integer({ minimum: 1, description: "walk limit, default 300" })),
			rects: Type.Optional(Type.Boolean({ description: "append screen rects @x,y wxh (for capture region / mask)" })),
		}),
		executionMode: "sequential",
		execute: async (_id, p, signal) =>
			reply(await cmd.tree({ title: p.title, filter: p.filter, maxNodes: p.max_nodes, rects: p.rects }, signal)),
	});

	pi.registerTool({
		name: "sidehand_ui_ocr",
		label: "Read window text (OCR)",
		description:
			"Only when sidehand_ui_tree shows almost nothing (games, Qt, Sciter, canvas UIs): the window's text read by the built-in " +
			"Windows OCR, one line per text with a ref (t1, t2, ...) and screen rect. sidehand_ui_act takes a t-ref for click, double-click, " +
			"right-click, hover, wheel and drag, posted at the text's center as mouse messages: the real cursor and the focus stay with the user. " +
			"About 0.5 to 2 s; works while the window is covered, not while it is minimized. t-refs expire after 60 s.",
		parameters: Type.Object({ title }),
		executionMode: "sequential",
		execute: async (_id, p, signal) => reply(await cmd.ocr({ title: p.title }, signal)),
	});

	pi.registerTool({
		name: "sidehand_ui_wait",
		label: "Wait for a control",
		description:
			"Poll a window until an element line contains `text` (or, with gone=true, until none does). " +
			"Use after an action that loads something instead of sleeping. Prints the matches with fresh refs.",
		parameters: Type.Object({
			title,
			text: Type.String({ description: "text to look for (case-insensitive)" }),
			gone: Type.Optional(Type.Boolean()),
			timeout_ms: Type.Optional(Type.Integer({ minimum: 100, description: "default 10000" })),
		}),
		executionMode: "sequential",
		execute: async (_id, p, signal) =>
			reply(await cmd.wait({ title: p.title, text: p.text, gone: p.gone, timeoutMs: p.timeout_ms }, signal)),
	});

	pi.registerTool({
		name: "sidehand_ui_act",
		label: "Act on a control",
		description:
			"Act on a ref from the latest sidehand_ui_tree/sidehand_ui_wait/sidehand_ui_ocr without moving the mouse or the user's focus. " +
			"click | type (replace text) | check | uncheck | select (or value=<item> inside a list/combo) | expand | collapse | scroll (into view) | " +
			"right-click | double-click | hover | wheel (value 'down 3') | drag (value=<ref> or 'dx,dy') | press (value 'Enter', 'ctrl+a', 'Down Down Enter'). " +
			"Classic controls get window messages, others UI Automation or posted input; the result warns if the app still came forward. " +
			"focus, and press on WPF/browser controls (except Enter on a button or link), take the user's foreground: only with allow_foreground=true after the user agreed. " +
			"If an action fails, never fall back to moving the real mouse or bringing the window forward yourself; tell the user. " +
			"Refs expire when the tree is read again.",
		parameters: Type.Object({
			ref: Type.String({ description: "e.g. e12, or t3 from sidehand_ui_ocr (click, double-click, right-click, hover, wheel, drag)" }),
			action: Type.Union(cmd.ACTIONS.map((a: string) => Type.Literal(a))),
			value: Type.Optional(Type.String({ description: "text for type, item for select, keys for press, target ref (e or t) or 'dx,dy' for drag, direction for wheel" })),
			allow_foreground: Type.Optional(Type.Boolean({ description: "permit taking the user's foreground window" })),
		}),
		executionMode: "sequential",
		execute: async (_id, p, signal) =>
			reply(await cmd.act({ ref: p.ref, action: p.action, value: p.value, allowForeground: p.allow_foreground }, signal)),
	});

	pi.registerTool({
		name: "sidehand_window",
		label: "Manage a window",
		description:
			"Move ('x,y'), resize ('w,h'), minimize, restore or close a window without activating it. " +
			"restore brings a minimized window back behind the user's windows so it can be read and operated.",
		parameters: Type.Object({
			title,
			action: Type.Union(cmd.WINDOW_ACTIONS.map((a: string) => Type.Literal(a))),
			value: Type.Optional(Type.String()),
		}),
		executionMode: "sequential",
		execute: async (_id, p, signal) => reply(await cmd.window({ title: p.title, action: p.action, value: p.value }, signal)),
	});

	pi.registerTool({
		name: "sidehand_launch",
		label: "Launch an app",
		description: "Start an app, document or URL without it taking the user's focus. Prints the new window's title.",
		parameters: Type.Object({
			app: Type.String({ description: "path, App Paths name (notepad, excel), document or URL" }),
			args: Type.Optional(Type.String()),
		}),
		executionMode: "sequential",
		execute: async (_id, p, signal) => reply(await cmd.launch({ app: p.app, args: p.args }, signal)),
	});

	pi.registerTool({
		name: "sidehand_clipboard",
		label: "Clipboard",
		description:
			"Read the clipboard text, or replace it with text. Replacing overwrites what the user copied, so prefer sidehand_ui_act type to enter text.",
		parameters: Type.Object({ text: Type.Optional(Type.String({ description: "omit to read" })) }),
		executionMode: "sequential",
		execute: async (_id, p, signal) => reply(await cmd.clipboard({ text: p.text }, signal)),
	});

	pi.registerTool({
		name: "sidehand_capture",
		label: "Capture screen",
		description:
			"Capture the Windows screen as PNG. To read or operate an app, try sidehand_ui_tree first (text, far fewer tokens). " +
			"Modes: full (all monitors), region (x,y,w,h), monitor (index), active (foreground window), " +
			"window (title substring; PrintWindow, works while the window is covered). " +
			"A minimized window is refused because restoring it takes the user's focus; bring_to_front=true only with consent.",
		parameters: Type.Object({
			mode: Type.Union([Type.Literal("full"), Type.Literal("region"), Type.Literal("monitor"), Type.Literal("active"), Type.Literal("window")]),
			x: Type.Optional(Type.Integer()),
			y: Type.Optional(Type.Integer()),
			w: Type.Optional(Type.Integer()),
			h: Type.Optional(Type.Integer()),
			monitor: Type.Optional(Type.Integer({ minimum: 0 })),
			title: Type.Optional(title),
			bring_to_front: Type.Optional(Type.Boolean({ default: false })),
			out,
			return_image: returnImage,
		}),
		executionMode: "sequential",
		execute: async (_id, p, signal) =>
			reply(
				await cmd.capture(
					{ mode: p.mode, x: p.x, y: p.y, w: p.w, h: p.h, monitor: p.monitor, title: p.title, bringToFront: p.bring_to_front, out: p.out },
					signal,
				),
				p.return_image !== false,
			),
	});

	pi.registerTool({
		name: "sidehand_crop",
		label: "Crop image",
		description: "Crop a PNG by pixel rectangle in image coordinates.",
		parameters: Type.Object({ in: Type.String(), x: Type.Integer(), y: Type.Integer(), w: Type.Integer(), h: Type.Integer(), out, return_image: returnImage }),
		executionMode: "sequential",
		execute: async (_id, p, signal) => reply(await cmd.crop(p, signal), p.return_image !== false),
	});

	pi.registerTool({
		name: "sidehand_mask",
		label: "Mask regions",
		description:
			"Hide private info (keys, names, faces) in one or more rectangles of a PNG. " +
			"style: black (solid, default), pixelate (shape stays, text unreadable), blur.",
		parameters: Type.Object({
			in: Type.String(),
			regions: Type.Array(Type.Object({ x: Type.Integer(), y: Type.Integer(), w: Type.Integer(), h: Type.Integer() }), { minItems: 1 }),
			style: Type.Optional(Type.Union([Type.Literal("black"), Type.Literal("pixelate"), Type.Literal("blur")])),
			pixel: Type.Optional(Type.Integer({ minimum: 2, description: "pixelate block size, default 16" })),
			blur_radius: Type.Optional(Type.Integer({ minimum: 2, description: "default 12" })),
			out,
			return_image: returnImage,
		}),
		executionMode: "sequential",
		execute: async (_id, p, signal) =>
			reply(await cmd.mask({ in: p.in, regions: p.regions, style: p.style, pixel: p.pixel, blurRadius: p.blur_radius, out: p.out }, signal), p.return_image !== false),
	});

	pi.registerTool({
		name: "sidehand_resize",
		label: "Resize image",
		description: "Resize a PNG keeping aspect ratio (one of scale, max_w, max_h) to cut tokens before showing it.",
		parameters: Type.Object({
			in: Type.String(),
			scale: Type.Optional(Type.Number({ exclusiveMinimum: 0 })),
			max_w: Type.Optional(Type.Integer({ minimum: 1 })),
			max_h: Type.Optional(Type.Integer({ minimum: 1 })),
			out,
			return_image: returnImage,
		}),
		executionMode: "sequential",
		execute: async (_id, p, signal) =>
			reply(await cmd.resize({ in: p.in, scale: p.scale, maxW: p.max_w, maxH: p.max_h, out: p.out }, signal), p.return_image !== false),
	});

	pi.registerTool({
		name: "sidehand_info",
		label: "Image size",
		description: "Report a PNG's width and height before crop/mask math.",
		parameters: Type.Object({ in: Type.String() }),
		executionMode: "parallel",
		execute: async (_id, p, signal) => reply(await cmd.info(p, signal)),
	});
}
