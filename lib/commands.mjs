// Every sidehand operation, shared by the CLI and the pi extension. Each returns
// { text, path?, details } where `path` is an image this process can read.
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readdirSync, statSync, unlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { IS_WSL, firstLine, localPath, parseJsonLine, psNum, psQuote, runPS, winToWsl, wslToWin } from "./powershell.mjs";

// Screenshots stay in the user's own profile: a folder under C:\ (C:\tmp) inherits the drive root's
// ACL, which lets other local accounts read it. On Windows the user's %TEMP% is already private.
let OUT_DIR;
export function outDir() {
	if (OUT_DIR) return OUT_DIR;
	if (!IS_WSL) return (OUT_DIR = join(tmpdir(), "sidehand"));
	const local = execFileSync("cmd.exe", ["/d", "/c", "echo %LOCALAPPDATA%"], { cwd: "/mnt/c", encoding: "utf8", windowsHide: true }).trim();
	if (!/^[a-zA-Z]:\\/.test(local)) throw new Error(`could not find %LOCALAPPDATA% (got ${local}); pass an output path`);
	return (OUT_DIR = join(winToWsl(local), "sidehand", "captures"));
}

// Captures (and the MCP server's _embed.png copies next to them) are throwaway: each new one removes
// those older than a day, so the folder does not grow forever.
export function pruneCaptures(dir, now = Date.now()) {
	for (const name of readdirSync(dir)) {
		const file = join(dir, name);
		try {
			if (name.endsWith(".png") && now - statSync(file).mtimeMs > 86_400_000) unlinkSync(file);
		} catch {
			/* in use or already gone */
		}
	}
}

// Image paths are refused on a network share (\\host\share, //host/share): opening one makes Windows
// connect to that host and may send it the user's credentials. WSL's own \\wsl.localhost\ is local.
export function filePath(p) {
	if (/^[\\/]{2}/.test(p) && !/^[\\/]{2}wsl(\.localhost|\$)[\\/]/i.test(p)) throw new Error(`network paths are refused: ${p}`);
	return localPath(p);
}

function outPath(out, prefix) {
	if (out) return filePath(out);
	const dir = outDir();
	mkdirSync(dir, { recursive: true });
	pruneCaptures(dir);
	const stamp = new Date().toISOString().replace(/[-:T.Z]/g, "").slice(0, 14);
	return join(dir, `${prefix}_${stamp}_${Math.random().toString(36).slice(2, 6)}.png`);
}

function inputPath(p) {
	const local = filePath(p);
	if (!existsSync(local)) throw new Error(`input not found: ${local}`);
	return local;
}

async function run(scriptName, args, what, signal) {
	const r = await runPS(scriptName, args, signal);
	if (r.code !== 0) throw new Error(`${what} failed: ${firstLine(r)}`);
	return r;
}

export async function windows(signal) {
	const data = parseJsonLine((await run("list.ps1", ["-What", "windows", "-Json"], "list windows", signal)).stdout);
	const list = Array.isArray(data) ? data : [data];
	const text = list
		.map((w) => `${w.handle} ${w.minimized ? "[min]" : "     "} ${String(w.w).padStart(5)}x${String(w.h).padEnd(5)}  ${w.title}`)
		.join("\n");
	return { text: text || "(no windows)", details: { windows: list } };
}

export async function monitors(signal) {
	const data = parseJsonLine((await run("list.ps1", ["-What", "monitors", "-Json"], "list monitors", signal)).stdout);
	const list = Array.isArray(data) ? data : [data];
	const text = list.map((m) => `monitor[${m.index}] primary=${m.primary} x=${m.x} y=${m.y} w=${m.w} h=${m.h}`).join("\n");
	return { text: text || "(no monitors)", details: { monitors: list } };
}

export async function capture(o, signal) {
	const path = outPath(o.out, `cap_${o.mode}`);
	const args = ["-Mode", psQuote(o.mode), "-Out", psQuote(wslToWin(path)), "-Json"];
	if (o.mode === "region") {
		if ([o.x, o.y, o.w, o.h].some((v) => v == null)) throw new Error("region mode requires x, y, w, h");
		args.push("-X", psNum(o.x), "-Y", psNum(o.y), "-W", psNum(o.w), "-H", psNum(o.h));
	}
	if (o.mode === "monitor") {
		if (o.monitor == null) throw new Error("monitor mode requires a monitor index");
		args.push("-Monitor", psNum(o.monitor));
	}
	if (o.mode === "window") {
		if (!o.title) throw new Error("window mode requires a title");
		args.push("-Title", psQuote(o.title));
	}
	if (o.bringToFront) args.push("-BringToFront");
	const meta = parseJsonLine((await run("capture.ps1", args, "capture", signal)).stdout);
	const text =
		`Captured ${meta.mode} via ${meta.method} ${meta.w}x${meta.h} at (${meta.x},${meta.y})` +
		(meta.title ? `\nwindow: ${meta.title}` : "") +
		`\nsaved: ${path}`;
	return { text, path, details: { ...meta, out_local: path } };
}

// <in>_crop.png etc. next to the input, whatever its extension: never the input itself.
export function editOut(o, input, suffix) {
	const out = o.out ? filePath(o.out) : input.replace(/(\.[^.\\/]*)?$/, `_${suffix}.png`);
	if (resolve(out).toLowerCase() === resolve(input).toLowerCase()) throw new Error(`refusing to overwrite the input ${input}; pass another output path`);
	return out;
}

async function edit(op, input, out, extra, signal) {
	const args = ["-Op", op, "-In", psQuote(wslToWin(input)), "-Out", psQuote(wslToWin(out)), "-Json", ...extra];
	return parseJsonLine((await run("edit.ps1", args, op, signal)).stdout);
}

export async function crop(o, signal) {
	const input = inputPath(o.in);
	const out = editOut(o, input, "crop");
	const meta = await edit("crop", input, out, ["-X", psNum(o.x), "-Y", psNum(o.y), "-W", psNum(o.w), "-H", psNum(o.h)], signal);
	return { text: `Cropped to ${meta.w}x${meta.h} at (${meta.x},${meta.y})\nsaved: ${out}`, path: out, details: meta };
}

export async function mask(o, signal) {
	const input = inputPath(o.in);
	const out = editOut(o, input, "masked");
	const spec = o.regions.map((r) => `${r.x},${r.y},${r.w},${r.h}`).join(";");
	const extra = ["-Regions", psQuote(spec), "-MaskStyle", psQuote(o.style ?? "black")];
	if (o.pixel != null) extra.push("-Pixel", psNum(o.pixel));
	if (o.blurRadius != null) extra.push("-BlurRadius", psNum(o.blurRadius));
	const meta = await edit("mask", input, out, extra, signal);
	return { text: `Masked ${meta.count} region(s) with style=${meta.style}\nsaved: ${out}`, path: out, details: meta };
}

export async function resize(o, signal) {
	const input = inputPath(o.in);
	const out = editOut(o, input, "resized");
	const extra = [];
	if (o.scale != null) extra.push("-Scale", psNum(o.scale));
	if (o.maxW != null) extra.push("-MaxW", psNum(o.maxW));
	if (o.maxH != null) extra.push("-MaxH", psNum(o.maxH));
	const meta = await edit("resize", input, out, extra, signal);
	return { text: `Resized ${meta.from_w}x${meta.from_h} -> ${meta.w}x${meta.h}\nsaved: ${out}`, path: out, details: meta };
}

export async function info(o, signal) {
	const input = inputPath(o.in);
	const r = await run("edit.ps1", ["-Op", "info", "-In", psQuote(wslToWin(input)), "-Json"], "info", signal);
	const meta = parseJsonLine(r.stdout);
	return { text: `${meta.w}x${meta.h} ${input}`, details: meta };
}

export async function tree(o, signal) {
	const args = ["-Op", "tree", "-Title", psQuote(o.title)];
	if (o.filter) args.push("-Filter", psQuote(o.filter));
	if (o.maxNodes != null) args.push("-MaxNodes", psNum(o.maxNodes));
	if (o.rects) args.push("-Rects");
	return { text: (await run("uia.ps1", args, "ui tree", signal)).stdout.trim(), details: {} };
}

export async function wait(o, signal) {
	const args = ["-Op", "wait", "-Title", psQuote(o.title), "-Filter", psQuote(o.text)];
	if (o.gone) args.push("-Gone");
	if (o.timeoutMs != null) args.push("-TimeoutMs", psNum(o.timeoutMs));
	return { text: (await run("uia.ps1", args, "ui wait", signal)).stdout.trim(), details: {} };
}

// Custom-drawn windows (games, Qt, canvas UIs) whose tree is nearly empty: text lines by Windows OCR,
// each with a ref (t1, ...) that act clicks with posted mouse messages.
export async function ocr(o, signal) {
	return { text: (await run("uia.ps1", ["-Op", "ocr", "-Title", psQuote(o.title)], "ocr", signal)).stdout.trim(), details: {} };
}

export const ACTIONS = ["click", "type", "check", "uncheck", "select", "expand", "collapse", "scroll", "focus",
	"right-click", "double-click", "hover", "wheel", "drag", "press"];

export async function act(o, signal) {
	if (!ACTIONS.includes(o.action)) throw new Error(`unknown action ${o.action}; one of ${ACTIONS.join(", ")}`);
	const args = ["-Op", "act", "-Ref", psQuote(o.ref), "-Action", o.action, "-Value", psQuote(o.value ?? "")];
	if (o.allowForeground) args.push("-AllowForeground");
	try {
		return { text: (await run("uia.ps1", args, "ui act", signal)).stdout.trim(), details: {} };
	} catch (e) {
		// Agents tend to "fix" a failed act with their own SetCursorPos/SetForegroundWindow script,
		// which pulls the window over the user's work and takes their mouse.
		e.message += "\nDo not work around this with your own script that moves the real mouse or brings the window forward " +
			"(SetCursorPos, mouse_event, SendInput, SetForegroundWindow): it interrupts the user. Tell the user instead.";
		throw e;
	}
}

export const WINDOW_ACTIONS = ["move", "resize", "minimize", "restore", "close"];

export async function window(o, signal) {
	if (!WINDOW_ACTIONS.includes(o.action)) throw new Error(`unknown window action ${o.action}; one of ${WINDOW_ACTIONS.join(", ")}`);
	const args = ["-Op", "window", "-Title", psQuote(o.title), "-Action", o.action, "-Value", psQuote(o.value ?? "")];
	return { text: (await run("uia.ps1", args, "window", signal)).stdout.trim(), details: {} };
}

export async function launch(o, signal) {
	const args = ["-Op", "launch", "-Value", psQuote(o.app), "-Arguments", psQuote(o.args ?? "")];
	return { text: (await run("uia.ps1", args, "launch", signal)).stdout.trim(), details: {} };
}

// Without text: read the clipboard. With text: replace it (this overwrites what the user copied).
export async function clipboard(o, signal) {
	const args = ["-Op", "clipboard"];
	if (o.text != null) args.push("-Set", "-Value", psQuote(o.text));
	return { text: (await run("uia.ps1", args, "clipboard", signal)).stdout.trimEnd(), details: {} };
}
