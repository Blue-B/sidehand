<#
  sidehand uia.ps1 - UI Automation text tree + ref actions (no pixels, no mouse, no focus change)
    -Op tree  -Title "<substring>" [-MaxNodes N] [-Rects] [-Filter text]   compact element tree with refs (e1, e2, ...)
    -Op wait  -Title "<substring>" -Filter text [-Gone] [-TimeoutMs N]     poll until an element line matches (or none does)
    -Op ocr   -Title "<substring>"         text lines read by Windows OCR, with refs (t1, t2, ...) for clicks
    -Op act   -Ref eN -Action click|type|check|uncheck|select|expand|collapse|scroll|focus
                      |right-click|double-click|hover|wheel|drag|press [-Value "..."] [-AllowForeground]
              -Ref tN (from ocr) or @x,y (a pixel of the last window capture, capture.ps1): pointer actions only
    -Op window -Title "<substring>" -Action move|resize|minimize|restore|close [-Value "x,y" | "w,h"]
    -Op launch -Value <path, app name, document or URL> [-Arguments "..."]
    -Op clipboard [-Value text]    read the clipboard, or replace it with -Value
    -Op undo                       put back the latest type/check/uncheck/select of this process (the MCP or pi worker)
    -Op target -Ref eN | -Title "<substring>" | -Value <what launch would start>
                                   JSON: the app (exe name) an action would touch, its window and the ref's control; acts on nothing
    -Op watch                      internal: launch's background foreground watch (state in SIDEHAND_LAUNCH_WATCH)
    -Op indicator                  internal: the activity indicator with Stop (SidehandIndicator), one per desktop
  Run on the isolated desktop (isolated.ps1 sets SIDEHAND_ISOLATED), launch fails unless a window opens there,
  and act refuses refs of a window on another desktop.
  -Title is a handle from list.ps1 (0x...), an exact title, or else part of one (case-insensitive).
  Refs from the last tree/wait/ocr call are cached in %TEMP%\sidehand-uia[-<SIDEHAND_SESSION>].txt as UIA RuntimeIds.
  The engine (SidehandUia.cs, Import-UiaEngine in lib.ps1) is compiled once into %LOCALAPPDATA%\sidehand and reused.
  While the user has pressed Stop (%LOCALAPPDATA%\sidehand\stop-<desktop> exists) act, undo, window, launch and a
  clipboard write are refused; reads still work.
#>
[CmdletBinding()]
param(
  [ValidateSet('tree','wait','ocr','act','undo','window','launch','clipboard','watch','target','indicator')]
  [string]$Op = 'tree',
  [string]$Title = "",
  [int]$MaxNodes = 300,
  [switch]$Rects,
  [string]$Filter = "",
  [switch]$Gone,
  [int]$TimeoutMs = 10000,
  [string]$Ref = "",
  [ValidateSet('click','type','check','uncheck','select','expand','collapse','scroll','focus',
    'right-click','double-click','hover','wheel','drag','press','move','resize','minimize','restore','close')]
  [string]$Action = 'click',
  [string]$Value = "",
  [string]$Arguments = "",
  [switch]$Set,
  [switch]$AllowForeground
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib.ps1"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
# One file per session (SIDEHAND_SESSION, set by the MCP server and the pi extension), so agents
# running side by side never read each other's refs.
$cachePath = Join-Path $env:TEMP $(if ($env:SIDEHAND_SESSION) { "sidehand-uia-$($env:SIDEHAND_SESSION).txt" } else { 'sidehand-uia.txt' })

# Every acting operation leaves a line in the action log (Write-ActionLog in lib.ps1), failed ones too.
$acting = $Op -in 'act', 'undo', 'window', 'launch' -or ($Op -eq 'clipboard' -and $Set)
$logHwnd = [IntPtr]::Zero; $logPid = 0
function Write-OpLog([string]$err) {
  if (-not $acting) { return }
  $name = switch ($Op) { 'act' { $Action } 'window' { "window $Action" } 'clipboard' { 'clipboard set' } default { $Op } }
  $target = ''
  if ($Op -in 'act', 'undo' -and ('SidehandUia' -as [type])) { $script:logHwnd = [SidehandUia]::LastWindow; $target = [SidehandUia]::LastTarget }
  Write-ActionLog $name $logHwnd $target $(if ($Op -in 'act', 'clipboard') { $Value }) $err $logPid
}
trap { if ($acting) { Write-OpLog $_.Exception.Message }; break }

function Find-Window {
  if (-not $Title) { throw "$Op requires -Title" }
  Select-Window $Title
}

# Stop and the activity indicator: state shared by every Sidehand process on this desktop (the
# hidden-desktop test gets its own). SIDEHAND_INDICATOR=0 hides the indicator; Stop still holds.
# On the isolated desktop, the state of the user's desktop it was opened from (isolated.ps1).
$desk = if ($env:SIDEHAND_HOME_DESKTOP) { $env:SIDEHAND_HOME_DESKTOP } else { [SidehandNative]::DesktopName() }
$stateDir = Join-Path $env:LOCALAPPDATA 'sidehand'
$stopPath = Join-Path $stateDir "stop-$desk"
$activityPath = Join-Path $stateDir "activity-$desk.txt"
$indicatorMutex = "Local\SidehandIndicator-$desk"
$activity = $false
function Start-Indicator {
  # Started from the isolated desktop it would show there, unseen; an open one still shows its actions.
  if ($env:SIDEHAND_INDICATOR -eq '0' -or $env:SIDEHAND_ISOLATED) { return }
  $m = $null
  if ([Threading.Mutex]::TryOpenExisting($indicatorMutex, [ref]$m)) { $m.Dispose(); return }
  Start-Process powershell.exe -WindowStyle Hidden -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-Op', 'indicator'
}
# The indicator shows "Sidehand: <what>" until 3 s after the activity file's write time: a minute
# ahead while the action runs, set to now when it ends. Best effort: never fails the action.
# shortcut: one file per desktop, so two sessions acting at once show the latest text and hide 3 s after
# the first one ends; per-session files if that matters.
function Show-Activity([string]$what) {
  if ($env:SIDEHAND_INDICATOR -eq '0') { return }
  try {
    [void][IO.Directory]::CreateDirectory($stateDir)
    [IO.File]::WriteAllText($activityPath, $what)
    [IO.File]::SetLastWriteTimeUtc($activityPath, [DateTime]::UtcNow.AddMinutes(1))
    $script:activity = $true
    Start-Indicator
  } catch {}
}
function End-Activity { if ($activity) { try { [IO.File]::SetLastWriteTimeUtc($activityPath, [DateTime]::UtcNow) } catch {} } }
# target (the approval lookup before an act) too, so a stopped agent never puts a question to the user.
if (($acting -or $Op -eq 'target') -and (Test-Path -LiteralPath $stopPath)) {
  Start-Indicator # it may have been closed; the user needs its Resume
  throw 'The user pressed Stop in Sidehand. Ask the user before doing anything else.'
}

if ($Op -eq 'clipboard') {
  Assert-Unrestricted 'the clipboard'
  # The clipboard is shared with the user: reading is harmless, writing replaces what they copied.
  if ($Set) {
    Show-Activity 'set the clipboard'
    try { Set-Clipboard -Value $Value } finally { End-Activity }
    Write-OpLog
    "ok clipboard set ($($Value.Length) chars); this replaced the user's clipboard"
  }
  else { $c = Get-Clipboard -Raw; if ($null -eq $c) { '(clipboard holds no text)' } else { $c } }
  return
}
Import-UiaEngine
# Surface the engine's own message instead of PowerShell's "Exception calling ..." wrapper.
trap [System.Management.Automation.MethodInvocationException] { $m = $_.Exception.InnerException.Message; Write-OpLog $m; throw $m }
[SidehandUia]::LastWindow = [IntPtr]::Zero; [SidehandUia]::LastTarget = $null
# launch/watch: the window in front is the launched app's if it belongs to the new process or to an
# already running instance of the same exe (that one brings itself forward despite the lock). Any other
# window (Start, a credential prompt, an app the user opened) means the user switched: leave it alone.
$isOurs = {
  $h = [SidehandNative]::GetForegroundWindow(); $p = [uint32]0; [void][SidehandNative]::GetWindowThreadProcessId($h, [ref]$p)
  $p -ne 0 -and ($p -eq $appPid -or ((Get-Process -Id $p -ErrorAction SilentlyContinue).Path -eq $appPath))
}
# On the private isolated desktop any new window is the launched app's (a stub such as notepad.exe shows none of its own).
$findNew = { Get-WindowList | Where-Object { $before -notcontains $_.Handle -and ($appPid -eq 0 -or $env:SIDEHAND_ISOLATED -or $_.ProcessId -eq $appPid) } | Select-Object -First 1 }
# Every top-level window on this process's desktop, shown or not (for isolated.ps1's desktop, SIDEHAND_ISOLATED).
function Get-DesktopWindows {
  $all = New-Object System.Collections.Generic.List[IntPtr]
  [void][SidehandNative]::EnumWindows([SidehandNative+EnumProc]{ param($h, $l) $all.Add($h); $true }, [IntPtr]::Zero)
  $all
}
# The ref cache is shared with the worker on the user's desktop: refs of a window there are its to act on.
if ($env:SIDEHAND_ISOLATED -and $Op -in 'act', 'target' -and $Ref) {
  $refFile = if ($Ref -like '@*') { $SidehandPointsPath } else { $cachePath }
  if (Test-Path $refFile) {
    $h = [long](Get-Content $refFile -TotalCount 1)
    if (-not (Get-DesktopWindows | Where-Object { $_.ToInt64() -eq $h })) { $acting = $false; throw "the window of these refs is not on the isolated desktop" } # not an action: the user's worker takes it
  }
}
try {
  switch ($Op) {
    'tree' {
      $w = Find-Window
      [SidehandUia]::Tree($w.Handle.ToInt64(), $w.Title, $MaxNodes, [bool]$Rects, $Filter, $cachePath)
    }
    'ocr' {
      $w = Find-Window
      if ($w.Minimized) { throw "window is minimized; run window restore first (it puts the window back behind the user's windows without activating it)" }
      $h = $w.Handle
      $phys = New-Object SidehandNative+RECT; [void][SidehandNative]::GetWindowRect($h, [ref]$phys)
      # PrintWindow draws in the window's own DPI (a DPI-unaware app at 125% comes out at 80%), so size the shot in its terms.
      $old = [SidehandDpi]::SetThreadDpiAwarenessContext([SidehandDpi]::GetWindowDpiAwarenessContext($h))
      try { $own = New-Object SidehandNative+RECT; [void][SidehandNative]::GetWindowRect($h, [ref]$own) } finally { [void][SidehandDpi]::SetThreadDpiAwarenessContext($old) }
      $ow = $own.Right - $own.Left; $oh = $own.Bottom - $own.Top
      $shot = New-Object System.Drawing.Bitmap $ow, $oh
      $g = [System.Drawing.Graphics]::FromImage($shot); $hdc = $g.GetHdc()
      [void][SidehandNative]::PrintWindow($h, $hdc, 0x2) # PW_RENDERFULLCONTENT: DirectX and browser content too
      $g.ReleaseHdc($hdc); $g.Dispose()
      Add-Type -AssemblyName System.Runtime.WindowsRuntime
      $null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]
      $null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Foundation, ContentType = WindowsRuntime]
      $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
      if (-not $engine) { throw "Windows OCR has no language installed; add one with OCR in Settings > Time & language > Language" }
      # Windows OCR misreads small UI text ("SettIngs"); at twice the size it reads it right.
      $up = [Math]::Min(2, [Windows.Media.Ocr.OcrEngine]::MaxImageDimension / [Math]::Max($ow, $oh))
      $big = New-Object System.Drawing.Bitmap ([int]($ow * $up)), ([int]($oh * $up))
      $g = [System.Drawing.Graphics]::FromImage($big); $g.InterpolationMode = 'HighQualityBicubic'
      $g.DrawImage($shot, 0, 0, $big.Width, $big.Height); $g.Dispose(); $shot.Dispose()
      $ms = New-Object System.IO.MemoryStream; $big.Save($ms, [System.Drawing.Imaging.ImageFormat]::Bmp); $big.Dispose(); $ms.Position = 0
      $asTask = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' } | Select-Object -First 1
      $await = { param($op, [type]$t) $task = $asTask.MakeGenericMethod($t).Invoke($null, @($op)); [void]$task.Wait(-1); $task.Result }
      $decoder = & $await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync([System.IO.WindowsRuntimeStreamExtensions]::AsRandomAccessStream($ms))) ([Windows.Graphics.Imaging.BitmapDecoder])
      $bitmap = & $await ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
      $result = & $await ($engine.RecognizeAsync($bitmap)) ([Windows.Media.Ocr.OcrResult])
      $ms.Dispose()
      # Image pixels -> physical screen pixels, the unit of tree rects and of act.
      $k = ($phys.Right - $phys.Left) / $ow / $up
      $cache = New-Object System.Collections.Generic.List[string]; $cache.Add($h.ToInt64())
      $lines = foreach ($l in $result.Lines) {
        [double]$x1 = [double]::MaxValue; [double]$y1 = [double]::MaxValue; [double]$x2 = 0; [double]$y2 = 0
        foreach ($word in $l.Words) {
          $b = $word.BoundingRect
          $x1 = [Math]::Min($x1, [double]$b.X); $y1 = [Math]::Min($y1, [double]$b.Y)
          $x2 = [Math]::Max($x2, [double]$b.X + $b.Width); $y2 = [Math]::Max($y2, [double]$b.Y + $b.Height)
        }
        $id = "t$($cache.Count)"
        # The ref keeps the text's center relative to the window, so a window moved since still gets hit.
        $cache.Add("$id`t$([int](($x1 + $x2) / 2 * $k)),$([int](($y1 + $y2) / 2 * $k))`t$($l.Text)")
        "$id `"$($l.Text)`" @$($phys.Left + [int]($x1 * $k)),$($phys.Top + [int]($y1 * $k)) $([int](($x2 - $x1) * $k))x$([int](($y2 - $y1) * $k))"
      }
      [System.IO.File]::WriteAllLines($cachePath, $cache)
      "window: $($w.Title)  ($(@($lines).Count) text lines by OCR, $($engine.RecognizerLanguage.LanguageTag))"
      $lines
    }
    'wait' {
      if (-not $Filter) { throw "wait requires -Filter" }
      $w = Find-Window
      [SidehandUia]::Wait($w.Handle.ToInt64(), $w.Title, $Filter, [bool]$Gone, $TimeoutMs, $MaxNodes, $cachePath)
    }
    'window' {
      $w = Find-Window
      $logHwnd = $w.Handle
      Show-Activity "$Action $($w.Title)"
      [SidehandUia]::Window($w.Handle.ToInt64(), $w.Title, $Action, $Value)
    }
    'launch' {
      Assert-Unrestricted 'launching apps'
      if (-not $Value) { throw "launch requires -Value" }
      Show-Activity "launch $Value"
      $before = @(Get-WindowList | ForEach-Object { $_.Handle })
      $fg = New-Object 'SidehandUia+Foreground'
      $launchStart = Get-Date
      $appPid = $logPid = [SidehandUia]::Launch($Value, $Arguments)
      $new = $null
      $gaveBack = [SidehandUia]::LaunchGaveBack -gt 0
      $appPath = try { (Get-Command $Value -ErrorAction Stop).Source } catch { $Value }
      # Many apps bring themselves forward a moment after their window shows: a hidden PowerShell keeps
      # watching until 3 s after that, so this call returns once the window is there. Started now so it is
      # ready by then; the state goes through the environment, so nothing is quoted.
      # On the isolated desktop there is no user's window to protect.
      if (-not $env:SIDEHAND_ISOLATED) {
        $env:SIDEHAND_LAUNCH_WATCH = ConvertTo-Json -Compress @{ before = @($before | ForEach-Object { $_.ToInt64() }); user = $fg.Before.ToInt64(); since = $fg.Since; app = $appPid; path = $appPath }
        try { Start-Process powershell.exe -WindowStyle Hidden -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-Op', 'watch' }
        finally { Remove-Item Env:SIDEHAND_LAUNCH_WATCH }
      }
      # A packaged app (Windows 11 Notepad) on a fresh hidden desktop took about 15 s to show its window.
      $tries = if ($env:SIDEHAND_ISOLATED) { 40 } else { 20 }
      for ($i = 0; $i -lt $tries -and -not $new; $i++) {
        if ((& $isOurs) -and $fg.GiveBack($true)) { $gaveBack = $true }
        $new = & $findNew
        if (-not $new) { Start-Sleep -Milliseconds 500 }
      }
      if ($env:SIDEHAND_ISOLATED) {
        if (-not $new) {
          # A single-instance app (Edge, Office, ...) passes the request to its running instance and exits.
          $here = @(Get-DesktopWindows | ForEach-Object { $p = [uint32]0; [void][SidehandNative]::GetWindowThreadProcessId($_, [ref]$p); $p })
          $exe = [IO.Path]::GetFileNameWithoutExtension($appPath)
          # Only an instance that ran before this launch: a stub's own child (notepad.exe starts the packaged Notepad) is not one.
          $outside = @(Get-Process -Name $exe -ErrorAction SilentlyContinue | Where-Object { $here -notcontains $_.Id -and $(try { $_.StartTime -lt $launchStart } catch { $true }) })
          if ($outside.Count) { throw "not isolated: no window of $Value opened on the isolated desktop. $exe is already running outside it (pid $(($outside | ForEach-Object Id) -join ', ')): a single-instance app hands the request to that instance, so its window may be on the user's screen" }
          throw "not isolated: no window of $Value opened on the isolated desktop in 20 s (pid $appPid); if it is still starting, list_windows shows it later tagged [isolated]"
        }
        $logHwnd = $new.Handle
        "ok launched on the isolated desktop: $($new.Title) ($('0x{0:X8}' -f $new.Handle.ToInt64()))`nnote: it never shows on the user's screen; read it with tree, see it with capture window"
      } else {
        if ((& $isOurs) -and $fg.GiveBack($true)) { $gaveBack = $true }
        $name = if ($new) { $logHwnd = $new.Handle; $new.Title } else { $Value }
        $msg = if ($new) { "ok launched: $name" } else { "ok started $Value (pid $appPid); no new window yet" }
        if ([SidehandNative]::GetForegroundWindow() -ne $fg.Before -and (& $isOurs)) { $msg += "`nWARNING: the app took the foreground while starting" }
        elseif ($gaveBack) { $msg += "`nnote: $name came forward; the user's window was put back in front" }
        $msg + "`nnote: for 3 s more, a background watch puts the user's window back in front if $name comes forward"
      }
    }
    'watch' {
      $w = $env:SIDEHAND_LAUNCH_WATCH | ConvertFrom-Json
      $before = @($w.before | ForEach-Object { [IntPtr][long]$_ }); $appPid = $w.app; $appPath = $w.path
      $fg = New-Object 'SidehandUia+Foreground' -ArgumentList ([IntPtr][long]$w.user), ([uint32]$w.since)
      # Like launch: up to 10 s for the window, then 3 s more.
      $shown = $null
      for ($i = 0; $i -lt 52 -and ($null -eq $shown -or $i -lt $shown + 12); $i++) {
        if (& $isOurs) { [void]$fg.GiveBack($true) }
        if ($null -eq $shown -and (& $findNew)) { $shown = $i }
        Start-Sleep -Milliseconds 250
      }
    }
    'target' {
      # For the approval prompts of the MCP server and the pi extension (lib/approve.mjs).
      $t = @{}
      if ($Ref) {
        # A point (@x,y) names no control; its window is the one of the last capture.
        if ($Ref -like '@*') {
          if (-not (Test-Path $SidehandPointsPath)) { throw "no window capture to take point refs from; capture the window (mode window) first" }
          $t.type = 'point'; $t.control = $Ref; $h = [IntPtr][long](Get-Content $SidehandPointsPath -TotalCount 1)
        } else {
          $t.type, $t.control = [SidehandUia]::Describe($cachePath, $Ref) -split "`t", 2
          $h = [IntPtr][long](Get-Content $cachePath -TotalCount 1)
        }
        $sb = New-Object System.Text.StringBuilder 512; [void][SidehandNative]::GetWindowText($h, $sb, $sb.Capacity); $t.window = "$sb"
        $procId = [uint32]0; [void][SidehandNative]::GetWindowThreadProcessId($h, [ref]$procId)
      } elseif ($Title) {
        $w = Find-Window; $t.window = $w.Title; $procId = $w.ProcessId
      } else {
        Assert-Unrestricted 'launching apps'
        if (-not $Value) { throw "target requires -Ref, -Title or -Value" }
        # A URL or a document starts the program registered for it; anything else is the program (notepad, C:\x\app.exe).
        # shortcut: an App Paths alias whose process has another name (calc -> CalculatorApp.exe) is asked for again on its first act.
        $assoc = if ($Value -match '^([a-z][a-z0-9+.-]+):') { $Matches[1] } else { try { [IO.Path]::GetExtension($Value) } catch { '' } }
        $exe = if ($assoc -and $assoc -ne '.exe') { [SidehandUia]::AssocExe($assoc) } else { $Value }
        $t.app = if ($exe) { [IO.Path]::GetFileNameWithoutExtension($exe).ToLower() + '.exe' } elseif ($assoc -like '.*') { $assoc } else { "${assoc}:" }
      }
      if ($procId) { $t.app = (Get-Process -Id $procId).ProcessName.ToLower() + '.exe' }
      ConvertTo-Json -Compress $t
    }
    'act' {
      if (-not $Ref) { throw "act requires -Ref" }
      # A point ref (@x,y) is on the window of the last capture, any other ref on the last read window.
      $refFile = if ($Ref -like '@*') { $SidehandPointsPath } else { $cachePath }
      if ($SidehandAllow.Count -and (Test-Path $refFile)) {
        $h = [long](Get-Content $refFile -TotalCount 1)
        if (-not (Get-WindowList | Where-Object { $_.Handle.ToInt64() -eq $h })) { throw "that window is not in SIDEHAND_ALLOW; read an allowed window first" }
      }
      $target = New-Object System.Text.StringBuilder 256
      if (Test-Path $refFile) { [void][SidehandNative]::GetWindowText([IntPtr][long](Get-Content $refFile -TotalCount 1), $target, 256) }
      Show-Activity "$Action in $target"
      [SidehandUia]::Act($cachePath, $SidehandPointsPath, $Ref, $Action, $Value, [bool]$AllowForeground)
    }
    'undo' { Show-Activity 'undo'; [SidehandUia]::Undo() }
    'indicator' { [SidehandIndicator]::Run($indicatorMutex, $activityPath, $stopPath) }
  }
} finally { End-Activity }
Write-OpLog
