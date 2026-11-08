# Runs inside the hidden test desktop (run.ps1 -Bench). For each app and each tool: read the window
# three times (raw output and time per read), then do one full task (the Contoso order form) with
# every tool. Raw outputs go to $Work\bench; bench_score.py turns them into numbers.
param([string]$Work, [string]$Repo, [string]$AgentDesktop = '', [string]$Cua = '')
$ErrorActionPreference = 'Stop'
trap { ($_ | Out-String) + $_.ScriptStackTrace | Set-Content -Encoding UTF8 (Join-Path $Work 'error.txt'); exit 1 }
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
$uia = Join-Path $Repo 'scripts\uia.ps1'
. (Join-Path $Repo 'scripts\lib.ps1')
$out = Join-Path $Work 'bench'
New-Item -ItemType Directory -Force -Path $out | Out-Null

function Native([string]$exe, [string[]]$argv) { $ErrorActionPreference = 'Continue'; (& $exe @argv 2>&1 | ForEach-Object { "$_" }) -join "`n" }
function Sidehand([string[]]$argv) { Native 'powershell.exe' (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $uia) + $argv) }
$cuaSock = '\\.\pipe\sidehand-bench-cua'
if ($Cua) { Start-Process $Cua -ArgumentList "serve --socket $cuaSock" -WindowStyle Hidden; Start-Sleep 3 }
function CuaCall([string]$tool, [hashtable]$a) { $ErrorActionPreference = 'Continue'; ((ConvertTo-Json $a -Compress) | & $Cua call $tool --socket $cuaSock 2>&1 | ForEach-Object { "$_" }) -join "`n" }
function Save([string]$name, [string]$text) { [IO.File]::WriteAllText((Join-Path $out $name), $text, (New-Object Text.UTF8Encoding $false)) }

function WaitWindow([string]$like, [int]$sec = 40) {
  for ($i = 0; $i -lt $sec * 4; $i++) {
    $w = Get-WindowList | Where-Object { $_.Title -like $like } | Select-Object -First 1
    if ($w) { Start-Sleep -Milliseconds 1500; return (Get-WindowList | Where-Object { $_.Handle -eq $w.Handle } | Select-Object -First 1) }
    Start-Sleep -Milliseconds 250
  }
  throw "no window like $like"
}

$log = Join-Path $Work 'apps.log'
$edge = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
$code = "$env:LOCALAPPDATA\Programs\Microsoft VS Code\Code.exe"
# name, title pattern, start command, arguments, agent-desktop app name
$apps = @(
  @('winforms', 'Sidehand Test WinForms', "$Work\TestWinForms.exe", "target `"$log`"", 'TestWinForms.exe'),
  @('wpf', 'Sidehand Test WPF target', "$Work\TestWpf.exe", "target `"$log`"", 'TestWpf.exe'),
  @('orders', 'Contoso Orders', "$Work\DemoApps.exe", "orders 40 40 900 600 `"$log`" `"$Work\t.txt`"", 'DemoApps.exe'),
  @('charmap', '*', "$env:WINDIR\System32\charmap.exe", '', 'charmap.exe'),
  @('msinfo32', '*', "$env:WINDIR\System32\msinfo32.exe", '', 'msinfo32.exe')
)
if ($edge) { $apps += ,@('edge', 'Sidehand Web Test*', $edge, "--user-data-dir=`"$Work\edge`" --no-first-run --no-default-browser-check --force-renderer-accessibility --new-window `"file:///$($Work.Replace('\','/'))/page.html`"", 'msedge.exe') }
if (Test-Path $code) { $apps += ,@('vscode', 'Welcome - Visual Studio Code', $code, "--user-data-dir `"$Work\vscode`" --extensions-dir `"$Work\vscode-ext`" --new-window --disable-workspace-trust --force-renderer-accessibility", 'Code.exe') }

$times = [ordered]@{}
foreach ($a in $apps) {
  $name, $like, $exe, $argv, $adApp = $a
  $before = @(Get-WindowList | ForEach-Object { $_.Handle })
  $p = if ($argv) { Start-Process $exe -ArgumentList $argv -PassThru } else { Start-Process $exe -PassThru }
  if ($like -eq '*') {
    # A system app: take the first new window of its process.
    $w = $null
    for ($i = 0; $i -lt 120 -and -not $w; $i++) { Start-Sleep -Milliseconds 250; $w = Get-WindowList | Where-Object { $before -notcontains $_.Handle -and $_.ProcessId -eq $p.Id } | Select-Object -First 1 }
    if (-not $w) { continue }
    Start-Sleep 2
  } else { $w = WaitWindow $like }
  if ($name -eq 'vscode') { Start-Sleep 4 }
  $h = $w.Handle.ToInt64(); $wpid = [int]$w.ProcessId
  $times[$name] = [ordered]@{ title = $w.Title }
  foreach ($tool in 'sidehand', 'agent-desktop', 'cua-tree', 'cua-default') {
    if ($tool -eq 'agent-desktop' -and -not $AgentDesktop) { continue }
    if ($tool -like 'cua*' -and -not $Cua) { continue }
    $ms = @()
    for ($n = 1; $n -le 3; $n++) {
      $sw = [Diagnostics.Stopwatch]::StartNew()
      $o = switch ($tool) {
        'sidehand' { Sidehand @('-Op', 'tree', '-Title', $w.Title) }
        'agent-desktop' { Native $AgentDesktop @('snapshot', '--app', $adApp, '--window-id', "w-$h", '-i', '--compact') }
        'cua-tree' { CuaCall 'get_window_state' @{ pid = $wpid; window_id = $h; include_screenshot = $false } }
        'cua-default' { CuaCall 'get_window_state' @{ pid = $wpid; window_id = $h } }
      }
      $ms += $sw.ElapsedMilliseconds
      if ($n -eq 1) { Save "$name.$tool.txt" $o }
    }
    $times[$name][$tool] = $ms
  }
}

# One full task per tool on a fresh order form: read, fill four fields, submit, read the result.
function AdFind($node, [string]$role, [string]$nm) {
  if ($node.role -eq $role -and ($nm -eq '' -or $node.name -eq $nm) -and $node.ref_id) { return $node.ref_id }
  foreach ($c in $node.children) { $r = AdFind $c $role $nm; if ($r) { return $r } }
}
$task = [ordered]@{}
foreach ($tool in 'sidehand', 'agent-desktop', 'cua-driver') {
  if ($tool -eq 'agent-desktop' -and -not $AgentDesktop) { continue }
  if ($tool -eq 'cua-driver' -and -not $Cua) { continue }
  Get-Process DemoApps -ErrorAction SilentlyContinue | Stop-Process -Force
  $tlog = Join-Path $Work "task-$tool.log"
  $p = Start-Process "$Work\DemoApps.exe" -ArgumentList "orders 40 40 900 600 `"$tlog`" `"$Work\t.txt`"" -PassThru
  $w = WaitWindow 'Contoso Orders'
  $h = $w.Handle.ToInt64(); $wpid = [int]$w.ProcessId
  $steps = New-Object System.Collections.Generic.List[string]
  $sw = [Diagnostics.Stopwatch]::StartNew()
  if ($tool -eq 'sidehand') {
    $t = Sidehand @('-Op', 'tree', '-Title', 'Contoso Orders'); $steps.Add($t)
    function RefOf([string]$rx) { if ($t -match "(?m)^\s*(e\d+) $rx") { $Matches[1] } }
    $steps.Add((Sidehand @('-Op', 'act', '-Ref', (RefOf 'Edit "Customer"'), '-Action', 'type', '-Value', 'Blue-B Studio')))
    $steps.Add((Sidehand @('-Op', 'act', '-Ref', (RefOf 'Edit "Quantity"'), '-Action', 'type', '-Value', '3')))
    $steps.Add((Sidehand @('-Op', 'act', '-Ref', (RefOf 'ComboBox "Region"'), '-Action', 'select', '-Value', 'Jeju')))
    $steps.Add((Sidehand @('-Op', 'act', '-Ref', (RefOf 'CheckBox "Express shipping"'), '-Action', 'check')))
    $steps.Add((Sidehand @('-Op', 'act', '-Ref', (RefOf 'Button "Submit order"'), '-Action', 'click')))
    $steps.Add((Sidehand @('-Op', 'wait', '-Title', 'Contoso Orders', '-Filter', 'Order submitted')))
  } elseif ($tool -eq 'agent-desktop') {
    $t = Native $AgentDesktop @('snapshot', '--app', 'DemoApps.exe', '--window-id', "w-$h", '-i', '--compact'); $steps.Add($t)
    $tree = ($t | ConvertFrom-Json).data.tree
    $edits = @(); function Walk($n) { if ($n.role -eq 'textfield' -and $n.ref_id) { $script:edits += $n.ref_id }; foreach ($c in $n.children) { Walk $c } }; Walk $tree
    $steps.Add((Native $AgentDesktop @('set-value', $edits[0], 'Blue-B Studio')))
    $steps.Add((Native $AgentDesktop @('set-value', $edits[1], '3')))
    $steps.Add((Native $AgentDesktop @('select', (AdFind $tree 'combobox' 'Region'), 'Jeju')))
    $steps.Add((Native $AgentDesktop @('check', (AdFind $tree 'checkbox' 'Express shipping'))))
    $steps.Add((Native $AgentDesktop @('click', (AdFind $tree 'button' 'Submit order'))))
    $steps.Add((Native $AgentDesktop @('snapshot', '--app', 'DemoApps.exe', '--window-id', "w-$h", '--compact')))
  } else {
    $t = CuaCall 'get_window_state' @{ pid = $wpid; window_id = $h; include_screenshot = $false }; $steps.Add($t)
    $els = ($t.Substring($t.IndexOf('{')) | ConvertFrom-Json).elements
    function Tok([string]$role, [string]$label) { ($els | Where-Object { $_.role -eq $role -and $_.label -eq $label } | Select-Object -First 1).element_token }
    $base = @{ pid = $wpid; window_id = $h }
    $steps.Add((CuaCall 'set_value' ($base + @{ element_token = (Tok 'Edit' 'Customer'); value = 'Blue-B Studio' })))
    $steps.Add((CuaCall 'set_value' ($base + @{ element_token = (Tok 'Edit' 'Quantity'); value = '3' })))
    $steps.Add((CuaCall 'set_value' ($base + @{ element_token = (Tok 'ComboBox' 'Region'); value = 'Jeju' })))
    $steps.Add((CuaCall 'click' ($base + @{ element_token = (Tok 'CheckBox' 'Express shipping') })))
    $steps.Add((CuaCall 'click' ($base + @{ element_token = (Tok 'Button' 'Submit order') })))
    $steps.Add((CuaCall 'get_window_state' ($base + @{ include_screenshot = $false })))
  }
  $ms = $sw.ElapsedMilliseconds
  Start-Sleep -Milliseconds 800
  $status = Sidehand @('-Op', 'tree', '-Title', 'Contoso Orders', '-Filter', 'Order submitted')
  $events = @(Get-Content -Encoding UTF8 $tlog -ErrorAction SilentlyContinue | ForEach-Object { ($_ -split "`t", 3)[-1] })
  Save "task.$tool.txt" ($steps -join "`n=====`n")
  $task[$tool] = [ordered]@{ ms = $ms; calls = $steps.Count; status = ($status -split "`n" | Select-Object -Last 1).Trim()
    activations = @($events | Where-Object { $_ -eq 'form.activated' -or $_ -like 'focus+*' }).Count }
  try { $p.Kill() } catch {}
}

[ordered]@{ reads = $times; task = $task } | ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 (Join-Path $out 'bench.json')
