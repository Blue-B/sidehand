// `sidehand doctor`: plain-English checks of what sidehand needs. Touches no window.
import { spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { IS_WSL, POWERSHELL, SCRIPT_DIR, psQuote, wslToWin } from "./powershell.mjs";

export async function doctor() {
	const lines = [];
	const check = (ok, what, detail) => lines.push(`${ok ? "ok  " : "FAIL"} ${what}: ${detail}`);
	const [major, minor] = process.versions.node.split(".").map(Number);
	check(major > 18 || (major === 18 && minor >= 3), "Node", `${process.versions.node} (needs 18.3 or later)`);
	if (IS_WSL) {
		const interop = ["WSLInterop", "WSLInterop-late"].some((n) => existsSync(`/proc/sys/fs/binfmt_misc/${n}`));
		check(interop, "WSL interop", interop ? "on" : "off; enable [interop] in /etc/wsl.conf, then wsl --shutdown");
	} else if (process.platform !== "win32") {
		check(false, "platform", `${process.platform}; sidehand runs on Windows or in WSL`);
	}
	const command = `[Console]::OutputEncoding = [System.Text.Encoding]::UTF8\n$ScriptDir = ${psQuote(wslToWin(SCRIPT_DIR))}\n${readFileSync(`${SCRIPT_DIR}/doctor.ps1`, "utf8")}`;
	const r = spawnSync(POWERSHELL, ["-NoProfile", "-ExecutionPolicy", "Bypass", "-EncodedCommand", Buffer.from(command, "utf16le").toString("base64")], {
		encoding: "utf8",
		windowsHide: true,
	});
	if (r.error) check(false, "powershell.exe", r.error.code === "ENOENT" ? "not found; sidehand runs on Windows, or in WSL with Windows interop on" : r.error.message);
	else {
		const out = r.stdout.split(/\r?\n/).filter((l) => /^(ok|FAIL) /.test(l));
		if (!out.length) check(false, "powershell.exe", `ran but printed no checks: ${(r.stderr || r.stdout).trim().slice(-500)}`);
		lines.push(...out);
	}
	console.log(lines.join("\n"));
	const failed = lines.some((l) => l.startsWith("FAIL"));
	console.log(failed ? "\nSome checks failed; see the FAIL lines." : "\nAll checks passed.");
	return failed ? 1 : 0;
}
