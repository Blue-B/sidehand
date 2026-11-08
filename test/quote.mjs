// psQuote must hand every string to PowerShell unchanged, including typographic apostrophes
// (PowerShell ends a quote at ‘ ’ ‚ ‛ too); psNum must refuse anything but a number.
// Run: node test/quote.mjs (Windows or WSL; starts powershell.exe once, touches nothing else).
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { psNum, psQuote } from "../lib/powershell.mjs";

const cases = ["plain", "it's", "don\u2019t", "\u2018a\u2019 \u201ab\u201b", "x\u2019\u2019y", "end\u2019", "abc\u2019 + (\"INJECT\" + \"ED\") + \u2019xyz", "$(1+1) `n ;", "한글 ’ '"];
const script = `[Console]::OutputEncoding=[System.Text.Encoding]::UTF8; ${cases.map((c) => `[Console]::WriteLine(${psQuote(c)})`).join("; ")}`;
const r = spawnSync("powershell.exe", ["-NoProfile", "-Command", script], { encoding: "utf8" });
assert.equal(r.status, 0, r.stderr);
assert.deepEqual(r.stdout.replace(/\r/g, "").split("\n").slice(0, cases.length), cases);

assert.equal(psNum(12), "12");
assert.equal(psNum("-3.5"), "-3.5");
for (const bad of ["1; calc", "", null, undefined, "abc", NaN]) assert.throws(() => psNum(bad));
console.log(`ok: ${cases.length} strings round-trip through PowerShell, psNum refuses non-numbers`);
