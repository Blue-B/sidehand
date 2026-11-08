<#
  sidehand doctor.ps1 - checks the PowerShell side of sidehand; touches no window.
  `sidehand doctor` (lib/doctor.mjs) sends this as an inline command with $ScriptDir set first:
  inline commands run even where policy blocks script files, so it can say that is the problem.
  Prints one "ok ..." or "FAIL ..." line per check.
#>
function Check([string]$what, [scriptblock]$test) {
  try { $r = & $test; "ok   ${what}$(if ($r) { ": $r" })" } catch { "FAIL ${what}: $($_.Exception.Message)" }
}
Check 'PowerShell' { "$($PSVersionTable.PSVersion)" }
Check 'language mode' {
  $m = "$($ExecutionContext.SessionState.LanguageMode)"
  if ($m -ne 'FullLanguage') { throw "$m; sidehand needs FullLanguage (Constrained Language Mode comes from AppLocker or WDAC policy; ask your administrator)" }
  $m
}
Check 'execution policy' {
  $p = "$(Get-ExecutionPolicy)"
  $gpo = @(Get-ExecutionPolicy -List | Where-Object { $_.Scope -like '*Policy' -and "$($_.ExecutionPolicy)" -ne 'Undefined' } | ForEach-Object { "$($_.Scope)=$($_.ExecutionPolicy)" }) -join ', '
  if ($p -in 'Restricted', 'AllSigned') { throw "$p (Group Policy: $gpo); PowerShell refuses sidehand's unsigned scripts" }
  "$p$(if ($gpo) { " (Group Policy: $gpo)" })"
}
Check 'administrator' {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  if ((New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { 'elevated' }
  else { 'not elevated; apps running as administrator cannot be read or operated' }
}
Check 'engine' {
  . (Join-Path $ScriptDir 'lib.ps1')
  Import-UiaEngine
  "compiled and loaded from $(Join-Path $env:LOCALAPPDATA 'sidehand')"
}
Check 'OCR languages' {
  Add-Type -AssemblyName System.Runtime.WindowsRuntime
  $null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]
  $langs = @([Windows.Media.Ocr.OcrEngine]::AvailableRecognizerLanguages | ForEach-Object { $_.LanguageTag })
  if (-not $langs.Count) { throw 'none installed; ocr needs one: Settings > Time & language > Language, add a language with OCR' }
  $langs -join ', '
}
