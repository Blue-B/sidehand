# Shared by record.ps1 and measure.ps1 (dot-source after setting $uia):
# [Rec] keeps every started process in a kill-on-close job, watches the real foreground window,
# and can type, capture and restore focus; the functions read and act through sidehand.
Add-Type -ReferencedAssemblies System.Drawing @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Drawing;
using System.Drawing.Imaging;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public static class Rec {
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  struct STARTUPINFO { public int cb; public string lpReserved; public string lpDesktop; public string lpTitle;
    public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
    public short wShowWindow, cbReserved2; public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError; }
  [StructLayout(LayoutKind.Sequential)] struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int pid, tid; }
  [StructLayout(LayoutKind.Sequential)] struct BASIC { public long a, b; public uint LimitFlags; public UIntPtr c, d; public uint e; public UIntPtr f; public uint g, h; }
  [StructLayout(LayoutKind.Sequential)] struct IOC { public ulong a, b, c, d, e, f; }
  [StructLayout(LayoutKind.Sequential)] struct EXT { public BASIC Basic; public IOC Io; public UIntPtr a, b, c, d; }
  [StructLayout(LayoutKind.Sequential)] struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr extra; }
  [StructLayout(LayoutKind.Sequential)] struct INPUT { public uint type; public KEYBDINPUT ki; public long pad; }
  [StructLayout(LayoutKind.Sequential)] struct MOUSEINPUT { public int dx, dy; public uint data, flags, time; public IntPtr extra; }
  [StructLayout(LayoutKind.Sequential)] struct MINPUT { public uint type; public MOUSEINPUT mi; }
  [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }
  [StructLayout(LayoutKind.Sequential)] struct RECT { public int L, T, R, B; }

  [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
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
  [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] static extern bool AttachThreadInput(uint a, uint b, bool attach);
  [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] static extern uint SendInput(uint n, INPUT[] inputs, int size);
  [DllImport("user32.dll", EntryPoint = "SendInput")] static extern uint SendMouse(uint n, MINPUT[] inputs, int size);
  [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT p);
  [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, string title);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] static extern uint GetDpiForSystem();
  [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int hh, uint f);
  delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, IntPtr l);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);

  static IntPtr job;
  static volatile bool stopAll, typing, stopCapture, stats;
  public static volatile bool Armed, Aborted;
  public static IntPtr Notes;
  public static string AbortReason = "";
  public static List<long[]> Fg = new List<long[]>(); // ticks, pid, inJob
  public static List<long[]> Cur = new List<long[]>(); // ticks, x, y: every move of the real cursor
  public static int Frames, Typed;

  public static void Init() {
    SetProcessDPIAware();
    job = CreateJobObject(IntPtr.Zero, IntPtr.Zero);
    var ext = new EXT(); ext.Basic.LimitFlags = 0x2000; // KILL_ON_JOB_CLOSE
    if (!SetInformationJobObject(job, 9, ref ext, Marshal.SizeOf(ext))) throw new Win32Exception();
    var t = new Thread(Monitor); t.IsBackground = true; t.Start();
  }

  public static int Launch(string cmdline) {
    var si = new STARTUPINFO(); si.cb = Marshal.SizeOf(si);
    PROCESS_INFORMATION pi;
    // CREATE_SUSPENDED | CREATE_NO_WINDOW: a console program (node) must not open a console window.
    if (!CreateProcess(null, new StringBuilder(cmdline), IntPtr.Zero, IntPtr.Zero, false, 0x4 | 0x08000000, IntPtr.Zero, null, ref si, out pi)) throw new Win32Exception();
    if (!AssignProcessToJobObject(job, pi.hProcess)) { TerminateProcess(pi.hProcess, 1); throw new Win32Exception(); }
    ResumeThread(pi.hThread); CloseHandle(pi.hThread); CloseHandle(pi.hProcess);
    return pi.pid;
  }

  public static bool InJob(uint pid) {
    bool r = false; var h = OpenProcess(0x1000, false, pid);
    if (h != IntPtr.Zero) { IsProcessInJob(h, job, out r); CloseHandle(h); }
    return r;
  }

  static void Monitor() {
    IntPtr last = IntPtr.Zero;
    while (!stopAll) {
      var fg = GetForegroundWindow();
      if (fg != last && fg != IntPtr.Zero) {
        uint pid; GetWindowThreadProcessId(fg, out pid);
        bool inJob = InJob(pid);
        lock (Fg) Fg.Add(new long[] { DateTime.UtcNow.Ticks, pid, inJob ? 1 : 0 });
        if (Armed && !inJob && !Aborted) { Aborted = true; AbortReason = "a window outside the demo took the foreground (pid " + pid + "): someone is using the PC"; }
        last = fg;
      }
      POINT c; GetCursorPos(out c);
      lock (Cur) if (Cur.Count == 0 || Cur[Cur.Count - 1][1] != c.X || Cur[Cur.Count - 1][2] != c.Y) Cur.Add(new long[] { DateTime.UtcNow.Ticks, c.X, c.Y });
      Thread.Sleep(5);
    }
  }

  public static uint PidOf(IntPtr h) { uint pid; GetWindowThreadProcessId(h, out pid); return pid; }
  [DllImport("user32.dll")] static extern int GetSystemMetrics(int i);
  public static int ScreenW() { return GetSystemMetrics(0); }
  public static int ScreenH() { return GetSystemMetrics(1); }
  public static int Dpi() { return (int)GetDpiForSystem(); }
  static bool FgInJob() { uint pid; GetWindowThreadProcessId(GetForegroundWindow(), out pid); return InJob(pid); }

  // Simulated user mouse, on the primary screen. Sent only while a demo window is in front.
  static void Mouse(int x, int y, uint flags) {
    var i = new MINPUT { type = 0, mi = new MOUSEINPUT { dx = (int)Math.Round(x * 65535.0 / (ScreenW() - 1)), dy = (int)Math.Round(y * 65535.0 / (ScreenH() - 1)), flags = 0x8001 | flags } };
    SendMouse(1, new[] { i }, Marshal.SizeOf(typeof(MINPUT)));
  }
  public static void Glide(int x, int y, int ms) {
    POINT p; GetCursorPos(out p);
    int steps = Math.Max(1, ms / 15);
    for (int i = 1; i <= steps; i++) {
      if (Aborted || !FgInJob()) return;
      double t = (double)i / steps; t = t < 0.5 ? 4 * t * t * t : 1 - Math.Pow(-2 * t + 2, 3) / 2;
      Mouse((int)(p.X + (x - p.X) * t), (int)(p.Y + (y - p.Y) * t), 0);
      Thread.Sleep(15);
    }
  }
  public static void Click(int x, int y) {
    if (Aborted || !FgInJob()) return;
    Mouse(x, y, 0x2); Thread.Sleep(70); Mouse(x, y, 0x4);
  }
  // Z-order only (rehearsal stand-in for a click on a title bar): top of the topmost band, not activated.
  public static void ToTop(IntPtr h) { SetWindowPos(h, new IntPtr(-1), 0, 0, 0, 0, 0x1 | 0x2 | 0x10); }

  // Live numbers for the demo's "You" card: typed, arrived in Notes, foreground changes since now.
  public static void StartStats(string path, string notesFile) {
    stats = true; long from = DateTime.UtcNow.Ticks;
    var t = new Thread(() => {
      while (stats && !stopAll) {
        int got = 0;
        try { using (var fs = new System.IO.FileStream(notesFile, System.IO.FileMode.Open, System.IO.FileAccess.Read, System.IO.FileShare.ReadWrite)) using (var r = new System.IO.StreamReader(fs)) got = r.ReadToEnd().Length; } catch { }
        try { System.IO.File.WriteAllText(path, Typed + "\t" + got + "\t" + FgSince(from).Length); } catch { }
        Thread.Sleep(150);
      }
    });
    t.IsBackground = true; t.Start();
  }
  public static void StopStats() { stats = false; Thread.Sleep(200); }

  // Rehearsal on a hidden desktop has no screen to copy: rebuild each frame from PrintWindow of
  // every visible window, bottom to top, at half size.
  public static void StartPreview(string dir, int fps) {
    var t = new Thread(() => {
      var enc = ImageCodecInfo.GetImageEncoders().First(c => c.MimeType == "image/jpeg");
      var ps = new EncoderParameters(1); ps.Param[0] = new EncoderParameter(System.Drawing.Imaging.Encoder.Quality, 85L);
      int w = ScreenW(), h = ScreenH();
      while (!stopAll && !stopCapture) {
        var wins = new List<IntPtr>();
        EnumWindows((hh, l) => { if (IsWindowVisible(hh)) wins.Add(hh); return true; }, IntPtr.Zero);
        using (var bmp = new Bitmap(w / 2, h / 2)) using (var g = Graphics.FromImage(bmp)) {
          g.Clear(Color.Black); g.ScaleTransform(0.5f, 0.5f);
          for (int i = wins.Count - 1; i >= 0; i--) {
            RECT r; if (!GetWindowRect(wins[i], out r) || r.R <= r.L || r.B <= r.T) continue;
            using (var wb = new Bitmap(r.R - r.L, r.B - r.T)) {
              using (var wg = Graphics.FromImage(wb)) { var hdc = wg.GetHdc(); if (!PrintWindow(wins[i], hdc, 2)) PrintWindow(wins[i], hdc, 0); wg.ReleaseHdc(hdc); }
              g.DrawImage(wb, r.L, r.T);
            }
          }
          bmp.Save(System.IO.Path.Combine(dir, string.Format("p{0:D4}.jpg", Frames++)), enc, ps);
        }
        Thread.Sleep(1000 / fps);
      }
    });
    t.IsBackground = true; t.Start();
  }
  public static string FindPrefix(string prefix) {
    string hit = null;
    EnumWindows((h, l) => { var sb = new StringBuilder(512); GetWindowText(h, sb, 512); if (IsWindowVisible(h) && sb.ToString().StartsWith(prefix)) { hit = sb.ToString(); return false; } return true; }, IntPtr.Zero);
    return hit;
  }

  // By exact title: Process.MainWindowHandle can pick the IME's input indicator window instead.
  public static IntPtr Find(string title) {
    IntPtr hit = IntPtr.Zero;
    EnumWindows((h, l) => { var sb = new StringBuilder(512); GetWindowText(h, sb, 512); if (IsWindowVisible(h) && sb.ToString() == title) { hit = h; return false; } return true; }, IntPtr.Zero);
    return hit;
  }

  // Start of the demo only: put the demo's Notes window in front, as a user clicking it would.
  [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
  public static bool ForceForeground(IntPtr h) {
    if (IsIconic(h)) ShowWindow(h, 9); // SW_RESTORE: a computer-use agent may have minimized it
    uint dummy; uint fgThread = GetWindowThreadProcessId(GetForegroundWindow(), out dummy), me = GetCurrentThreadId();
    AttachThreadInput(me, fgThread, true);
    SetForegroundWindow(h); BringWindowToTop(h);
    AttachThreadInput(me, fgThread, false);
    Thread.Sleep(150);
    return GetForegroundWindow() == h;
  }

  public static void StartCapture(int x, int y, int w, int h, string dir, int fps) {
    var t = new Thread(() => {
      var enc = ImageCodecInfo.GetImageEncoders().First(c => c.MimeType == "image/jpeg");
      var ps = new EncoderParameters(1); ps.Param[0] = new EncoderParameter(System.Drawing.Imaging.Encoder.Quality, 92L);
      var sw = System.Diagnostics.Stopwatch.StartNew();
      using (var bmp = new Bitmap(w, h)) using (var g = Graphics.FromImage(bmp)) {
        while (!stopAll && !stopCapture) {
          g.CopyFromScreen(x, y, 0, 0, new Size(w, h));
          bmp.Save(System.IO.Path.Combine(dir, string.Format("f{0:D5}.jpg", Frames)), enc, ps);
          Frames++;
          long next = (long)Frames * 1000 / fps;
          int wait = (int)(next - sw.ElapsedMilliseconds);
          if (wait > 0) Thread.Sleep(wait);
        }
      }
    });
    t.IsBackground = true; t.Start();
  }

  // Simulated user keystrokes. Sent only while Notes is the foreground window. A rehearsal (dry)
  // posts the characters to the Notes text box instead, since a hidden desktop takes no input.
  public static void StartTyping(string text, int msPerChar, bool dry) {
    typing = true;
    IntPtr box = IntPtr.Zero;
    if (dry) for (var c = FindWindowEx(Notes, IntPtr.Zero, null, null); c != IntPtr.Zero; c = FindWindowEx(Notes, c, null, null)) {
      var sb = new StringBuilder(128); GetClassName(c, sb, 128); if (sb.ToString().ToUpperInvariant().Contains("EDIT")) box = c;
    }
    var t = new Thread(() => {
      var rnd = new Random(7);
      for (int i = 0; i < text.Length && typing && !stopAll; ) {
        if (Aborted) return;
        if (dry) PostMessage(box, 0x0102, new IntPtr(text[i]), new IntPtr(1));
        else {
        if (GetForegroundWindow() != Notes) { Thread.Sleep(20); continue; }
        var down = new INPUT { type = 1, ki = new KEYBDINPUT { wScan = text[i], dwFlags = 0x4 } };
        var up = new INPUT { type = 1, ki = new KEYBDINPUT { wScan = text[i], dwFlags = 0x4 | 0x2 } };
        SendInput(2, new[] { down, up }, Marshal.SizeOf(typeof(INPUT)));
        }
        Typed = ++i;
        Thread.Sleep(msPerChar + rnd.Next(-25, 40));
      }
    });
    t.IsBackground = true; t.Start();
  }
  public static void StopTyping() { typing = false; }
  public static void StopCapture() { stopCapture = true; Thread.Sleep(300); }

  public static long[][] FgSince(long ticks) { lock (Fg) return Fg.Where(e => e[0] >= ticks).ToArray(); }
  public static long[][] CurSince(long ticks) { lock (Cur) return Cur.Where(e => e[0] >= ticks).ToArray(); }
  // Milliseconds in [from, to] during which the foreground window was not Notes.
  public static long AwayMs(long from, long to) {
    uint notes = PidOf(Notes); long away = 0, since = -1;
    long[][] all; lock (Fg) all = Fg.ToArray();
    var before = all.Where(e => e[0] < from).LastOrDefault();
    if (before != null && before[1] != notes) since = from;
    foreach (var e in all.Where(e => e[0] >= from && e[0] <= to)) {
      if (e[1] != notes && since < 0) since = e[0];
      else if (e[1] == notes && since >= 0) { away += e[0] - since; since = -1; }
    }
    if (since >= 0) away += to - since;
    return away / 10000;
  }

  public static void Close() {
    stopAll = true; Thread.Sleep(200);
    if (job != IntPtr.Zero) { TerminateJobObject(job, 1); CloseHandle(job); job = IntPtr.Zero; }
  }
}
'@

function Window([string]$title) {
  for ($i = 0; $i -lt 100; $i++) {
    $h = [Rec]::Find($title)
    if ($h -ne [IntPtr]::Zero) { return [pscustomobject]@{ MainWindowHandle = $h; Id = [Rec]::PidOf($h) } }
    Start-Sleep -Milliseconds 100
  }
  throw "window did not appear: $title"
}
function Assert-NotAborted { if ([Rec]::Aborted) { throw "aborted: $([Rec]::AbortReason)" } }
function UiTree([string]$title) { $ErrorActionPreference = 'Continue'; (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $uia -Op tree -Title $title -MaxNodes 800 2>&1 | ForEach-Object { "$_" }) -join "`n" }
function UiAct([string]$ref, [string]$action, [string]$value = '') {
  $ErrorActionPreference = 'Continue'
  $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $uia, '-Op', 'act', '-Ref', $ref, '-Action', $action)
  if ($value) { $a += @('-Value', $value) }
  (& powershell.exe @a 2>&1 | ForEach-Object { "$_" }) -join ' '
}
function RefExact([string]$tree, [string]$name) { if ($tree -match "(?m)^\s*(e\d+) \S+ `"$([regex]::Escape($name))`"") { $Matches[1] } }
# Ref of the first line matching "<ref> <rx>", e.g. 'Button "(Stop|중지)"$'. Recordly's labels follow
# the Windows display language; English and Korean are covered.
function RefRx([string]$tree, [string]$rx) { if ($tree -match "(?m)^\s*(e\d+) $rx") { $Matches[1] } }
# Polls a window's tree until $finder returns a ref; returns @(ref, tree).
function WaitRef([string]$title, [scriptblock]$finder, [int]$timeoutSec = 20) {
  $end = (Get-Date).AddSeconds($timeoutSec)
  while ((Get-Date) -lt $end) {
    $t = UiTree $title
    $r = & $finder $t
    if ($r) { return @($r, $t) }
    Start-Sleep -Milliseconds 500
  }
  throw "timed out waiting in '$title'"
}
