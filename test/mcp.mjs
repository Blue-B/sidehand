// `sidehand mcp` answers initialize and tools/list with every tool, a closed input schema and MCP
// annotations (read-only reads; window close and clipboard writes marked destructive).
// Then, with a stand-in powershell.exe: a cancelled queued call never reaches PowerShell and gets no
// reply, and calls still queued when stdin closes are answered "not run" while the running one finishes.
// And while the user has pressed Stop (the stand-in refuses acts as uia.ps1 does): the refused act's
// message reaches the agent, acting calls queued behind it never run, a queued read still runs.
// Run: node test/mcp.mjs (any OS; no real PowerShell. The stand-in part runs on Linux/WSL only,
// since on Windows sidehand starts powershell.exe by its full path).
import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const requests = [
	{ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "test", version: "0" } } },
	{ jsonrpc: "2.0", method: "notifications/initialized" },
	{ jsonrpc: "2.0", id: 2, method: "tools/list" },
];
const r = spawnSync(process.execPath, [fileURLToPath(new URL("../bin/sidehand.mjs", import.meta.url)), "mcp"], {
	input: requests.map((m) => JSON.stringify(m)).join("\n") + "\n",
	encoding: "utf8",
	timeout: 10000,
});
assert.equal(r.status, 0, r.stderr);
const replies = r.stdout.trim().split("\n").map((l) => JSON.parse(l));
const init = replies.find((m) => m.id === 1).result;
assert.equal(init.protocolVersion, "2025-06-18");
assert.equal(init.serverInfo.name, "sidehand");
assert.ok(init.capabilities.tools);
assert.match(init.instructions, /pressed Stop.*ask the user/);

const tools = Object.fromEntries(replies.find((m) => m.id === 2).result.tools.map((t) => [t.name, t]));
assert.deepEqual(Object.keys(tools).sort(), ["capture", "clipboard", "crop", "launch", "list_monitors", "list_windows", "mask", "ui_act", "ui_ocr", "ui_tree", "ui_wait", "window"]);
for (const [name, t] of Object.entries(tools)) {
	assert.ok(t.description, `${name} has no description`);
	assert.equal(t.inputSchema.type, "object", name);
	assert.equal(t.inputSchema.additionalProperties, false, name);
	for (const req of t.inputSchema.required) assert.ok(t.inputSchema.properties[req], `${name} requires undeclared ${req}`);
	for (const key of Object.keys(t.annotations)) assert.ok(["readOnlyHint", "destructiveHint", "idempotentHint", "openWorldHint"].includes(key), `${name}: ${key}`);
}
const readOnly = Object.keys(tools).filter((n) => tools[n].annotations.readOnlyHint).sort();
assert.deepEqual(readOnly, ["capture", "list_monitors", "list_windows", "ui_ocr", "ui_tree", "ui_wait"]);
for (const n of ["window", "clipboard", "ui_act"]) assert.equal(tools[n].annotations.destructiveHint, true, n);
for (const n of ["crop", "mask"]) assert.equal(tools[n].annotations.destructiveHint, false, n);
assert.deepEqual(tools.ui_tree.inputSchema.required, ["title"]);
assert.ok(tools.ui_act.inputSchema.properties.action.enum.includes("drag"));
assert.match(tools.ui_ocr.description, /click, double-click, right-click, hover, wheel and drag/);
console.log(`ok: mcp lists ${Object.keys(tools).length} tools with closed schemas and annotations`);

if (process.platform !== "win32") {
	const dir = mkdtempSync(join(tmpdir(), "sidehand-fake-ps-"));
	const log = join(dir, "calls.log");
	// Answers each worker request after 300 ms and logs what it was asked to run.
	writeFileSync(
		join(dir, "powershell.exe"),
		`#!${process.execPath}\nconst fs = require("fs");\nrequire("readline").createInterface({ input: process.stdin }).on("line", (l) => {\n` +
			`  const r = JSON.parse(l); fs.appendFileSync(${JSON.stringify(log)}, r.cmd + "\\n");\n` +
			`  setTimeout(() => process.stdout.write(JSON.stringify({ id: r.id, code: 0, out: "ok ran", err: "" }) + "\\n"), 300);\n});\n`,
	);
	chmodSync(join(dir, "powershell.exe"), 0o755);
	const call = (id, name, args) => ({ jsonrpc: "2.0", id, method: "tools/call", params: { name, arguments: args } });
	const lines = [
		call(1, "ui_tree", { title: "Notes" }),
		call(2, "ui_act", { ref: "e5", action: "click" }),
		call(3, "window", { title: "Notes", action: "close" }),
		call(4, "ui_act", { ref: "e6", action: "click" }),
		{ jsonrpc: "2.0", method: "notifications/cancelled", params: { requestId: 2 } },
	];
	const q = spawnSync(process.execPath, [fileURLToPath(new URL("../bin/sidehand.mjs", import.meta.url)), "mcp"], {
		input: lines.map((m) => JSON.stringify(m)).join("\n") + "\n",
		encoding: "utf8",
		timeout: 10000,
		env: { ...process.env, PATH: `${dir}:${process.env.PATH}` },
	});
	assert.equal(q.status, 0, q.stderr);
	const got = Object.fromEntries(q.stdout.trim().split("\n").map((l) => JSON.parse(l)).map((m) => [m.id, m.result]));
	assert.deepEqual(Object.keys(got).sort(), ["1", "3", "4"], "the cancelled call 2 gets no reply");
	assert.equal(got[1].content[0].text, "ok ran");
	for (const id of [3, 4]) assert.ok(got[id].isError && /not run/.test(got[id].content[0].text), `call ${id}: ${JSON.stringify(got[id])}`);
	const ran = readFileSync(log, "utf8").trim().split("\n");
	assert.equal(ran.length, 1, `PowerShell ran ${ran.join(" | ")}`);
	assert.match(ran[0], /-Op tree/);
	console.log("ok: a cancelled queued call never runs; queued calls are refused on stdin close, the running one is answered");

	// Stop: the stand-in refuses ui_act like uia.ps1 does while the stop file exists.
	const stopLog = join(dir, "stop-calls.log");
	const stopDir = join(dir, "stopped");
	mkdirSync(stopDir);
	writeFileSync(
		join(stopDir, "powershell.exe"),
		`#!${process.execPath}\nconst fs = require("fs");\nrequire("readline").createInterface({ input: process.stdin }).on("line", (l) => {\n` +
			`  const r = JSON.parse(l); fs.appendFileSync(${JSON.stringify(stopLog)}, r.cmd + "\\n");\n` +
			`  const stopped = /-Op (act|window|launch)/.test(r.cmd);\n` +
			`  const reply = stopped ? { id: r.id, code: 1, out: "", err: "The user pressed Stop in Sidehand. Ask the user before doing anything else." } : { id: r.id, code: 0, out: "ok read", err: "" };\n` +
			`  setTimeout(() => process.stdout.write(JSON.stringify(reply) + "\\n"), 300);\n});\n`,
	);
	chmodSync(join(stopDir, "powershell.exe"), 0o755);
	// stdin stays open until every call is answered: closing it would refuse the queued calls for that reason instead.
	const server = spawn(process.execPath, [fileURLToPath(new URL("../bin/sidehand.mjs", import.meta.url)), "mcp"], {
		env: { ...process.env, PATH: `${stopDir}:${process.env.PATH}` },
	});
	const res = {};
	let out = "";
	const done = new Promise((resolve, reject) => {
		const timer = setTimeout(() => reject(new Error(`no replies in 10 s: ${out}`)), 10000);
		server.stdout.setEncoding("utf8");
		server.stdout.on("data", (chunk) => {
			out += chunk;
			for (const line of out.split("\n").slice(0, -1)) {
				const m = JSON.parse(line);
				res[m.id] = m.result;
			}
			out = out.slice(out.lastIndexOf("\n") + 1);
			if (Object.keys(res).length === 4) {
				clearTimeout(timer);
				resolve();
			}
		});
	});
	for (const m of [
		call(1, "ui_act", { ref: "e5", action: "click" }),
		call(2, "window", { title: "Notes", action: "close" }),
		call(3, "ui_tree", { title: "Notes" }),
		call(4, "clipboard", { text: "x" }),
	])
		server.stdin.write(`${JSON.stringify(m)}\n`);
	await done;
	server.stdin.end();
	assert.ok(res[1].isError && /^ui act failed: The user pressed Stop in Sidehand\. Ask the user/.test(res[1].content[0].text), JSON.stringify(res[1]));
	for (const id of [2, 4]) assert.ok(res[id].isError && /^not run: The user pressed Stop/.test(res[id].content[0].text), `call ${id}: ${JSON.stringify(res[id])}`);
	assert.equal(res[3].content[0].text, "ok read");
	const stopRan = readFileSync(stopLog, "utf8").trim().split("\n");
	assert.equal(stopRan.length, 2, `PowerShell ran ${stopRan.join(" | ")}`);
	assert.match(stopRan[0], /-Op act/);
	assert.match(stopRan[1], /-Op tree/);
	console.log("ok: after Stop the act is refused with the user's message, queued acting calls never run, a queued read does");
}
