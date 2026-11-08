// Screenshots go to a folder only the user (plus SYSTEM and Administrators) can open: no entry for
// Users, Authenticated Users or Everyone, as C:\tmp has.
// Old captures are removed when a new one is written (pruneCaptures).
// Run: node test/outdir.mjs (Windows or WSL; creates the capture folder if missing, starts powershell.exe once).
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, mkdirSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { outDir, pruneCaptures } from "../lib/commands.mjs";
import { psQuote, wslToWin } from "../lib/powershell.mjs";

const dir = outDir();
mkdirSync(dir, { recursive: true });
const win = wslToWin(dir);
assert.doesNotMatch(win, /^[a-z]:\\tmp\\/i);
const r = spawnSync("powershell.exe", ["-NoProfile", "-Command", `(Get-Acl -LiteralPath ${psQuote(win)}).Access | ForEach-Object { $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value }`], { encoding: "utf8" });
assert.equal(r.status, 0, r.stderr);
const sids = r.stdout.split(/\r?\n/).filter(Boolean);
assert.ok(sids.length > 0, "no ACL entries read");
for (const shared of ["S-1-5-32-545", "S-1-5-11", "S-1-1-0"]) assert.ok(!sids.includes(shared), `${win} grants ${shared}`);
console.log(`ok: captures go to ${win}, readable only by ${[...new Set(sids)].join(", ")}`);

const tmp = mkdtempSync(join(tmpdir(), "sidehand-prune-"));
const old = join(tmp, "cap_old.png"), fresh = join(tmp, "cap_new.png"), other = join(tmp, "keep.txt");
for (const f of [old, fresh, other]) writeFileSync(f, "");
const twoDaysAgo = (Date.now() - 2 * 86_400_000) / 1000;
utimesSync(old, twoDaysAgo, twoDaysAgo);
utimesSync(other, twoDaysAgo, twoDaysAgo);
pruneCaptures(tmp);
assert.deepEqual([old, fresh, other].map(existsSync), [false, true, true]);
console.log("ok: captures older than a day are removed, newer ones and other files stay");
