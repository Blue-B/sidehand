<#
  Same task, four tools, on the REAL desktop: while the user keeps typing in a note, each tool fills
  in an order form that sits behind the note (demo/compare-task.mjs does it the way each tool's own
  instructions say). Measures what the user notices: the window that comes to the front, the real
  cursor moving, the seconds their note had no keyboard, and whether the order went through.
  Run it only while nobody is using the PC (about 3 minutes).

    powershell -ExecutionPolicy Bypass -File demo\compare.ps1 [-Out C:\tmp\sidehand-compare] [-Tools sidehand,terminator]

  Needs: agent-desktop (npm), npx (Terminator: terminator-mcp-agent), uvx (Windows-MCP).
  claude and chatgpt are computer use in the Claude and ChatGPT desktop apps (open, signed in, computer
  use switched on): the script asks the app the way a user would (paste the request, Enter), goes back
  to the note, and measures until the order is submitted (8 minutes at most). Their permission prompts
  are approved through sidehand.
  Safety: a full-screen backdrop covers the desktop so a misplaced click lands on it; every process
  is in a kill-on-close job; the simulated keystrokes go only to the note; if a window outside the
  job takes the foreground (someone used the PC), it stops.
#>
# -DryRun: no foreground and no real keystrokes, for rehearsing on a hidden desktop.
param([string]$Out = "$env:TEMP\sidehand-compare", [string[]]$Tools = @('sidehand', 'agent-desktop', 'terminator', 'windows-mcp'), [switch]$DryRun,
  [string]$ClaudeTitle = 'Claude', [string]$ChatGptTitle = 'ChatGPT')
$ErrorActionPreference = 'Stop'
$Tools = @($Tools | ForEach-Object { $_ -split ',' }) # -File passes "a,b" as one string
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).ProviderPath
$node = (Get-Command node.exe).Source
$uia = Join-Path $repo 'scripts\uia.ps1'
if (Test-Path $Out) { Remove-Item -Recurse -Force $Out }
New-Item -ItemType Directory -Force -Path $Out | Out-Null
. "$PSScriptRoot\harness.ps1"
$fw = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319"
& "$fw\csc.exe" /nologo /target:winexe "/out:$Out\DemoApps.exe" /r:System.Windows.Forms.dll /r:System.Drawing.dll "$PSScriptRoot\DemoApps.cs"
Copy-Item "$Out\DemoApps.exe" "$Out\Orders.exe" # its own process name, for tools that scope by process
$log = "$Out\apps.log"
Add-Type -AssemblyName System.Windows.Forms
$agentApps = @{ claude = $ClaudeTitle; chatgpt = $ChatGptTitle }
$ask = 'Use computer use (control the screen; no shell commands or scripts). In the open Windows app window titled "Contoso Orders", fill in Customer: Blue-B Studio, Quantity: 3, Region: Jeju, tick Express shipping, then click Submit order. Do not touch any other window.'
function Status { ((& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $uia -Op tree -Title 'Contoso Orders' -Filter 'Order' 2>&1) -join "`n") }

$result = [ordered]@{ aborted = $false; reason = ''; runs = @() }
try {
  [Rec]::Init()
  $W = [Rec]::ScreenW(); $H = [Rec]::ScreenH()
  $env:SIDEHAND_DEMO_ZOOM = [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0:0.###}', $H / 1440 * 96 / [Rec]::Dpi())
  [void][Rec]::Launch("`"$Out\DemoApps.exe`" stage 0 0 $W $H `"$log`" `"$Out`"")
  Start-Sleep -Milliseconds 600
  # The note covers the middle of the screen; each order form opens behind it.
  [void][Rec]::Launch(("`"$Out\DemoApps.exe`" notes {0} {1} {2} {3} `"{4}`" `"{5}`"" -f [int]($W * 0.25), [int]($H * 0.15), [int]($W * 0.5), [int]($H * 0.7), $log, $Out))
  [Rec]::Notes = (Window 'Your note').MainWindowHandle
  if (-not $DryRun -and -not [Rec]::ForceForeground([Rec]::Notes)) { throw 'could not put the note in front' }
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $uia -Op tree -Title 'Your note' -Filter 'zzz' | Out-Null
  [Rec]::Armed = $true
  $sentence = 'The agent works on the order form behind this note while I keep typing. '
  [Rec]::StartTyping(($sentence * 300), 90, [bool]$DryRun)

  foreach ($tool in $Tools) {
    Assert-NotAborted
    if (-not $DryRun -and [Rec]::GetForegroundWindow() -ne [Rec]::Notes -and -not [Rec]::ForceForeground([Rec]::Notes)) { throw 'the note lost the foreground and could not get it back' }
    [void][Rec]::Launch(("`"$Out\Orders.exe`" orders {0} {1} {2} {3} `"{4}`" `"{5}`"" -f [int]($W * 0.3), [int]($H * 0.25), [int]($W * 0.3), [int]($H * 0.45), "$Out\$tool.form.log", $Out))
    $form = Window 'Contoso Orders'
    [Rec]::ToTop([Rec]::Notes)
    Start-Sleep -Milliseconds 1500
    $typed0 = [Rec]::Typed
    $got0 = (Get-Content -Raw -Encoding UTF8 "$log.notes.txt" -ErrorAction SilentlyContinue).Length
    if ($agentApps.Contains($tool)) {
      # Other apps take the foreground on purpose here, so a foreign foreground no longer means a user.
      [Rec]::Armed = $false
      $app = $agentApps[$tool]
      if ([Rec]::Find($app) -eq [IntPtr]::Zero) { throw "open the $tool desktop app first (a window titled '$app')" }
      Set-Clipboard -Value $ask
      [void][Rec]::ForceForeground([Rec]::Find($app)); Start-Sleep -Milliseconds 800
      [Windows.Forms.SendKeys]::SendWait('^v'); Start-Sleep -Milliseconds 500; [Windows.Forms.SendKeys]::SendWait('{ENTER}')
      Start-Sleep -Milliseconds 800
      [void][Rec]::ForceForeground([Rec]::Notes) # back to the note, as the user would
      $t0 = [DateTime]::UtcNow.Ticks
      $end = (Get-Date).AddMinutes(8); $approved = 0
      while ((Get-Date) -lt $end -and (Status) -notmatch 'Order submitted') {
        # Approve the app's permission prompt for this session, as the user would.
        $tree = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $uia -Op tree -Title $app -MaxNodes 600 2>&1) -join "`n"
        if ($tree -match '(?m)^\s*(e\d+) Button "(Allow for this session|이번 세션[^"]*허용[^"]*|Allow|허용)"') {
          & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $uia -Op act -Ref $Matches[1] -Action click | Out-Null; $approved++
        }
        Start-Sleep -Seconds 3
      }
      $t1 = [DateTime]::UtcNow.Ticks
      $task = [pscustomobject]@{ ms = [int](($t1 - $t0) / 10000); startMs = $null; calls = $null; errors = @("permission prompts approved: $approved") }
      [Rec]::Armed = $true
    } else {
    $t0 = [DateTime]::UtcNow.Ticks
    $taskPid = [Rec]::Launch("`"$node`" `"$repo\demo\compare-task.mjs`" $tool `"$Out`" $($form.MainWindowHandle.ToInt64())")
    $end = (Get-Date).AddMinutes(4)
    while ((Get-Process -Id $taskPid -ErrorAction SilentlyContinue) -and (Get-Date) -lt $end) { Assert-NotAborted; Start-Sleep -Milliseconds 250 }
    $t1 = [DateTime]::UtcNow.Ticks
    $task = Get-Content -Raw "$Out\$tool.json" -ErrorAction SilentlyContinue | ConvertFrom-Json
    }
    Start-Sleep -Milliseconds 500
    $notesPid = [Rec]::PidOf([Rec]::Notes)
    $cur = @([Rec]::CurSince($t0) | Where-Object { $_[0] -le $t1 })
    $status = Status
    $result.runs += [pscustomobject]@{
      tool = $tool
      completed = ($status -match 'Order submitted: Blue-B Studio, 3 units to Jeju, express')
      status = (($status -split "`n") | Where-Object { $_ -match 'Order|Waiting' } | Select-Object -Last 1)
      foreground_changes = @([Rec]::FgSince($t0) | Where-Object { $_[0] -le $t1 -and $_[1] -ne $notesPid }).Count
      note_without_keyboard_ms = [Rec]::AwayMs($t0, $t1)
      cursor_moves = [Math]::Max(0, $cur.Count)
      typed = [Rec]::Typed - $typed0
      reached_note = (Get-Content -Raw -Encoding UTF8 "$log.notes.txt").Length - $got0
      form_activations = @(Get-Content "$Out\$tool.form.log" -ErrorAction SilentlyContinue | Where-Object { $_ -match 'form.activated' }).Count
      task_ms = $task.ms; server_start_ms = $task.startMs; calls = $task.calls; errors = @($task.errors)
    }
    Stop-Process -Id $form.Id -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 800
  }
} catch {
  $result.aborted = $true; $result.reason = $_.Exception.Message
} finally {
  [Rec]::StopTyping()
  [Rec]::Close()
}
$result | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 "$Out\compare.json"
Get-Content -Raw "$Out\compare.json"
