<#
  sidehand uia.ps1 - UI Automation text tree + ref actions (no pixels, no mouse, no focus change)
    -Op tree  -Title "<substring>" [-MaxNodes N] [-Rects] [-Filter text]   compact element tree with refs (e1, e2, ...)
    -Op wait  -Title "<substring>" -Filter text [-Gone] [-TimeoutMs N]     poll until an element line matches (or none does)
    -Op ocr   -Title "<substring>"         text lines read by Windows OCR, with refs (t1, t2, ...) for clicks
    -Op act   -Ref eN -Action click|type|check|uncheck|select|expand|collapse|scroll|focus
                      |right-click|double-click|hover|wheel|drag|press [-Value "..."] [-AllowForeground]
    -Op window -Title "<substring>" -Action move|resize|minimize|restore|close [-Value "x,y" | "w,h"]
    -Op launch -Value <path, app name, document or URL> [-Arguments "..."]
    -Op clipboard [-Value text]    read the clipboard, or replace it with -Value
    -Op watch                      internal: launch's background foreground watch (state in SIDEHAND_LAUNCH_WATCH)
  -Title is a handle from list.ps1 (0x...), an exact title, or else part of one (case-insensitive).
  Refs from the last tree/wait/ocr call are cached in %TEMP%\sidehand-uia[-<SIDEHAND_SESSION>].txt as UIA RuntimeIds.
  The engine (SidehandUia.cs, Import-UiaEngine in lib.ps1) is compiled once into %LOCALAPPDATA%\sidehand and reused.
#>
[CmdletBinding()]
param(
  [ValidateSet('tree','wait','ocr','act','window','launch','clipboard','watch')]
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

function Find-Window {
  if (-not $Title) { throw "$Op requires -Title" }
  Select-Window $Title
}

if ($Op -eq 'clipboard') {
  Assert-Unrestricted 'the clipboard'
  # The clipboard is shared with the user: reading is harmless, writing replaces what they copied.
  if ($Set) { Set-Clipboard -Value $Value; "ok clipboard set ($($Value.Length) chars); this replaced the user's clipboard" }
  else { $c = Get-Clipboard -Raw; if ($null -eq $c) { '(clipboard holds no text)' } else { $c } }
  return
}
Import-UiaEngine
# Surface the engine's own message instead of PowerShell's "Exception calling ..." wrapper.
trap [System.Management.Automation.MethodInvocationException] { throw $_.Exception.InnerException.Message }
# launch/watch: the window in front is the launched app's if it belongs to the new process or to an
# already running instance of the same exe (that one brings itself forward despite the lock). Any other
# window (Start, a credential prompt, an app the user opened) means the user switched: leave it alone.
$isOurs = {
  $h = [SidehandNative]::GetForegroundWindow(); $p = [uint32]0; [void][SidehandNative]::GetWindowThreadProcessId($h, [ref]$p)
  $p -ne 0 -and ($p -eq $appPid -or ((Get-Process -Id $p -ErrorAction SilentlyContinue).Path -eq $appPath))
}
$findNew = { Get-WindowList | Where-Object { $before -notcontains $_.Handle -and ($appPid -eq 0 -or $_.ProcessId -eq $appPid) } | Select-Object -First 1 }
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
    [SidehandUia]::Window($w.Handle.ToInt64(), $w.Title, $Action, $Value)
  }
  'launch' {
    Assert-Unrestricted 'launching apps'
    if (-not $Value) { throw "launch requires -Value" }
    $before = @(Get-WindowList | ForEach-Object { $_.Handle })
    $fg = New-Object 'SidehandUia+Foreground'
    $appPid = [SidehandUia]::Launch($Value, $Arguments)
    $new = $null
    $gaveBack = $false
    $appPath = try { (Get-Command $Value -ErrorAction Stop).Source } catch { $Value }
    # Many apps bring themselves forward a moment after their window shows: a hidden PowerShell keeps
    # watching until 3 s after that, so this call returns once the window is there. Started now so it is
    # ready by then; the state goes through the environment, so nothing is quoted.
    $env:SIDEHAND_LAUNCH_WATCH = ConvertTo-Json -Compress @{ before = @($before | ForEach-Object { $_.ToInt64() }); user = $fg.Before.ToInt64(); since = $fg.Since; app = $appPid; path = $appPath }
    try { Start-Process powershell.exe -WindowStyle Hidden -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-Op', 'watch' }
    finally { Remove-Item Env:SIDEHAND_LAUNCH_WATCH }
    for ($i = 0; $i -lt 20 -and -not $new; $i++) {
      if ((& $isOurs) -and $fg.GiveBack($true)) { $gaveBack = $true }
      $new = & $findNew
      if (-not $new) { Start-Sleep -Milliseconds 500 }
    }
    if ((& $isOurs) -and $fg.GiveBack($true)) { $gaveBack = $true }
    $name = if ($new) { $new.Title } else { $Value }
    $msg = if ($new) { "ok launched: $name" } else { "ok started $Value (pid $appPid); no new window yet" }
    if ([SidehandNative]::GetForegroundWindow() -ne $fg.Before -and (& $isOurs)) { $msg += "`nWARNING: the app took the foreground while starting" }
    elseif ($gaveBack) { $msg += "`nnote: $name came forward; the user's window was put back in front" }
    $msg + "`nnote: for 3 s more, a background watch puts the user's window back in front if $name comes forward"
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
  'act' {
    if (-not $Ref) { throw "act requires -Ref" }
    if ($SidehandAllow.Count -and (Test-Path $cachePath)) {
      $h = [long](Get-Content $cachePath -TotalCount 1)
      if (-not (Get-WindowList | Where-Object { $_.Handle.ToInt64() -eq $h })) { throw "that window is not in SIDEHAND_ALLOW; read an allowed window first" }
    }
    [SidehandUia]::Act($cachePath, $Ref, $Action, $Value, [bool]$AllowForeground)
  }
}
