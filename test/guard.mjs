// findInputTakeover reads local script files named in a command, but never a network path: opening
// \\host\share\x.ps1 or //host/share/x.ps1 makes Windows connect to that host with the user's credentials.
// Run: node test/guard.mjs (any OS; reads only files it writes to a temp folder).
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { findInputTakeover } from "../lib/guard.mjs";

const dir = mkdtempSync(join(tmpdir(), "sidehand-guard-"));
try {
	const takeover = "Add-Type ...; [W]::SetCursorPos(0, 0)\n";
	writeFileSync(join(dir, "x.ps1"), takeover);
	// On Linux these names are ordinary local files, so a read would show up as a hit.
	writeFileSync(join(dir, "\\\\host\\share\\x.ps1"), takeover);
	writeFileSync(join(dir, "\\\\host@80\\dav\\x.ps1"), takeover);

	assert.match(findInputTakeover(`powershell -File ${join(dir, "x.ps1")}`, dir), /SetCursorPos in /, "a local script is read");
	assert.match(findInputTakeover("powershell -File x.ps1", dir), /SetCursorPos in x\.ps1/, "a relative script is read");
	for (const p of ["\\\\host\\share\\x.ps1", "\\\\host@80\\dav\\x.ps1", `/${dir}/x.ps1`, "//host/share/x.ps1"])
		for (const cmd of [`powershell -File ${p}`, `powershell -File "${p}"`]) assert.equal(findInputTakeover(cmd, dir), null, `network path opened: ${cmd}`);
	assert.match(findInputTakeover("powershell -c '[W]::SetCursorPos(0,0)' ; powershell -File \\\\host\\s\\x.ps1", dir), /SetCursorPos in the command/);
	console.log("ok: guard reads local scripts and never opens a network path");
} finally {
	rmSync(dir, { recursive: true, force: true });
}
