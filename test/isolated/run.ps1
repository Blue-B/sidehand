<#
  Measures whether sidehand (and agent-desktop, when installed) takes the user's focus.
  Everything runs on a separate, never-shown Windows desktop inside a kill-on-close job, so the
  test cannot touch the real desktop, and a monitor thread proves it by watching the real
  foreground window for the whole run.

    powershell -ExecutionPolicy Bypass -File test\isolated\run.ps1 [-NoAgentDesktop]

  Every sidehand action except an approved `focus` must take effect without activating its
  window; `focus` with consent is the positive control that proves activations are detected.
#>
param([switch]$NoAgentDesktop, [int]$TimeoutSec = 400, [switch]$Bench, [string]$Cua = '')
# -Cua <path to cua-driver.exe> also measures Cua Driver. Never automatic: Cua Driver 0.28.2 runs
# `cmd /c ver` for telemetry on every call, which opens a console window on the REAL desktop
# (even from the hidden test desktop) and takes the foreground from whatever the user is doing.
# -Bench runs bench.ps1 instead: token, speed and coverage numbers for all three tools, written to
# bench.json in the work folder (scored by test/isolated/bench_score.py).
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).ProviderPath
$work = Join-Path $env:TEMP ('sidehand-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $work | Out-Null

Add-Type @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public static class SidehandSandbox {
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  struct STARTUPINFO { public int cb; public string lpReserved; public string lpDesktop; public string lpTitle;
    public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
    public short wShowWindow, cbReserved2; public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError; }
  [StructLayout(LayoutKind.Sequential)] struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int pid, tid; }
  [StructLayout(LayoutKind.Sequential)] struct BASIC { public long a, b; public uint LimitFlags; public UIntPtr c, d; public uint e; public UIntPtr f; public uint g, h; }
  [StructLayout(LayoutKind.Sequential)] struct IOC { public ulong a, b, c, d, e, f; }
  [StructLayout(LayoutKind.Sequential)] struct EXT { public BASIC Basic; public IOC Io; public UIntPtr a, b, c, d; }

  [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern IntPtr CreateDesktop(string n, IntPtr d, IntPtr m, uint f, uint acc, IntPtr sa);
  [DllImport("user32.dll", SetLastError = true)] static extern bool CloseDesktop(IntPtr h);
  [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr CreateJobObject(IntPtr a, IntPtr n);
  [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetInformationJobObject(IntPtr j, int c, ref EXT i, int l);
  [DllImport("kernel32.dll", SetLastError = true)] static extern bool AssignProcessToJobObject(IntPtr j, IntPtr p);
  [DllImport("kernel32.dll", SetLastError = true)] static extern bool TerminateJobObject(IntPtr j, uint c);
  [DllImport("kernel32.dll", SetLastError = true)] static extern bool TerminateProcess(IntPtr p, uint c);
  [DllImport("kernel32.dll", SetLastError = true)] static extern bool IsProcessInJob(IntPtr p, IntPtr j, out bool r);
  [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr OpenProcess(uint a, bool i, uint pid);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
  [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
  static extern bool CreateProcess(string app, StringBuilder cmd, IntPtr pa, IntPtr ta, bool inh, uint f, IntPtr env, string cwd, ref STARTUPINFO si, out PROCESS_INFORMATION pi);
  [DllImport("kernel32.dll")] static extern uint ResumeThread(IntPtr t);
  [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr h, uint ms);
  [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);

  static IntPtr job, desk;
  static volatile bool stop;
  static Thread mon;
  public static int ForegroundHits;

  public static void Open(string name) {
    desk = CreateDesktop(name, IntPtr.Zero, IntPtr.Zero, 0, 0x10000000, IntPtr.Zero);
    if (desk == IntPtr.Zero) throw new Win32Exception();
    job = CreateJobObject(IntPtr.Zero, IntPtr.Zero);
    var ext = new EXT(); ext.Basic.LimitFlags = 0x2000; // KILL_ON_JOB_CLOSE: nothing outlives the test
    if (!SetInformationJobObject(job, 9, ref ext, Marshal.SizeOf(ext))) throw new Win32Exception();
    mon = new Thread(() => {
      IntPtr last = IntPtr.Zero;
      while (!stop) {
        var fg = GetForegroundWindow();
        if (fg != last) {
          uint pid; GetWindowThreadProcessId(fg, out pid);
          bool inJob = false; var h = OpenProcess(0x1000, false, pid);
          if (h != IntPtr.Zero) { IsProcessInJob(h, job, out inJob); CloseHandle(h); }
          if (inJob) ForegroundHits++;
          last = fg;
        }
        Thread.Sleep(5);
      }
    });
    mon.IsBackground = true; mon.Start();
  }

  public static bool Run(string desktopName, string cmdline, uint timeoutMs) {
    var si = new STARTUPINFO(); si.cb = Marshal.SizeOf(si); si.lpDesktop = "WinSta0\\" + desktopName;
    PROCESS_INFORMATION pi;
    if (!CreateProcess(null, new StringBuilder(cmdline), IntPtr.Zero, IntPtr.Zero, false, 0x4 | 0x08000000, IntPtr.Zero, null, ref si, out pi)) throw new Win32Exception();
    if (!AssignProcessToJobObject(job, pi.hProcess)) { TerminateProcess(pi.hProcess, 1); throw new Win32Exception(); }
    ResumeThread(pi.hThread);
    uint w = WaitForSingleObject(pi.hProcess, timeoutMs);
    CloseHandle(pi.hThread); CloseHandle(pi.hProcess);
    return w == 0;
  }

  public static void Close() {
    stop = true; if (mon != null) mon.Join();
    if (job != IntPtr.Zero) { TerminateJobObject(job, 1); CloseHandle(job); job = IntPtr.Zero; }
    if (desk != IntPtr.Zero) { CloseDesktop(desk); desk = IntPtr.Zero; }
  }
}
'@

try {
  $fw = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319"
  & "$fw\csc.exe" /nologo /target:winexe "/out:$work\TestWinForms.exe" /r:System.Windows.Forms.dll /r:System.Drawing.dll "$PSScriptRoot\TestWinForms.cs"
  & "$fw\csc.exe" /nologo /target:winexe "/out:$work\TestWpf.exe" "/r:$fw\WPF\PresentationFramework.dll" "/r:$fw\WPF\PresentationCore.dll" "/r:$fw\WPF\WindowsBase.dll" "/r:$fw\System.Xaml.dll" "$PSScriptRoot\TestWpf.cs"
  if (-not (Test-Path "$work\TestWpf.exe")) { throw 'could not compile the test apps' }

  $ad = ''
  if (-not $NoAgentDesktop) { $cmdInfo = Get-Command agent-desktop -ErrorAction SilentlyContinue; if ($cmdInfo) { $ad = $cmdInfo.Source } }
  $cua = if ($Cua -and (Test-Path $Cua)) { $Cua } else { $null }

  $desk = 'sidehand-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
  [SidehandSandbox]::Open($desk)
  $scenario = if ($Bench) { 'bench.ps1' } else { 'scenario.ps1' }
  if ($Bench) { & "$fw\csc.exe" /nologo /target:winexe "/out:$work\DemoApps.exe" /r:System.Windows.Forms.dll /r:System.Drawing.dll "$repo\demo\DemoApps.cs"; Copy-Item "$PSScriptRoot\page.html" $work }
  $cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$PSScriptRoot\$scenario`" -Work `"$work`" -Repo `"$repo`""
  if ($ad) { $cmd += " -AgentDesktop `"$ad`"" }
  if ($cua) { $cmd += " -Cua `"$cua`"" }
  $finished = [SidehandSandbox]::Run($desk, $cmd, [uint32]($TimeoutSec * 1000))
} finally {
  [SidehandSandbox]::Close()
}
if (-not $finished) { throw "scenario timed out after $TimeoutSec s (all test processes were killed)" }
if (Test-Path "$work\error.txt") { throw ("scenario failed:`n" + (Get-Content -Raw "$work\error.txt")) }
# Browser and editor profiles (the test Edge may sign in with the Windows account) never outlive the run.
# Edge keeps files locked for a moment after it is killed, so retry.
for ($i = 0; $i -lt 10 -and (Test-Path "$work\edge", "$work\vscode", "$work\vscode-ext") -contains $true; $i++) {
  Remove-Item -Recurse -Force "$work\edge", "$work\vscode", "$work\vscode-ext" -ErrorAction SilentlyContinue
  Start-Sleep -Milliseconds 500
}
if ($Bench) { "bench: $work\bench"; "real desktop foreground taken by a test process: $([SidehandSandbox]::ForegroundHits) time(s)"; return }

$results = Get-Content -Raw -Encoding UTF8 "$work\results.json" | ConvertFrom-Json
$failures = New-Object System.Collections.Generic.List[string]
$rows = foreach ($r in $results) {
  $events = @(Get-Content -Encoding UTF8 $r.log -ErrorAction SilentlyContinue | ForEach-Object {
    $t, $role, $e = $_ -split "`t", 3
    if ([long]$t -ge $r.t0 -and [long]$t -lt $r.t1) { [pscustomobject]@{ role = $role; e = $e } }
  })
  $activated = [bool]($events | Where-Object { $_.role -eq 'target' -and ($_.e -eq 'form.activated' -or $_.e -like 'focus+*') })
  $took = if ($r.expect) { [bool]($events | Where-Object { $_.role -eq 'target' -and $_.e -eq $r.expect }) } else { $null }
  $via = if ($r.output -match 'via window message') { 'window message' } elseif ($r.output -match 'via posted input') { 'posted input' } elseif ($r.output -match 'via UI Automation') { 'UI Automation' } elseif ($r.tool -eq 'agent-desktop') { 'UI Automation' } elseif ($r.label -like '*type_text*') { 'window message' } elseif ($r.tool -eq 'cua-driver') { 'UI Automation' } else { '-' }
  if ($r.label -like '*refused*' -and ($activated -or $took -or $r.output -notmatch 'allow-foreground|no selectable item|needs real input')) { $failures.Add("$($r.app) $($r.label): not refused") }
  if ($r.tool -eq 'sidehand' -and $r.label -notlike 'focus*' -and $r.label -notlike '*refused*' -and ($activated -or -not $took)) { $failures.Add("$($r.app) $($r.label): activated=$activated took_effect=$took") }
  if ($r.label -eq 'focus without consent' -and ($activated -or $r.output -notmatch 'allow-foreground')) { $failures.Add('focus without consent was not refused') }
  if ($r.label -like 'focus with consent*' -and -not $activated) { $failures.Add('positive control: focus did not register an activation, so the measurement is blind') }
  $err = if ($r.output -match '"ok":false.*?"message":"([^"]+)"') { $Matches[1] } elseif ($r.tool -eq 'cua-driver' -and $r.output -match '"isError":\s*true|^error') { ($r.output -split "`n" | Select-Object -First 1) } elseif ($r.output -match '^(ok |\{)' -or -not $r.output) { '' } else { ($r.output -split "`n")[0] }
  if ($err.Length -gt 60) { $err = $err.Substring(0, 60) + '...' }
  [pscustomobject]@{ Tool = $r.tool; App = $r.app; Action = $r.label; Via = $via; 'Took effect' = $(if ($null -eq $took) { '-' } else { $took }); 'Target activated' = $activated; Ms = $r.ms; Error = $err }
}
$rows | Format-Table -AutoSize | Out-String -Width 200
"Real desktop foreground taken by a test process: $([SidehandSandbox]::ForegroundHits) time(s)"
if ([SidehandSandbox]::ForegroundHits -gt 0) { $failures.Add('a test process took the real foreground') }
if ($failures.Count) { "FAIL (app logs kept in $work)"; $failures | ForEach-Object { "  $_" }; exit 1 }
Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
"PASS: every sidehand action took effect without activating its window"
