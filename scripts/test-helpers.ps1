# Runs the array-returning helpers out of dev-setup.ps1 in isolation, under the
# same Set-StrictMode -Version Latest the script itself sets.
#
# This exists because of a real crash: `return @()` from a PowerShell function
# emits nothing (the pipeline unrolls the empty array), so the caller gets
# $null, and $null.Count is a terminating error under StrictMode - which took
# health_check down with "The property 'Count' cannot be found on this object".
# The fix (`return ,@()`) has an equally silent failure mode in the other
# direction: re-wrapping the result in @() at the call site yields Count 1 for
# an empty result, which would read as "every package is blocked". Only
# executing these against known-empty and known-non-empty inputs catches both,
# so a parse check or grep is not enough.

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot\..

$scriptPath = Join-Path (Get-Location) 'dev-setup.ps1'
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
if ($errors) { throw ($errors | ForEach-Object { $_.ToString() } | Out-String) }

$wanted = @('Get-WingetUpgradeBlocker', 'Get-DwAgentProcess', 'Get-ForeignInstallerPids', 'Get-WingetUpgradable', 'Wait-ProcessExitCode', 'Test-WingetUpgradeOk', 'Get-WingetExe')
$defs = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
    Where-Object { $wanted -contains $_.Name } |
    ForEach-Object { $_.Extent.Text }
if ($defs.Count -lt 5) {
    throw "Expected to extract winget/process helpers, got $($defs.Count). Renamed or removed?"
}

# A blocker map with one process that is certainly running (this very
# PowerShell) and one that certainly is not, so both branches are deterministic
# rather than depending on what happens to be open on the machine.
$self = [System.IO.Path]::GetFileNameWithoutExtension(
    (Get-Process -Id $PID).MainModule.ModuleName)

$okCodes = ($ast.FindAll({ $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true) |
    Where-Object { $_.Left.Extent.Text -eq '$WingetUpgradeOkCodes' } |
    Select-Object -First 1).Extent.Text
if (-not $okCodes) { throw 'Missing $WingetUpgradeOkCodes assignment in dev-setup.ps1' }

$probe = @"
Set-StrictMode -Version Latest
`$ErrorActionPreference = 'Stop'
`$WingetUpgradeBlockers = @{
    'Fixture.Running'    = @('$self')
    'Fixture.NotRunning' = @('dev-setup-no-such-process-fixture')
}
$okCodes
$($defs -join "`n`n")

`$fail = 0
function Assert-Count([string]`$Label, `$Value, [int]`$Expected) {
    `$got = `$Value.Count      # deliberately unguarded: this is what the script does
    if (`$got -ne `$Expected) {
        Write-Host "FAIL  `$Label : expected `$Expected, got `$got"
        `$script:fail++
    } else {
        Write-Host "ok    `$Label = `$got"
    }
}

# Id absent from the map, and Id present but its process not running: both
# must come back as an empty array whose .Count is readable and 0.
Assert-Count 'blockers for unmapped id' (Get-WingetUpgradeBlocker 'GitHub.cli') 0
Assert-Count 'blockers for mapped id, process not running' (Get-WingetUpgradeBlocker 'Fixture.NotRunning') 0
Assert-Count 'blockers for mapped id, process running' (Get-WingetUpgradeBlocker 'Fixture.Running') 1

# Never-empty-on-this-box vs possibly-empty: only the .Count access matters.
Assert-Count 'foreign installer pids' (Get-ForeignInstallerPids) (@(Get-Process -Name 'vs_installer','vs_installershell','vs_bootstrapper','VSIXInstaller' -ErrorAction SilentlyContinue).Count)
Assert-Count 'dwagent processes' (Get-DwAgentProcess) (@(Get-Process -Name 'dwagent','dwagsvc','dwaglnc' -ErrorAction SilentlyContinue).Count)

# The exact bug from the health_check log: winget via Start-Process -NoNewWindow
# left ExitCode $null, and `$null -ne 0` reported every "Successfully installed"
# as a failure with an empty "(exit )".
`$winget = Get-WingetExe
`$pBad = Start-Process -FilePath `$winget -ArgumentList @('--version') -NoNewWindow -PassThru
`$pBad.WaitForExit(15000) | Out-Null
if (`$null -eq `$pBad.ExitCode) {
    Write-Host "ok    unreproduced baseline: ExitCode is null without Handle cache"
} else {
    Write-Host ("ok    baseline ExitCode already populated on this host ({0})" -f `$pBad.ExitCode)
}
`$pOk = Start-Process -FilePath `$winget -ArgumentList @('--version') -NoNewWindow -PassThru
`$code = Wait-ProcessExitCode -Process `$pOk -TimeoutSec 15
if (`$null -eq `$code) { Write-Host 'FAIL  Wait-ProcessExitCode returned null'; `$script:fail++ }
elseif (`$code -ne 0) { Write-Host "FAIL  Wait-ProcessExitCode expected 0, got `$code"; `$script:fail++ }
else { Write-Host "ok    Wait-ProcessExitCode ExitCode=`$code" }

if (-not (Test-WingetUpgradeOk 0)) { Write-Host 'FAIL  Test-WingetUpgradeOk 0'; `$script:fail++ }
if (-not (Test-WingetUpgradeOk -1978335189)) { Write-Host 'FAIL  Test-WingetUpgradeOk UPDATE_NOT_APPLICABLE'; `$script:fail++ }
if (Test-WingetUpgradeOk 1) { Write-Host 'FAIL  Test-WingetUpgradeOk should reject 1'; `$script:fail++ }
if (Test-WingetUpgradeOk `$null) { Write-Host 'FAIL  Test-WingetUpgradeOk should reject null'; `$script:fail++ }
Write-Host 'ok    Test-WingetUpgradeOk soft-success codes'

if (`$fail -gt 0) { Write-Host "`$fail helper assertion(s) failed"; exit 1 }
Write-Host 'helpers OK'
exit 0
"@

$probePath = Join-Path ([System.IO.Path]::GetTempPath()) 'dev-setup-helper-probe.ps1'
Set-Content -LiteralPath $probePath -Value $probe -Encoding UTF8
try {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $probePath
    if ($LASTEXITCODE -ne 0) { throw "helper probe failed (exit $LASTEXITCODE)" }
} finally {
    Remove-Item -LiteralPath $probePath -ErrorAction SilentlyContinue
}
