<#
  sidehand isolated.ps1 - a private desktop that is never shown, for apps started with launch --isolated.
  Windows there never reach the user's screen or taskbar and cannot take their foreground.
  UI Automation and window lists see only the calling thread's desktop, so operations on those
  windows run in a PowerShell started on that desktop:
    -Op worker              worker.ps1 there, on this process's stdin/stdout (the MCP server and pi).
                            The desktop and every app started there end when this process ends.
    -Op run -Command "..."  one command there (the CLI); -Create makes the desktop if it does not exist.
                            Apps it starts keep running, and the desktop with them, until -Op close.
    -Op close               end every app on that desktop.
  The desktop is named sidehand-<SIDEHAND_SESSION, or cli>; the PowerShell there gets SIDEHAND_ISOLATED.
#>
param([ValidateSet('worker', 'run', 'close')][string]$Op = 'run', [string]$Command = '', [switch]$Create)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib.ps1"

Import-SidehandType -name 'SidehandIsolated' @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

public static class SidehandIsolated {
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  struct STARTUPINFO { public int cb; public string lpReserved, lpDesktop, lpTitle;
    public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
    public short wShowWindow, cbReserved2; public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError; }
  [StructLayout(LayoutKind.Sequential)] struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int pid, tid; }
  [StructLayout(LayoutKind.Sequential)] struct BASIC { public long a, b; public uint LimitFlags; public UIntPtr c, d; public uint e; public UIntPtr f; public uint g, h; }
  [StructLayout(LayoutKind.Sequential)] struct IOC { public ulong a, b, c, d, e, f; }
  [StructLayout(LayoutKind.Sequential)] struct EXT { public BASIC Basic; public IOC Io; public UIntPtr a, b, c, d; }
  delegate bool EnumProc(IntPtr h, IntPtr l);

  [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern IntPtr CreateDesktop(string n, IntPtr d, IntPtr m, uint f, uint acc, IntPtr sa);
  [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern IntPtr OpenDesktop(string n, uint f, bool inherit, uint acc);
  [DllImport("user32.dll")] static extern IntPtr GetThreadDesktop(uint tid);
  [DllImport("user32.dll")] static extern bool EnumDesktopWindows(IntPtr d, EnumProc f, IntPtr l);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
  [DllImport("kernel32.dll")] static extern IntPtr GetStdHandle(int n);
  [DllImport("kernel32.dll")] static extern bool SetHandleInformation(IntPtr h, uint mask, uint flags);
  [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr CreateJobObject(IntPtr a, IntPtr n);
  [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetInformationJobObject(IntPtr j, int c, ref EXT i, int l);
  [DllImport("kernel32.dll", SetLastError = true)] static extern bool AssignProcessToJobObject(IntPtr j, IntPtr p);
  [DllImport("kernel32.dll")] static extern bool TerminateProcess(IntPtr p, uint c);
  [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
  static extern bool CreateProcess(string app, StringBuilder cmd, IntPtr pa, IntPtr ta, bool inh, uint f, IntPtr env, string cwd, ref STARTUPINFO si, out PROCESS_INFORMATION pi);
  [DllImport("kernel32.dll")] static extern uint ResumeThread(IntPtr t);
  [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr h, uint ms);
  [DllImport("kernel32.dll")] static extern bool GetExitCodeProcess(IntPtr h, out uint code);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);

  // Zero when create is off and the desktop does not exist. A desktop lasts while a handle to it is
  // open or a process runs on it.
  public static IntPtr Open(string name, bool create) {
    return create ? CreateDesktop(name, IntPtr.Zero, IntPtr.Zero, 0, 0x10000000 /* GENERIC_ALL */, IntPtr.Zero)
                  : OpenDesktop(name, 0, false, 0x10000000);
  }

  // Runs cmdline on the desktop with this process's stdin, stdout and stderr, and returns its exit code.
  // kill: it and everything it starts end with this process (a job that kills on close).
  public static int Run(string desktop, string cmdline, bool kill) {
    var si = new STARTUPINFO(); si.cb = Marshal.SizeOf(si); si.lpDesktop = desktop;
    si.dwFlags = 0x100; // STARTF_USESTDHANDLES
    si.hStdInput = Inherit(-10); si.hStdOutput = Inherit(-11); si.hStdError = Inherit(-12);
    IntPtr job = IntPtr.Zero;
    if (kill) {
      job = CreateJobObject(IntPtr.Zero, IntPtr.Zero);
      var ext = new EXT(); ext.Basic.LimitFlags = 0x2000; // KILL_ON_JOB_CLOSE; the handle stays open until this process ends
      if (job == IntPtr.Zero || !SetInformationJobObject(job, 9, ref ext, Marshal.SizeOf(ext))) throw new Win32Exception();
    }
    PROCESS_INFORMATION pi;
    if (!CreateProcess(null, new StringBuilder(cmdline), IntPtr.Zero, IntPtr.Zero, true, 0x4 /* SUSPENDED */ | 0x08000000 /* NO_WINDOW */, IntPtr.Zero, null, ref si, out pi))
      throw new Win32Exception();
    if (kill && !AssignProcessToJobObject(job, pi.hProcess)) { TerminateProcess(pi.hProcess, 1); throw new Win32Exception(); }
    ResumeThread(pi.hThread);
    WaitForSingleObject(pi.hProcess, 0xFFFFFFFF);
    uint code; GetExitCodeProcess(pi.hProcess, out code);
    CloseHandle(pi.hThread); CloseHandle(pi.hProcess);
    return (int)code;
  }
  static IntPtr Inherit(int std) { var h = GetStdHandle(std); SetHandleInformation(h, 1, 1); return h; }

  // Processes that own a top-level window (shown or not) on the desktop; desk zero: this thread's.
  public static uint[] Pids(IntPtr desk) {
    var pids = new HashSet<uint>();
    EnumDesktopWindows(desk == IntPtr.Zero ? GetThreadDesktop(GetCurrentThreadId()) : desk, (h, l) => { uint p; GetWindowThreadProcessId(h, out p); pids.Add(p); return true; }, IntPtr.Zero);
    return new List<uint>(pids).ToArray();
  }
}
'@

$name = "sidehand-$(if ($env:SIDEHAND_SESSION) { $env:SIDEHAND_SESSION } else { 'cli' })"
$desk = [SidehandIsolated]::Open($name, $Op -eq 'worker' -or $Create)
if ($desk -eq [IntPtr]::Zero) { throw "no isolated desktop is open (launch an app with --isolated first)" }
$ps = "`"$PSHOME\powershell.exe`" -NoProfile -ExecutionPolicy Bypass -NonInteractive"
$env:SIDEHAND_ISOLATED = $name
switch ($Op) {
  'worker' { exit [SidehandIsolated]::Run($name, "$ps -File `"$PSScriptRoot\worker.ps1`"", $true) }
  'run' {
    # Through the environment, so nothing is quoted again.
    $env:SIDEHAND_RUN = "[Console]::OutputEncoding = [System.Text.Encoding]::UTF8; $Command"
    exit [SidehandIsolated]::Run($name, "$ps -Command `"& ([ScriptBlock]::Create(`$env:SIDEHAND_RUN))`"", $false)
  }
  'close' {
    # shortcut: ends the processes that own a window there (and their child processes); a windowless
    # process started there without a parent that had one keeps running. Processes that also have a
    # window on this desktop (shared ones such as the shell) are left alone.
    $mine = [SidehandIsolated]::Pids([IntPtr]::Zero)
    $pids = @([SidehandIsolated]::Pids($desk) | Where-Object { $mine -notcontains $_ -and $_ -ne $PID })
    foreach ($p in $pids) { & taskkill.exe /F /T /PID $p 2>&1 | Out-Null }
    "ok closed the isolated desktop: ended $($pids.Count) app process(es)"
  }
}
