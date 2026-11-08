# Shared helpers and Win32 P/Invoke for sidehand.
# Dot-source this file: . "$PSScriptRoot\lib.ps1"

# Inline C# is compiled once into %LOCALAPPDATA%\sidehand and loaded from there afterwards.
# Compiling on every call would start csc.exe each time: slower, and an agent without a console
# would see that compiler flash a console window.
function Import-SidehandType([string]$source) {
  $dir = Join-Path $env:LOCALAPPDATA 'sidehand'
  $sha = [Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($source))
  $dll = Join-Path $dir ('SidehandNative-' + ([BitConverter]::ToString($sha) -replace '-', '').Substring(0, 12) + '.dll')
  if (-not (Test-Path $dll)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Add-Type -TypeDefinition $source -OutputAssembly $dll -OutputType Library
    Get-ChildItem $dir -Filter 'SidehandNative-*.dll' | Where-Object { $_.FullName -ne $dll } | Remove-Item -ErrorAction SilentlyContinue
  }
  Add-Type -Path $dll
}

if (-not ("SidehandNative" -as [type])) {
  Import-SidehandType @'
using System;
using System.Runtime.InteropServices;
using System.Text;

// Work in physical pixels: otherwise Windows hands this (DPI-unaware) process scaled coordinates
// and scaled-down screenshots on displays above 100%.
public static class SidehandDpi {
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr c);
  [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr c);
  [DllImport("user32.dll")] public static extern IntPtr GetWindowDpiAwarenessContext(IntPtr h);
}

public class SidehandNative {
  public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);

  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc lpEnumFunc, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr hWnd);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdcBlt, uint nFlags);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
  [DllImport("dwmapi.dll")]
  public static extern int DwmGetWindowAttribute(IntPtr hWnd, int dwAttr, out RECT pvAttr, int cbAttr);

  [StructLayout(LayoutKind.Sequential)]
  public struct RECT { public int Left, Top, Right, Bottom; }
}
'@
}
if (-not [SidehandDpi]::SetProcessDpiAwarenessContext([IntPtr]-4)) { [void][SidehandDpi]::SetThreadDpiAwarenessContext([IntPtr]-4) } # PER_MONITOR_AWARE_V2

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

# SIDEHAND_ALLOW="Notepad;Contoso Orders;*Excel": sidehand then sees, operates and captures only
# windows whose title contains one of these (wildcards allowed). Screen and region captures, the
# clipboard and launching apps are off while it is set, since they reach beyond those windows.
$SidehandAllow = @(([string]$env:SIDEHAND_ALLOW -split ';') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
function Test-Allowed([string]$title) {
  if ($SidehandAllow.Count -eq 0) { return $true }
  foreach ($p in $SidehandAllow) { if ($title -like $(if ($p -match '[*?]') { $p } else { "*$p*" })) { return $true } }
  return $false
}
function Assert-Unrestricted([string]$what) {
  if ($SidehandAllow.Count) { throw "$what is off while SIDEHAND_ALLOW limits sidehand to: $($SidehandAllow -join '; ')" }
}

function Get-WindowList {
  $list = New-Object System.Collections.ArrayList
  $cb = [SidehandNative+EnumProc]{
    param($h, $l)
    if (-not [SidehandNative]::IsWindowVisible($h)) { return $true }
    $len = [SidehandNative]::GetWindowTextLength($h)
    if ($len -le 0) { return $true }
    $sb = New-Object System.Text.StringBuilder ($len + 2)
    [void][SidehandNative]::GetWindowText($h, $sb, $sb.Capacity)
    $t = $sb.ToString()
    if ([string]::IsNullOrWhiteSpace($t) -or -not (Test-Allowed $t)) { return $true }
    $r = New-Object SidehandNative+RECT
    [void][SidehandNative]::GetWindowRect($h, [ref]$r)
    $procId = [uint32]0; [void][SidehandNative]::GetWindowThreadProcessId($h, [ref]$procId)
    $w = $r.Right - $r.Left; $hgt = $r.Bottom - $r.Top
    if ($w -lt 50 -or $hgt -lt 50) { return $true }
    [void]$list.Add([pscustomobject]@{
      Handle = $h
      Title  = $t
      X = $r.Left; Y = $r.Top; W = $w; H = $hgt
      Minimized = [SidehandNative]::IsIconic($h)
      ProcessId = $procId
    })
    return $true
  }
  [void][SidehandNative]::EnumWindows($cb, [IntPtr]::Zero)
  return $list
}

# -Title is a handle from list_windows (0x...), an exact title, or else part of a title. Exact first:
# several agents may each open a window whose title is part of another's. IndexOf, not -like: titles
# hold [ and ], and PowerShell 5.1's WildcardPattern.Escape leaves a backtick unescaped.
function Select-Window([string]$Title) {
  $wins = Get-WindowList
  $match = if ($Title -match '^0x[0-9a-f]+$') { $wins | Where-Object { $_.Handle.ToInt64() -eq [Convert]::ToInt64($Title.Substring(2), 16) } }
           else { @($wins | Where-Object { $_.Title -eq $Title }) + @($wins | Where-Object { $_.Title.IndexOf($Title, [StringComparison]::OrdinalIgnoreCase) -ge 0 }) }
  $match = $match | Select-Object -First 1
  if (-not $match) { throw "no visible window matches: $Title$(if ($SidehandAllow.Count) { ' (sidehand only sees SIDEHAND_ALLOW windows)' })" }
  $match
}

# The UI Automation engine (SidehandUia.cs), compiled once into %LOCALAPPDATA%\sidehand and reused.
function Import-UiaEngine {
  $dir = Join-Path $env:LOCALAPPDATA 'sidehand'
  $src = Join-Path $PSScriptRoot 'SidehandUia.cs'
  $interop = Join-Path $dir 'Interop.UIAutomationClient.dll'
  $dll = Join-Path $dir ("SidehandUia-{0}.dll" -f (Get-FileHash $src -Algorithm SHA256).Hash.Substring(0, 12))
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  if (-not (Test-Path $interop)) {
    # Windows ships the UIA type library inside UIAutomationCore.dll; import it once instead of bundling an interop DLL.
    Add-Type @'
using System; using System.Reflection; using System.Runtime.InteropServices;
public class SidehandTlbSink : ITypeLibImporterNotifySink { public void ReportEvent(ImporterEventKind k, int c, string m) {} public Assembly ResolveRef(object t) { return null; } }
public static class SidehandTlb {
  [DllImport("oleaut32.dll", CharSet = CharSet.Unicode, PreserveSig = false)] static extern void LoadTypeLibEx(string f, int kind, [MarshalAs(UnmanagedType.Interface)] out object tl);
  public static void Import(string path) {
    object tl; LoadTypeLibEx(Environment.SystemDirectory + "\\UIAutomationCore.dll", 2, out tl);
    new TypeLibConverter().ConvertTypeLibToAssembly(tl, path, TypeLibImporterFlags.None, new SidehandTlbSink(), null, null, "Interop.UIAutomationClient", null).Save(System.IO.Path.GetFileName(path));
  }
}
'@
    [SidehandTlb]::Import($interop)
  }
  Add-Type -Path $interop
  if (-not (Test-Path $dll)) {
    Add-Type -Path $src -ReferencedAssemblies $interop -OutputAssembly $dll -OutputType Library
    # Builds of older script versions; one still loaded by another call just stays until next time.
    Get-ChildItem $dir -Filter 'SidehandUia-*.dll' | Where-Object { $_.FullName -ne $dll } | Remove-Item -ErrorAction SilentlyContinue
  }
  Add-Type -Path $dll
}

function Get-WindowRectDwm {
  param([IntPtr]$Handle)
  $r = New-Object SidehandNative+RECT
  $size = [System.Runtime.InteropServices.Marshal]::SizeOf([type][SidehandNative+RECT])
  # DWMWA_EXTENDED_FRAME_BOUNDS = 9 (excludes invisible drop-shadow border)
  $res = [SidehandNative]::DwmGetWindowAttribute($Handle, 9, [ref]$r, $size)
  if ($res -ne 0) {
    [void][SidehandNative]::GetWindowRect($Handle, [ref]$r)
  }
  return $r
}

function Ensure-Dir {
  param([string]$Path)
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
}

function Get-VirtualScreenBounds {
  $screens = [System.Windows.Forms.Screen]::AllScreens
  $minX = 0; $minY = 0; $maxR = 0; $maxB = 0
  $first = $true
  foreach ($s in $screens) {
    $b = $s.Bounds
    if ($first) {
      $minX = $b.X; $minY = $b.Y; $maxR = $b.X + $b.Width; $maxB = $b.Y + $b.Height
      $first = $false
    } else {
      if ($b.X -lt $minX) { $minX = $b.X }
      if ($b.Y -lt $minY) { $minY = $b.Y }
      if (($b.X + $b.Width)  -gt $maxR) { $maxR = $b.X + $b.Width }
      if (($b.Y + $b.Height) -gt $maxB) { $maxB = $b.Y + $b.Height }
    }
  }
  return [pscustomobject]@{ X=$minX; Y=$minY; W=($maxR-$minX); H=($maxB-$minY) }
}

function Write-Json {
  param($Object)
  ($Object | ConvertTo-Json -Compress -Depth 6)
}
