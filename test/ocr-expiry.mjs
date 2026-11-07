// OCR refs (t1, ...) are only points, so act refuses them 60 s after the ocr that made them.
// The ref cache here names no window (handle 0), so nothing could be clicked even if the check failed.
// Run: node test/ocr-expiry.mjs (Windows or WSL; starts powershell.exe once, touches no window).
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { psQuote, script } from "../lib/powershell.mjs";

const session = `expiry-test-${process.pid}`;
const command =
	`$env:SIDEHAND_SESSION = ${psQuote(session)}; $c = Join-Path $env:TEMP 'sidehand-uia-${session}.txt'; ` +
	`[IO.File]::WriteAllLines($c, [string[]]@('0', "t1\`t10,10\`tSave")); (Get-Item $c).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(-2); ` +
	`try { & ${psQuote(script("uia.ps1"))} -Op act -Ref t1 -Action click } catch { [Console]::WriteLine('ERR ' + $_) } finally { Remove-Item $c }`;
const r = spawnSync("powershell.exe", ["-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", command], { encoding: "utf8" });
assert.equal(r.status, 0, r.stderr);
assert.match(r.stdout, /ERR OCR refs expire after 60 s/, r.stdout + r.stderr);
console.log("ok: a 2-minute-old OCR ref is refused");
