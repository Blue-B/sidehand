// powershell.exe is started by its full path on Windows (a bare name is looked up in the working
// directory first); crop/mask/resize never write over their input, whatever its extension; image paths
// on a network share are refused.
// Run: node test/paths.mjs (any OS; starts no PowerShell).
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { win32 } from "node:path";
import { editOut, filePath } from "../lib/commands.mjs";

// The module computes the path at import, so ask a child that pretends to be Windows.
const probe = `Object.defineProperty(process, "platform", { value: "win32" }); import(${JSON.stringify(new URL("../lib/powershell.mjs", import.meta.url).href)}).then((m) => console.log(m.POWERSHELL));`;
const r = spawnSync(process.execPath, ["--input-type=module", "-e", probe], { encoding: "utf8", env: { ...process.env, SystemRoot: "C:\\Windows" } });
assert.equal(r.status, 0, r.stderr);
assert.ok(win32.isAbsolute(r.stdout.trim()), r.stdout);
assert.equal(r.stdout.trim().toLowerCase(), "c:\\windows\\system32\\windowspowershell\\v1.0\\powershell.exe");

for (const [input, out] of [
	["/pics/photo.jpg", "/pics/photo_crop.png"],
	["/pics/scan.GIF", "/pics/scan_crop.png"],
	["/pics/shot.png", "/pics/shot_crop.png"],
	["/pics.v1/noext", "/pics.v1/noext_crop.png"],
]) assert.equal(editOut({}, input, "crop"), out);
assert.throws(() => editOut({ out: "/pics/photo.jpg" }, "/pics/photo.jpg", "masked"), /refusing to overwrite the input/);

for (const p of ["\\\\host\\share\\x.png", "//host/share/x.png", "\\\\?\\UNC\\host\\share\\x.png"]) assert.throws(() => filePath(p), /network paths are refused/, p);
assert.throws(() => editOut({ out: "\\\\host\\share\\out.png" }, "/pics/photo.jpg", "crop"), /network paths are refused/);
assert.equal(filePath("/pics/photo.jpg"), "/pics/photo.jpg");
console.log("ok: powershell.exe by full path on Windows; edits never overwrite their input; network image paths refused");
