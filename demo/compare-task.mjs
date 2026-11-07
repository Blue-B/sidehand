// One tool does the same task the way an agent following that tool's own instructions would: fill
// in the Contoso order form (Customer "Blue-B Studio", Quantity 3, Region Jeju, Express shipping,
// Submit) and read the result. demo/compare.ps1 runs it and measures the user's side (foreground,
// cursor, keyboard).
//   node demo/compare-task.mjs <sidehand|agent-desktop|terminator|windows-mcp> <out folder> <form hwnd>
// Writes <out>/<tool>.json { tool, startMs, ms, calls, errors } and <out>/<tool>.txt (every output,
// for token counts). The order form runs as Orders.exe so no other window shares its process name.
import { spawn, spawnSync } from "node:child_process";
import { appendFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const [tool, out, hwnd] = process.argv.slice(2);
const repo = join(dirname(fileURLToPath(import.meta.url)), "..");
const log = join(out, `${tool}.txt`);
const res = { tool, startMs: 0, ms: 0, calls: 0, errors: [] };
writeFileSync(log, "");
const record = (call, text) => {
	res.calls++;
	appendFileSync(log, `=== ${call}\n${text}\n`);
	return text;
};

// A minimal MCP stdio session: initialize once, then tools/call in order.
class Mcp {
	constructor(command, args, env = {}) {
		// npx and uvx are .cmd shims on Windows, which start only through a shell.
		this.p = spawn(command, args, { shell: command !== process.execPath, windowsHide: true, env: { ...process.env, ...env } });
		this.buf = "";
		this.next = 1;
		this.wait = new Map();
		this.p.stdout.setEncoding("utf8");
		this.p.stdout.on("data", (d) => {
			this.buf += d;
			let i;
			while ((i = this.buf.indexOf("\n")) >= 0) {
				const line = this.buf.slice(0, i).trim();
				this.buf = this.buf.slice(i + 1);
				if (!line.startsWith("{")) continue;
				let m;
				try {
					m = JSON.parse(line);
				} catch {
					continue; // a log line that happens to start with {
				}
				if (this.wait.has(m.id)) {
					this.wait.get(m.id)(m);
					this.wait.delete(m.id);
				} else if (m.id !== undefined && m.method) this.send({ jsonrpc: "2.0", id: m.id, error: { code: -32601, message: "not supported" } });
			}
		});
		this.p.stderr.on("data", () => {});
	}
	send(o) {
		this.p.stdin.write(`${JSON.stringify(o)}\n`);
	}
	request(method, params, ms = 120000) {
		const id = this.next++;
		return new Promise((ok, fail) => {
			const t = setTimeout(() => fail(new Error(`${method} timed out`)), ms);
			this.wait.set(id, (m) => (clearTimeout(t), m.error ? fail(new Error(m.error.message)) : ok(m.result)));
			this.send({ jsonrpc: "2.0", id, method, params });
		});
	}
	async start() {
		const t = performance.now();
		await this.request("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "sidehand-compare", version: "1" } }, 900000);
		this.send({ jsonrpc: "2.0", method: "notifications/initialized" });
		res.startMs = Math.round(performance.now() - t);
	}
	async call(name, args) {
		let text;
		try {
			const r = await this.request("tools/call", { name, arguments: args });
			text = (r.content ?? []).filter((c) => c.type === "text").map((c) => c.text).join("\n");
			// Windows-MCP wraps its text in a JSON array of strings.
			if (text.startsWith("[")) {
				try {
					text = JSON.parse(text).join("\n");
				} catch {}
			}
			this.ok = !r.isError;
			if (r.isError) res.errors.push(`${name}: ${text.slice(0, 300)}`);
		} catch (e) {
			text = `error: ${e.message}`;
			this.ok = false;
			res.errors.push(`${name}: ${e.message}`);
		}
		return record(`${name} ${JSON.stringify(args)}`, text);
	}
	close() {
		spawnSync("taskkill", ["/T", "/F", "/PID", String(this.p.pid)], { windowsHide: true });
	}
}

const tasks = {
	async sidehand() {
		const m = new Mcp(process.execPath, [join(repo, "bin", "sidehand.mjs"), "mcp"]);
		await m.start();
		const t0 = performance.now();
		const tree = await m.call("ui_tree", { title: "Contoso Orders" });
		const ref = (rx) => tree.match(new RegExp(`^\\s*(e\\d+) ${rx}`, "m"))?.[1] ?? "e0";
		await m.call("ui_act", { ref: ref('Edit "Customer"'), action: "type", value: "Blue-B Studio" });
		await m.call("ui_act", { ref: ref('Edit "Quantity"'), action: "type", value: "3" });
		await m.call("ui_act", { ref: ref('ComboBox "Region"'), action: "select", value: "Jeju" });
		await m.call("ui_act", { ref: ref('CheckBox "Express shipping"'), action: "check" });
		await m.call("ui_act", { ref: ref('Button "Submit order"'), action: "click" });
		await m.call("ui_wait", { title: "Contoso Orders", text: "Order submitted" });
		res.ms = Math.round(performance.now() - t0);
		m.close();
	},

	async "agent-desktop"() {
		const ad = (...a) => {
			// Through a shell (an npm shim): quote values with spaces.
			const r = spawnSync("agent-desktop", a.map((x) => (/\s/.test(x) ? `"${x}"` : x)), { shell: true, windowsHide: true, encoding: "utf8" });
			const text = `${r.stdout ?? ""}${r.stderr ?? ""}`.trim();
			adOk = r.status === 0;
			if (!adOk) res.errors.push(`${a[0]}: ${text.slice(0, 300)}`);
			return record(a.join(" "), text);
		};
		let adOk = true;
		const t0 = performance.now();
		const snap = ad("snapshot", "--app", "Orders.exe", "--window-id", `w-${hwnd}`, "-i", "--compact");
		const refs = [];
		const find = (n, role, name) => {
			if (n.role === role && (name === undefined || n.name === name) && n.ref_id) refs.push(n.ref_id);
			for (const c of n.children ?? []) find(c, role, name);
		};
		let tree = {};
		try {
			tree = JSON.parse(snap).data.tree;
		} catch {}
		const first = (role, name) => (refs.length = 0, find(tree, role, name), refs[0] ?? "@e0");
		const named = (n, name) => (n.name === name && n.ref_id ? n.ref_id : (n.children ?? []).map((c) => named(c, name)).find(Boolean));
		find(tree, "textfield");
		const edits = [...refs];
		ad("set-value", edits[0] ?? "@e0", "Blue-B Studio");
		ad("set-value", edits[1] ?? "@e0", "3");
		ad("select", first("combobox", "Region"), "Jeju");
		if (!adOk) {
			// What an agent does next: open the drop-down and click the item.
			ad("expand", first("combobox", "Region"));
			const open = ad("snapshot", "--app", "Orders.exe", "-i", "--compact");
			let t = {};
			try {
				t = JSON.parse(open).data.tree;
			} catch {}
			ad("click", named(t, "Jeju") ?? "@e0");
		}
		ad("check", first("checkbox", "Express shipping"));
		ad("click", first("button", "Submit order"));
		ad("snapshot", "--app", "Orders.exe", "--window-id", `w-${hwnd}`, "--compact");
		res.ms = Math.round(performance.now() - t0);
	},

	async terminator() {
		const m = new Mcp("npx", ["-y", "terminator-mcp-agent@latest"]);
		await m.start();
		const t0 = performance.now();
		const base = { process: "Orders", highlight_before_action: false, ui_diff_before_after: false, verify_element_exists: "", verify_element_not_exists: "" };
		await m.call("get_window_tree", { process: "Orders", title: "Contoso Orders", include_tree_after_action: true });
		await m.call("type_into_element", { ...base, selector: "role:Edit|name:Customer", text_to_type: "Blue-B Studio", clear_before_typing: true });
		await m.call("type_into_element", { ...base, selector: "role:Edit|name:Quantity", text_to_type: "3", clear_before_typing: true });
		await m.call("select_option", { ...base, selector: "role:ComboBox|name:Region", option_name: "Jeju" });
		if (!m.ok) {
			// What an agent does next: open the drop-down and click the item.
			await m.call("click_element", { ...base, selector: "role:ComboBox|name:Region" });
			await m.call("click_element", { ...base, selector: "name:Jeju" });
		}
		await m.call("set_selected", { ...base, selector: "role:CheckBox|name:Express shipping", state: true });
		// Its instructions prefer invoke_element over click_element for buttons.
		await m.call("invoke_element", { ...base, selector: "role:Button|name:Submit order" });
		await m.call("get_window_tree", { process: "Orders", title: "Contoso Orders", include_tree_after_action: true });
		res.ms = Math.round(performance.now() - t0);
		m.close();
	},

	async "windows-mcp"() {
		const m = new Mcp("uvx", ["windows-mcp", "serve"], { ANONYMIZED_TELEMETRY: "false" });
		await m.start();
		const t0 = performance.now();
		// Snapshot lists each window's interactive elements as `(x,y) <localized role> "name"` under
		// `window "<title>"`; actions take that point. An open drop-down list is a window of its own.
		const at = (snap, name, anywhere = false) => {
			const lines = snap.split("\n");
			let i = anywhere ? 0 : lines.findIndex((l) => l.includes('window "Contoso Orders"'));
			if (i < 0) return null;
			for (i++; i < lines.length && (anywhere || !lines[i].includes('window "')); i++) {
				const m = lines[i].match(/\((\d+),(\d+)\) .*? "([^"]*)"/);
				if (m && m[3] === name) return [+m[1], +m[2]];
			}
			return null;
		};
		let snap = await m.call("Snapshot", { use_vision: false });
		if (!at(snap, "Customer")) {
			// The form is behind the user's window: its own tool for that is App switch.
			await m.call("App", { mode: "switch", name: "Contoso Orders" });
			snap = await m.call("Snapshot", { use_vision: false });
		}
		const go = async (name, args, loc) => (loc ? m.call(name, { ...args, loc }) : res.errors.push(`${name}: no element in the snapshot`));
		await go("Type", { text: "Blue-B Studio", clear: true }, at(snap, "Customer"));
		await go("Type", { text: "3", clear: true }, at(snap, "Quantity"));
		await go("Click", {}, at(snap, "Region"));
		const open = await m.call("Snapshot", { use_vision: false });
		await go("Click", {}, at(open, "Jeju", true));
		await go("Click", {}, at(snap, "Express shipping"));
		await go("Click", {}, at(snap, "Submit order"));
		await m.call("Snapshot", { use_vision: false });
		res.ms = Math.round(performance.now() - t0);
		m.close();
	},
};

if (!tasks[tool] || !out) {
	console.error(`usage: node demo/compare-task.mjs <${Object.keys(tasks).join("|")}> <out folder> <form hwnd>`);
	process.exit(2);
}
try {
	await tasks[tool]();
} catch (e) {
	res.errors.push(`fatal: ${e.message}`);
}
writeFileSync(join(out, `${tool}.json`), JSON.stringify(res, null, 1));
process.exit(0);
