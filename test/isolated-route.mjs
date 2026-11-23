// launch --isolated routing (lib/commands.mjs, lib/powershell.mjs) with a stand-in powershell.exe:
// nothing goes to the isolated desktop until an app is launched there; then list_windows merges both
// desktops and tags [isolated], window operations try the isolated desktop first and fall back to the
// user's only on a "not here" answer. MCP starts a second worker through isolated.ps1; the CLI runs one
// command there per call while its marker file exists, and `sidehand isolated close` removes it.
// Run: node test/isolated-route.mjs (Linux/WSL only: on Windows sidehand starts powershell.exe by full path).
import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { chmodSync, existsSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";

if (process.platform === "win32") process.exit(0);
const bin = fileURLToPath(new URL("../bin/sidehand.mjs", import.meta.url));
const dir = mkdtempSync(join(tmpdir(), "sidehand-fake-ps-"));
const log = join(dir, "calls.log");
// Main desktop: window "Notes" (0x1). Isolated desktop: "Agent app" (0x2). Ref e1 belongs to the main
// desktop; e9 to the isolated one, where acting on it fails for real.
writeFileSync(
	join(dir, "powershell.exe"),
	`#!${process.execPath}
const fs = require("fs");
const argv = process.argv.slice(2);
const win = (h, t) => ({ handle: h, title: t, x: 0, y: 0, w: 100, h: 100, minimized: false });
function answer(iso, cmd) {
  const title = (cmd.match(/-Title '+([^']*)'/) || [])[1];
  const miss = { code: 1, err: "no visible window matches: " + title };
  if (/-Op close/.test(cmd)) return { out: "ok closed the isolated desktop: ended 1 app process(es)" };
  if (/list\\.ps1/.test(cmd)) return { out: JSON.stringify(iso ? [win("0x2", "Agent app")] : [win("0x1", "Notes")]) };
  if (/-Op launch/.test(cmd)) return { out: iso ? "ok launched on the isolated desktop: Agent app (0x2)" : "ok launched: Notes" };
  if (/-Op tree/.test(cmd)) return title === (iso ? "Agent app" : "Notes") ? { out: "window: " + title + (iso ? " (isolated)" : " (main)") } : miss;
  if (/-Ref '+e1/.test(cmd)) return iso ? { code: 1, err: "the window of these refs is not on the isolated desktop" } : { out: "ok click (main)" };
  if (/-Ref '+e9/.test(cmd)) return iso ? { code: 1, err: "element gone" } : { out: "ok click (main)" };
  return { code: 1, err: "unexpected " + cmd };
}
if (argv.includes("-Command")) {
  const cmd = argv[argv.indexOf("-Command") + 1];
  const iso = /isolated\\.ps1'+ -Op run/.test(cmd);
  fs.appendFileSync(${JSON.stringify(log)}, (iso ? "isolated" : "main") + " " + cmd + "\\n");
  const r = answer(iso, cmd);
  if (r.out) process.stdout.write(r.out + "\\n");
  if (r.err) process.stderr.write(r.err + "\\n");
  process.exitCode = r.code || 0;
} else {
  const iso = argv.some((a) => /isolated\\.ps1/.test(a));
  fs.appendFileSync(${JSON.stringify(log)}, "start " + argv.slice(-3).join(" ") + "\\n");
  require("readline").createInterface({ input: process.stdin }).on("line", (l) => {
    const q = JSON.parse(l); fs.appendFileSync(${JSON.stringify(log)}, (iso ? "isolated " : "main ") + q.cmd + "\\n");
    const r = answer(iso, q.cmd);
    process.stdout.write(JSON.stringify({ id: q.id, code: r.code || 0, out: r.out || "", err: r.err || "" }) + "\\n");
  });
}
`,
);
chmodSync(join(dir, "powershell.exe"), 0o755);
const env = { ...process.env, PATH: `${dir}:${process.env.PATH}`, SIDEHAND_SESSION: `route-${process.pid}` };
const calls = () => readFileSync(log, "utf8").trim().split("\n");
const since = (n) => calls().slice(n).map((l) => l.split(" ")[0]);

// MCP: one request at a time, each answered before the next.
const mcp = spawn(process.execPath, [bin, "mcp"], { env });
const replies = createInterface({ input: mcp.stdout });
const waiting = new Map();
replies.on("line", (l) => {
	const m = JSON.parse(l);
	waiting.get(m.id)?.(m.result);
});
let id = 0;
const tool = (name, args) =>
	new Promise((done) => {
		waiting.set(++id, (r) => done({ text: r.content[0].text, error: Boolean(r.isError) }));
		mcp.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id, method: "tools/call", params: { name, arguments: args } })}\n`);
	});

let r = await tool("list_windows", {});
assert.match(r.text, /^0x1 .*Notes$/);
assert.ok(!/\[isolated\]/.test(r.text));
r = await tool("ui_tree", { title: "Notes" });
assert.equal(r.text, "window: Notes (main)");
assert.deepEqual(since(0), ["start", "main", "main"], "no isolated worker before launch --isolated");

r = await tool("launch", { app: "agent.exe", isolated: true });
assert.equal(r.text, "ok launched on the isolated desktop: Agent app (0x2)");
assert.match(calls()[3], /^start .*isolated\.ps1 -Op worker$/);
let n = calls().length;
r = await tool("list_windows", {});
assert.match(r.text, /^0x1 .*  Notes\n0x2 .*  \[isolated\] Agent app$/);
r = await tool("ui_tree", { title: "Agent app" });
assert.equal(r.text, "window: Agent app (isolated)");
r = await tool("ui_tree", { title: "Notes" });
assert.equal(r.text, "window: Notes (main)", "a window not on the isolated desktop is looked for on the user's");
r = await tool("ui_act", { ref: "e1", action: "click" });
assert.equal(r.text, "ok click (main)");
assert.deepEqual(since(n), ["main", "isolated", "isolated", "isolated", "main", "isolated", "main"]);
n = calls().length;
r = await tool("ui_act", { ref: "e9", action: "click" });
assert.ok(r.error && /element gone/.test(r.text), r.text);
assert.deepEqual(since(n), ["isolated"], "a real failure on the isolated desktop is not retried on the user's");
r = await tool("launch", { app: "notes.exe" });
assert.equal(r.text, "ok launched: Notes");
mcp.stdin.end();
await new Promise((done) => mcp.on("exit", done));
console.log("ok: MCP routes to the isolated worker only after launch --isolated, isolated first, user's desktop on a miss");

// CLI: a marker file keeps the isolated route on between calls.
const cli = (...a) => spawnSync(process.execPath, [bin, ...a], { env, encoding: "utf8" });
const mark = join(tmpdir(), `sidehand-isolated-${env.SIDEHAND_SESSION}`);
n = calls().length;
assert.equal(cli("tree", "Notes").stdout.trim(), "window: Notes (main)");
assert.deepEqual(since(n), ["main"]);
assert.equal(cli("launch", "--isolated", "agent.exe").stdout.trim(), "ok launched on the isolated desktop: Agent app (0x2)");
assert.match(calls().at(-1), /^isolated .*isolated\.ps1' -Op run -Create -Command '& ''.*uia\.ps1'' -Op launch/);
assert.ok(existsSync(mark));
n = calls().length;
assert.equal(cli("tree", "Notes").stdout.trim(), "window: Notes (main)");
assert.equal(cli("tree", "Agent app").stdout.trim(), "window: Agent app (isolated)");
assert.match(cli("windows").stdout, /\[isolated\] Agent app/);
assert.deepEqual(since(n), ["isolated", "main", "isolated", "main", "isolated"]);
assert.equal(cli("isolated", "close").stdout.trim(), "ok closed the isolated desktop: ended 1 app process(es)");
assert.ok(!existsSync(mark));
n = calls().length;
assert.equal(cli("tree", "Notes").stdout.trim(), "window: Notes (main)");
assert.deepEqual(since(n), ["main"]);
console.log("ok: the CLI routes isolated first while its marker exists; isolated close removes it");
