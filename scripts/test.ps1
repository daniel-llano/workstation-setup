$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot\..
Write-Host "== Workstation Setup =="
$tokens = $null
$errors = $null
$path = Join-Path (Get-Location) "dev-setup.ps1"
$ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
if ($errors) { throw ($errors | ForEach-Object { $_.ToString() } | Out-String) }
Write-Host "dev-setup.ps1 parses"
$list = .\dev-setup.ps1 -List | Out-String
Write-Host $list
foreach ($need in @('remote_vnc','vnc_viewer','obs','ai_media','comms_zoom','desktop_prefs','win11_cleanup','power_management','vscode_ext','node_nvm','docker','cpp_build','cpp_msvc')) {
  if ($list -notmatch [regex]::Escape($need)) { throw "Missing step id in -List: $need" }
}
if ($list -match '(?m)^\s*rdp_client\s') { throw "rdp_client should be an alias only; list must show vnc_viewer" }
if ($list -match '(?m)^\s*remote_dwservice_manual\s') { throw "remote_dwservice_manual should be an alias only" }
if ($list -match 'Sublime Text') { throw "Sublime Text (paid) should not appear in -List descriptions" }
if ($list -match 'silent install|business/org') { throw "DWService list desc should not advertise silent/business-only install" }
if ($list -notmatch 'OPTIONAL \(default no\)') { throw "cpp_msvc should be described as optional/default no" }
$ids = @()
foreach ($line in ($list -split "`r?`n")) {
  if ($line -match '^\s*(\S+)\s+') { $ids += $Matches[1] }
}
$cppAt = [array]::IndexOf($ids, 'cpp_build')
$msvcAt = [array]::IndexOf($ids, 'cpp_msvc')
if ($cppAt -lt 0 -or $msvcAt -lt 0 -or $cppAt -ge $msvcAt) {
  throw "cpp_build (light) must run before optional cpp_msvc"
}
$dockerAt = [array]::IndexOf($ids, 'docker')
$extAt = [array]::IndexOf($ids, 'vscode_ext')
if ($dockerAt -lt 0 -or $extAt -lt 0 -or $dockerAt -ge $extAt) {
  throw "docker must run before vscode_ext so skipped stacks can drop their extensions"
}
$raw = Get-Content $path -Raw
foreach ($need in @(
    'DisableSearchBoxSuggestions','DisableWebSearch','ConnectedSearchUseWeb','AllowCloudSearch',
    'Set-Win11SearchLocalOnly','Test-AppxPackageRemovable','NonRemovable',
    'Wait-InstallerIdle','Get-InstallerHolders','Resolve-InstallerHolders','Test-InstallerBusy',
    'Import-NvmWindows','Get-VscodeExtensionsForRun','Test-StackEnabled',
    'Test-WingetBlockedByOtherInstaller',
    'Wait-DwAgentInstall','Test-DwAgentInstalled','Invoke-WingetUpgrade',
    'WingetUpgradeBlockers','BatteryChargeTools','Write-BatteryWearReport','Test-WingetIdListed',
    'Wait-ProcessExitCode','Test-WingetUpgradeOk','Get-WingetExe','Test-NeedsElevationResult','Confirm-DefaultNo',
    'Disable-SmartAppControl','VerifiedAndReputablePolicyState','ScreenSaveActive','VIDEOCONLOCK',
    'Resolve-WingetRunningApps','Stop-WingetBlockingProcesses','Test-IsHostingProcess','Wait-WingetBlockersGone',
    'Test-ChromeInstalled','already has a more recent version',
    'Install-TightVnc','Test-TightVncViewer','GlavSoft.TightVNC',
    'Ensure-PythonOnPath','Get-PythonPathDirs','OBSProject.OBSStudio','5319275A.WhatsAppDesktop','*LinkedIn*',
    'Gyan.FFmpeg','oschwartz10612.Poppler','QPDF.QPDF','UB-Mannheim.TesseractOCR','Step_ai_media','Step_comms_zoom',
    'MarkText.MarkText','Test-TeamsInstalled','Repair-TeamsAppxRegistration','XP8BT8DW290MPQ',
    'Set-Win11NightLight','ConvertFrom-NightLightStrengthToKelvin','NIGHT_LIGHT_STRENGTH',
    'Unblock-File','-Verb RunAs','dwagent.exe'
  )) {
    if ($raw -notmatch [regex]::Escape($need)) { throw "Missing helper or key: $need" }
}
if ($list -notmatch 'MarkText') { throw 'editor_pdf list description should mention MarkText' }
if ($list -notmatch 'Night Light') { throw 'desktop_prefs list description should mention Night Light' }
# win11_cleanup must not strip the Teams Appx that comms_teams installs.
$bloat = [regex]::Match($raw, '\$Win11BloatIds\s*=\s*@\((.*?)\)\s*\r?\n\s*function', [System.Text.RegularExpressions.RegexOptions]::Singleline)
if (-not $bloat.Success) { throw 'Could not locate $Win11BloatIds for Teams safety check' }
if ($bloat.Groups[1].Value -match "'MSTeams'|`"MSTeams`"|'MicrosoftTeams'|`"MicrosoftTeams`"") {
  throw 'MSTeams/MicrosoftTeams must not appear in $Win11BloatIds (comms_teams installs them)'
}
# $HOME is a read-only automatic variable: assigning to it threw
# "Cannot overwrite variable HOME" and took the whole node_nvm step down.
foreach ($ro in @('home','host','pid','input','args','matches','pshome','executioncontext')) {
  if ($raw -match ('\$' + $ro + '\s*=[^=]')) {
    throw "Assignment to read-only/automatic variable `$$ro - rename the local"
  }
}
# A parameter named $Profile would shadow PowerShell's own $PROFILE.
if ($raw -match '\[string\]\$Profile\b') { throw 'Use $SetupProfile with [Alias(''Profile'')] instead of $Profile' }
# `return @()` emits nothing, so the caller gets $null and $null.Count is a
# terminating error under StrictMode. Use `return ,@()`. Checked against the
# AST rather than the text, so the comments explaining this do not trip it.
$emptyReturns = $ast.FindAll({
    param($node)
    if ($node -isnot [System.Management.Automation.Language.ReturnStatementAst]) { return $false }
    if (-not $node.Pipeline) { return $false }
    return ($node.Pipeline.Extent.Text.Trim() -eq '@()')
  }, $true)
if ($emptyReturns) {
  $lines = ($emptyReturns | ForEach-Object { $_.Extent.StartLineNumber }) -join ', '
  throw "Bare 'return @()' at line(s) ${lines}: reaches the caller as `$null. Use 'return ,@()'."
}
# The DWService wizard's process never exits; -Wait on it hangs forever.
if ($raw -match 'Start-Process[^\r\n]*\$installer[^\r\n]*-Wait') {
  throw 'Do not -Wait on the DWService installer; poll with Wait-DwAgentInstall'
}
Write-Host "== array-returning helpers under StrictMode =="
# Executes them for real against empty and non-empty inputs. A parse check
# cannot catch the $null.Count crash that took health_check down.
& $PSScriptRoot\test-helpers.ps1
if ($LASTEXITCODE -ne 0) { throw "scripts/test-helpers.ps1 failed" }

# -Yes must skip optional cpp_msvc (default N) unless -Only selects it.
Write-Host "== -Yes skips optional cpp_msvc =="
$skipAllButMsvc = ($ids | Where-Object { $_ -ne 'cpp_msvc' }) -join ','
$yesOpt = (.\dev-setup.ps1 -DryRun -Yes -Skip $skipAllButMsvc *>&1 | Out-String)
if ($yesOpt -notmatch 'Skipping optional step cpp_msvc') {
  throw "-Yes must skip optional cpp_msvc when not selected with -Only:`n$yesOpt"
}
$onlyMsvc = (.\dev-setup.ps1 -DryRun -Only cpp_msvc *>&1 | Out-String)
if ($onlyMsvc -notmatch 'cpp_msvc\s+dry-run' -and $onlyMsvc -notmatch 'Visual Studio 2022 Build Tools') {
  throw "-Only cpp_msvc should run the optional step:`n$onlyMsvc"
}
# Light cpp_build must not install VS Build Tools / Windows SDK.
$cppFn = [regex]::Match($raw, '(?s)function Step_cpp_build \{.*?^\}', [System.Text.RegularExpressions.RegexOptions]::Multiline).Value
if (-not $cppFn) { throw 'Could not extract Step_cpp_build for inspection' }
if ($cppFn -match 'VisualStudio\.2022\.BuildTools|Workload\.VCTools') {
  throw "Step_cpp_build must not install Visual Studio Build Tools (that belongs in cpp_msvc)"
}
if ($raw -notmatch 'function Step_cpp_msvc') {
  throw 'Missing Step_cpp_msvc (optional VS Build Tools + Windows SDK)'
}

Write-Host "== dry-run vscode_ext with docker+scala skipped =="
$logDir = Join-Path $env:USERPROFILE 'dev-setup-logs'
.\dev-setup.ps1 -DryRun -Only vscode_ext -Skip docker,java_scala | Out-Null
$log = Get-ChildItem $logDir -Filter 'dev-setup-*.log' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
$dry = Get-Content -Raw $log.FullName
if ($dry -notmatch 'Skipping VS Code extensions for stacks not present or skipped this run') {
  throw "dry-run log did not report skipped stacks:`n$dry"
}
if ($dry -notmatch 'docker' -or $dry -notmatch 'java_scala') {
  throw "dry-run skip list missing docker/java_scala:`n$dry"
}
if ($dry -match 'ms-azuretools.vscode-docker') {
  throw "docker extension should not be installed when docker is skipped:`n$dry"
}
Write-Host "== dry-run remote_check + battery_charge_limit =="
# *>&1 so the Write-Host summary table lands in $report too, not just the log.
$report = (.\dev-setup.ps1 -DryRun -Only remote_check,battery_charge_limit *>&1 | Out-String)
# Both are report-only steps: neither may report FAILED just because a remote
# was deliberately left off, or because this hardware has no charge control.
if ($report -notmatch '=== Result ===') { throw "remote_check did not print its result summary:`n$report" }
if ($report -match 'remote_check\s+FAILED') { throw "remote_check must not fail for remotes left off:`n$report" }
if ($report -notmatch 'battery_charge_limit\s+(dry-run|OK)') { throw "battery_charge_limit did not complete:`n$report" }
if ($report -match 'battery_charge_limit\s+needs-elevation') {
  throw "battery_charge_limit must not be needs-elevation (boolean/string -eq coercion bug):`n$report"
}

# -Profile is an alias now; make sure it still binds.
.\dev-setup.ps1 -DryRun -Profile server -Only battery_charge_limit | Out-Null
if ($LASTEXITCODE -ne 0) { throw "-Profile server no longer binds (exit $LASTEXITCODE)" }

$cmd = Get-Content (Join-Path (Get-Location) "dev-setup.cmd") -Raw
if ($cmd -notmatch 'ExecutionPolicy Bypass') { throw "dev-setup.cmd must Bypass execution policy" }
$admin = Get-Content (Join-Path (Get-Location) "dev-setup-admin.cmd") -Raw
if ($admin -notmatch 'ExecutionPolicy Bypass' -or $admin -notmatch 'RunAs') { throw "dev-setup-admin.cmd must elevate and Bypass" }
$launcher = Join-Path (Get-Location) "dev-setup.cmd"
$fromCmd = & cmd.exe /c "`"$launcher`" -List" | Out-String
if ($LASTEXITCODE -ne 0) { throw "dev-setup.cmd -List failed with $LASTEXITCODE" }
if ($fromCmd -notmatch 'node_nvm') { throw "dev-setup.cmd -List did not list steps:`n$fromCmd" }
Write-Host "OK"
