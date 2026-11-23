<#
  sidehand capture.ps1
  Modes:
    -Mode full                                    full virtual desktop
    -Mode region   -X N -Y N -W N -H N            screen coordinates region
    -Mode monitor  -Monitor N                     by monitor index (0-based)
    -Mode active                                  current foreground window
    -Mode window   -Title "<substring>"           window by title substring (PrintWindow; works for occluded)
  Common:
    -Out  <path>                                  output PNG (default: %LOCALAPPDATA%\sidehand\captures\sidehand.png)
    -BringToFront                                 restore + foreground before capture (window/active)
    -ShownMaxEdge N                               window mode: the caller shows the image downscaled to N px
                                                  on its long edge; point refs (@x,y) are then pixels of that
    -Json                                         emit JSON result line
#>
[CmdletBinding()]
param(
  [ValidateSet('full','region','monitor','active','window')]
  [string]$Mode = 'full',
  [int]$X = 0, [int]$Y = 0, [int]$W = 0, [int]$H = 0,
  [int]$Monitor = -1,
  [string]$Title = "",
  [string]$Out = "$env:LOCALAPPDATA\sidehand\captures\sidehand.png",
  [switch]$BringToFront,
  [int]$ShownMaxEdge = 0,
  [switch]$Json
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib.ps1"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Ensure-Dir $Out
$rx = 0; $ry = 0; $rw = 0; $rh = 0
$method = "BitBlt"
$matchedTitle = $null
$shown = @($null, $null)
# Points of an earlier window capture must not be taken for points of this image.
Remove-Item $SidehandPointsPath -ErrorAction SilentlyContinue

if ($Mode -in 'full', 'region', 'monitor') { Assert-Unrestricted "$Mode capture" }
switch ($Mode) {
  'full' {
    $vb = Get-VirtualScreenBounds
    $rx = $vb.X; $ry = $vb.Y; $rw = $vb.W; $rh = $vb.H
  }
  'region' {
    if ($W -le 0 -or $H -le 0) { throw "region mode requires -W and -H > 0" }
    $rx = $X; $ry = $Y; $rw = $W; $rh = $H
  }
  'monitor' {
    $screens = [System.Windows.Forms.Screen]::AllScreens
    if ($Monitor -lt 0 -or $Monitor -ge $screens.Count) {
      throw "monitor index $Monitor out of range (0..$($screens.Count - 1))"
    }
    $b = $screens[$Monitor].Bounds
    $rx = $b.X; $ry = $b.Y; $rw = $b.Width; $rh = $b.Height
  }
  'active' {
    $h = [SidehandNative]::GetForegroundWindow()
    if ($h -eq [IntPtr]::Zero) { throw "no foreground window" }
    if ($SidehandAllow.Count -and -not (Get-WindowList | Where-Object { $_.Handle -eq $h })) { throw "the foreground window is not in SIDEHAND_ALLOW" }
    if ($BringToFront) {
      [void][SidehandNative]::ShowWindow($h, 9)
      [void][SidehandNative]::SetForegroundWindow($h)
      Start-Sleep -Milliseconds 200
    }
    $r = Get-WindowRectDwm $h
    $rx = $r.Left; $ry = $r.Top; $rw = $r.Right - $r.Left; $rh = $r.Bottom - $r.Top
  }
  'window' {
    if (-not $Title) { throw "window mode requires -Title" }
    $match = Select-Window $Title
    $matchedTitle = $match.Title
    $hWnd = $match.Handle

    # Restoring a minimized window would pop it over the user's game or browser and take focus.
    if ($match.Minimized -and -not $BringToFront) { throw "window is minimized; run window restore first (it puts the window back behind the user's windows without activating it), or pass bring_to_front only if the user agreed" }
    if ($BringToFront) {
      [void][SidehandNative]::ShowWindow($hWnd, 9)
      [void][SidehandNative]::SetForegroundWindow($hWnd)
      Start-Sleep -Milliseconds 250
    }

    $r = Get-WindowRectDwm $hWnd
    $rw = $r.Right - $r.Left; $rh = $r.Bottom - $r.Top
    $rx = $r.Left; $ry = $r.Top
    if ($rw -le 0 -or $rh -le 0) { throw "window has zero size (minimized?)" }

    # PrintWindow w/ PW_RENDERFULLCONTENT (0x2) - captures occluded windows incl. Chrome/Edge
    $bmp = New-Object System.Drawing.Bitmap $rw, $rh
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $hdc = $g.GetHdc()
    $ok = [SidehandNative]::PrintWindow($hWnd, $hdc, 0x2)
    $g.ReleaseHdc($hdc); $g.Dispose()
    if (-not $ok) { Write-Warning "PrintWindow returned false (may be partially blank)" }
    $bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    $method = "PrintWindow"

    # Point refs: image pixel -> offset from the window's top-left (PrintWindow's origin) in physical
    # pixels. PrintWindow draws in the window's own DPI (a DPI-unaware app at 125% comes out at 80%),
    # and the caller may show the image downscaled (same arithmetic as edit.ps1 resize).
    $phys = New-Object SidehandNative+RECT; [void][SidehandNative]::GetWindowRect($hWnd, [ref]$phys)
    $old = [SidehandDpi]::SetThreadDpiAwarenessContext([SidehandDpi]::GetWindowDpiAwarenessContext($hWnd))
    try { $own = New-Object SidehandNative+RECT; [void][SidehandNative]::GetWindowRect($hWnd, [ref]$own) } finally { [void][SidehandDpi]::SetThreadDpiAwarenessContext($old) }
    $shown = @($rw, $rh)
    if ($ShownMaxEdge -gt 0 -and [Math]::Max($rw, $rh) -gt $ShownMaxEdge) {
      $r = $ShownMaxEdge / [double][Math]::Max($rw, $rh)
      $shown = @([int]($rw * $r), [int]($rh * $r))
    }
    $scale = ($phys.Right - $phys.Left) / [double]($own.Right - $own.Left) * $rw / $shown[0]
    [System.IO.File]::WriteAllLines($SidehandPointsPath, [string[]]@($hWnd.ToInt64(),
      "$($phys.Right - $phys.Left),$($phys.Bottom - $phys.Top)`t$($shown[0]),$($shown[1])`t$scale"))
  }
}

if ($Mode -ne 'window') {
  if ($rw -le 0 -or $rh -le 0) { throw "computed region is empty: ${rw}x${rh}" }
  $bmp = New-Object System.Drawing.Bitmap $rw, $rh
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($rx, $ry, 0, 0, (New-Object System.Drawing.Size $rw, $rh))
  $g.Dispose()
  $bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
}

$result = [pscustomobject]@{
  ok      = $true
  mode    = $Mode
  method  = $method
  x       = $rx; y = $ry; w = $rw; h = $rh
  out     = $Out
  title   = $matchedTitle
  shown_w = $shown[0]; shown_h = $shown[1]
}

if ($Json) { Write-Output (Write-Json $result) }
else { Write-Host ("OK mode={0} method={1} x={2} y={3} w={4} h={5} out={6}" -f $Mode, $method, $rx, $ry, $rw, $rh, $Out) }
