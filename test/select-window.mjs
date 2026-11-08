// Select-Window (scripts/lib.ps1) on fake windows: [ and ] match literally, an unbalanced [ does not
// throw, a 0x handle picks that window, and an exact title wins over an earlier substring match.
// Run: node test/select-window.mjs (Windows or WSL; starts powershell.exe once, touches no window).
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { psQuote, script } from "../lib/powershell.mjs";

const titles = ["main.ts - app [WSL: Ubuntu] - Visual Studio Code", "Agent 1 - Notes", "Agent 1", "a`b [x"];
const ask = ["[WSL: Ubuntu]", "Agent 1", "0x2", "0X2", "a`b [", "[unbalanced"];
const fake = titles.map((t, i) => `[pscustomobject]@{ Handle = [IntPtr]${i + 1}; Title = ${psQuote(t)} }`).join(", ");
const command = `[Console]::OutputEncoding=[System.Text.Encoding]::UTF8; . ${psQuote(script("lib.ps1"))}; function Get-WindowList { @(${fake}) }; ` +
	ask.map((a) => `try { [Console]::WriteLine((Select-Window ${psQuote(a)}).Title) } catch { [Console]::WriteLine('ERR ' + $_.Exception.Message) }`).join("; ");
const r = spawnSync("powershell.exe", ["-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", command], { encoding: "utf8" });
assert.equal(r.status, 0, r.stderr);
assert.deepEqual(r.stdout.replace(/\r/g, "").split("\n").slice(0, ask.length), [
	titles[0],
	titles[2],
	titles[1],
	titles[1],
	titles[3],
	"ERR no visible window matches: [unbalanced",
]);
console.log(`ok: ${ask.length} window titles and handles resolve as expected`);
