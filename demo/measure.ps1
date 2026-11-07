<#
  Measures on the REAL desktop what the background actions do to the user: whether the foreground
  window changes and whether the mouse cursor moves, for WinForms, browser content (Edge) and an
  Electron app (VS Code).
  A Notes window holds the foreground the whole time; run only while nobody uses the PC (~3 min).

    powershell -ExecutionPolicy Bypass -File demo\measure.ps1 [-Out C:\tmp\sidehand-measure]
#>
param([string]$Out = "$env:TEMP\sidehand-measure")
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
Add-Type -AssemblyName System.Windows.Forms
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).ProviderPath
$node = (Get-Command node.exe).Source
$cli = Join-Path $repo 'bin\sidehand.mjs'
$uia = Join-Path $repo 'scripts\uia.ps1'
if (Test-Path $Out) { Remove-Item -Recurse -Force $Out }
New-Item -ItemType Directory -Force -Path $Out | Out-Null
. "$PSScriptRoot\harness.ps1"

$fw = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319"
& "$fw\csc.exe" /nologo /target:winexe "/out:$Out\DemoApps.exe" /r:System.Windows.Forms.dll /r:System.Drawing.dll "$PSScriptRoot\DemoApps.cs"
& "$fw\csc.exe" /nologo /target:winexe "/out:$Out\TestWinForms.exe" /r:System.Windows.Forms.dll /r:System.Drawing.dll "$repo\test\isolated\TestWinForms.cs"
& "$fw\csc.exe" /nologo /target:winexe "/out:$Out\TestWpf.exe" "/r:$fw\WPF\PresentationFramework.dll" "/r:$fw\WPF\PresentationCore.dll" "/r:$fw\WPF\WindowsBase.dll" "/r:$fw\System.Xaml.dll" "$repo\test\isolated\TestWpf.cs"
Copy-Item "$repo\test\isolated\page.html" "$Out\page.html"
$log = "$Out\apps.log"; $vlog = "$Out\verify.log"

$result = [ordered]@{ aborted = $false; reason = ''; last_case = ''; rows = @() }
try {
  [Rec]::Init()
  $W = [Rec]::ScreenW(); $H = [Rec]::ScreenH()
  # Notes bottom right, out of the way of the test windows.
  [void][Rec]::Launch(("`"$Out\DemoApps.exe`" notes {0} {1} 700 420 `"{2}`" `"{3}`"" -f ($W - 740), ($H - 520), $log, "$Out\t.txt"))
  $notes = Window 'Your note'
  [Rec]::Notes = $notes.MainWindowHandle
  $browser = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
  if ($browser) {
    [void][Rec]::Launch("`"$browser`" --user-data-dir=`"$Out\edge`" --no-first-run --no-default-browser-check --force-renderer-accessibility --window-position=1100,40 --window-size=820,640 --new-window `"file:///$($Out.Replace('\','/'))/page.html`"")
    for ($i = 0; $i -lt 60 -and -not [Rec]::FindPrefix('Sidehand Web Test'); $i++) { Start-Sleep -Milliseconds 250 }
  }
  $code = "$env:LOCALAPPDATA\Programs\Microsoft VS Code\Code.exe"
  if (Test-Path $code) {
    [void][Rec]::Launch("`"$code`" --user-data-dir `"$Out\vscode`" --extensions-dir `"$Out\vscode-ext`" --new-window --disable-workspace-trust --force-renderer-accessibility")
    for ($i = 0; $i -lt 80 -and -not [Rec]::FindPrefix('Welcome - Visual Studio Code'); $i++) { Start-Sleep -Milliseconds 250 }
    Start-Sleep 3
    $vs = [Rec]::Find([Rec]::FindPrefix('Welcome - Visual Studio Code'))
    if ($vs -ne [IntPtr]::Zero) { [void](& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $uia -Op window -Title 'Welcome - Visual Studio Code' -Action move -Value '40,500') }
  }
  Start-Sleep 2

  $wf = @('TestWinForms.exe', 'Sidehand Test WinForms'); $wpf = @('TestWpf.exe', 'Sidehand Test WPF target')
  $web = @('', 'Sidehand Web Test'); $vsc = @('', 'Welcome - Visual Studio Code')
  # app, label, element line, action, value, (unused), expected effect (app event, title token or output text)
  $cases = @(
    @($wf, 'right-click', 'Pane "Pad"', 'right-click', '', $false, 'rightclick'),
    @($wf, 'double-click', 'Pane "Pad"', 'double-click', '', $false, 'dblclick'),
    @($wf, 'press ctrl+a', 'Edit "Name"', 'press', 'ctrl+a', $false, 'key A ctrl'),
    @($wf, 'launch an app', '', 'launch', '', $false, 'shown')
  )
  if ($browser) {
    $cases += @(
      @($web, 'type', 'Edit "Name"', 'type', 'hello', $false, 'input'),
      @($web, 'click', 'Button "Apply"', 'click', '', $false, 'apply'),
      @($web, 'check', 'CheckBox "Enable"', 'check', '', $false, 'checktrue'),
      @($web, 'double-click', 'Button "Pad"', 'double-click', '', $false, 'dblclick'),
      @($web, 'right-click', 'Button "Pad"', 'right-click', '', $false, 'rightclick'),
    )
  }
  if (Test-Path $code) { $cases += ,@($vsc, 'click', 'TabItem "Search[^"]*"', 'click', '', $false, 'selected') }

  foreach ($c in $cases) {
    Assert-NotAborted
    $app, $label, $find, $action, $value, $pointer, $expect = $c
    $exe, $title = $app
    $result.last_case = "$title $label"
    if ([Rec]::GetForegroundWindow() -ne [Rec]::Notes -and -not [Rec]::ForceForeground([Rec]::Notes)) { throw 'Notes lost the foreground and could not get it back' }
    if ($exe) { [void][Rec]::Launch(("`"$Out\$exe`" target `"$vlog`" {0}" -f [Rec]::Notes.ToInt64())); [void](Window $title); Start-Sleep -Milliseconds 800 }
    $fullTitle = [Rec]::FindPrefix($title)
    $before = $fullTitle
    if ($action -eq 'launch') {
      $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $uia, '-Op', 'launch', '-Value', "$Out\TestWinForms.exe", '-Arguments', "launched `"$vlog`"")
    } else {
      $tree = UiTree $fullTitle
      $ref = RefRx $tree $find
    }
    $cursor = [System.Windows.Forms.Cursor]::Position
    [Rec]::Armed = $true
    $t0 = [DateTime]::UtcNow.Ticks; $sw = [Diagnostics.Stopwatch]::StartNew()
    $o = if ($action -eq 'launch') { $ErrorActionPreference = 'Continue'; (& powershell.exe @argv 2>&1 | ForEach-Object { "$_" }) -join ' ' }
         elseif (-not $ref) { "no ref for $find" }
         else { UiAct $ref $action $value }
    $ms = $sw.ElapsedMilliseconds
    Start-Sleep -Milliseconds 900
    [Rec]::Armed = $false
    $notesPid = [Rec]::PidOf([Rec]::Notes)
    $moved = @([Rec]::FgSince($t0) | Where-Object { $_[1] -ne $notesPid } | ForEach-Object { (Get-Process -Id $_[1] -ErrorAction SilentlyContinue).ProcessName }) | Select-Object -Unique
    $events = @(Get-Content -Encoding UTF8 $vlog -ErrorAction SilentlyContinue | ForEach-Object { $tk, $r2, $e = $_ -split "`t", 3; if ([long]$tk -ge $t0) { $e } })
    $after = [Rec]::FindPrefix($title)
    # The test page appends every event to its title: "Sidehand Web Test | input apply ... - <browser>".
    $tokens = { param($t) if ($t -match '\|([^-]*)') { @($Matches[1].Trim() -split ' ' | Where-Object { $_ -eq $expect }).Count } else { 0 } }
    $effect = if ($exe) { $events -contains $expect } elseif ($title -eq 'Sidehand Web Test') { (& $tokens $after) -gt (& $tokens $before) } else { $o -match $expect }
    $result.rows += [pscustomobject]@{ app = $(if ($exe) { $exe.Replace('Test', '').Replace('.exe', '') } else { $title }); action = $label; took_effect = [bool]$effect
      foreground_moved_to = ($moved -join ','); cursor_moved = ([System.Windows.Forms.Cursor]::Position -ne $cursor); ms = $ms; output = $(if ($o.Length -gt 140) { $o.Substring(0, 140) } else { $o }) }
    if ($exe) { Get-Process ($exe.Replace('.exe', '')) -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 300
  }
} catch {
  $result.aborted = $true; $result.reason = $_.Exception.Message
} finally {
  [Rec]::Close()
}
Start-Sleep 2
Remove-Item -Recurse -Force "$Out\edge", "$Out\vscode", "$Out\vscode-ext" -ErrorAction SilentlyContinue
$result | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 "$Out\result.json"
Get-Content -Raw "$Out\result.json"
