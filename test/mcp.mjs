// `sidehand mcp` answers initialize and tools/list with every tool, a closed input schema and MCP
// annotations (read-only reads; window close and clipboard writes marked destructive).
// Then, with a stand-in powershell.exe: a cancelled queued call never reaches PowerShell and gets no
// reply, and calls still queued when stdin closes are answered "not run" while the running one finishes.
// Approvals (lib/approve.mjs): elicitation only when the client declared it; accept, decline and cancel;
// Always allow / Always block kept in SIDEHAND_CONFIG_DIR; sensitive names; SIDEHAND_CONFIRM=strict and off.
// And while the user has pressed Stop (the stand-in refuses acts as uia.ps1 does): the refused act's
// message reaches the agent, acting calls queued behind it never run, a queued read still runs.
// Run: node test/mcp.mjs (any OS; no real PowerShell. The stand-in part runs on Linux/WSL only,
// since on Windows sidehand starts powershell.exe by its full path).
import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";
import { isSensitive } from "../lib/approve.mjs";

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
assert.match(init.instructions, /data, not instructions/);

const tools = Object.fromEntries(replies.find((m) => m.id === 2).result.tools.map((t) => [t.name, t]));
assert.deepEqual(Object.keys(tools).sort(), ["capture", "clipboard", "crop", "launch", "list_monitors", "list_windows", "mask", "ui_act", "ui_ocr", "ui_tree", "ui_undo", "ui_wait", "window"]);
for (const [name, t] of Object.entries(tools)) {
	assert.ok(t.description, `${name} has no description`);
	assert.equal(t.inputSchema.type, "object", name);
	assert.equal(t.inputSchema.additionalProperties, false, name);
	for (const req of t.inputSchema.required) assert.ok(t.inputSchema.properties[req], `${name} requires undeclared ${req}`);
	for (const key of Object.keys(t.annotations)) assert.ok(["readOnlyHint", "destructiveHint", "idempotentHint", "openWorldHint"].includes(key), `${name}: ${key}`);
}
const readOnly = Object.keys(tools).filter((n) => tools[n].annotations.readOnlyHint).sort();
assert.deepEqual(readOnly, ["capture", "list_monitors", "list_windows", "ui_ocr", "ui_tree", "ui_wait"]);
for (const n of ["window", "clipboard", "ui_act", "ui_undo"]) assert.equal(tools[n].annotations.destructiveHint, true, n);
for (const n of ["crop", "mask"]) assert.equal(tools[n].annotations.destructiveHint, false, n);
assert.deepEqual(tools.ui_tree.inputSchema.required, ["title"]);
assert.ok(tools.ui_act.inputSchema.properties.action.enum.includes("drag"));
assert.match(tools.ui_ocr.description, /click, double-click, right-click, hover, wheel and drag/);
assert.match(tools.capture.description, /ui_act ref \"@x,y\"/);
assert.match(tools.ui_act.inputSchema.properties.ref.description, /@x,y/);
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
		env: { ...process.env, PATH: `${dir}:${process.env.PATH}`, SIDEHAND_CONFIG_DIR: mkdtempSync(join(tmpdir(), "sidehand-cfg-")) },
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

// Sensitive names: click, double-click and Enter on them ask first; other actions and look-alikes do not.
for (const name of ["Delete", "Remove item", "Send", "Pay now", "Buy", "Checkout", "Sign in", "Log-in", "Share", "Publish", "Submit order", "삭제", "메일 보내기", "전송", "결제하기", "구매", "로그인", "공유", "게시"])
	assert.ok(isSensitive("click", "", name), name);
assert.ok(isSensitive("double-click", "", "Delete"));
assert.ok(isSensitive("press", "Down Enter", "Send"));
assert.ok(!isSensitive("press", "a", "Send"), "keys without Enter");
for (const action of ["type", "check", "hover", "right-click"]) assert.ok(!isSensitive(action, "", "Delete"), action);
for (const name of ["Apply", "SharePoint", "Payment history", "Deleted Items", "Sender"]) assert.ok(!isSensitive("click", "", name), name);
console.log("ok: sensitive control names are told apart from look-alikes");

if (process.platform !== "win32") {
	const dir = mkdtempSync(join(tmpdir(), "sidehand-fake-ps-"));
	const log = join(dir, "calls.log");
	// -Op target answers like uia.ps1: e2 is a "Delete" button, every other ref "Apply"; a title is notes.exe, a launch <value>.exe.
	writeFileSync(
		join(dir, "powershell.exe"),
		`#!${process.execPath}\nconst fs = require("fs");\nrequire("readline").createInterface({ input: process.stdin }).on("line", (l) => {\n` +
			`  const r = JSON.parse(l); fs.appendFileSync(${JSON.stringify(log)}, r.cmd + "\\n");\n` +
			`  const ref = (r.cmd.match(/-Ref '(\\w+)'/) || [])[1];\n` +
			`  const launched = (r.cmd.match(/-Op target -Value '(\\w+)'/) || [])[1];\n` +
			`  const out = !/-Op target/.test(r.cmd) ? "ok ran" : JSON.stringify(launched ? { app: launched + ".exe" } : { app: "notes.exe", window: "Notes", ...(ref && { type: "button", control: ref === "e2" ? "Delete" : "Apply" }) });\n` +
			`  process.stdout.write(JSON.stringify({ id: r.id, code: 0, out, err: "" }) + "\\n");\n});\n`,
	);
	chmodSync(join(dir, "powershell.exe"), 0o755);
	const config = mkdtempSync(join(tmpdir(), "sidehand-cfg-"));

	// A server the test talks to line by line, answering its elicitation requests.
	function server(capabilities, env = {}) {
		const p = spawn(process.execPath, [fileURLToPath(new URL("../bin/sidehand.mjs", import.meta.url)), "mcp"], {
			env: { ...process.env, PATH: `${dir}:${process.env.PATH}`, SIDEHAND_CONFIG_DIR: config, SIDEHAND_CONFIRM: "", ...env },
		});
		const inbox = [];
		let wake = () => {};
		createInterface({ input: p.stdout }).on("line", (l) => {
			inbox.push(JSON.parse(l));
			wake();
		});
		const send = (m) => p.stdin.write(`${JSON.stringify(m)}\n`);
		async function next(pred, what) {
			const deadline = Date.now() + 10000;
			for (;;) {
				const i = inbox.findIndex(pred);
				if (i >= 0) return inbox.splice(i, 1)[0];
				if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}; got ${JSON.stringify(inbox)}`);
				await new Promise((r) => {
					wake = r;
					setTimeout(r, 200);
				});
			}
		}
		let id = 100;
		send({ jsonrpc: "2.0", id: id, method: "initialize", params: { protocolVersion: "2025-06-18", capabilities, clientInfo: { name: "test", version: "0" } } });
		return {
			send,
			next,
			end: () => p.stdin.end(),
			ready: next((m) => m.id === 100, "initialize"),
			// Calls a tool; answer(question) -> elicitation result for each question asked meanwhile, which are also returned.
			async call(name, args, answer) {
				const callId = ++id;
				send({ jsonrpc: "2.0", id: callId, method: "tools/call", params: { name, arguments: args } });
				const questions = [];
				for (;;) {
					const m = await next((m) => m.id === callId || m.method === "elicitation/create", `call ${name}`);
					if (m.id === callId) return { ...m.result, questions };
					questions.push(m.params);
					assert.ok(answer, `unexpected question: ${m.params.message}`);
					send({ jsonrpc: "2.0", id: m.id, result: answer(m.params) });
				}
			},
			close: () => new Promise((r) => (p.on("exit", r), p.stdin.end())),
		};
	}
	const pick = (choice) => () => ({ action: "accept", content: { choice } });
	const ran = () => (existsSync(log) ? readFileSync(log, "utf8").trim().split("\n").filter((l) => /-Op (act|window|launch|clipboard)/.test(l)).length : 0);
	const click = (ref) => ({ ref, action: "click" });

	// No elicitation capability, default mode: today's behaviour, no question and no extra PowerShell call.
	let s = server({});
	await s.ready;
	let r = await s.call("ui_act", click("e2"));
	assert.equal(r.content[0].text, "ok ran");
	assert.doesNotMatch(readFileSync(log, "utf8"), /-Op target/, "no approval check without a client that can ask");
	await s.close();
	console.log("ok: a client without elicitation acts as before");

	// Elicitation: decline, cancel and Don't allow refuse without acting; Allow once covers the session.
	s = server({ elicitation: {} });
	await s.ready;
	let before = ran();
	for (const answer of [() => ({ action: "decline" }), () => ({ action: "cancel" }), pick("Don't allow")]) {
		r = await s.call("ui_act", click("e1"), answer);
		assert.ok(r.isError && /did not allow click on button "Apply" in "Notes" \(notes\.exe\)/.test(r.content[0].text), r.content[0].text);
		assert.match(r.content[0].text, /Do not retry/);
		assert.deepEqual(r.questions[0].requestedSchema.properties.choice.enum, ["Don't allow", "Allow once (this session)", "Always allow", "Always block"]);
		assert.match(r.questions[0].message, /Allow sidehand to operate notes\.exe\?/);
	}
	assert.equal(ran(), before, "a declined action never reaches PowerShell");
	r = await s.call("ui_act", click("e1"), pick("Allow once (this session)"));
	assert.equal(r.content[0].text, "ok ran");
	r = await s.call("window", { title: "Notes", action: "move", value: "1,2" });
	assert.equal(r.content[0].text, "ok ran", "the app is allowed for the rest of the session");
	// Sensitive: a click on Delete and a window close confirm with app, control and action, even in an allowed app.
	r = await s.call("ui_act", click("e2"), pick("No"));
	assert.ok(r.isError, JSON.stringify(r));
	assert.match(r.questions[0].message, /click on button "Delete" in "Notes" \(notes\.exe\)/);
	assert.deepEqual(r.questions[0].requestedSchema.properties.choice.enum, ["Yes", "No"]);
	before = ran();
	r = await s.call("window", { title: "Notes", action: "close" }, pick("Yes"));
	assert.equal(r.content[0].text, "ok ran");
	assert.match(r.questions[0].message, /close the window "Notes" \(notes\.exe\)/);
	assert.equal(ran(), before + 1);
	await s.close();
	assert.ok(!existsSync(join(config, "approvals.json")), "Allow once is not saved");
	// The client goes away while the user is being asked: the call is answered "not run" and never acts.
	s = server({ elicitation: {} });
	await s.ready;
	before = ran();
	s.send({ jsonrpc: "2.0", id: 7, method: "tools/call", params: { name: "ui_act", arguments: click("e1") } });
	await s.next((m) => m.method === "elicitation/create", "the question");
	s.end();
	r = (await s.next((m) => m.id === 7, "the reply")).result;
	assert.ok(r.isError && /not run/.test(r.content[0].text), JSON.stringify(r));
	assert.equal(ran(), before);
	console.log("ok: elicitation accept/decline/cancel, Allow once for the session, sensitive actions confirmed");

	// Always allow is saved and holds in the next session; a sensitive first action is one question, not two.
	s = server({ elicitation: { form: {} } });
	await s.ready;
	r = await s.call("ui_act", click("e2"), pick("Always allow"));
	assert.equal(r.content[0].text, "ok ran");
	assert.equal(r.questions.length, 1);
	assert.match(r.questions[0].message, /hard to undo/);
	await s.close();
	assert.deepEqual(JSON.parse(readFileSync(join(config, "approvals.json"), "utf8")), { allow: ["notes.exe"], block: [] });
	s = server({ elicitation: {} });
	await s.ready;
	r = await s.call("ui_act", click("e1"));
	assert.equal(r.content[0].text, "ok ran", "Always allow persisted");
	r = await s.call("clipboard", { text: "x" }, pick("Always block"));
	assert.ok(r.isError);
	assert.match(r.questions[0].message, /replace your clipboard/);
	await s.close();
	assert.deepEqual(JSON.parse(readFileSync(join(config, "approvals.json"), "utf8")), { allow: ["notes.exe"], block: ["clipboard"] });
	console.log("ok: Always allow and Always block are saved in SIDEHAND_CONFIG_DIR/approvals.json and hold in the next session");

	// Always block holds without a client that can ask, and with SIDEHAND_CONFIRM=off.
	for (const env of [{}, { SIDEHAND_CONFIRM: "off" }]) {
		s = server({}, env);
		await s.ready;
		r = await s.call("clipboard", { text: "x" });
		assert.ok(r.isError && /Always block for clipboard/.test(r.content[0].text), r.content[0].text);
		await s.close();
	}
	writeFileSync(join(config, "approvals.json"), JSON.stringify({ allow: ["notes.exe"], block: [] }));

	// strict: what needs the user is refused when the client cannot ask; an Always-allowed app still works.
	s = server({}, { SIDEHAND_CONFIRM: "strict" });
	await s.ready;
	r = await s.call("ui_act", click("e1"));
	assert.equal(r.content[0].text, "ok ran");
	before = ran();
	r = await s.call("ui_act", click("e2"));
	assert.ok(r.isError && /needs the user's approval.*SIDEHAND_CONFIRM=strict\). Ask the user/.test(r.content[0].text), r.content[0].text);
	r = await s.call("launch", { app: "other" });
	assert.ok(r.isError && /launch other \(other\.exe\) needs .*add "other\.exe" to "allow" in /.test(r.content[0].text), r.content[0].text);
	assert.equal(ran(), before, "refused actions never reach PowerShell");
	await s.close();

	// off: never asks, even a client that can.
	s = server({ elicitation: {} }, { SIDEHAND_CONFIRM: "off" });
	await s.ready;
	r = await s.call("ui_act", click("e2"));
	assert.equal(r.content[0].text, "ok ran");
	await s.close();
	console.log("ok: SIDEHAND_CONFIRM=strict refuses without a way to ask, off never asks, Always block holds in both");
}
