// Shared by the CLI (bin/sidehand.mjs) and the pi extension: locate the bundled PowerShell
// scripts, translate WSL <-> Windows paths, and run a script through powershell.exe.
import { execFileSync, spawn } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { dirname, join, resolve, win32 } from "node:path";
import { fileURLToPath } from "node:url";

export const SCRIPT_DIR = resolve(dirname(fileURLToPath(import.meta.url)), "..", "scripts");

export const IS_WSL = (() => {
	if (process.platform !== "linux") return false;
	try {
		return /microsoft/i.test(readFileSync("/proc/version", "utf8"));
	} catch {
		return false;
	}
})();

// By full path on Windows: a bare name is looked up in the working directory first, which may be a
// folder the agent opened (a planted powershell.exe there would run). WSL finds it on PATH via interop.
export const POWERSHELL =
	process.platform === "win32" ? win32.join(process.env.SystemRoot || "C:\\Windows", "System32", "WindowsPowerShell", "v1.0", "powershell.exe") : "powershell.exe";

export function script(name) {
	const p = join(SCRIPT_DIR, name);
	if (!existsSync(p)) throw new Error(`sidehand: missing ${p}`);
	return wslToWin(p);
}

// /mnt/c/foo -> C:\foo ; other WSL paths -> \\wsl.localhost\<distro>\... ; Windows paths unchanged.
export function wslToWin(p) {
	if (!IS_WSL) return p;
	const m = p.match(/^\/mnt\/([a-z])\/(.*)$/i);
	if (m) return `${m[1].toUpperCase()}:\\${m[2].replace(/\//g, "\\")}`;
	if (p.startsWith("/")) {
		try {
			return execFileSync("wslpath", ["-w", p], { encoding: "utf8" }).trim() || p;
		} catch {
			return p;
		}
	}
	return p;
}

// C:\foo -> /mnt/c/foo under WSL; unchanged on Windows.
export function winToWsl(p) {
	if (!IS_WSL) return p;
	const m = p.match(/^([a-zA-Z]):\\(.*)$/);
	return m ? `/mnt/${m[1].toLowerCase()}/${m[2].replace(/\\/g, "/")}` : p;
}

// Accepts either form and returns the path this process can open.
export function localPath(p) {
	return IS_WSL && /^[a-zA-Z]:\\/.test(p) ? winToWsl(p) : p;
}

// PowerShell single-quoted literal. PowerShell also ends a quote at ‘ ’ ‚ ‛, so those are doubled too:
// left alone, text after a typographic apostrophe ("don’t") would run as code.
export function psQuote(v) {
	return `'${String(v).replace(/['\u2018\u2019\u201A\u201B]/g, "$&$&")}'`;
}

// A number for the command line; anything else ("1; calc") is refused instead of pasted into the script.
export function psNum(v) {
	const n = Number(v);
	if (v === "" || v == null || !Number.isFinite(n)) throw new Error(`not a number: ${v}`);
	return String(n);
}

// WSL hands only the variables named in WSLENV to Windows programs.
const ENV = IS_WSL ? { ...process.env, WSLENV: [process.env.WSLENV, "SIDEHAND_ALLOW", "SIDEHAND_SESSION"].filter(Boolean).join(":") } : process.env;

// What went wrong starting powershell.exe, in words a user can act on.
function startError(e, stderr = "") {
	if (e?.code === "ENOENT") return "powershell.exe not found: sidehand runs on Windows, or in WSL with Windows interop on";
	const tail = stderr.trim();
	return `${e ? e.message : "sidehand worker exited"}${tail ? `: ${tail}` : ""}`;
}

// Long-running hosts (the MCP server, the pi extension) call useWorker(): every operation then
// goes to one persistent powershell.exe (scripts/worker.ps1) instead of starting a new one each
// time. One request at a time.
let worker = null;
let workerWanted = false;
let queue = Promise.resolve();

export function useWorker(on = true) {
	workerWanted = on;
	if (!on && worker) worker.proc.kill();
}

function startWorker() {
	// A long-running host gets its own ref cache, so two agents at once never share refs.
	const env = { ...ENV, SIDEHAND_SESSION: process.env.SIDEHAND_SESSION || String(process.pid) };
	const proc = spawn(POWERSHELL, ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", script("worker.ps1")], { windowsHide: true, env });
	const w = { proc, pending: new Map(), buf: "", nextId: 1, stderr: "" };
	// Startup failures (execution policy, Constrained Language Mode) are only told on stderr.
	proc.stderr.setEncoding("utf8");
	proc.stderr.on("data", (chunk) => {
		w.stderr = (w.stderr + chunk).slice(-2048);
	});
	proc.stdout.setEncoding("utf8");
	proc.stdout.on("data", (chunk) => {
		w.buf += chunk;
		let i;
		while ((i = w.buf.indexOf("\n")) >= 0) {
			const line = w.buf.slice(0, i).trim();
			w.buf = w.buf.slice(i + 1);
			if (!line.startsWith("{")) continue;
			let r;
			try {
				r = JSON.parse(line);
			} catch {
				continue;
			}
			const p = w.pending.get(r.id);
			if (!p) continue;
			w.pending.delete(r.id);
			p({ stdout: r.out ?? "", stderr: r.err ?? "", code: r.code });
		}
	});
	const gone = (e) => {
		if (worker === w) worker = null;
		const stderr = startError(e, w.stderr);
		for (const p of w.pending.values()) p({ stdout: "", stderr, code: -1 });
		w.pending.clear();
	};
	// exit can come before the last stderr; wait for it briefly (an app the worker started may hold the pipe).
	proc.on("exit", () => {
		if (proc.stderr.readableEnded) return gone();
		const t = setTimeout(gone, 200);
		proc.stderr.once("end", () => (clearTimeout(t), gone()));
	});
	proc.on("error", gone);
	// A write to a worker that just died (EPIPE) must not crash the host; the exit handler answers the call.
	proc.stdin.on("error", () => {});
	return w;
}

function viaWorker(scriptName, args, signal) {
	const job = () =>
		new Promise((done) => {
			if (!worker) worker = startWorker();
			const w = worker;
			const id = w.nextId++;
			w.pending.set(id, done);
			// An abandoned call may not finish soon (a long wait): drop the worker, the next call starts a fresh one.
			signal?.addEventListener("abort", () => w.proc.kill(), { once: true });
			w.proc.stdin.write(`${JSON.stringify({ id, cmd: `& ${psQuote(script(scriptName))} ${args.join(" ")}` })}\n`);
		});
	const p = queue.then(job, job);
	queue = p;
	return p;
}

export function runPS(scriptName, args, signal) {
	if (workerWanted) return viaWorker(scriptName, args, signal);
	return new Promise((done, fail) => {
		const command = `[Console]::OutputEncoding=[System.Text.Encoding]::UTF8; & ${psQuote(script(scriptName))} ${args.join(" ")}`;
		// windowsHide: an agent without a console of its own (a desktop app, an IDE) would otherwise
		// open a console window for every call, and that window takes the user's foreground.
		const ps = spawn(POWERSHELL, ["-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", command], { signal, windowsHide: true, env: ENV });
		let stdout = "";
		let stderr = "";
		ps.stdout.on("data", (b) => {
			stdout += b.toString("utf8");
		});
		ps.stderr.on("data", (b) => {
			stderr += b.toString("utf8");
		});
		ps.on("error", (e) => fail(new Error(startError(e, stderr))));
		ps.on("close", (code) => done({ stdout, stderr, code: code ?? -1 }));
	});
}

// PowerShell errors carry a multi-line location trace; the first line is the message.
export function firstLine(r) {
	return (r.stderr || r.stdout).trim().split(/\r?\n/)[0];
}

export function parseJsonLine(stdout) {
	const lines = stdout
		.split(/\r?\n/)
		.map((s) => s.trim())
		.filter(Boolean);
	for (let i = lines.length - 1; i >= 0; i--) {
		if (lines[i].startsWith("{") || lines[i].startsWith("[")) {
			try {
				return JSON.parse(lines[i]);
			} catch {
				/* try the previous line */
			}
		}
	}
	throw new Error(`could not parse JSON output: ${stdout.slice(0, 500)}`);
}
