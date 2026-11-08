# Runs inside the hidden test desktop (started by run.ps1). One action per fresh target window,
# with a decoy window standing in for the user's app, so every activation is attributable.
param([string]$Work, [string]$Repo, [string]$AgentDesktop = '', [string]$Cua = '')
$ErrorActionPreference = 'Stop'
trap { ($_ | Out-String) + $_.ScriptStackTrace | Set-Content -Encoding UTF8 (Join-Path $Work 'error.txt'); exit 1 }
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
$uia = Join-Path $Repo 'scripts\uia.ps1'
# Own refs and own processes only: another test run may be going on at the same time.
$env:SIDEHAND_SESSION = Split-Path $Work -Leaf
$results = New-Object System.Collections.Generic.List[object]

function Tick { [DateTime]::UtcNow.Ticks }

function Start-App([string]$exe, [string]$role, [string]$log) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo (Join-Path $Work $exe), "$role `"$log`""
  $psi.UseShellExecute = $false
  $p = [System.Diagnostics.Process]::Start($psi)
  for ($i = 0; $i -lt 100 -and $p.MainWindowHandle -eq [IntPtr]::Zero; $i++) { Start-Sleep -Milliseconds 100; $p.Refresh() }
  $p
}

# Native tools report refusals on stderr; collect them as output instead of stopping the run.
function Native([string]$exe, [string[]]$argv) { $ErrorActionPreference = 'Continue'; (& $exe @argv 2>&1 | ForEach-Object { "$_" }) -join "`n" }
function Sidehand([string[]]$argv) { Native 'powershell.exe' (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $uia) + $argv) }

function AdFind($node, [string]$role, [string]$name) {
  if ($node.role -eq $role -and ($name -eq '' -or $node.name -eq $name) -and $node.ref_id) { return $node.ref_id }
  foreach ($c in $node.children) { $r = AdFind $c $role $name; if ($r) { return $r } }
}

# Cua Driver: a private daemon on its own pipe, killed with the job. JSON goes through stdin
# because Windows PowerShell strips the quotes from JSON arguments.
$cuaSock = '\\.\pipe\sidehand-test-cua'
if ($Cua) { Start-Process $Cua -ArgumentList "serve --socket $cuaSock" -WindowStyle Hidden; Start-Sleep 3 }
function CuaCall([string]$tool, [hashtable]$a) { $ErrorActionPreference = 'Continue'; ((ConvertTo-Json $a -Compress) | & $Cua call $tool --socket $cuaSock 2>&1 | ForEach-Object { "$_" }) -join "`n" }

$apps = @{
  WinForms = @{ exe = 'TestWinForms.exe'; title = 'Sidehand Test WinForms' }
  WPF      = @{ exe = 'TestWpf.exe'; title = 'Sidehand Test WPF target' }
  Drawn    = @{ exe = 'TestWinForms.exe'; title = 'Sidehand Test Drawn' }
}
# tool, app, label, sidehand line regex | agent-desktop role/name, action, value, expected app event
$cases = @(
  @('sidehand', 'WinForms', 'type', 'Edit "Name"', 'type', 'hello', 'text len=5'),
  @('sidehand', 'WinForms', 'click', 'Button "Apply"', 'click', '', 'apply.click'),
  @('sidehand', 'WinForms', 'check', 'CheckBox "Enable"', 'check', '', 'check True'),
  @('sidehand', 'WinForms', 'select list item', 'List "Items"', 'select', 'Two', 'list Two'),
  @('sidehand', 'WinForms', 'select combo item', 'ComboBox "Mode"', 'select', 'Beta', 'combo Beta'),
  # An item only in another window of the same app (role "twin") must not be selected: an expandable
  # element without it sends select looking through the app's top-level windows (for Chromium popups).
  @('sidehand', 'WinForms', 'select item of another window refused', 'TreeItem "Root"', 'select', 'Elsewhere', 'other.list Elsewhere'),
  @('sidehand', 'WinForms', 'expand tree item', 'TreeItem "Root"', 'expand', '', 'tree.expand'),
  @('sidehand', 'WinForms', 'focus without consent', 'Edit "Name"', 'focus', '', ''),
  @('sidehand', 'WinForms', 'focus with consent (control)', 'Edit "Name"', 'focus+', '', ''),
  @('sidehand', 'WPF', 'type', 'Edit "Name"', 'type', 'hello', 'text len=5'),
  @('sidehand', 'WPF', 'click', 'Button "Apply"', 'click', '', 'apply.click'),
  @('sidehand', 'WPF', 'check', 'CheckBox "Enable"', 'check', '', 'check True'),
  @('sidehand', 'WPF', 'select list item', 'List "Items"', 'select', 'Two', 'list Two'),
  @('sidehand', 'WPF', 'expand tree item', 'TreeItem "Root"', 'expand', '', 'tree.expand'),
  # Posted input, window management and launching.
  @('sidehand', 'WinForms', 'press Enter', 'Edit "Name"', 'press', 'Enter', 'key Return'),
  @('sidehand', 'WinForms', 'press ctrl+a', 'Edit "Name"', 'press', 'ctrl+a', 'key A ctrl'),
  # Every key lands once, shifted and non-ASCII characters included ([char]0xAC00 is Hangul "ga"):
  # a doubled or garbled key never produces this text.
  @('sidehand', 'WinForms', 'press characters', 'Edit "Name"', 'press', "B @ space x Backspace $([char]0xAC00)", "text=B@ $([char]0xAC00)"),
  @('sidehand', 'WinForms', 'right-click', 'Pane "Pad"', 'right-click', '', 'rightclick'),
  @('sidehand', 'WinForms', 'double-click', 'Pane "Pad"', 'double-click', '', 'dblclick'),
  @('sidehand', 'WinForms', 'mouse wheel', 'Pane "Pad"', 'wheel', 'down', 'wheel -120'),
  @('sidehand', 'WinForms', 'hover', 'Pane "Pad"', 'hover', '', 'hover None'),
  @('sidehand', 'WinForms', 'drag', 'Pane "Pad"', 'drag', '0,60', 'drag'),
  # Custom-drawn text has no controls: read it with OCR, act on the t-ref at the text's center.
  @('sidehand', 'Drawn', 'OCR click', '"Save report"', 'click', '', 'drawn.click Save report'),
  @('sidehand', 'Drawn', 'OCR double-click', '"Export"', 'double-click', '', 'drawn.dblclick Export'),
  @('sidehand', 'Drawn', 'OCR right-click', '"Settings"', 'right-click', '', 'drawn.rightclick Settings'),
  @('sidehand', 'Drawn', 'OCR hover', '"Open file"', 'hover', '', 'drawn.hover Open file'),
  @('sidehand', 'Drawn', 'OCR wheel', '"Settings"', 'wheel', 'down 2', 'drawn.wheel -240 Settings'),
  # A quoted value is another text on the window: its t-ref is the drop target.
  @('sidehand', 'Drawn', 'OCR drag to a t-ref', '"Open file"', 'drag', '"Export"', 'drawn.drag Open file -> Export'),
  # WPF ignores posted mouse input and takes keys only when focused: keys must be refused.
  @('sidehand', 'WPF', 'press without consent refused', 'Edit "Name"', 'press', 'Enter', ''),
  # ...except where UI Automation does the same: wheel scrolls the nearest ScrollPattern (here the
  # item's list), double-click and Enter run the element's Invoke. Right-click has no such route.
  @('sidehand', 'WPF', 'mouse wheel (scroll)', 'ListItem "Row 1"', 'wheel', 'down 3', 'rows.scroll'),
  @('sidehand', 'WPF', 'double-click (default action)', 'DataItem "report.txt"', 'double-click', '', 'grid.edit report.txt'),
  @('sidehand', 'WPF', 'press Enter on a button', 'Button "Apply"', 'press', 'Enter', 'apply.click'),
  @('sidehand', 'WPF', 'right-click refused', 'Text "Pad"', 'right-click', '', 'contextmenu'),
  @('sidehand', 'WinForms', 'window minimize', '', 'window:minimize', '', 'state Minimized'),
  @('sidehand', 'WinForms', 'window move', '', 'window:move', '30,40', 'moved'),
  @('sidehand', 'WinForms', 'launch an app', '', 'launch', '', 'shown')
)
if ($AgentDesktop) {
  $cases += @(
    @('agent-desktop', 'WinForms', 'type', 'textfield|', 'set-value', 'hello', 'text len=5'),
    @('agent-desktop', 'WinForms', 'click', 'button|Apply', 'click', '', 'apply.click'),
    @('agent-desktop', 'WinForms', 'check', 'checkbox|Enable', 'check', '', 'check True'),
    @('agent-desktop', 'WinForms', 'expand tree item', 'treeitem|Root', 'expand', '', 'tree.expand'),
    @('agent-desktop', 'WPF', 'type', 'textfield|', 'set-value', 'hello', 'text len=5'),
    @('agent-desktop', 'WPF', 'click', 'button|Apply', 'click', '', 'apply.click')
  )
}

if ($Cua) {
  $cases += @(
    @('cua-driver', 'WinForms', 'type (set_value)', 'Edit|Name', 'set_value', 'hello', 'text len=5'),
    @('cua-driver', 'WinForms', 'type (type_text)', 'Edit|Name', 'type_text', 'hello', 'text len=5'),
    @('cua-driver', 'WinForms', 'click', 'Button|Apply', 'click', '', 'apply.click'),
    @('cua-driver', 'WinForms', 'check', 'CheckBox|Enable', 'click', '', 'check True'),
    @('cua-driver', 'WPF', 'type (set_value)', 'Edit|Name', 'set_value', 'hello', 'text len=5'),
    @('cua-driver', 'WPF', 'click', 'Button|Apply', 'click', '', 'apply.click')
  )
}

$n = 0
foreach ($c in $cases) {
  $n++
  $tool, $appName, $label, $find, $action, $value, $expect = $c
  $app = $apps[$appName]
  $log = Join-Path $Work "case$n.log"
  $target = Start-App $app.exe $(if ($label -like '*another window*') { 'twin' } elseif ($appName -eq 'Drawn') { 'drawn' } else { 'target' }) $log
  Start-Sleep -Milliseconds 700
  $decoy = Start-App 'TestWinForms.exe' 'decoy' $log
  Start-Sleep -Milliseconds 800
  try {
    if ($action -like 'window:*') {
      $argv = @('-Op', 'window', '-Title', $app.title, '-Action', $action.Substring(7))
      if ($value) { $argv += @('-Value', $value) }
    } elseif ($action -eq 'launch') {
      # A second copy that, like most apps, activates itself when it opens.
      try { $target.Kill() } catch {}
      $argv = @('-Op', 'launch', '-Value', (Join-Path $Work 'TestWinForms.exe'), '-Arguments', "launched `"$log`"")
    } elseif ($tool -eq 'sidehand') {
      # A freshly started drawn window may not be painted yet when OCR reads it: read again briefly.
      for ($try = 0; $try -lt 3; $try++) {
        $tree = Sidehand @('-Op', $(if ($appName -eq 'Drawn') { 'ocr' } else { 'tree' }), '-Title', $app.title)
        if ($tree -match "(?m)^\s*([et]\d+) $([regex]::Escape($find))" -or $appName -ne 'Drawn') { break }
        Start-Sleep -Milliseconds 700
      }
      $ref = if ($tree -match "(?m)^\s*([et]\d+) $([regex]::Escape($find))") { $Matches[1] } else { 'e0' }
      if ($value -like '"*' -and $tree -match "(?m)^\s*(t\d+) $([regex]::Escape($value))") { $value = $Matches[1] }
      $argv = @('-Op', 'act', '-Ref', $ref, '-Action', $action.TrimEnd('+'))
      if ($value) { $argv += @('-Value', $value) }
      if ($action.EndsWith('+')) { $argv += '-AllowForeground' }
    } elseif ($tool -eq 'cua-driver') {
      $role, $name = $find.Split('|')
      $hwnd = $target.MainWindowHandle.ToInt64()
      for ($try = 0; $try -lt 8; $try++) {
        $raw = CuaCall 'get_window_state' @{ pid = $target.Id; window_id = $hwnd; include_screenshot = $false }
        $state = try { $raw.Substring($raw.IndexOf('{')) | ConvertFrom-Json } catch { $null } # the daemon may still be starting
        $el = $state.elements | Where-Object { $_.role -eq $role -and $_.label -eq $name } | Select-Object -First 1
        if ($el) { break }
        Start-Sleep -Milliseconds 800
      }
      $cuaArgs = @{ pid = $target.Id; window_id = $hwnd }
      if ($action -ne 'type_text') { $cuaArgs.element_token = $el.element_token }
      if ($value) { if ($action -eq 'type_text') { $cuaArgs.text = $value } else { $cuaArgs.value = $value } }
    } else {
      $role, $name = $find.Split('|')
      # WPF can answer the first snapshot before its automation peers exist; retry briefly.
      for ($try = 0; $try -lt 4; $try++) {
        $snap = & $AgentDesktop snapshot --app $app.exe --window-id ('w-' + $target.MainWindowHandle.ToInt64()) -i | Out-String | ConvertFrom-Json
        $ref = AdFind $snap.data.tree $role $name
        if ($ref) { break }
        Start-Sleep -Milliseconds 800
      }
    }
    $t0 = Tick; $sw = [Diagnostics.Stopwatch]::StartNew()
    $out = if ($tool -eq 'sidehand') { Sidehand $argv }
           elseif ($tool -eq 'cua-driver') { CuaCall $action $cuaArgs }
           elseif ($value) { Native $AgentDesktop @($action, $ref, $value) }
           else { Native $AgentDesktop @($action, $ref) }
    $ms = $sw.ElapsedMilliseconds
    Start-Sleep -Milliseconds 500 # late activation messages still land inside this case
    $results.Add([pscustomobject]@{ n = $n; tool = $tool; app = $appName; label = $label; expect = $expect; t0 = $t0; t1 = (Tick); ms = $ms; log = $log; output = $out.Trim() })
  } finally {
    foreach ($p in $target, $decoy) { try { $p.Kill() } catch {} }
    Get-Process TestWinForms -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne $decoy.Id -and $_.Path -like "$Work\*" } | Stop-Process -Force -ErrorAction SilentlyContinue
  }
}
$results | ConvertTo-Json -Depth 3 | Set-Content -Encoding UTF8 (Join-Path $Work 'results.json')
Remove-Item (Join-Path $env:TEMP "sidehand-uia-$env:SIDEHAND_SESSION.txt") -ErrorAction SilentlyContinue
