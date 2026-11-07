<#
  Records the README demo on the REAL desktop and then measures, on that same real desktop, which
  actions take the foreground. Run it only while nobody is using the PC (3-5 minutes).

    powershell -ExecutionPolicy Bypass -File demo\record.ps1 [-Out C:\tmp\sidehand-demo] [-NoVerify] [-Recordly]

  The demo: three apps sit behind the user's note. Three agents (demo/agent.mjs, each its own
  sidehand process) fill them in at the same time while simulated keystrokes and mouse moves go to
  the note. A live view shows the covered windows (PrintWindow) with each agent's pointer and text
  caret. At the end the "user" clicks the windows forward to show the result.

  -Recordly records the whole screen with Recordly (https://www.recordly.dev, installed, not running)
  and exports an MP4 in its wallpaper frame. Its editor preferences are backed up and restored.
  Recordly captures the physical monitor, so check the take before you publish it.

  Safety:
  - every process it starts is in a kill-on-close job, so nothing outlives the script
  - simulated keystrokes go only to the demo's Notes window; mouse input only while a demo window is in front
  - if any window outside the job takes the foreground (someone used the PC), it stops at once
  - the stage covers the desktop behind the demo windows
#>
# -DryRun: no foreground, capture or real input, for rehearsing on a hidden desktop. -Preview (with
# -DryRun) saves frames rebuilt from PrintWindow into $Out\frames, two per second.
param([string]$Out = "$env:TEMP\sidehand-demo", [switch]$NoVerify, [switch]$DryRun, [switch]$Preview, [switch]$Recordly, [string]$Wallpaper = 'glassmorphism-4.jpg', [string]$Cua = '', [int]$X = 80, [int]$Y = 60, [ValidateSet('en', 'ko')][string]$Lang = 'en')
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).ProviderPath
$node = (Get-Command node.exe).Source
$uia = Join-Path $repo 'scripts\uia.ps1'
$adCmd = Get-Command agent-desktop -ErrorAction SilentlyContinue
# Cua Driver only when passed explicitly (-Cua <exe>): its telemetry opens a console window per call.
$cuaExe = if ($Cua -and (Test-Path $Cua)) { $Cua } else { $null }
$recordlyExe = "$env:LOCALAPPDATA\Programs\recordly\Recordly.exe"
$recordlySettings = "$env:APPDATA\Recordly\app-settings.json"
if ($Recordly -and (Get-Process Recordly -ErrorAction SilentlyContinue)) { throw 'Recordly is already running; close it first so the script does not touch your session' }
if (Test-Path $Out) { Remove-Item -Recurse -Force $Out }
New-Item -ItemType Directory -Force -Path "$Out\frames", "$Out\events" | Out-Null

. "$PSScriptRoot\harness.ps1"

$fw = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319"
& "$fw\csc.exe" /nologo /target:winexe "/out:$Out\DemoApps.exe" /r:System.Windows.Forms.dll /r:System.Drawing.dll "$PSScriptRoot\DemoApps.cs"
& "$fw\csc.exe" /nologo /target:winexe "/out:$Out\TestWinForms.exe" /r:System.Windows.Forms.dll /r:System.Drawing.dll "$repo\test\isolated\TestWinForms.cs"
& "$fw\csc.exe" /nologo /target:winexe "/out:$Out\TestWpf.exe" "/r:$fw\WPF\PresentationFramework.dll" "/r:$fw\WPF\PresentationCore.dll" "/r:$fw\WPF\WindowsBase.dll" "/r:$fw\System.Xaml.dll" "$repo\test\isolated\TestWpf.cs"

$ev = "$Out\events"; $log = "$Out\apps.log"
# -Lang ko: the apps, the live view and the captions in Korean (DemoApps.cs and agent.mjs read the same variable).
$env:SIDEHAND_DEMO_LANG = $Lang
function L([string]$en, [string]$ko) { if ($Lang -eq 'ko') { $ko } else { $en } }
function Caption([string]$main, [string]$sub = '') { [IO.File]::WriteAllText("$ev\caption.txt", "$main`n$sub", (New-Object Text.UTF8Encoding $false)) }
$rxStop = 'Button "(Stop|중지)"$'
$editor = 'Recordly ' # the editor window; the recording HUD is titled just "Recordly"
function Start-RecordlyRecording {
  [void][Rec]::Launch("`"$recordlyExe`" --force-renderer-accessibility")
  # Record -> (source list) Screen 1 -> Record, until the HUD shows Stop.
  for ($i = 0; $i -lt 6; $i++) {
    $r = WaitRef 'Recordly' { param($t)
      if (RefRx $t $rxStop) { 'recording' }
      elseif ($x = RefRx $t 'Button "Screen 1[^"]*(Screen|화면)"$') { $x }
      else { RefRx $t 'Button "(Record|녹화)"$' } } 40
    if ($r[0] -eq 'recording') { return }
    [void](UiAct $r[0] 'click')
    Start-Sleep -Milliseconds 1200
  }
  throw 'Recordly did not start recording'
}
function Stop-RecordlyRecording {
  $r = WaitRef 'Recordly' { param($t) RefRx $t $rxStop } 20
  [void](UiAct $r[0] 'click')
  [void](WaitRef $editor { param($t) RefRx $t 'Button "(Export|내보내기)"$' } 120)
}
function Export-Recordly([string]$format, [string]$path) {
  if (Test-Path $path) { Remove-Item $path }
  $r = WaitRef $editor { param($t) RefRx $t 'Button "(Export|내보내기)"$' } 30
  if ($r[1] -notmatch 'Menu "(Export|내보내기)"') { [void](UiAct $r[0] 'click') } # open the export menu
  $r = WaitRef $editor { param($t) RefExact $t $format } 20
  if ($r[1] -notmatch "(?m)^\s*$($r[0]) \S+ `"$format`" \[On\]") { [void](UiAct $r[0] 'click'); Start-Sleep -Milliseconds 800 }
  $r = WaitRef $editor { param($t) RefRx $t 'Button "(Export (Video|MP4|GIF)|(Video|MP4|GIF) 내보내기)"' } 20
  [void](UiAct $r[0] 'click')
  # Recordly renders, then opens a native save dialog; sidehand fills it in with window messages.
  $end = (Get-Date).AddSeconds(900); $dlg = $null
  while (-not $dlg -and (Get-Date) -lt $end) { $dlg = [Rec]::FindPrefix('Save Exported'); if (-not $dlg) { Start-Sleep -Milliseconds 500 } }
  if (-not $dlg) { throw "no save dialog for $format" }
  $r = WaitRef $dlg { param($t) RefRx $t 'Edit "(File name:|파일 이름:)"' } 20
  [void](UiAct $r[0] 'type' $path)
  $r = WaitRef $dlg { param($t) RefRx $t 'Button "(&?Save|저장\(S\))"$' } 10
  [void](UiAct $r[0] 'click')
  $end = (Get-Date).AddSeconds(900); $last = -1
  while ((Get-Date) -lt $end) {
    Start-Sleep -Seconds 2
    if (Test-Path $path) { $size = (Get-Item $path).Length; if ($size -gt 0 -and $size -eq $last) { return $size }; $last = $size }
  }
  throw "export did not finish: $path"
}

$result = [ordered]@{ aborted = $false; reason = ''; last_case = ''; demo = $null; verify = @() }
try {
  [Rec]::Init()
  if ($Recordly) {
    $W = [Rec]::ScreenW(); $H = [Rec]::ScreenH(); $X = 0; $Y = 0
    Copy-Item $recordlySettings "$Out\recordly-settings.backup.json"
    $settings = Get-Content -Raw -Encoding UTF8 $recordlySettings | ConvertFrom-Json
    $pref = $settings.'recordly.editor.preferences'
    # The real mouse pointer is part of the story (it stays with the user), so Recordly shows it.
    $pref.wallpaper = "/wallpapers/$Wallpaper"; $pref.showCursor = $true; $pref.autoApplyFreshRecordingAutoZooms = $false
    [IO.File]::WriteAllText($recordlySettings, ($settings | ConvertTo-Json -Depth 30), (New-Object Text.UTF8Encoding $false))
  } else { $W = 1920; $H = 1080 }
  # Same proportions at any resolution: forms are 1.5x at 1440p, so they stay readable after the
  # recording is framed and downscaled.
  $env:SIDEHAND_DEMO_ZOOM = [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0:0.###}', $H / 1440 * 1.5 * 96 / [Rec]::Dpi())
  # Left half: three apps cascaded behind the note, their title bars showing. Right half: live view.
  $g = [int]($W * 0.016); $top = [int]($H * 0.10); $split = [int]($W * 0.50)
  $dx = [int]($W * 0.022); $dy = [int]($H * 0.036); $aw = [int]($W * 0.31); $ah = [int]($H * 0.50)
  $nx = $X + $g + 3 * $dx; $ny = $Y + $top + 3 * $dy
  $spec = @(
    @('stage', $X, $Y, $W, $H, ''),
    @('orders', ($X + $g), ($Y + $top), $aw, $ah, (L 'Contoso Orders' 'Contoso 주문')),
    @('expense', ($X + $g + $dx), ($Y + $top + $dy), $aw, $ah, (L 'Expense report' '경비 보고서')),
    @('mail', ($X + $g + 2 * $dx), ($Y + $top + 2 * $dy), $aw, $ah, (L 'New message - Mail' '새 메일')),
    @('notes', $nx, $ny, ($X + $split - $nx), ($Y + $H - $g - $ny), (L 'Your note' '내 메모')),
    @('live', ($X + $split + $g), ($Y + $top), ($W - $split - 2 * $g), ($H - $top - $g), '')
  )
  $wins = @{}; $at = @{}
  foreach ($s in $spec) {
    [void][Rec]::Launch(("`"$Out\DemoApps.exe`" {0} {1} {2} {3} {4} `"{5}`" `"{6}`"" -f $s[0], $s[1], $s[2], $s[3], $s[4], $log, $ev))
    $at[$s[0]] = $s
    # The stage and the live view have no taskbar entry; just give them a moment.
    if (-not $s[5]) { Start-Sleep -Milliseconds 600 } else { $wins[$s[0]] = Window $s[5] }
  }
  foreach ($r in 'orders', 'expense', 'mail', 'notes') { [Rec]::ToTop($wins[$r].MainWindowHandle) }
  [Rec]::Notes = $wins.notes.MainWindowHandle
  # Compile and warm the UIA engine before the agents start three at once (read-only).
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $uia -Op tree -Title $at.orders[5] -Filter 'zzz' | Out-Null
  if ($Recordly) { Start-RecordlyRecording; Start-Sleep -Milliseconds 1500 }
  if (-not $DryRun -and -not [Rec]::ForceForeground([Rec]::Notes)) { throw 'could not put the Notes window in front' }
  [Rec]::Armed = $true
  if (-not $DryRun -and -not $Recordly) { [Rec]::StartCapture($X, $Y, $W, $H, "$Out\frames", 15) }
  if ($DryRun -and $Preview) { [Rec]::StartPreview("$Out\frames", 2) }
  $mx = $nx + [int](($X + $split - $nx) * 0.5); $my = $ny + [int](($Y + $H - $ny) * 0.32)
  if (-not $DryRun) { [Rec]::Glide($mx, $my, 600) }
  Caption (L 'Three apps are open behind your note.' '내 메모 뒤에 앱 3개가 열려 있어요.') (L 'Each colored title bar is one app. Your note is in front, and it has your keyboard.' '색깔 제목 표시줄 하나가 앱 하나예요. 맨 앞의 메모가 키보드를 가지고 있어요.')
  Start-Sleep -Milliseconds 3000

  $demoStart = [DateTime]::UtcNow.Ticks
  [Rec]::StartStats("$ev\stats.txt", "$log.notes.txt")
  $typed = L 'Notes for Monday: three agents are filling in the windows behind this note while I keep writing it. My keyboard and mouse never leave this window.' '월요일 메모: 에이전트 셋이 이 메모 뒤의 창들을 채우는 동안 나는 계속 이 글을 쓴다. 내 키보드와 마우스는 이 창을 떠나지 않는다. 주문서와 경비 보고서와 메일이 끝나면 창을 하나씩 열어서 확인해 볼 생각이다.'
  [Rec]::StartTyping($typed, 80, [bool]$DryRun)
  Caption (L 'Three AI agents fill them in at the same time, while you keep typing.' 'AI 에이전트 3개가 동시에 채우는 동안, 나는 계속 메모를 써요.') (L 'Each agent has its own pointer and text cursor (right). Your keyboard and mouse stay with you (left).' '에이전트마다 자기 포인터와 입력 커서가 있어요(오른쪽). 내 키보드와 마우스는 그대로 내 것이에요(왼쪽).')
  $agents = @()
  $i = 0
  foreach ($name in 'orders', 'expense', 'mail') {
    $i++
    $agents += [Rec]::Launch("`"$node`" `"$repo\demo\agent.mjs`" $name `"$ev\agent$i.txt`" $(($i - 1) * 400)")
  }
  # The user's hand on the mouse: slow moves inside the note while the agents work.
  $end = (Get-Date).AddSeconds(90); $k = 0
  while ((Get-Date) -lt $end -and (@($agents | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue }).Count -or [Rec]::Typed -lt $typed.Length)) {
    Assert-NotAborted
    $k++
    if ($DryRun) { Start-Sleep -Milliseconds 1500 } else { [Rec]::Glide($mx + [int](140 * [Math]::Sin($k * 1.7)), $my + [int](70 * [Math]::Cos($k * 1.1)), 1300); Start-Sleep -Milliseconds 500 }
  }
  Assert-NotAborted
  Start-Sleep -Milliseconds 1200
  [Rec]::StopStats()
  $changes = @([Rec]::FgSince($demoStart)).Count
  $notesText = Get-Content -Raw -Encoding UTF8 "$log.notes.txt" -ErrorAction SilentlyContinue
  $got = if ($notesText) { $notesText.Length } else { 0 }

  # The user brings each window forward with a real click on its title bar, last one first.
  Caption (L 'Now click the windows behind your note.' '이제 메모 뒤의 창을 클릭해 볼게요.') (L 'They were filled in while they stayed behind it.' '창이 가려진 채로 내용이 다 채워졌어요.')
  Start-Sleep -Milliseconds 1500
  foreach ($r in 'mail', 'expense', 'orders') {
    Assert-NotAborted
    $s = $at[$r]; $cx = $s[1] + [int]($s[3] * 0.35); $cy = $s[2] + [int]($dy * 0.3)
    if ($DryRun) { [Rec]::ToTop($wins[$r].MainWindowHandle) } else { [Rec]::Glide($cx, $cy, 800); [Rec]::Click($cx, $cy) }
    Start-Sleep -Milliseconds 2200
  }
  Caption (L "Three apps done from behind your note. $changes interruptions." "메모 뒤에서 앱 3개를 끝냈어요. 방해 ${changes}번.") (L "$got of $($typed.Length) of your keystrokes reached your note, and no window jumped in front of you while you typed." "내가 친 $($typed.Length)자 중 ${got}자가 메모에 들어갔고, 입력하는 동안 앞으로 튀어나온 창은 없었어요.")
  if ($changes) { Caption (L "Three apps done from behind your note, but the foreground changed $changes times." "메모 뒤에서 앱 3개를 끝냈지만, 맨 앞 창이 ${changes}번 바뀌었어요.") (L "$got of $($typed.Length) of your keystrokes reached your note." "내가 친 $($typed.Length)자 중 ${got}자가 메모에 들어갔어요.") }
  Start-Sleep -Milliseconds 4500
  [Rec]::StopCapture()
  [Rec]::StopTyping()
  $agentResults = foreach ($n in 1..3) {
    $lines = @(Get-Content -Encoding UTF8 "$ev\agent$n.txt" -ErrorAction SilentlyContinue)
    [ordered]@{ agent = $n; done = ($lines -contains 'done'); last = (@($lines | Where-Object { $_ -like "state`t*" }) | Select-Object -Last 1) }
  }
  $result.demo = [ordered]@{ frames = [Rec]::Frames; focus_changes = $changes; typed_chars = [Rec]::Typed; notes_received_chars = $got; notes_matches_typed = ($notesText -eq $typed.Substring(0, [Rec]::Typed)); agents = @($agentResults) }
  [Rec]::Armed = $false
  if ($Recordly) {
    Stop-RecordlyRecording
    # While the stage still covers the screen: Recordly renders the take into its wallpaper frame.
    $result.demo.recordly_mp4_bytes = Export-Recordly 'MP4' "$Out\sidehand-demo.mp4"
  }

  if (-not $NoVerify) {
    # Same real desktop, Notes in front, one fresh background target per action, three tools.
    $wf = @('TestWinForms.exe', 'Sidehand Test WinForms'); $wpf = @('TestWpf.exe', 'Sidehand Test WPF target')
    # tool, app, action label, element (sidehand line | role|name), tool action, value, expected app event
    $cases = @()
    foreach ($app in $wf, $wpf) {
      $cases += ,@('sidehand', $app, 'type', 'Edit "Name"', 'type', 'hello', 'text len=5')
      $cases += ,@('sidehand', $app, 'click', 'Button "Apply"', 'click', '', 'apply.click')
      $cases += ,@('sidehand', $app, 'check', 'CheckBox "Enable"', 'check', '', 'check True')
      $cases += ,@('sidehand', $app, 'select list item', 'List "Items"', 'select', 'Two', 'list Two')
      $cases += ,@('sidehand', $app, 'expand tree item', 'TreeItem "Root"', 'expand', '', 'tree.expand')
    }
    if ($adCmd) {
      foreach ($app in $wf, $wpf) {
        $cases += ,@('agent-desktop', $app, 'type', 'textfield|', 'set-value', 'hello', 'text len=5')
        $cases += ,@('agent-desktop', $app, 'click', 'button|Apply', 'click', '', 'apply.click')
        $cases += ,@('agent-desktop', $app, 'check', 'checkbox|Enable', 'check', '', 'check True')
        $cases += ,@('agent-desktop', $app, 'expand tree item', 'treeitem|Root', 'expand', '', 'tree.expand')
      }
    }
    if ($cuaExe) {
      foreach ($app in $wf, $wpf) {
        $cases += ,@('cua-driver', $app, 'type', 'Edit|Name', 'set_value', 'hello', 'text len=5')
        $cases += ,@('cua-driver', $app, 'click', 'Button|Apply', 'click', '', 'apply.click')
        $cases += ,@('cua-driver', $app, 'check', 'CheckBox|Enable', 'click', '', 'check True')
        $cases += ,@('cua-driver', $app, 'expand tree item', 'TreeItem|Root', 'click', 'expand', 'tree.expand')
      }
    }
    function AdFind($node, [string]$role, [string]$name) {
      if ($node.role -eq $role -and ($name -eq '' -or $node.name -eq $name) -and $node.ref_id) { return $node.ref_id }
      foreach ($c in $node.children) { $r = AdFind $c $role $name; if ($r) { return $r } }
    }
    # Cua Driver: a private daemon on its own pipe inside the job. JSON goes through stdin because
    # Windows PowerShell strips the quotes from JSON arguments.
    $cuaSock = '\\.\pipe\sidehand-demo-cua'
    if ($cuaExe) { [void][Rec]::Launch("`"$cuaExe`" serve --socket $cuaSock"); Start-Sleep 3 }
    function CuaCall([string]$tool, [hashtable]$a) { $ErrorActionPreference = 'Continue'; ((ConvertTo-Json $a -Compress) | & $cuaExe call $tool --socket $cuaSock 2>&1 | ForEach-Object { "$_" }) -join "`n" }
    $vlog = "$Out\verify.log"
    foreach ($c in $cases) {
      Assert-NotAborted
      $tool, $app, $label, $find, $action, $value, $expect = $c
      $exe, $title = $app
      $result.last_case = "$tool $exe $label"
      if (-not $DryRun -and [Rec]::GetForegroundWindow() -ne [Rec]::Notes -and -not [Rec]::ForceForeground([Rec]::Notes)) { throw 'Notes lost the foreground and could not get it back' }
      [void][Rec]::Launch(("`"$Out\$exe`" target `"$vlog`" {0}" -f [Rec]::Notes.ToInt64()))
      $target = Window $title
      Start-Sleep -Milliseconds 800
      # Cua Driver restores "the previous foreground" after some actions; with the PC idle, a foreign
      # window coming forward during its cases is recorded as its effect instead of aborting the run.
      [Rec]::Armed = ($tool -ne 'cua-driver')
      if ($tool -eq 'sidehand') {
        $tree = UiTree $title
        $ref = if ($tree -match "(?m)^\s*(e\d+) $([regex]::Escape($find))") { $Matches[1] } else { 'e0' }
        $run = { UiAct $ref $action $value }
      } elseif ($tool -eq 'cua-driver') {
        $role, $name = $find.Split('|')
        $hwnd = $target.MainWindowHandle.ToInt64()
        for ($try = 0; $try -lt 8; $try++) {
          $raw = CuaCall 'get_window_state' @{ pid = [int]$target.Id; window_id = $hwnd; include_screenshot = $false }
          $state = try { $raw.Substring($raw.IndexOf('{')) | ConvertFrom-Json } catch { $null }
          $el = $state.elements | Where-Object { $_.role -eq $role -and $_.label -eq $name } | Select-Object -First 1
          if ($el) { break }
          Start-Sleep -Milliseconds 800
        }
        $cuaArgs = @{ pid = [int]$target.Id; window_id = $hwnd; element_token = $el.element_token }
        if ($action -eq 'set_value') { $cuaArgs.value = $value } elseif ($value) { $cuaArgs.action = $value }
        $run = { CuaCall $action $cuaArgs }
      } else {
        $role, $name = $find.Split('|')
        for ($try = 0; $try -lt 4; $try++) {
          $snap = (& $adCmd.Source snapshot --app $exe --window-id ('w-' + $target.MainWindowHandle.ToInt64()) -i) -join "`n" | ConvertFrom-Json
          $ref = AdFind $snap.data.tree $role $name
          if ($ref) { break }
          Start-Sleep -Milliseconds 800
        }
        $argv = @($action, $ref); if ($value) { $argv += $value }
        $run = { $ErrorActionPreference = 'Continue'; (& $adCmd.Source @argv 2>&1 | ForEach-Object { "$_" }) -join ' ' }
      }
      $t0 = [DateTime]::UtcNow.Ticks; $sw = [Diagnostics.Stopwatch]::StartNew()
      $o = "$(& $run)"
      $ms = $sw.ElapsedMilliseconds
      Start-Sleep -Milliseconds 800
      $targetPid = [uint32]$target.Id
      $stole = [bool](@([Rec]::FgSince($t0)) | Where-Object { $_[1] -eq $targetPid })
      $notesPid = [Rec]::PidOf([Rec]::Notes)
      $others = @([Rec]::FgSince($t0) | Where-Object { $_[1] -ne $targetPid -and $_[1] -ne $notesPid } | ForEach-Object { (Get-Process -Id $_[1] -ErrorAction SilentlyContinue).ProcessName }) | Select-Object -Unique
      $events = @(Get-Content -Encoding UTF8 $vlog -ErrorAction SilentlyContinue | ForEach-Object { $tk, $role2, $e = $_ -split "`t", 3; if ([long]$tk -ge $t0) { $e } })
      [Rec]::Armed = $false
      $result.verify += [pscustomobject]@{ tool = $tool; app = $exe.Replace('Test', '').Replace('.exe', ''); action = $label; took_effect = ($events -contains $expect); took_foreground = $stole; other_foreground = ($others -join ','); ms = $ms; output = $(if ($o.Length -gt 160) { $o.Substring(0, 160) } else { $o }) }
      Stop-Process -Id $target.Id -Force -ErrorAction SilentlyContinue
      Start-Sleep -Milliseconds 300
    }
  }
} catch {
  $result.aborted = $true; $result.reason = $_.Exception.Message
} finally {
  [Rec]::StopTyping()
  [Rec]::Close()
  if (Test-Path "$Out\recordly-settings.backup.json") { Copy-Item "$Out\recordly-settings.backup.json" $recordlySettings -Force }
}
$result | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 "$Out\result.json"
Get-Content -Raw "$Out\result.json"
