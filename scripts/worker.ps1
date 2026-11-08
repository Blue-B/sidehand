<#
  sidehand worker.ps1 - one long-lived PowerShell for the MCP server and the pi extension.
  Starting powershell.exe and loading .NET costs most of a call; the worker pays it once.
  Reads one JSON request per line on stdin: {"id":1,"cmd":"& 'C:\...\uia.ps1' -Op tree ..."}
  Writes one JSON reply per line on stdout:  {"id":1,"code":0,"out":"...","err":""}
  Ends when stdin closes.
#>
$ErrorActionPreference = 'Stop'
[Console]::InputEncoding = New-Object System.Text.UTF8Encoding $false
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
$stdout = [Console]::Out
while ($null -ne ($line = [Console]::In.ReadLine())) {
  if (-not $line.Trim()) { continue }
  $req = $line | ConvertFrom-Json
  $out = New-Object System.Collections.Generic.List[string]
  $err = ''; $code = 0
  try {
    # Every stream (warnings, Write-Host) goes into the reply, never straight to stdout.
    & ([ScriptBlock]::Create($req.cmd)) *>&1 | ForEach-Object {
      if ($_ -is [System.Management.Automation.ErrorRecord]) { if (-not $err) { $err = "$_" } } else { $out.Add("$_") }
    }
  } catch {
    $err = $_.Exception.Message; $code = 1
  }
  $stdout.WriteLine((@{ id = $req.id; code = $code; out = ($out -join "`n"); err = $err } | ConvertTo-Json -Compress))
  $stdout.Flush()
}
