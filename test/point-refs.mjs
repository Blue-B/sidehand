// Point refs (@x,y) from the last window capture: act refuses a malformed one, one outside the image
// as shown, and any 60 s after the capture. The record here names no window (handle 0), so nothing
// could be clicked even if a check failed.
// Run: node test/point-refs.mjs (Windows or WSL; starts powershell.exe once, touches no window).
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { psQuote, script } from "../lib/powershell.mjs";

const session = `points-test-${process.pid}`;
const act = (ref) => `try { & ${psQuote(script("uia.ps1"))} -Op act -Ref '${ref}' -Action click } catch { [Console]::WriteLine('ERR ${ref} ' + $_) }`;
const command =
	`$env:SIDEHAND_SESSION = ${psQuote(session)}; $c = Join-Path $env:TEMP 'sidehand-points-${session}.txt'; ` +
	// A 1000x800 window shown as a 500x400 image.
	`[IO.File]::WriteAllLines($c, [string[]]@('0', "1000,800\`t500,400\`t2")); ` +
	`try { ${act("@1,2,3")}; ${act("@500,10")}; ${act("@10,10")}; ` +
	`(Get-Item $c).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(-2); ${act("@10,10")} } finally { Remove-Item $c }; ` +
	act("@10,10");
const r = spawnSync("powershell.exe", ["-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", command], { encoding: "utf8" });
assert.equal(r.status, 0, r.stderr);
const out = r.stdout.split(/\r?\n/).filter((l) => l.startsWith("ERR "));
assert.equal(out.length, 5, r.stdout + r.stderr);
assert.match(out[0], /^ERR @1,2,3 a point ref is @x,y/);
assert.match(out[1], /^ERR @500,10 @500,10 is outside the 500x400 image/);
assert.match(out[2], /^ERR @10,10 the captured window is gone/); // in range: only the missing window stops it
assert.match(out[3], /^ERR @10,10 point refs expire 60 s after the capture/);
assert.match(out[4], /^ERR @10,10 no window capture to take point refs from/);
console.log("ok: malformed, out-of-image, stale and missing point refs are refused");
