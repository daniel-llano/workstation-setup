#requires -Version 5.1
<#
  dev-setup.ps1 - Interactive development environment bootstrapper for Windows 11 (64-bit).

  Windows port of dev-setup.sh. Uses winget as the package manager (in place of apt),
  PowerShell's user/machine PATH in place of shell rc files, and a .env file next to this
  script for the same non-interactive settings (git identity/token, remote-access credentials).

  Usage:
    .\dev-setup.ps1                 interactive: ask before each step
    .\dev-setup.ps1 -Yes            non-interactive: install everything
    .\dev-setup.ps1 -DryRun         print what would happen, change nothing
    .\dev-setup.ps1 -Only a,b       only run the given step ids
    .\dev-setup.ps1 -Skip a,b       run everything except the given step ids
    .\dev-setup.ps1 -List           list step ids and exit
    .\dev-setup.ps1 -Help           help
#>

[CmdletBinding()]
param(
    [Alias('y')][switch]$Yes,
    [Alias('n')][switch]$DryRun,
    [string[]]$Only = @(),
    [string[]]$Skip = @(),
    # Bound as $SetupProfile, exposed as -Profile: a parameter literally named
    # $Profile shadows PowerShell's own $PROFILE automatic variable for the
    # whole script scope, so anything that later reads $PROFILE (or any module
    # dot-sourced from here) silently sees '' instead of the profile path.
    [ValidateSet('', 'minimal', 'server', 'desktop')]
    [Alias('Profile')]
    [string]$SetupProfile = '',
    [switch]$List,
    [Alias('h')][switch]$Help
)

$ErrorActionPreference = 'Continue'
Set-StrictMode -Version Latest
# Set-StrictMode throws on reading $LASTEXITCODE before any native command has
# run yet in this runspace - seed it so every code path can check it safely.
$global:LASTEXITCODE = 0

# Windows PowerShell 5.1's console defaults to the legacy system codepage
# (often CP437/CP1252), not UTF-8 - native tools that print Unicode (pipx's
# emoji, npm/composer's box-drawing characters) come out as mojibake without
# this, even though the bytes themselves are fine.
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
    chcp 65001 > $null
} catch {}

# ---------------------------------------------------------------------------
# Globals
# ---------------------------------------------------------------------------
$ScriptVersion = '1.6.1'
$ScriptDir     = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$LogDir        = Join-Path $env:USERPROFILE 'dev-setup-logs'
$LogFile       = Join-Path $LogDir ("dev-setup-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$DownloadDir   = Join-Path $env:USERPROFILE 'Downloads'
$StateDir      = Join-Path $env:LOCALAPPDATA 'dev-setup\state'
$EnvFile       = Join-Path $ScriptDir '.env'
$EnvLoaded     = $false
$Cfg           = @{}

$DesktopSteps = @(
    'cursor', 'chatgpt', 'editor_pdf', 'libreoffice', 'postman_newman',
    'chrome', 'vnc_viewer', 'media_apps', 'obs', 'comms_zoom',
    'comms_slack', 'comms_teams', 'comms_notion', 'comms_pumble', 'comms_linear', 'comms_clockify',
    'pin_apps', 'win11_cleanup'
)

if ($SetupProfile -eq 'minimal' -and $Only.Count -eq 0) {
    $Only = @('prereqs','path_check','git_gh','dotnet','python','node_nvm','vscode','docker','cli_tools')
}
if ($SetupProfile -eq 'server') {
    $Skip = @($Skip) + $DesktopSteps | Select-Object -Unique
}

function Expand-StepList([string[]]$Items) {
    $out = @()
    foreach ($i in @($Items)) {
        if (-not $i) { continue }
        foreach ($part in ($i -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
            # Legacy aliases
            if ($part -eq 'rdp_client') { $part = 'vnc_viewer' }
            # Silent DWService removed 1.5.6, only the interactive wizard remains.
            if ($part -eq 'remote_dwservice_manual') { $part = 'remote_dwservice' }
            $out += $part
        }
    }
    return ,$out
}
$Only = Expand-StepList $Only
$Skip = Expand-StepList $Skip

New-Item -ItemType Directory -Force -Path $LogDir, $DownloadDir, $StateDir | Out-Null

$UseColor = -not $env:NO_COLOR

$Results = [ordered]@{}
$FailedSteps = @()

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
function Write-RawLog([string]$Line) {
    Add-Content -Path $LogFile -Value ("{0} {1}" -f (Get-Date -Format 'HH:mm:ss'), $Line)
}
function Write-LogInfo([string]$Msg) {
    if ($UseColor) { Write-Host '[INFO] ' -ForegroundColor Blue -NoNewline } else { Write-Host '[INFO] ' -NoNewline }
    Write-Host $Msg
    Write-RawLog "[INFO] $Msg"
}
function Write-LogOk([string]$Msg) {
    if ($UseColor) { Write-Host '[ OK ] ' -ForegroundColor Green -NoNewline } else { Write-Host '[ OK ] ' -NoNewline }
    Write-Host $Msg
    Write-RawLog "[OK] $Msg"
}
function Write-LogWarn([string]$Msg) {
    if ($UseColor) { Write-Host '[WARN] ' -ForegroundColor Yellow -NoNewline } else { Write-Host '[WARN] ' -NoNewline }
    Write-Host $Msg
    Write-RawLog "[WARN] $Msg"
}
function Write-LogErr([string]$Msg) {
    if ($UseColor) { Write-Host '[FAIL] ' -ForegroundColor Red -NoNewline } else { Write-Host '[FAIL] ' -NoNewline }
    Write-Host $Msg
    Write-RawLog "[FAIL] $Msg"
}
function Write-LogStep([string]$Msg) {
    Write-Host ''
    if ($UseColor) { Write-Host '==> ' -ForegroundColor White -NoNewline } else { Write-Host '==> ' -NoNewline }
    Write-Host $Msg
    Write-RawLog "==> $Msg"
}

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------
function Test-CmdExists([string]$Name) {
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Re-reads PATH from the registry into this session, so a step that just
# installed something (winget/npm/pip) is usable by the next step without
# needing a new shell.
function Update-SessionPath {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user    = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = @($machine, $user) -join ';'
}

function Test-MsiExecuteBusy {
    try {
        $m = [System.Threading.Mutex]::OpenExisting('Global\_MSIExecute')
        $m.Dispose()
        return $true
    } catch [System.Threading.WaitHandleCannotBeOpenedException] {
        return $false
    } catch {
        return $false
    }
}

function Get-ForeignInstallerPids {
    # The Visual Studio installer family holds its own global lock that is
    # separate from _MSIExecute, so the mutex check above does not see it.
    # ,@(...) so an empty result survives as an empty array instead of
    # collapsing to $null - see Get-WingetUpgradeBlocker for the full note.
    return ,@(Get-Process -Name 'vs_installer', 'vs_installershell', 'vs_bootstrapper', 'VSIXInstaller' -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty Id -Unique)
}

# Identify processes that typically hold the Windows Installer / winget lock.
# Returns objects: Pid, Name, Path. Empty array when nothing found.
function Get-InstallerHolders {
    $names = @(
        'msiexec', 'vs_installer', 'vs_installershell', 'vs_bootstrapper', 'VSIXInstaller',
        'TiWorker', 'TrustedInstaller', 'UsoClient', 'MusNotification', 'MusNotificationUx',
        'WindowsUpdateBox', 'SetupHost', 'InstallAgent', 'Wuauclt'
    )
    $holders = [System.Collections.Generic.List[object]]::new()
    $seen = @{}
    foreach ($n in $names) {
        foreach ($p in @(Get-Process -Name $n -ErrorAction SilentlyContinue)) {
            if ($seen.ContainsKey($p.Id)) { continue }
            $seen[$p.Id] = $true
            $path = $null
            try { $path = $p.Path } catch { }
            $holders.Add([pscustomobject]@{ Pid = $p.Id; Name = $p.ProcessName; Path = $path })
        }
    }
    foreach ($p in @(Get-Process -Name 'winget' -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne $PID })) {
        if ($seen.ContainsKey($p.Id)) { continue }
        $seen[$p.Id] = $true
        $path = $null
        try { $path = $p.Path } catch { }
        $holders.Add([pscustomobject]@{ Pid = $p.Id; Name = $p.ProcessName; Path = $path })
    }
    return , @($holders)
}

function Test-InstallerBusy {
    if (Test-MsiExecuteBusy) { return $true }
    if ((Get-ForeignInstallerPids).Count -gt 0) { return $true }
    if (@(Get-Process -Name 'winget' -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne $PID }).Count -gt 0) { return $true }
    return $false
}

# Ask to stop installer holders. Returns: 'clear' | 'wait' | 'abort'
function Resolve-InstallerHolders {
    $holders = @(Get-InstallerHolders)
    $msi = Test-MsiExecuteBusy

    if ($holders.Count -eq 0 -and -not $msi) { return 'clear' }

    Write-LogWarn "These processes appear to be blocking installs (or the MSI mutex is held):"
    if ($msi) {
        Write-LogWarn "  _MSIExecute mutex is held (another MSI/EXE setup in progress)"
    }
    foreach ($h in $holders) {
        $detail = if ($h.Path) { $h.Path } else { '(path unavailable)' }
        Write-LogWarn ("  PID {0}: {1} - {2}" -f $h.Pid, $h.Name, $detail)
    }

    if ($DryRun) {
        Write-Host "  [dry-run] would offer to kill those PIDs (may need Administrator elevation)" -ForegroundColor Yellow
        return 'abort'
    }

    if ($Yes) {
        Write-LogErr "An installer is busy and -Yes will not kill other processes automatically."
        Write-LogErr "Re-run without -Yes to identify holders and stop them, or close winget/MSI/Windows Update yourself."
        if ($holders.Count -gt 0) {
            Write-LogErr ("  Stop-Process -Id {0} -Force" -f (($holders | ForEach-Object { $_.Pid }) -join ','))
        }
        return 'abort'
    }

    Write-Host ''
    Write-Host '  Stop these processes so setup can continue?' -ForegroundColor Yellow
    Write-Host '    [K] Kill them now (may prompt for Administrator / UAC)   (default)'
    Write-Host '    [W] Wait more'
    Write-Host '    [A] Abort this step'
    $ans = Read-Host '  Choice [K/w/a]'
    if ([string]::IsNullOrWhiteSpace($ans)) { $ans = 'K' }

    switch -Regex ($ans) {
        '^[Ww]' { return 'wait' }
        '^[Aa]' { return 'abort' }
        default {
            $pids = @($holders | ForEach-Object { $_.Pid } | Select-Object -Unique)
            if ($pids.Count -eq 0) {
                Write-LogWarn "No killable PIDs listed (mutex may clear when Windows Update finishes). Waiting..."
                return 'wait'
            }
            Write-LogInfo "Stopping installer holders (PIDs $($pids -join ', '))..."
            $failed = @()
            foreach ($id in $pids) {
                try {
                    Stop-Process -Id $id -Force -ErrorAction Stop
                } catch {
                    $failed += $id
                }
            }
            if ($failed.Count -gt 0) {
                if (-not (Test-Admin)) {
                    Write-LogWarn "Some PIDs need elevation. Launching elevated Stop-Process (UAC prompt)..."
                    $arg = '-NoProfile -Command "Stop-Process -Id {0} -Force -ErrorAction SilentlyContinue"' -f ($failed -join ',')
                    try {
                        $elev = Start-Process -FilePath 'powershell.exe' -ArgumentList $arg -Verb RunAs -Wait -PassThru
                        if ($elev.ExitCode -ne 0) {
                            Write-LogWarn "Elevated kill exited $($elev.ExitCode)"
                        }
                    } catch {
                        Write-LogWarn "UAC elevation cancelled or failed: $($_.Exception.Message)"
                        return 'abort'
                    }
                } else {
                    Write-LogWarn "Could not kill PIDs $($failed -join ', '): access denied even as Administrator"
                    return 'abort'
                }
            }
            Start-Sleep -Seconds 2
            if (Test-InstallerBusy) {
                Write-LogWarn "Installer still looks busy after kill."
                return 'abort'
            }
            Write-LogOk "Installer locks appear clear"
            return 'clear'
        }
    }
}

function Wait-InstallerIdle {
    param([int]$TimeoutSec = 180)
    if ($DryRun) { return $true }
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $n = 0
    $maxRounds = [Math]::Max(1, [int][Math]::Ceiling($TimeoutSec / 5.0))
    while ((Get-Date) -lt $deadline) {
        if (-not (Test-InstallerBusy)) { return $true }
        $n++
        # After a few waits, identify holders and offer kill (sudo/UAC equivalent).
        if ($n -ge 3) {
            $decision = Resolve-InstallerHolders
            if ($decision -eq 'clear') { return $true }
            if ($decision -eq 'wait') {
                Write-LogInfo "Waiting another round for installers to finish..."
                $n = 0
                Start-Sleep -Seconds 5
                continue
            }
            Write-LogErr "Timed out / aborted waiting for another installer. Close winget/MSI/VS Installer/Windows Update and re-run this step."
            return $false
        }
        $holders = @(Get-InstallerHolders)
        $summary = if ($holders.Count -gt 0) {
            ($holders | Select-Object -First 3 | ForEach-Object { "$($_.Name):$($_.Pid)" }) -join ', '
        } elseif (Test-MsiExecuteBusy) {
            '_MSIExecute held'
        } else {
            'busy'
        }
        Write-LogWarn "Another installer is running ($summary); waiting 5s ($n/$maxRounds)..."
        Start-Sleep -Seconds 5
    }
    # Final offer after the soft timeout.
    $decision = Resolve-InstallerHolders
    if ($decision -eq 'clear') { return $true }
    if ($decision -eq 'wait') {
        Start-Sleep -Seconds 10
        if (-not (Test-InstallerBusy)) { return $true }
    }
    Write-LogErr "Timed out waiting for another installer to finish. Close winget/MSI/VS Installer/Windows Update and re-run this step."
    return $false
}

function Test-WingetBlockedByOtherInstaller([int]$ExitCode, [string]$Text) {
    if ($ExitCode -eq 1618 -or $ExitCode -eq -2147023646) { return $true }
    if ($Text -match 'another installation is in progress|another installer is running|ERROR_INSTALL_ALREADY_RUNNING|Windows Installer is in use|error code:\s*1618|0x80070652') {
        return $true
    }
    return $false
}

function Import-NvmWindows {
    Update-SessionPath
    # $nvmHome, never $home: $HOME is a read-only PowerShell automatic
    # variable, so assigning to it throws "Cannot overwrite variable HOME
    # because it is read-only or constant" and takes the whole step down.
    foreach ($scope in @('Machine', 'User')) {
        $nvmHome = [Environment]::GetEnvironmentVariable('NVM_HOME', $scope)
        $link    = [Environment]::GetEnvironmentVariable('NVM_SYMLINK', $scope)
        if ($nvmHome) { $env:NVM_HOME = $nvmHome }
        if ($link) { $env:NVM_SYMLINK = $link }
    }
    $candidates = @()
    if ($env:NVM_HOME) { $candidates += (Join-Path $env:NVM_HOME 'nvm.exe') }
    $candidates += @(
        (Join-Path $env:ProgramFiles 'nvm\nvm.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'nvm\nvm.exe'),
        (Join-Path $env:APPDATA 'nvm\nvm.exe'),
        (Join-Path $env:LOCALAPPDATA 'nvm\nvm.exe')
    )
    foreach ($exe in $candidates) {
        if ($exe -and (Test-Path -LiteralPath $exe)) {
            $dir = Split-Path -Parent $exe
            $env:NVM_HOME = $dir
            $parts = @($dir)
            if ($env:NVM_SYMLINK) { $parts += $env:NVM_SYMLINK }
            $env:Path = (($parts + ($env:Path -split ';' | Where-Object { $_ -and $parts -notcontains $_ })) -join ';')
            return $true
        }
    }
    return (Test-CmdExists 'nvm')
}

# Is this stack part of this machine, so its VS Code extensions are wanted?
#
# -Skip is an explicit opt-out and always wins. Answering "n" at a step's
# prompt is NOT: the usual reason to decline "Install Docker?" is that Docker
# is already there, and dropping its extensions for that would be backwards.
# So a declined step falls through to detection and counts as enabled if the
# toolchain is actually present.
function Test-StackEnabled([string]$StepId) {
    $skipFlat = @()
    foreach ($s in @($Skip)) { $skipFlat += ($s -split ',') }
    if ($skipFlat -contains $StepId) { return $false }
    if ($Results.Contains($StepId) -and $Results[$StepId] -in @('OK', 'FAILED', 'dry-run', 'dry-run-error')) { return $true }
    switch ($StepId) {
        'docker'      { return (Test-CmdExists 'docker') }
        'kubectl'     { return (Test-CmdExists 'kubectl') }
        'python'      { return (Test-CmdExists 'python') -or (Test-CmdExists 'py') -or (Test-Path (Join-Path $env:LOCALAPPDATA 'Programs\Python')) }
        'java_scala'  { return (Test-CmdExists 'java') -or (Test-CmdExists 'sbt') }
        'php'         { return (Test-CmdExists 'php') }
        'dotnet'      { return (Test-CmdExists 'dotnet') }
        'cpp_build'   { return (Test-CmdExists 'cmake') -or (Test-CmdExists 'clang') -or (Test-CmdExists 'g++') -or (Test-CmdExists 'cl') }
        'cpp_msvc'    { return (Test-CmdExists 'cl') }
        'node_nvm'    { return (Test-CmdExists 'npm') -or (Test-CmdExists 'node') -or (Test-CmdExists 'nvm') }
        'playwright'  { return (Test-CmdExists 'npm') -or (Test-CmdExists 'npx') }
        default       { return $true }
    }
}

function Add-UserPath([string]$Dir) {
    $current = [Environment]::GetEnvironmentVariable('Path', 'User')
    $parts = @()
    if ($current) { $parts = $current -split ';' | Where-Object { $_ -ne '' } }
    if ($parts -contains $Dir) { return $false }
    if ($DryRun) {
        Write-Host "  [dry-run] would add to User PATH: $Dir" -ForegroundColor Yellow
        return $true
    }
    $newPath = (@($parts) + $Dir) -join ';'
    [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
    Update-SessionPath
    return $true
}

function Confirm-Step([string]$Prompt) {
    if ($Yes) { return $true }
    if ($DryRun) { Write-Host "$Prompt [dry-run auto-yes]"; return $true }
    $ans = Read-Host "$Prompt [Y/n]"
    return ([string]::IsNullOrWhiteSpace($ans) -or $ans -match '^[Yy]')
}

# Default-N. Creating/resetting an OS login is never implied by -Yes.
function Confirm-YesExplicit([string]$Prompt) {
    if ($DryRun) {
        Write-Host "$Prompt [dry-run: will not create/reset an OS user]"
        return $false
    }
    if ($Yes) { return $false }
    $ans = Read-Host "$Prompt [y/N]"
    return ($ans -match '^[Yy]')
}

# Default-N for optional install steps (e.g. heavy VS Build Tools). -Yes does
# not flip these on; use -Only <id> to opt in non-interactively.
function Confirm-DefaultNo([string]$Prompt) {
    if ($DryRun) {
        Write-Host "$Prompt [dry-run: optional step, default skip]"
        return $false
    }
    if ($Yes) { return $false }
    $ans = Read-Host "$Prompt [y/N]"
    return ($ans -match '^[Yy]')
}

# Cached so remote_ssh + remote_rdp ask once per run.
$script:RemoteUserDecision = $null

function Get-RemoteUserDecision {
    if ($null -ne $script:RemoteUserDecision) { return $script:RemoteUserDecision }

    Import-EnvFile
    $requested = Get-Cfg 'REMOTE_USER'
    $current = $env:USERNAME
    $create = $false
    $updatePw = $false
    $effective = $current

    Write-LogInfo "Remote OS-user check (will not create an account unless you confirm):"
    Write-LogInfo "  Current login: $current"
    if ([string]::IsNullOrWhiteSpace($requested)) {
        Write-LogInfo "  REMOTE_USER is empty in .env - using '$current' (no new account)."
        $script:RemoteUserDecision = @{ Name = $current; Create = $false; UpdatePassword = $false }
        return $script:RemoteUserDecision
    }
    Write-LogInfo "  REMOTE_USER from .env: $requested"

    $existing = Get-LocalUser -Name $requested -ErrorAction SilentlyContinue
    if ($existing) {
        Write-LogOk "  Account '$requested' already exists on this machine."
        if ($Yes) {
            Write-LogWarn "  -Yes never resets OS passwords. Leaving '$requested' unchanged."
            $effective = $requested
        } elseif (Confirm-YesExplicit "Update password for '$requested' from .env and add it to Administrators / Remote Desktop Users?") {
            $effective = $requested
            $updatePw = $true
        } else {
            Write-LogInfo "  Leaving account '$requested' unchanged."
            $effective = $requested
        }
    } else {
        Write-LogWarn "  Account '$requested' does NOT exist."
        if ($Yes) {
            Write-LogWarn "  -Yes never creates OS accounts. Using current login '$current' instead."
            Write-LogWarn "  Re-run this step interactively (without -Yes) if you really want a new user."
            $effective = $current
        } elseif (Confirm-YesExplicit "Create a new local Windows user '$requested' for remote login?") {
            $effective = $requested
            $create = $true
            $updatePw = $true
        } else {
            Write-LogInfo "  Not creating '$requested'. Using current login '$current'."
            $effective = $current
        }
    }

    $script:RemoteUserDecision = @{ Name = $effective; Create = $create; UpdatePassword = $updatePw }
    return $script:RemoteUserDecision
}

function Invoke-RemoteOsUser {
    $d = Get-RemoteUserDecision
    $name = $d.Name
    if ($DryRun) {
        Write-LogInfo ('[dry-run] effective remote user would be {0} (create={1}, update-password={2})' -f $name, $d['Create'], $d['UpdatePassword'])
        return $name
    }
    $pw = Get-Cfg 'REMOTE_PASSWORD'
    if ($d['Create']) {
        if (-not $pw) {
            Write-LogErr "Cannot create '$name' without REMOTE_PASSWORD in .env"
            return $name
        }
        $secure = ConvertTo-SecureString $pw -AsPlainText -Force
        New-LocalUser -Name $name -Password $secure -PasswordNeverExpires | Out-Null
        Write-LogOk "Created local user '$name'"
    }
    if ($d['UpdatePassword']) {
        if ($pw) {
            $secure = ConvertTo-SecureString $pw -AsPlainText -Force
            Set-LocalUser -Name $name -Password $secure | Out-Null
            Write-LogOk "Updated password for '$name' from .env"
        } else {
            Write-LogWarn "REMOTE_PASSWORD is empty; not changing the password for '$name'"
        }
        Add-LocalGroupMember -Group 'Administrators' -Member $name -ErrorAction SilentlyContinue | Out-Null
    }
    return $name
}

# Runs a native executable, honoring -DryRun. Returns $true/$false.
function Invoke-Native {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @()
    )
    if ($DryRun) {
        $shown = @($FilePath) + $Arguments
        Write-Host ("  [dry-run] {0}" -f ($shown -join ' ')) -ForegroundColor Yellow
        return $true
    }
    # `| Out-Host` is load-bearing, not cosmetic: a PowerShell function's return
    # value is EVERY uncaptured pipeline object, not just the final `return`.
    # Left unpiped, the native command's own stdout would ride along with the
    # trailing boolean into a multi-element array - and any non-empty array is
    # truthy in a boolean context, even @($false) - silently turning every
    # failure this wraps into a false "succeeded" for every caller.
    & $FilePath @Arguments | Out-Host
    return ($LASTEXITCODE -eq 0)
}

# Loads known keys from .env (same file format/keys as dev-setup.sh where they
# translate) into $Cfg. Never sourced/executed - strict KEY=VALUE parsing only.
$KnownEnvKeys = @(
    'EMAIL','GIT_USER_NAME','GIT_USER_EMAIL','GH_TOKEN',
    'REMOTE_USER','REMOTE_PASSWORD',
    'RUSTDESK_PASSWORD','RUSTDESK_USER',
    'DWSERVICE_KEY','DWSERVICE_USER','DWSERVICE_PASSWORD',
    'BATTERY_CHARGE_LIMIT','TIMEZONE','NIGHT_LIGHT_STRENGTH',
    'PIN_VSCODE','PIN_CURSOR','PIN_CHATGPT','PIN_CHROME','PIN_LIBREOFFICE','PIN_POSTMAN',
    'PIN_REMMINA','PIN_SLACK','PIN_TEAMS','PIN_NOTION','PIN_PUMBLE','PIN_LINEAR','PIN_CLOCKIFY','PIN_EDITOR_PDF'
)

function Import-EnvFile {
    if ($EnvLoaded) { return }
    $script:EnvLoaded = $true
    if (-not (Test-Path $EnvFile)) { return }

    try {
        $acl = Get-Acl $EnvFile
        $others = $acl.Access | Where-Object {
            $_.IdentityReference -notmatch [regex]::Escape($env:USERNAME) -and
            $_.IdentityReference -notmatch 'SYSTEM' -and
            $_.IdentityReference -notmatch 'Administrators'
        }
        if ($others -and -not $DryRun) {
            Write-LogWarn "$EnvFile is readable by accounts other than you/SYSTEM/Administrators."
            Write-LogWarn "It holds plaintext credentials - locking it down to your account only."
            $envGrant = '{0}:(R,W)' -f $env:USERNAME
            icacls $EnvFile /inheritance:r /grant:r $envGrant 'SYSTEM:(F)' 'Administrators:(F)' | Out-Null
        }
    } catch { }

    foreach ($line in Get-Content -Path $EnvFile) {
        if ($line -match '^\s*(#.*)?$') { continue }
        if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') {
            $key = $Matches[1]
            $value = $Matches[2]
            if ($value -match '^"(.*)"$' -or $value -match "^'(.*)'$") { $value = $Matches[1] }
            if ($KnownEnvKeys -contains $key) { $Cfg[$key] = $value }
        }
    }
    if (-not $Cfg.ContainsKey('GIT_USER_EMAIL') -or [string]::IsNullOrEmpty($Cfg['GIT_USER_EMAIL'])) {
        $Cfg['GIT_USER_EMAIL'] = $Cfg['EMAIL']
    }
    if (-not $Cfg.ContainsKey('DWSERVICE_USER') -or [string]::IsNullOrEmpty($Cfg['DWSERVICE_USER'])) {
        $Cfg['DWSERVICE_USER'] = $Cfg['EMAIL']
    }
}

function Get-Cfg([string]$Key) {
    if ($Cfg.ContainsKey($Key)) { return $Cfg[$Key] }
    return ''
}

function Test-FlagEnabled([string]$Val, [bool]$Default = $true) {
    if ([string]::IsNullOrWhiteSpace($Val)) { return $Default }
    return $Val -match '^(true|yes|1)$'
}

# ---------------------------------------------------------------------------
# winget helpers
# ---------------------------------------------------------------------------
function Test-WingetInstalled([string]$Id) {
    $out = winget list --id $Id -e --accept-source-agreements --disable-interactivity 2>&1 | Out-String
    return ($out -notmatch 'No installed package found') -and ($out -match [regex]::Escape($Id))
}

function Install-Winget {
    param(
        [Parameter(Mandatory)][string]$Id,
        [string]$Name,
        [string]$Source = 'winget',
        [string]$OverrideArgs,
        # Re-run the MSI even when winget already lists the id (TightVNC Viewer
        # then Server: same package id, different ADDLOCAL features).
        [switch]$Force
    )
    if (-not $Name) { $Name = $Id }
    if (-not $Force -and (Test-WingetInstalled $Id)) {
        Write-LogInfo "$Name already installed, skipping"
        Update-SessionPath
        return $true
    }
    $wingetArgs = @('install', '--id', $Id, '-e', '--source', $Source,
        '--accept-package-agreements', '--accept-source-agreements',
        '--silent', '--disable-interactivity')
    if ($Force) { $wingetArgs += '--force' }
    if ($OverrideArgs) { $wingetArgs += @('--override', $OverrideArgs) }

    if ($DryRun) {
        Write-Host ("  [dry-run] winget {0}" -f ($wingetArgs -join ' ')) -ForegroundColor Yellow
        return $true
    }
    if (-not (Wait-InstallerIdle)) { return $false }

    $maxAttempts = 4
    $genericRetried = $false
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        $lines = New-Object System.Collections.Generic.List[string]
        winget @wingetArgs 2>&1 | ForEach-Object {
            $s = "$_"
            Write-Host $s
            [void]$lines.Add($s)
        }
        $code = $LASTEXITCODE
        $text = $lines -join "`n"
        if ($code -eq 0) {
            Write-LogOk "$Name installed"
            Update-SessionPath
            return $true
        }
        if (Test-WingetBlockedByOtherInstaller -ExitCode $code -Text $text) {
            Write-LogWarn "$Name failed because another installer is blocking Windows Installer/winget (exit $code)."
            if ($attempt -lt $maxAttempts) {
                Write-LogWarn "Waiting for the other installer to finish, then retrying ($attempt/$maxAttempts)..."
                if (-not (Wait-InstallerIdle -TimeoutSec 120)) { return $false }
                continue
            }
            Write-LogErr "$Name blocked by another installer after $maxAttempts attempts. Close that installer and re-run this step."
            return $false
        }
        # Chrome (and similar self-updating apps) often sit on disk ahead of the
        # winget catalog. The MSI then refuses a downgrade with this message and
        # winget surfaces INSTALL_FAILED (-1978335159) - treat as already OK.
        if ($text -match 'already has a more recent version') {
            Write-LogWarn "${Name}: winget catalog is older than what is already installed - treating as OK"
            Update-SessionPath
            return $true
        }
        if (-not $genericRetried) {
            $genericRetried = $true
            Write-LogWarn "$Name install returned exit code $code, retrying once after a short wait..."
            Start-Sleep -Seconds 5
            continue
        }
        Write-LogWarn "$Name install returned exit code $code"
        return $false
    }
    return $false
}

# winget lays its output out as a fixed-width table sized to the console and
# truncates the Id column with a single-character ellipsis when it does not
# fit - so a plain full-id match in a narrow window silently reports
# "everything up to date" for exactly the long ids (Microsoft.VisualStudio.
# 2022.BuildTools, IrfanSkiljan.IrfanView.PlugIns) most likely to be stale.
# Widen the buffer for the call, and still accept a truncated prefix.
function Test-WingetIdListed([string]$Id, [string]$Text) {
    if ($Text -match [regex]::Escape($Id)) { return $true }
    for ($len = $Id.Length - 1; $len -ge 12; $len--) {
        if ($Text -match ([regex]::Escape($Id.Substring(0, $len)) + '\u2026')) { return $true }
    }
    return $false
}

function Get-WingetUpgradable([string[]]$Ids) {
    $previous = $null
    try {
        $previous = $Host.UI.RawUI.BufferSize
        $wide = $previous
        if ($wide.Width -lt 300) {
            $wide.Width = 300
            $Host.UI.RawUI.BufferSize = $wide
        } else { $previous = $null }
    } catch { $previous = $null }

    try {
        $out = winget upgrade --accept-source-agreements --disable-interactivity 2>&1 | Out-String
    } finally {
        if ($previous) { try { $Host.UI.RawUI.BufferSize = $previous } catch { } }
    }

    $upgradable = @()
    foreach ($id in $Ids) {
        if (Test-WingetIdListed -Id $id -Text $out) { $upgradable += $id }
    }
    return ,$upgradable
}

# ---------------------------------------------------------------------------
# Download helper (mirrors dev-setup.sh: everything lands in ~/Downloads, not TEMP)
# ---------------------------------------------------------------------------
function Get-RemoteFile([string]$Url, [string]$OutFile) {
    if ($DryRun) {
        Write-Host "  [dry-run] would download $Url -> $OutFile" -ForegroundColor Yellow
        return $true
    }
    # Windows PowerShell 5.1's Invoke-WebRequest predates -MaximumRetryCount
    # (PS7+ only), so retries are hand-rolled here to match dev-setup.sh's
    # CURL_RETRY behavior on flaky networks.
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing
            return $true
        } catch {
            if ($attempt -eq 3) {
                Write-LogErr "Download failed: $Url ($($_.Exception.Message))"
                return $false
            }
            Start-Sleep -Seconds 2
        }
    }
    return $false
}

function Test-NeedsElevationResult($Result) {
    # Strict: never use `$Result -eq 'needs-elevation'` alone. In PowerShell,
    # `$true -eq 'needs-elevation'` is $true (non-empty string coerces to bool),
    # which wrongly marked successful dry-runs as needs-elevation.
    return ($Result -is [string] -and $Result -eq 'needs-elevation')
}

function Invoke-StepFunc {
    param([string]$Id, [string]$Desc, [scriptblock]$Func)
    Write-LogStep $Desc
    if ($DryRun) {
        $ok = & $Func
        if (Test-NeedsElevationResult $ok) {
            $Results[$Id] = 'needs-elevation'
            Write-LogWarn "$Desc`: would need an elevated PowerShell (dry-run)"
            return
        }
        $Results[$Id] = if ($ok) { 'dry-run' } else { 'dry-run-error' }
        if (-not $ok) { Write-LogWarn "$Desc`: dry-run reported a problem, see above" }
        return
    }
    try {
        $ok = & $Func
    } catch {
        Write-LogErr "Unhandled error in ${Id}: $($_.Exception.Message)"
        $ok = $false
    }
    # 'needs-elevation' is not a bug: the step refused to change system state
    # without admin. Count it separately so unelevated full runs can still
    # exit 0 after installing everything that does not need elevation.
    if (Test-NeedsElevationResult $ok) {
        $Results[$Id] = 'needs-elevation'
        Write-LogWarn "$Desc skipped - needs elevation (see re-run hint above)"
    } elseif ($ok) {
        $Results[$Id] = 'OK'
        Write-LogOk "$Desc done"
    } else {
        $Results[$Id] = 'FAILED'
        Write-LogErr "$Desc failed - continuing with the next step (see $LogFile)"
    }
}

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------
function Test-Preconditions {
    if (-not (Test-CmdExists 'winget')) {
        Write-LogErr "winget (Windows Package Manager) was not found. Install 'App Installer' from the"
        Write-LogErr "Microsoft Store, then re-run this script."
        exit 1
    }
    $ver = [Environment]::OSVersion.Version
    if ($ver.Major -lt 10 -or ($ver.Major -eq 10 -and $ver.Build -lt 22000)) {
        Write-LogWarn "This does not look like Windows 11 (build $($ver.Build)). The script targets"
        Write-LogWarn "Windows 11 64-bit and may not work correctly elsewhere."
        if (-not (Confirm-Step "Continue anyway?")) { exit 1 }
    }
    if (-not [Environment]::Is64BitOperatingSystem) {
        Write-LogWarn "This does not look like a 64-bit Windows install; most winget packages here target x64."
        if (-not (Confirm-Step "Continue anyway?")) { exit 1 }
    }
}

# ---------------------------------------------------------------------------
# Steps: languages / toolchains
# ---------------------------------------------------------------------------

function Step_prereqs {
    Write-LogInfo "Refreshing winget source index..."
    if (-not $DryRun) { winget source update | Out-Null }
    $ok = $true
    foreach ($tool in @('curl', 'tar')) {
        if (Test-CmdExists $tool) { Write-LogInfo "$tool available (built into Windows 11)" }
        else { Write-LogWarn "$tool not found on PATH"; $ok = $false }
    }
    return $ok
}

# Fixed directories other steps add tools into - checked/re-added to the
# user's PATH each run, the same role PATH_MANAGED_DIRS plays in dev-setup.sh.
$PathManagedDirs = @(
    (Join-Path $env:APPDATA 'npm'),
    (Join-Path $env:APPDATA 'Python\Scripts'),
    (Join-Path $env:USERPROFILE '.dotnet\tools'),
    (Join-Path $env:APPDATA 'Composer\vendor\bin'),
    (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps')
)

# Winget Python + pip --user Scripts dirs (versioned under %APPDATA%\Python\Python3xx\Scripts).
function Get-PythonPathDirs {
    $dirs = New-Object System.Collections.Generic.List[string]
    $pyRoot = Get-ChildItem "$env:LOCALAPPDATA\Programs\Python" -Directory -Filter 'Python3*' -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1
    if ($pyRoot) {
        [void]$dirs.Add($pyRoot.FullName)
        $scripts = Join-Path $pyRoot.FullName 'Scripts'
        if (Test-Path -LiteralPath $scripts) { [void]$dirs.Add($scripts) }
    }
    $userPy = Join-Path $env:APPDATA 'Python'
    if (Test-Path -LiteralPath $userPy) {
        Get-ChildItem $userPy -Directory -Filter 'Python*' -ErrorAction SilentlyContinue | ForEach-Object {
            $s = Join-Path $_.FullName 'Scripts'
            if (Test-Path -LiteralPath $s) { [void]$dirs.Add($s) }
        }
        $legacy = Join-Path $userPy 'Scripts'
        if (Test-Path -LiteralPath $legacy) { [void]$dirs.Add($legacy) }
    }
    return ,(@($dirs | Select-Object -Unique))
}

function Ensure-PythonOnPath {
    $added = 0
    $dirs = Get-PythonPathDirs
    foreach ($dir in @($dirs)) {
        if (-not $dir) { continue }
        if (Add-UserPath $dir) { $added++ }
        elseif (($env:Path -split ';') -notcontains $dir) {
            $env:Path = "$dir;$env:Path"
        }
    }
    # Prefer the real interpreter ahead of the WindowsApps Store stub this session.
    $exe = Get-PythonExe
    if ($exe) {
        $dir = Split-Path -Parent $exe
        $scripts = Join-Path $dir 'Scripts'
        $env:Path = (@($dir, $scripts) + ($env:Path -split ';' | Where-Object { $_ -and $_ -ne $dir -and $_ -ne $scripts })) -join ';'
    }
    return $added
}

function Step_path_check {
    $fixed = 0
    $pyDirs = Get-PythonPathDirs
    $managed = @($PathManagedDirs) + @($pyDirs)
    foreach ($dir in $managed) {
        if (-not $dir -or -not (Test-Path -LiteralPath $dir)) { continue }
        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        $already = $userPath -and (($userPath -split ';') -contains $dir)
        $alreadySession = ($env:Path -split ';') -contains $dir
        if (-not $already) {
            Write-LogWarn "$dir exists but isn't on your User PATH; adding it now"
            if (Add-UserPath $dir) { $fixed++ }
        } elseif (-not $alreadySession) {
            $env:Path = "$env:Path;$dir"
        }
    }
    $fixed += Ensure-PythonOnPath

    $missing = @()
    foreach ($tool in @('code', 'docker', 'kubectl', 'rg', 'fd', 'bat', 'fzf', 'jq', 'git', 'gh', 'php', 'composer', 'python', 'pip')) {
        if (-not (Test-CmdExists $tool)) { $missing += $tool }
    }
    if ($missing.Count -gt 0) {
        Write-LogInfo "Not on PATH right now (fine if not installed yet, or needs a new shell): $($missing -join ', ')"
    }
    Write-LogOk "PATH check complete ($fixed dir(s) added to your User PATH)"
    return $true
}

function Step_git_gh {
    $ok1 = Install-Winget -Id 'Git.Git' -Name 'Git'
    $ok2 = Install-Winget -Id 'GitHub.cli' -Name 'GitHub CLI'
    Import-EnvFile

    $gitUserName = Get-Cfg 'GIT_USER_NAME'
    $gitUserEmail = Get-Cfg 'GIT_USER_EMAIL'
    if ($gitUserName -or $gitUserEmail) {
        Write-LogInfo "Checking git identity against $EnvFile"
        $curName = git config --global user.name 2>$null
        $curEmail = git config --global user.email 2>$null
        if ($gitUserName -and $gitUserName -ne $curName) {
            Write-LogInfo "git user.name changed: '$curName' -> '$gitUserName'; publishing globally"
            Invoke-Native git @('config', '--global', 'user.name', $gitUserName) | Out-Null
        }
        if ($gitUserEmail -and $gitUserEmail -ne $curEmail) {
            Write-LogInfo "git user.email changed: '$curEmail' -> '$gitUserEmail'; publishing globally"
            Invoke-Native git @('config', '--global', 'user.email', $gitUserEmail) | Out-Null
        }
    } elseif (-not $Yes -and -not $DryRun -and -not (git config --global user.email 2>$null)) {
        if (Confirm-Step "git user.name/user.email are not set globally. Configure them now?") {
            $gname = Read-Host '  git user.name'
            $gmail = Read-Host '  git user.email'
            if ($gname) { git config --global user.name $gname }
            if ($gmail) { git config --global user.email $gmail }
        }
    }

    $ghToken = Get-Cfg 'GH_TOKEN'
    if ($ghToken) {
        $tokenHashFile = Join-Path $StateDir 'gh-token-sha256'
        $newHash = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($ghToken))) -replace '-', ''
        $oldHash = if (Test-Path $tokenHashFile) { Get-Content $tokenHashFile -Raw } else { '' }
        $tokenChanged = $newHash -ne $oldHash.Trim()

        if ($DryRun) {
            if ($tokenChanged) { Write-LogInfo "[dry-run] would authenticate gh via GH_TOKEN (token changed since last run)" }
            else { Write-LogInfo "[dry-run] GH_TOKEN unchanged since last run; would skip re-authenticating gh" }
        } else {
            $ghAuthed = (gh auth status 2>&1 | Out-String) -match 'Logged in'
            if ($ghAuthed -and -not $tokenChanged) {
                Write-LogInfo "gh already authenticated and GH_TOKEN in .env is unchanged, skipping login"
            } else {
                if ($tokenChanged) { Write-LogInfo "GH_TOKEN in $EnvFile changed since the last run; re-authenticating gh" }
                $ghToken | gh auth login --with-token | Out-Host
                if ($LASTEXITCODE -eq 0) {
                    Write-LogOk "gh authenticated via GH_TOKEN"
                    Set-Content -Path $tokenHashFile -Value $newHash -NoNewline
                } else {
                    Write-LogWarn "gh auth login --with-token failed; check GH_TOKEN in $EnvFile"
                }
            }
        }
    }
    return ($ok1 -and $ok2)
}

# Light C++ toolchain: enough for Code::Blocks + CMake/Ninja/clang builds
# (PvZ-Portable-style MinGW workflows). Does NOT install Visual Studio Build
# Tools or the Windows SDK - those are a multi-GB download; see cpp_msvc.
function Step_cpp_build {
    $ok = $true
    $ok = (Install-Winget -Id 'Kitware.CMake' -Name 'CMake') -and $ok
    $ok = (Install-Winget -Id 'Ninja-build.Ninja' -Name 'Ninja') -and $ok
    $ok = (Install-Winget -Id 'LLVM.LLVM' -Name 'LLVM (clang/lldb)') -and $ok
    $ok = (Install-Winget -Id 'Ccache.Ccache' -Name 'ccache') -and $ok
    # The MinGW bundle, not plain CodeBlocks.CodeBlocks: Code::Blocks doesn't
    # ship a compiler of its own, so the plain package would be a C++ IDE
    # with nothing to actually build with until you separately install and
    # wire up a toolchain by hand.
    $ok = (Install-Winget -Id 'CodeBlocks.CodeBlocks.MinGW' -Name 'Code::Blocks (with MinGW)') -and $ok
    return $ok
}

# Optional / default-N: MSVC + Windows SDK via VS 2022 Build Tools. Needed for
# projects that require cl.exe / Windows SDK headers (Win32, some .NET native,
# Chromium-style builds). Skip this if MinGW/clang from cpp_build is enough -
# the VCTools workload with --includeRecommended routinely pulls several GB
# (MSVC toolset + Windows SDK + ATL/MFC recommendations).
function Step_cpp_msvc {
    $vsOverride = '--quiet --wait --norestart --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended'
    if ($DryRun) {
        Write-Host "  [dry-run] would install Visual Studio 2022 Build Tools with the C++ (VCTools)" -ForegroundColor Yellow
        Write-Host "  [dry-run] workload + recommended components (includes Windows SDK) - multi-GB" -ForegroundColor Yellow
        return $true
    }
    Write-LogInfo "This installs MSVC (cl.exe) and typically the Windows SDK via VS Build Tools."
    Write-LogInfo "Expect a large download and a long install. For MinGW-only work, skip this step"
    Write-LogInfo "and use cpp_build (CMake + Ninja + clang + Code::Blocks/MinGW) instead."
    return (Install-Winget -Id 'Microsoft.VisualStudio.2022.BuildTools' -Name 'Visual Studio Build Tools (C++ workload + Windows SDK)' -OverrideArgs $vsOverride)
}

function Step_java_scala {
    $ok = Install-Winget -Id 'EclipseAdoptium.Temurin.21.JDK' -Name 'Temurin JDK 21 (LTS)'
    # sbt bootstraps the Scala compiler/version per-project on first use, so a
    # JDK + sbt is a complete Scala dev setup without a separate Scala install.
    $ok = (Install-Winget -Id 'sbt.sbt' -Name 'sbt') -and $ok
    return $ok
}

function Step_dotnet {
    return Install-Winget -Id 'Microsoft.DotNet.SDK.10' -Name '.NET SDK 10 (current LTS)'
}

$PythonGlobalTools = @('poetry', 'ruff', 'black', 'mypy', 'httpie', 'ipython', 'pre-commit')

function Step_python {
    # PrependPath so python.exe / Scripts land on User PATH (not only the Store stub).
    $ok = Install-Winget -Id 'Python.Python.3.13' -Name 'Python 3.13' `
        -OverrideArgs 'PrependPath=1 InstallAllUsers=0 Include_launcher=1 Include_test=0 SimpleInstall=1'
    if ($DryRun) {
        Write-Host ("  [dry-run] would ensure Python + Scripts on User PATH, then: python -m pip install --user --upgrade {0}" -f ($PythonGlobalTools -join ' ')) -ForegroundColor Yellow
        return $ok
    }
    # Bypass PATH resolution entirely: Windows' "python" App Execution Alias
    # stub in WindowsApps\ shadows the real interpreter ahead of it on PATH,
    # so a bare `python` call here would hit the Store stub, not winget's install.
    Ensure-PythonOnPath | Out-Null
    $pythonExe = Get-PythonExe
    if (-not $pythonExe) {
        Write-LogErr "Could not locate python.exe under $env:LOCALAPPDATA\Programs\Python after install"
        return $false
    }
    Write-LogInfo "Using $pythonExe"
    # An earlier version of this script used pipx, which shims each tool as a
    # symlink-like stub under ~\.local\bin - that directory sits ahead of the
    # global pip install's Scripts dir on PATH, so a leftover pipx shim would
    # keep shadowing the real global install below. Retire it if present.
    if (Test-CmdExists 'pipx') {
        Write-LogInfo "Removing old pipx-managed installs (switching to a global pip install)..."
        foreach ($tool in $PythonGlobalTools) {
            & $pythonExe -m pipx uninstall $tool 2>&1 | Out-Null
        }
    }

    # Installed straight into the user site-packages (one shared environment,
    # no pipx, no per-tool venv) so every tool's console script lands
    # directly on PATH, matching a normal system-wide pip install.
    & $pythonExe -m pip install --user --upgrade @PythonGlobalTools | Out-Host
    if ($LASTEXITCODE -ne 0) { Write-LogWarn "some pip installs failed"; $ok = $false }
    Ensure-PythonOnPath | Out-Null
    Update-SessionPath
    if (Test-CmdExists 'python') {
        Write-LogOk "python is on PATH: $((Get-Command python).Source)"
    } else {
        Write-LogWarn "python still not resolving on PATH in this shell; open a new terminal or re-run -Only path_check"
    }
    return $ok
}

function Get-PythonExe {
    $dir = Get-ChildItem "$env:LOCALAPPDATA\Programs\Python" -Directory -Filter 'Python3*' -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1
    if ($dir) {
        $exe = Join-Path $dir.FullName 'python.exe'
        if (Test-Path $exe) { return $exe }
    }
    return $null
}

$NpmGlobalTools = @('typescript', 'eslint', 'prettier', 'pnpm', 'yarn')

function Step_node_nvm {
    $ok = Install-Winget -Id 'CoreyButler.NVMforWindows' -Name 'nvm-windows'
    if ($DryRun) {
        Write-Host "  [dry-run] would import NVM_HOME/NVM_SYMLINK into PATH, then: nvm install lts; nvm use <lts>; npm install -g npm@latest $($NpmGlobalTools -join ' ')" -ForegroundColor Yellow
        return $ok
    }
    $found = $false
    for ($i = 1; $i -le 12; $i++) {
        if (Import-NvmWindows) { $found = $true; break }
        Start-Sleep -Seconds 2
    }
    if (-not $found) {
        Write-LogErr "nvm.exe not found after nvm-windows install (NVM_HOME/PATH not published yet)."
        Write-LogErr "Close other installers if any are running, then re-run: .\dev-setup.ps1 -Only node_nvm"
        return $false
    }
    Write-LogInfo "nvm on PATH (NVM_HOME=$env:NVM_HOME)"
    if (-not (Test-Admin)) {
        Write-LogWarn "nvm-windows needs an elevated (Run as Administrator) shell to switch the active Node"
        Write-LogWarn "version (symlink under Program Files). Re-run:"
        Write-LogWarn "  .\dev-setup.ps1 -Only node_nvm   # from an elevated PowerShell / dev-setup-admin.cmd"
        return 'needs-elevation'
    }
    nvm install lts | Out-Host
    $installed = (nvm list 2>&1 | Select-String -Pattern '\d+\.\d+\.\d+' | Select-Object -First 1)
    if ($installed) {
        $verNum = $installed.Matches[0].Value
        nvm use $verNum | Out-Host
    }
    Import-NvmWindows | Out-Null
    if ($env:NVM_SYMLINK -and (Test-Path $env:NVM_SYMLINK)) {
        $env:Path = "$env:NVM_SYMLINK;$env:Path"
        Add-UserPath $env:NVM_SYMLINK | Out-Null
    }
    $npmCmd = Get-Command npm -ErrorAction SilentlyContinue
    if (-not $npmCmd -and $env:NVM_SYMLINK) {
        $npmBat = Join-Path $env:NVM_SYMLINK 'npm.cmd'
        if (Test-Path $npmBat) { $npmCmd = $npmBat }
    }
    if (-not $npmCmd) {
        Write-LogErr "npm still not on PATH after nvm use (symlink $env:NVM_SYMLINK). Re-run this step after nvm finishes."
        return $false
    }
    Write-LogInfo "Installing global npm libraries: npm@latest $($NpmGlobalTools -join ' ')"
    npm install -g npm@latest @NpmGlobalTools | Out-Host
    if ($LASTEXITCODE -ne 0) { Write-LogWarn "some global npm packages failed to install" }
    corepack enable 2>$null | Out-Null
    return $true
}

$ComposerGlobalPackages = @('laravel/installer')

$PhpExtensions = @('openssl', 'curl', 'mbstring', 'fileinfo', 'zip', 'gd', 'intl', 'bcmath', 'pdo_mysql', 'mysqli', 'pdo_pgsql', 'pgsql', 'pdo_sqlite', 'sqlite3')

function Step_php {
    $ok = Install-Winget -Id 'PHP.PHP.8.4' -Name 'PHP 8.4'
    if (-not (Test-CmdExists 'php') -and -not $DryRun) {
        Write-LogErr "php not found on PATH after install; skipping Composer/Laravel setup"
        return $false
    }

    if (-not $DryRun) {
        # winget's PHP package ships only php.ini-development/-production
        # templates, not an active php.ini - with none present PHP loads zero
        # extensions (not just openssl, which is what breaks Composer/HTTPS)
        # so this mirrors what apt's php-mysql/php-curl/php-zip/etc. packages
        # give you out of the box on Linux.
        $phpDir = Split-Path -Parent (Get-Command php).Source
        $iniPath = Join-Path $phpDir 'php.ini'
        if (-not (Test-Path $iniPath)) {
            $template = Join-Path $phpDir 'php.ini-development'
            if (Test-Path $template) {
                Copy-Item $template $iniPath
                $extDir = Join-Path $phpDir 'ext'
                (Get-Content $iniPath) -replace '^;?\s*extension_dir\s*=.*', "extension_dir = `"$extDir`"" |
                    Set-Content $iniPath
                foreach ($ext in $PhpExtensions) {
                    (Get-Content $iniPath) -replace "^;extension=$ext(\s|$)", "extension=$ext`$1" | Set-Content $iniPath
                }
                Write-LogOk "Created php.ini and enabled: $($PhpExtensions -join ', ')"
            } else {
                Write-LogWarn "No php.ini-development template found under $phpDir; PHP has no extensions enabled"
            }
        }
    }
    $composerDir = Join-Path $env:LOCALAPPDATA 'Programs\composer'
    New-Item -ItemType Directory -Force -Path $composerDir | Out-Null
    $composerPhar = Join-Path $composerDir 'composer.phar'
    $composerBat  = Join-Path $composerDir 'composer.bat'

    if ((Test-CmdExists 'composer') -or (Test-Path $composerPhar)) {
        Write-LogInfo "Composer already installed, skipping installer"
    } else {
        $installerPhp = Join-Path $DownloadDir 'composer-setup.php'
        if (-not (Get-RemoteFile 'https://getcomposer.org/installer' $installerPhp)) {
            $ok = $false
        } elseif ($DryRun) {
            Write-Host "  [dry-run] would verify the installer's sha384 signature, then install to $composerPhar" -ForegroundColor Yellow
        } else {
            # .Content comes back as byte[] (not string) for some content-types under
            # Windows PowerShell 5.1's Invoke-WebRequest - decode explicitly rather
            # than assuming .Trim() (a string-only method) is available on it.
            $sigResponse = Invoke-WebRequest -Uri 'https://composer.github.io/installer.sig' -UseBasicParsing
            $expected = if ($sigResponse.Content -is [byte[]]) {
                [Text.Encoding]::UTF8.GetString($sigResponse.Content).Trim()
            } else {
                $sigResponse.Content.Trim()
            }
            $actual = (php -r "echo hash_file('sha384', '$installerPhp');")
            if (-not $expected -or $expected -ne $actual) {
                Write-LogErr "Composer installer signature mismatch (expected '$expected', got '$actual'); aborting"
                Remove-Item -Force $installerPhp -ErrorAction SilentlyContinue
                $ok = $false
            } else {
                php $installerPhp --quiet --install-dir=$composerDir --filename=composer.phar | Out-Host
                Remove-Item -Force $installerPhp -ErrorAction SilentlyContinue
                if ($LASTEXITCODE -eq 0 -and (Test-Path $composerPhar)) {
                    Set-Content -Path $composerBat -Value "@echo off`r`nphp `"%~dp0composer.phar`" %*" -NoNewline
                } else {
                    Write-LogErr "Composer installer ran but composer.phar was not created (exit code $LASTEXITCODE)"
                    $ok = $false
                }
            }
        }
    }
    Add-UserPath $composerDir | Out-Null
    $composerUserBin = Join-Path $env:APPDATA 'Composer\vendor\bin'
    if (Test-Path $composerUserBin) { Add-UserPath $composerUserBin | Out-Null }

    if ((Test-CmdExists 'composer') -or (Test-Path $composerBat) -or $DryRun) {
        $composerCmd = if (Test-CmdExists 'composer') { 'composer' } else { $composerBat }
        if (-not (Invoke-Native $composerCmd (@('global', 'require', '--no-interaction') + $ComposerGlobalPackages))) {
            Write-LogWarn "composer global require failed for: $($ComposerGlobalPackages -join ', ')"
            $ok = $false
        }
    } else {
        Write-LogWarn "Composer not available; skipping $($ComposerGlobalPackages -join ', ')"
        $ok = $false
    }
    return $ok
}

# ---------------------------------------------------------------------------
# Steps: editors / GUI apps
# ---------------------------------------------------------------------------

function Step_vscode {
    return Install-Winget -Id 'Microsoft.VisualStudioCode' -Name 'Visual Studio Code'
}

$VSCodeExtensionsCore = @(
    'eamodio.gitlens', 'mhutchie.git-graph', 'editorconfig.editorconfig',
    'usernamehw.errorlens', 'streetsidesoftware.code-spell-checker',
    'christian-kohler.path-intellisense', 'redhat.vscode-yaml',
    'tomoki1207.pdf', 'mechatroner.rainbow-csv', 'anthropic.claude-code'
)

$VSCodeExtensionsByStack = @{
    node_nvm   = @('esbenp.prettier-vscode', 'dbaeumer.vscode-eslint', 'dsznajder.es7-react-js-snippets', 'bradlc.vscode-tailwindcss')
    python     = @('ms-python.python', 'ms-python.vscode-pylance', 'charliermarsh.ruff', 'ms-toolsai.jupyter')
    java_scala = @('scalameta.metals')
    php        = @('bmewburn.vscode-intelephense-client', 'onecentlin.laravel-blade')
    dotnet     = @('ms-dotnettools.csharp', 'ms-dotnettools.csdevkit')
    cpp_build  = @('ms-vscode.cpptools', 'ms-vscode.cmake-tools')
    docker     = @('ms-azuretools.vscode-docker', 'ms-vscode-remote.remote-containers')
    kubectl    = @('ms-kubernetes-tools.vscode-kubernetes-tools')
    playwright = @('ms-playwright.playwright')
}

function Get-VscodeExtensionsForRun {
    $list = [System.Collections.Generic.List[string]]::new()
    foreach ($e in $VSCodeExtensionsCore) { [void]$list.Add($e) }
    $skippedStacks = @()
    foreach ($stack in @($VSCodeExtensionsByStack.Keys)) {
        if (Test-StackEnabled $stack) {
            foreach ($e in $VSCodeExtensionsByStack[$stack]) {
                if (-not $list.Contains($e)) { [void]$list.Add($e) }
            }
        } else {
            $skippedStacks += $stack
        }
    }
    return [pscustomobject]@{ Extensions = @($list); SkippedStacks = $skippedStacks }
}

function Step_vscode_ext {
    if (-not (Test-CmdExists 'code') -and -not $DryRun) {
        Write-LogWarn "VS Code (code CLI) not found; install the vscode step first"
        return $false
    }
    $plan = Get-VscodeExtensionsForRun
    if ($plan.SkippedStacks.Count -gt 0) {
        Write-LogInfo ("Skipping VS Code extensions for stacks not present or skipped this run: " + ($plan.SkippedStacks -join ', '))
    }
    $failures = 0
    foreach ($ext in $plan.Extensions) {
        if (-not (Invoke-Native 'code' @('--install-extension', $ext, '--force'))) {
            Write-LogWarn "extension failed: $ext"
            $failures++
        }
    }
    return ($failures -eq 0)
}

function Step_cursor {
    return Install-Winget -Id 'Anysphere.Cursor' -Name 'Cursor'
}

function Step_chatgpt {
    # OpenAI ships ChatGPT desktop for Windows only through the Microsoft Store
    # (see https://chatgpt.com/download) - there is no standalone .exe like the
    # Linux .deb this step downloads directly in dev-setup.sh, and deliberately
    # so: OpenAI's own guidance warns that malware has been distributed as
    # fake "ChatGPT desktop" installers outside the Store, so this step won't
    # hardcode a direct-download URL for it the way it does for e.g. RustDesk.
    if (Get-AppxPackage -Name '*ChatGPT*' -ErrorAction SilentlyContinue) {
        Write-LogInfo "ChatGPT desktop already installed, skipping"
        return $true
    }
    if ($DryRun) {
        Write-Host "  [dry-run] winget install --id 9NT1R1C2HH7J --source msstore" -ForegroundColor Yellow
        return $true
    }
    winget install --id 9NT1R1C2HH7J --source msstore --accept-package-agreements --accept-source-agreements --silent | Out-Host
    if ($LASTEXITCODE -eq 0) { return $true }
    Write-LogWarn "Microsoft Store install failed (store source unreachable/blocked here)."
    Write-LogWarn "Install manually from https://chatgpt.com/download - avoid any other .exe claiming to be it."
    return $false
}

function Step_editor_pdf {
    # Notepad++ + SumatraPDF + MarkText. Sublime Text is paid (evaluation nag), dropped 2026.
    $ok = $true
    $ok = (Install-Winget -Id 'Notepad++.Notepad++' -Name 'Notepad++') -and $ok
    $ok = (Install-Winget -Id 'SumatraPDF.SumatraPDF' -Name 'SumatraPDF') -and $ok
    $ok = (Install-Winget -Id 'MarkText.MarkText' -Name 'MarkText') -and $ok
    return $ok
}

function Step_libreoffice {
    return Install-Winget -Id 'TheDocumentFoundation.LibreOffice' -Name 'LibreOffice'
}

function Step_postman_newman {
    $ok = Install-Winget -Id 'Postman.Postman' -Name 'Postman'
    if ((Test-CmdExists 'npm') -or $DryRun) {
        if (-not (Invoke-Native 'npm' @('install', '-g', 'newman', 'newman-reporter-htmlextra'))) { $ok = $false }
    } else {
        Write-LogWarn "npm not found (run the node_nvm step first); skipping newman"
        $ok = $false
    }
    return $ok
}

function Step_playwright {
    if (-not (Test-CmdExists 'npm') -and -not $DryRun) {
        Write-LogWarn "npm not found (run the node_nvm step first); skipping playwright"
        return $false
    }
    $ok = Invoke-Native 'npm' @('install', '-g', 'playwright')
    Write-LogInfo "Downloading Playwright browsers..."
    if (-not (Invoke-Native 'npx' @('--yes', 'playwright', 'install'))) {
        Write-LogWarn "playwright browser download had issues; you can rerun 'npx playwright install' later"
    }
    return $ok
}

function Step_docker {
    $wslOk = $false
    try {
        $wslStatus = wsl --status 2>&1 | Out-String
        $wslOk = ($LASTEXITCODE -eq 0)
    } catch { }
    if (-not $wslOk) {
        Write-LogWarn "WSL2 does not look installed/enabled - Docker Desktop needs it. This is a Windows"
        Write-LogWarn "feature toggle (system setting), so run it yourself in an elevated PowerShell first:"
        Write-LogWarn "  wsl --install"
        Write-LogWarn "then reboot and re-run: .\dev-setup.ps1 -Only docker"
    }
    return Install-Winget -Id 'Docker.DockerDesktop' -Name 'Docker Desktop'
}

function Step_kubectl {
    return Install-Winget -Id 'Kubernetes.kubectl' -Name 'kubectl'
}

function Step_archive_tools {
    return Install-Winget -Id '7zip.7zip' -Name '7-Zip'
}

$CliToolsWinget = @(
    @{ Id = 'BurntSushi.ripgrep.MSVC'; Name = 'ripgrep (rg)' }
    @{ Id = 'sharkdp.fd'; Name = 'fd' }
    @{ Id = 'sharkdp.bat'; Name = 'bat' }
    @{ Id = 'junegunn.fzf'; Name = 'fzf' }
    @{ Id = 'jqlang.jq'; Name = 'jq' }
    @{ Id = 'MikeFarah.yq'; Name = 'yq' }
    @{ Id = 'dandavison.delta'; Name = 'git-delta' }
    @{ Id = 'dbrgn.tealdeer'; Name = 'tealdeer (tldr)' }
    @{ Id = 'direnv.direnv'; Name = 'direnv' }
    @{ Id = 'JesseDuffield.lazygit'; Name = 'lazygit' }
    @{ Id = 'aristocratos.btop4win'; Name = 'btop4win (htop/glances equivalent)' }
    @{ Id = 'AntibodySoftware.WizTree'; Name = 'WizTree (ncdu equivalent)' }
    @{ Id = 'Microsoft.WindowsTerminal'; Name = 'Windows Terminal (tmux-adjacent: tabs/panes)' }
    @{ Id = 'Anthropic.ClaudeCode'; Name = 'Claude Code CLI' }
)

function Step_cli_tools {
    $ok = $true
    foreach ($t in $CliToolsWinget) {
        $ok = (Install-Winget -Id $t.Id -Name $t.Name) -and $ok
    }
    return $ok
}

# Chrome from google.com / Google Update is often not correlated to winget's
# Google.Chrome id, so Test-WingetInstalled alone misses it and we try to
# install an older enterprise MSI that refuses the downgrade.
function Test-ChromeInstalled {
    $paths = @(
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
        "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
    )
    foreach ($p in $paths) {
        if (Test-Path -LiteralPath $p) { return $true }
    }
    return $false
}

function Step_chrome {
    if ((Test-WingetInstalled 'Google.Chrome') -or (Test-ChromeInstalled)) {
        Write-LogInfo 'Google Chrome already installed, skipping'
        return $true
    }
    return Install-Winget -Id 'Google.Chrome' -Name 'Google Chrome'
}

function Install-Aimp {
    # winget's AIMP.AIMP manifest is stale and 404s: it still points at
    # aimp.ru/files/windows/...5.10.2418..., but the site has since moved to
    # /files/desktop/... and is now on 5.40+. aimp.ru's own "?do=download.file
    # &id=3" link redirects to whatever the current Windows 64-bit installer
    # actually is (confirmed by resolving it directly), so download through
    # that instead of a version-pinned URL that will just go stale again.
    if (Test-Path "${env:ProgramFiles}\AIMP\AIMP.exe") {
        Write-LogInfo "AIMP already installed, skipping"
        return $true
    }
    if ($DryRun) {
        Write-Host "  [dry-run] would download AIMP from https://aimp.ru/?do=download.file&id=3 and run it with /AUTO /SILENT" -ForegroundColor Yellow
        return $true
    }
    $exe = Join-Path $DownloadDir 'aimp-setup.exe'
    if (-not (Get-RemoteFile 'https://aimp.ru/?do=download.file&id=3' $exe)) { return $false }
    $ok = Invoke-Native $exe @('/AUTO', '/SILENT')
    if ($ok) { Write-LogOk "AIMP installed" } else { Write-LogWarn "AIMP installer exited with an error" }
    return $ok
}

function Step_media_apps {
    # Desktop media apps only (no Zoom, that is its own optional step).
    $ok = $true
    $ok = (Install-Winget -Id 'dotPDN.PaintDotNet' -Name 'Paint.NET') -and $ok
    $ok = (Install-Winget -Id 'IrfanSkiljan.IrfanView' -Name 'IrfanView') -and $ok
    $ok = (Install-Winget -Id 'IrfanSkiljan.IrfanView.PlugIns' -Name 'IrfanView PlugIns') -and $ok
    $ok = (Install-Aimp) -and $ok
    $ok = (Install-Winget -Id 'CodecGuide.K-LiteCodecPack.Mega' -Name 'K-Lite Mega Codec Pack') -and $ok
    return $ok
}

function Step_comms_zoom {
    return Install-Winget -Id 'Zoom.Zoom' -Name 'Zoom'
}

# Free CLI tools for AI / local media+PDF work (ffmpeg, images, PDF text/OCR).
# Kept separate from media_apps GUIs so headless/server profiles can still get them.
function Step_ai_media {
    $ok = $true
    $ok = (Install-Winget -Id 'Gyan.FFmpeg' -Name 'FFmpeg') -and $ok
    $ok = (Install-Winget -Id 'ImageMagick.ImageMagick' -Name 'ImageMagick') -and $ok
    $ok = (Install-Winget -Id 'oschwartz10612.Poppler' -Name 'Poppler (pdftotext/pdfinfo/pdftoppm)') -and $ok
    $ok = (Install-Winget -Id 'QPDF.QPDF' -Name 'QPDF') -and $ok
    $ok = (Install-Winget -Id 'UB-Mannheim.TesseractOCR' -Name 'Tesseract OCR') -and $ok
    if ($DryRun) {
        Write-Host '  [dry-run] would pip install --user ocrmypdf (if python is available)' -ForegroundColor Yellow
        return $ok
    }
    Ensure-PythonOnPath | Out-Null
    $pythonExe = Get-PythonExe
    if ($pythonExe) {
        Write-LogInfo 'Installing ocrmypdf (searchable PDF OCR) into the user site-packages...'
        & $pythonExe -m pip install --user --upgrade ocrmypdf | Out-Host
        if ($LASTEXITCODE -ne 0) {
            Write-LogWarn 'ocrmypdf pip install failed (Tesseract/Poppler/QPDF are still installed)'
            $ok = $false
        } else {
            Ensure-PythonOnPath | Out-Null
            Write-LogOk 'ocrmypdf ready (needs tesseract + poppler on PATH)'
        }
    } else {
        Write-LogWarn 'Python not found yet, skip ocrmypdf. Re-run -Only python,ai_media later.'
    }
    Update-SessionPath
    return $ok
}

function Get-TightVncRoot {
    foreach ($root in @("$env:ProgramFiles\TightVNC", "${env:ProgramFiles(x86)}\TightVNC")) {
        if (Test-Path -LiteralPath $root) { return $root }
    }
    return $null
}

function Test-TightVncViewer {
    $root = Get-TightVncRoot
    return [bool]($root -and (Test-Path -LiteralPath (Join-Path $root 'tvnviewer.exe')))
}

function Test-TightVncServerInstalled {
    return [bool](Get-Service -Name 'tvnserver' -ErrorAction SilentlyContinue)
}

# One winget id (GlavSoft.TightVNC) installs Viewer and/or Server via MSI ADDLOCAL.
# Keep already-present features when adding the other so a Viewer-only install
# is not stripped when remote_vnc later adds the Server.
function Install-TightVnc {
    param(
        [switch]$Viewer,
        [switch]$Server
    )
    $wantViewer = [bool]$Viewer
    $wantServer = [bool]$Server
    if (-not $wantViewer -and -not $wantServer) {
        Write-LogWarn 'Install-TightVnc called with no components'
        return $false
    }

    $haveViewer = Test-TightVncViewer
    $haveServer = Test-TightVncServerInstalled
    if ($wantViewer -and $haveViewer -and (-not $wantServer -or $haveServer)) {
        if ($wantServer) {
            Write-LogInfo 'TightVNC Viewer and Server already installed, skipping'
        } else {
            Write-LogInfo 'TightVNC Viewer already installed, skipping'
        }
        return $true
    }
    if ($wantServer -and $haveServer -and (-not $wantViewer -or $haveViewer)) {
        Write-LogInfo 'TightVNC Server already installed, skipping'
        return $true
    }

    $features = New-Object System.Collections.Generic.List[string]
    if ($wantViewer -or $haveViewer) { [void]$features.Add('Viewer') }
    if ($wantServer -or $haveServer) { [void]$features.Add('Server') }
    $addLocal = ($features | Select-Object -Unique) -join ','

    $parts = New-Object System.Collections.Generic.List[string]
    [void]$parts.Add("ADDLOCAL=$addLocal")
    if ($features -contains 'Server') {
        [void]$parts.Add('SERVER_REGISTER_AS_SERVICE=1')
        [void]$parts.Add('SERVER_ADD_FIREWALL_EXCEPTION=1')
        Import-EnvFile
        $pw = Get-Cfg 'REMOTE_PASSWORD'
        if ($pw) {
            Write-LogInfo 'TightVNC uses REMOTE_PASSWORD as the VNC secret only (no new Windows login).'
            [void]$parts.Add('SET_USEVNCAUTHENTICATION=1')
            [void]$parts.Add('VALUE_OF_USEVNCAUTHENTICATION=1')
            [void]$parts.Add('SET_PASSWORD=1')
            [void]$parts.Add("VALUE_OF_PASSWORD=$pw")
        } elseif ($wantServer) {
            Write-LogWarn "No REMOTE_PASSWORD in $EnvFile; installing TightVNC Server without a password - set"
            Write-LogWarn 'one yourself afterward (TightVNC Server icon in the tray > Configuration).'
        }
    }
    [void]$parts.Add('/quiet')
    $override = $parts -join ' '

    $label = if ($wantViewer -and $wantServer) { 'TightVNC (Viewer + Server)' }
        elseif ($wantViewer) { 'TightVNC Viewer' }
        else { 'TightVNC Server' }

    if ($DryRun) {
        $safe = ($override -replace 'VALUE_OF_PASSWORD=\S+', 'VALUE_OF_PASSWORD=<redacted>')
        Write-Host "  [dry-run] would install $label via GlavSoft.TightVNC ($safe)" -ForegroundColor Yellow
        return $true
    }

    # Same package id for both features: force reinstall when winget already
    # lists GlavSoft.TightVNC but a required feature is still missing.
    $force = (Test-WingetInstalled 'GlavSoft.TightVNC') -and (
        ($wantViewer -and -not $haveViewer) -or ($wantServer -and -not $haveServer))

    return Install-Winget -Id 'GlavSoft.TightVNC' -Name $label -OverrideArgs $override -Force:$force
}

function Step_vnc_viewer {
    # Client machines only. Built-in mstsc.exe covers RDP. TightVNC Viewer is free GPL , 
    # RealVNC Connect is a paid trial / account product (removed 2026).
    return Install-TightVnc -Viewer
}

function Step_remote_vnc {
    # Server / share-this-desktop machines only (port 5900). Independent of vnc_viewer , 
    # skip one or the other per machine role.
    return Install-TightVnc -Server
}

function Step_obs {
    return Install-Winget -Id 'OBSProject.OBSStudio' -Name 'OBS Studio'
}

# ---------------------------------------------------------------------------
# Steps: communication apps
# ---------------------------------------------------------------------------

function Step_comms_slack {
    return Install-Winget -Id 'SlackTechnologies.Slack' -Name 'Slack'
}

function Test-TeamsInstalled {
    # Real presence for the new Teams client, not winget's list alone. winget
    # can report Microsoft.Teams installed while Start has nothing (wrong user
    # registration, or a later win11_cleanup pass stripped the Appx).
    if (Get-AppxPackage -Name 'MSTeams' -ErrorAction SilentlyContinue) { return $true }
    if (Get-AppxPackage -Name 'MicrosoftTeams' -ErrorAction SilentlyContinue) { return $true }
    if (Test-Path -LiteralPath (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\ms-teams.exe')) { return $true }
    $start = @(Get-StartApps -ErrorAction SilentlyContinue | Where-Object {
            $_.AppID -like 'MSTeams_*' -or $_.Name -eq 'Microsoft Teams'
        })
    return ($start.Count -gt 0)
}

function Repair-TeamsAppxRegistration {
    # Package staged machine-wide but not registered for this user → invisible in Start.
    $pkg = $null
    try {
        $pkg = Get-AppxPackage -Name 'MSTeams' -AllUsers -ErrorAction SilentlyContinue |
            Sort-Object -Property Version -Descending |
            Select-Object -First 1
    } catch { }
    if (-not $pkg) { return $false }
    $manifest = Join-Path $pkg.InstallLocation 'AppxManifest.xml'
    if (-not (Test-Path -LiteralPath $manifest)) { return $false }
    Write-LogInfo "Registering staged MSTeams package for the current user..."
    try {
        Add-AppxPackage -Register $manifest -DisableDevelopmentMode -ErrorAction Stop
        return (Test-TeamsInstalled)
    } catch {
        Write-LogWarn "Could not register MSTeams for this user: $($_.Exception.Message)"
        return $false
    }
}

function Step_comms_teams {
    # Prefer the Microsoft Store product (same path that works when installing
    # manually), then the winget community MSIX. Always verify Appx/Start , 
    # never trust winget exit 0 alone.
    if (Test-TeamsInstalled) {
        Write-LogInfo "Microsoft Teams already installed, skipping"
        return $true
    }
    if ($DryRun) {
        Write-Host "  [dry-run] winget install --id XP8BT8DW290MPQ --source msstore (Teams)" -ForegroundColor Yellow
        Write-Host "  [dry-run] fallback: winget install --id Microsoft.Teams -e --source winget" -ForegroundColor Yellow
        return $true
    }
    if (-not (Wait-InstallerIdle)) { return $false }

    Write-LogInfo "Installing Microsoft Teams from the Microsoft Store..."
    winget install --id XP8BT8DW290MPQ --source msstore --accept-package-agreements --accept-source-agreements --silent --disable-interactivity 2>&1 | Out-Host
    if (Test-TeamsInstalled) {
        Write-LogOk "Microsoft Teams installed (Store)"
        return $true
    }

    Write-LogWarn "Store install did not register Teams for this user; trying winget community MSIX (Microsoft.Teams)..."
    if (-not (Install-Winget -Id 'Microsoft.Teams' -Name 'Microsoft Teams' -Force)) {
        Write-LogWarn "winget Microsoft.Teams reported failure"
    }
    if (Test-TeamsInstalled) {
        Write-LogOk "Microsoft Teams installed"
        return $true
    }

    if (Repair-TeamsAppxRegistration) {
        Write-LogOk "Microsoft Teams registered for this user"
        return $true
    }

    Write-LogErr "Microsoft Teams is not visible in Start after install."
    Write-LogErr "Install manually from the Microsoft Store (search 'Microsoft Teams'), or:"
    Write-LogErr "  winget install --id XP8BT8DW290MPQ --source msstore"
    return $false
}

function Step_comms_notion {
    return Install-Winget -Id 'Notion.Notion' -Name 'Notion'
}

function Step_comms_pumble {
    if (Test-Path "$env:LOCALAPPDATA\Programs\pumble-desktop\Pumble.exe") {
        Write-LogInfo "Pumble already installed, skipping"
        return $true
    }

    Write-LogInfo "No winget package for Pumble; looking up the current version from pumble.com"
    if ($DryRun) {
        Write-Host "  [dry-run] would resolve and download the current Pumble-win-*.exe from pumble.com/apps, then run it silently" -ForegroundColor Yellow
        return $true
    }
    try {
        $page = (Invoke-WebRequest -Uri 'https://pumble.com/apps' -UseBasicParsing).Content
    } catch {
        Write-LogWarn "Could not reach pumble.com/apps: $($_.Exception.Message)"
        return $false
    }
    $m = [regex]::Match($page, 'https://pumble\.com/download/desktop/windows/Pumble-win-[0-9.]+\.exe')
    if (-not $m.Success) {
        Write-LogWarn "Could not find a current Pumble .exe link on pumble.com/apps"
        Write-LogWarn "Install manually: https://pumble.com/apps"
        return $false
    }
    $url = $m.Value
    $exe = Join-Path $DownloadDir (Split-Path $url -Leaf)
    if (-not (Get-RemoteFile $url $exe)) { return $false }

    # Pumble ships a Squirrel.Windows installer, not an NSIS one - there's no
    # "/S" silent switch to pass (Squirrel installs unattended by default);
    # it hands off to a detached updater process and its own visible process
    # exits almost immediately, well before the real install finishes, so
    # poll for the result instead of trusting that quick exit.
    Start-Process -FilePath $exe | Out-Null
    $installed = $false
    for ($i = 0; $i -lt 12; $i++) {
        Start-Sleep -Seconds 5
        if (Get-Process -Name 'Pumble' -ErrorAction SilentlyContinue) { $installed = $true; break }
    }
    if (-not $installed) {
        Write-LogWarn "Pumble installer launched but didn't confirm within 60s - check manually"
        return $false
    }
    return $true
}

function Step_comms_linear {
    return Install-Winget -Id 'LinearOrbit.Linear' -Name 'Linear'
}

function Step_comms_clockify {
    return Install-Winget -Id 'Clockify.Clockify' -Name 'Clockify'
}

# ---------------------------------------------------------------------------
# Remote access: OpenSSH Server, built-in Windows RDP, RustDesk, DWService.
# All credentials come from $EnvFile - see .env-sample.
#
# NOTE: remote_ssh and remote_rdp flip Windows security settings (an inbound
# service + firewall rule) and need an elevated (Administrator) PowerShell -
# same as dev-setup.sh needing sudo for its equivalent steps. Run them
# yourself from an elevated prompt; this script will tell you plainly if it
# isn't elevated instead of silently doing nothing.
# ---------------------------------------------------------------------------

function Step_remote_ssh {
    Import-EnvFile
    $pw = Get-Cfg 'REMOTE_PASSWORD'
    if (-not $pw) {
        Write-LogWarn "No REMOTE_PASSWORD in $EnvFile. SSH can still be enabled for your current account."
    }
    if (-not (Test-Admin) -and -not $DryRun) {
        Write-LogWarn "This step needs an elevated PowerShell (installs a Windows feature + a service +"
        Write-LogWarn "a firewall rule). Re-run:"
        Write-LogWarn "  .\dev-setup.ps1 -Only remote_ssh   # as Administrator / via dev-setup-admin.cmd"
        return 'needs-elevation'
    }

    if ($DryRun) {
        Write-Host "  [dry-run] would install the OpenSSH.Server capability, enable+start sshd, open the" -ForegroundColor Yellow
        Write-Host "  [dry-run] firewall for it, then ask before creating/updating any OS user" -ForegroundColor Yellow
        [void](Get-RemoteUserDecision)
        return $true
    }

    $cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' | Select-Object -First 1
    if ($cap.State -ne 'Installed') {
        Add-WindowsCapability -Online -Name $cap.Name | Out-Null
    }
    Set-Service -Name sshd -StartupType Automatic
    Start-Service sshd

    $sshdConfig = Join-Path $env:ProgramData 'ssh\sshd_config'
    if (Test-Path $sshdConfig) {
        $content = Get-Content $sshdConfig -Raw
        if ($content -notmatch '(?m)^PasswordAuthentication\s+yes') {
            Add-Content -Path $sshdConfig -Value "`nPasswordAuthentication yes`n"
            Restart-Service sshd
        }
    }

    $remoteUser = Invoke-RemoteOsUser
    Write-LogInfo "SSH remote login will use OS account '$remoteUser'"

    $rule = Get-NetFirewallRule -DisplayName 'OpenSSH SSH Server (sshd)' -ErrorAction SilentlyContinue
    if (-not $rule) {
        New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH SSH Server (sshd)' `
            -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
    }
    return $true
}

function Step_remote_rdp {
    Import-EnvFile
    if (-not (Test-Admin) -and -not $DryRun) {
        Write-LogWarn "This step needs an elevated PowerShell (registry + firewall rule). Re-run:"
        Write-LogWarn "  .\dev-setup.ps1 -Only remote_rdp   # as Administrator / via dev-setup-admin.cmd"
        return 'needs-elevation'
    }
    if ($DryRun) {
        Write-Host "  [dry-run] would enable Remote Desktop (fDenyTSConnections=0) and its firewall rule group" -ForegroundColor Yellow
        [void](Get-RemoteUserDecision)
        return $true
    }
    Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections' -Value 0
    Enable-NetFirewallRule -DisplayGroup 'Remote Desktop'
    $remoteUser = Invoke-RemoteOsUser
    Add-LocalGroupMember -Group 'Remote Desktop Users' -Member $remoteUser -ErrorAction SilentlyContinue
    Write-LogInfo "Added '$remoteUser' to Remote Desktop Users (existing account; no new login was implied)"
    return $true
}

function Get-RustDeskAsset {
    $json = Invoke-RestMethod -Uri 'https://api.github.com/repos/rustdesk/rustdesk/releases/latest'
    $asset = $json.assets | Where-Object { $_.name -match '^rustdesk-[\d.]+-x86_64\.exe$' } | Select-Object -First 1
    return $asset
}

function Test-RustDeskInstalled {
    (Test-Path "$env:ProgramFiles\RustDesk\rustdesk.exe") -or (Get-Service -Name rustdesk -ErrorAction SilentlyContinue)
}

function Step_remote_rustdesk {
    if (Test-RustDeskInstalled) { Write-LogInfo "RustDesk already installed, skipping package install" }
    else {
        Write-LogInfo "Resolving the latest RustDesk release for Windows x86_64..."
        if ($DryRun) {
            Write-Host "  [dry-run] would download rustdesk-<version>-x86_64.exe from the latest GitHub release" -ForegroundColor Yellow
            Write-Host "  [dry-run] and run it with --silent-install" -ForegroundColor Yellow
        } else {
            $asset = Get-RustDeskAsset
            if (-not $asset) { Write-LogErr "Could not resolve the latest RustDesk Windows asset from GitHub"; return $false }
            $exe = Join-Path $DownloadDir $asset.name
            if (-not (Test-Path $exe)) {
                if (-not (Get-RemoteFile $asset.browser_download_url $exe)) { return $false }
            }
            # --silent-install self-elevates via UAC; unattended it can't be
            # answered, so instead of installing it just launches the plain
            # app (which never exits) and `& $exe` would then block forever -
            # bound the wait and verify the real install location afterward
            # rather than trusting the process ever returning.
            $proc = Start-Process -FilePath $exe -ArgumentList '--silent-install' -PassThru
            $proc | Wait-Process -Timeout 30 -ErrorAction SilentlyContinue
            if (-not $proc.HasExited) {
                Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
                Get-Process -Name 'rustdesk' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            }
            Start-Sleep -Seconds 3
            if (-not (Test-RustDeskInstalled)) {
                if (-not (Test-Admin)) {
                    Write-LogErr "RustDesk did not install (needs an elevated PowerShell to register its service - same"
                    Write-LogErr "as DWService). Re-run: .\dev-setup.ps1 -Only remote_rustdesk as Administrator"
                } else {
                    Write-LogErr "RustDesk installer did not complete - check $DownloadDir\$($asset.name) manually"
                }
                return $false
            }
        }
    }

    Import-EnvFile
    $pw = Get-Cfg 'RUSTDESK_PASSWORD'
    if (-not $pw) { $pw = Get-Cfg 'REMOTE_PASSWORD' }
    if ($pw) {
        if ($DryRun) {
            Write-Host "  [dry-run] would set the RustDesk permanent password (value withheld from this log)" -ForegroundColor Yellow
        } else {
            $rustdeskPath = "$env:ProgramFiles\RustDesk\rustdesk.exe"
            if (-not (Test-Path $rustdeskPath)) {
                $rustdeskPath = (Get-Command rustdesk -ErrorAction SilentlyContinue).Source
            }
            if ($rustdeskPath) {
                & $rustdeskPath --password $pw | Out-Host
                Write-LogOk "RustDesk permanent password set."
            } else {
                Write-LogWarn "rustdesk.exe not found; set the password by hand once it's installed:"
                Write-LogWarn "  rustdesk.exe --password <password>"
            }
        }
    } else {
        Write-LogWarn "No RUSTDESK_PASSWORD/REMOTE_PASSWORD in $EnvFile; RustDesk is installed but has no"
        Write-LogWarn "permanent access password set - set one with: rustdesk.exe --password <password>"
    }
    return $true
}

# ---------------------------------------------------------------------------
# DWService's Windows installer is a self-extracting bootstrapper, not a
# process that exits when its wizard closes: it unpacks a bundled Python
# runtime, re-launches itself elevated through its own runasadmin.install
# flag file, registers the DWAgent service, and then leaves the agent's
# monitor/systray process running as a child of that tree. So waiting on the
# process we started either returns immediately (the elevation handoff) or
# never returns at all (the systray child holds the tree open) - which is
# exactly why remote_dwservice_manual looked hung forever after the wizard
# had in fact already finished. Poll for the artifacts the installer really
# leaves behind instead, and use "no dwagent process left alive" as the
# give-up signal rather than process exit.
# ---------------------------------------------------------------------------

$DwAgentUninstallKeys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\DWAgent',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\DWAgent'
)

function Test-DwAgentInstalled {
    if (Get-Service -Name 'DWAgent' -ErrorAction SilentlyContinue) { return $true }
    foreach ($key in $DwAgentUninstallKeys) {
        $loc = (Get-ItemProperty -Path $key -Name 'InstallLocation' -ErrorAction SilentlyContinue).InstallLocation
        if ($loc -and (Test-Path -LiteralPath $loc)) { return $true }
    }
    return $false
}

function Get-DwAgentProcess {
    # ,@(...) for the same reason as Get-WingetUpgradeBlocker below: with no
    # dwagent process running - the normal case on every poll - a bare @()
    # return reaches the caller as $null and makes $null.Count throw. Callers
    # must therefore NOT re-wrap this in @(), or empty would read as Count 1.
    return ,@(Get-Process -Name 'dwagent', 'dwagsvc', 'dwaglnc' -ErrorAction SilentlyContinue)
}

function Wait-DwAgentInstall {
    param(
        [System.Diagnostics.Process]$Process,
        [int]$TimeoutSec = 1800,
        [int]$GraceSec = 20
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $nextTick = (Get-Date).AddSeconds(60)
    $goneSince = $null
    while ((Get-Date) -lt $deadline) {
        if (Test-DwAgentInstalled) {
            Write-LogOk "DWAgent is registered (service + uninstall entry present) - installer finished."
            return $true
        }
        $alive = (Get-DwAgentProcess).Count -gt 0
        if (-not $alive -and $Process) {
            try { $alive = -not $Process.HasExited } catch { $alive = $false }
        }
        if ($alive) {
            $goneSince = $null
        } elseif (-not $goneSince) {
            $goneSince = Get-Date
        } elseif (((Get-Date) - $goneSince).TotalSeconds -ge $GraceSec) {
            Write-LogWarn "The DWService installer exited without registering the DWAgent service"
            Write-LogWarn "(wizard cancelled, or 'Run without installation' was chosen)."
            return $false
        }
        if ((Get-Date) -ge $nextTick) {
            Write-LogInfo "Still waiting for the DWService wizard - finish it in its own window."
            Write-LogInfo "Ctrl+C stops this wait only; the wizard keeps running either way."
            $nextTick = (Get-Date).AddSeconds(60)
        }
        Start-Sleep -Seconds 3
    }
    Write-LogWarn "Stopped waiting after ${TimeoutSec}s. If you did finish the wizard, confirm with:"
    Write-LogWarn "  .\dev-setup.ps1 -Only remote_check"
    return $false
}

# Interactive DWService install only. Silent/unattended install is a
# business/org-account feature and is not available for normal/personal
# accounts (DWService support confirms this), so there is no silent step.
function Step_remote_dwservice {
    if (Test-DwAgentInstalled) {
        Write-LogInfo "DWService agent already installed, skipping"
        return $true
    }
    if ($Yes -and $Only.Count -eq 0) {
        Write-LogWarn "Skipping - DWService needs the interactive installer wizard and can't run"
        Write-LogWarn "under an unattended -Yes full run. Run it on its own:"
        Write-LogWarn "  .\dev-setup.ps1 -Only remote_dwservice"
        return $false
    }
    Import-EnvFile
    $code = Get-Cfg 'DWSERVICE_KEY'
    $codeLabel = 'installation code (DWSERVICE_KEY)'
    if (-not $code) { $code = Get-Cfg 'DWSERVICE_PASSWORD'; $codeLabel = 'agent installation password (DWSERVICE_PASSWORD)' }
    if (-not $code) {
        Write-LogWarn "No DWSERVICE_KEY or DWSERVICE_PASSWORD in $EnvFile to copy to the clipboard; you'll"
        Write-LogWarn "need to enter one by hand when the installer asks for it."
    }
    $installer = Join-Path $DownloadDir 'dwagent.exe'
    $needDl = $true
    if (Test-Path -LiteralPath $installer) {
        $len = (Get-Item -LiteralPath $installer).Length
        # Real dwagent.exe is multi-MB; tiny/HTML downloads are corrupt.
        if ($len -gt 1MB) { $needDl = $false }
        else {
            Write-LogWarn "Existing dwagent.exe looks too small ($len bytes); re-downloading."
            Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
        }
    }
    if ($needDl) {
        if (-not (Get-RemoteFile 'https://www.dwservice.net/download/dwagent.exe' $installer)) { return $false }
    }
    if ($DryRun) {
        Write-Host "  [dry-run] would Unblock-File, elevate, and run the interactive DWService wizard" -ForegroundColor Yellow
        return $true
    }
    # Mark-of-the-Web / SmartScreen often blocks a freshly downloaded exe until unblocked.
    try { Unblock-File -LiteralPath $installer -ErrorAction Stop } catch { }
    if ($code) {
        try {
            Set-Clipboard -Value $code
            Write-LogOk "Copied the DWService $codeLabel to your clipboard - paste it (Ctrl+V) when the"
            Write-LogOk "installer below asks for it."
        } catch {
            Write-LogWarn "Clipboard unavailable ($($_.Exception.Message)). Paste this $codeLabel by hand:"
            Write-Host $code
        }
    }
    Write-LogInfo "Launching DWService's interactive installer - complete its wizard in the window"
    Write-LogInfo "that opens. Approve the UAC prompt (installer must run elevated)."
    Write-LogInfo "If SmartScreen says 'Windows protected your PC', click More info -> Run anyway."
    Write-LogInfo "This step watches for the DWAgent service instead of waiting on the installer"
    Write-LogInfo "process, which does not exit when the wizard closes."

    $proc = $null
    try {
        if (Test-Admin) {
            $proc = Start-Process -FilePath $installer -WorkingDirectory $DownloadDir -PassThru
        } else {
            # Explicit elevation: without RunAs the bootstrapper may exit before the wizard
            # appears, or UAC handoff loses the process handle we were watching.
            $proc = Start-Process -FilePath $installer -WorkingDirectory $DownloadDir -Verb RunAs -PassThru
        }
    } catch {
        Write-LogErr "Could not start dwagent.exe: $($_.Exception.Message)"
        Write-LogErr "Open $installer from Explorer (Run as administrator) if UAC was cancelled."
        return $false
    }
    if (-not $proc) {
        Write-LogWarn "Installer process handle unavailable (UAC elevation handoff). Still watching for DWAgent registration..."
    }
    if (-not (Wait-DwAgentInstall -Process $proc)) {
        Write-LogWarn "DWService is not installed. Re-run this step to try the wizard again:"
        Write-LogWarn "  .\dev-setup.ps1 -Only remote_dwservice"
        Write-LogWarn "Or double-click: $installer"
        return $false
    }
    return $true
}

# Read-only status report. It deliberately separates "you did not enable this"
# (informational - skipping remote_rdp is a legitimate choice, and the step
# used to report FAILED for it) from "this is installed but not working"
# (the only thing worth failing the step over).
function Step_remote_check {
    $broken = @()
    $off = @()

    Write-LogInfo "=== SSH ==="
    $sshd = Get-Service -Name sshd -ErrorAction SilentlyContinue
    if ($sshd) {
        if ($sshd.Status -eq 'Running') { Write-LogOk "sshd is running" }
        else { Write-LogWarn "sshd service exists but is not running"; $broken += 'SSH (service installed but stopped)' }
    } else { Write-LogInfo "OpenSSH Server not installed (remote_ssh not run)"; $off += 'SSH' }

    Write-LogInfo "=== Remote Desktop (RDP) ==="
    $deny = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -ErrorAction SilentlyContinue).fDenyTSConnections
    if ($deny -eq 0) { Write-LogOk "Remote Desktop is enabled" }
    else { Write-LogInfo "Remote Desktop is disabled (remote_rdp not run)"; $off += 'RDP' }

    Write-LogInfo "=== RustDesk ==="
    if (Test-RustDeskInstalled) {
        Write-LogOk "rustdesk installed"
        # NOT $cfg: PowerShell's scope lookup for unqualified variables follows
        # the call stack, not lexical definition site, so a local $cfg here
        # (case-insensitively the same name) would shadow the script-scoped
        # $Cfg hashtable for the rest of this call stack - including inside
        # Get-Cfg, called a few lines down - turning it into this string.
        $rustdeskCfgPath = Join-Path $env:APPDATA 'RustDesk\config\RustDesk2.toml'
        if (Test-Path $rustdeskCfgPath) { Write-LogOk "RustDesk has a local config (password likely set)" }
        else { Write-LogWarn "No RustDesk config found yet - run it once or set a password"; $broken += 'RustDesk (installed, no config/password)' }
    } else { Write-LogInfo "rustdesk not installed (remote_rustdesk not run)"; $off += 'RustDesk' }

    Write-LogInfo "=== DWService ==="
    $dw = Get-Service -Name 'DWAgent' -ErrorAction SilentlyContinue
    if ($dw -and $dw.Status -eq 'Running') { Write-LogOk "dwagent service is active" }
    elseif ($dw) { Write-LogWarn "dwagent installed but not running"; $broken += 'DWService (service installed but stopped)' }
    else { Write-LogInfo "DWService (dwagent) not installed (remote_dwservice not run)"; $off += 'DWService' }

    Write-LogInfo "=== TightVNC / VNC ==="
    $tvn = Get-Service -Name 'tvnserver' -ErrorAction SilentlyContinue
    if ($tvn) {
        if ($tvn.Status -eq 'Running') { Write-LogOk "TightVNC Server (tvnserver) is running" }
        else { Write-LogWarn "TightVNC Server is installed but not running"; $broken += 'TightVNC (service installed but stopped)' }
    } else { Write-LogInfo "TightVNC Server not installed (remote_vnc not run)"; $off += 'VNC' }

    Write-LogInfo "=== Firewall ==="
    Get-NetFirewallProfile | Select-Object Name, Enabled | Format-Table | Out-String | Write-Host

    $ip = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceAlias -notmatch 'Loopback' } | Select-Object -First 1).IPAddress
    if ($ip) {
        Import-EnvFile
        $remoteUser = Get-Cfg 'REMOTE_USER'
        if ([string]::IsNullOrWhiteSpace($remoteUser)) { $remoteUser = $env:USERNAME }
        Write-LogInfo "Reachable at $ip - SSH: ssh ${remoteUser}@$ip | RDP: ${ip}:3389 | VNC: ${ip}:5900"
    }

    Write-LogInfo "=== Result ==="
    if ($off.Count -gt 0) {
        Write-LogInfo "Not enabled (fine if that was deliberate): $($off -join ', ')"
    }
    if ($broken.Count -gt 0) {
        Write-LogErr "Enabled but not working: $($broken -join '; ')"
        return $false
    }
    Write-LogOk "Nothing is half-configured: everything installed here is running."
    return $true
}

# ---------------------------------------------------------------------------
# Battery charge limiting. Keeping a lithium cell off 100% is one of the
# best-documented ways to slow its wear, but Windows has no generic
# charge-threshold API at all - no equivalent of Linux's
# charge_control_end_threshold sysfs attribute that dev-setup.sh writes
# directly. The cap lives in the laptop's embedded controller, so only the
# UEFI firmware or the vendor's own tool can set it.
#
# Every option below is free (open source where one exists, otherwise the
# vendor's own no-cost app). What this step deliberately does NOT do is
# install a third-party tool that pokes EC registers over a generic
# ring-0 driver (the WinRing0-based ones): those need per-model register
# discovery, get the wrong register wrong silently, and WinRing0 itself is
# on Microsoft's vulnerable-driver blocklist. That is a bad trade for a
# machine-setup script to make on the user's behalf.
# ---------------------------------------------------------------------------

# Matched against Win32_ComputerSystem.Manufacturer. Tool/Id pairs were
# verified against `winget search`; entries with no Id have no free
# installable tool and are firmware-only.
$BatteryChargeTools = @(
    @{  Match = 'LENOVO'
        Tool = 'Lenovo Vantage'; Id = '9WZDNCRFJ4MV'; Source = 'msstore'; Appx = '*LenovoCompanion*'
        Where = 'Vantage > Device > Power > Battery Charge Threshold (custom %), or Conservation Mode (~55-60%)'
        Alt = 'Lenovo Legion Toolkit (open source, Legion/LOQ/IdeaPad)'; AltId = 'LenovoLegionToolkitTeam.LenovoLegionToolkit'; AltSource = 'winget' }
    @{  Match = 'ASUS'
        Tool = 'G-Helper (open source, single exe, installs no service)'; Id = 'seerge.g-helper'; Source = 'winget'
        Where = 'G-Helper > Fans + Power > Battery charge limit'
        Alt = 'MyASUS (vendor app)'; AltId = '9N7R5S6B0ZZH'; AltSource = 'msstore'; AltAppx = '*MyASUS*' }
    @{  Match = 'Dell|Alienware'
        Tool = 'Dell Optimizer (supersedes Dell Power Manager)'; Id = 'Dell.Optimizer'; Source = 'winget'
        Where = 'Dell Optimizer > Power > Battery Information > Advanced Charge / Custom start-stop levels' }
    @{  Match = 'Micro-Star|MSI'
        Tool = 'MSI Center'; Id = 'MSI.MSICenter'; Source = 'winget'
        Where = 'MSI Center > System Diagnosis > Battery Master (60% / 80% / 100%)' }
    @{  Match = 'HP|Hewlett'
        Tool = 'UEFI firmware setting (no Windows app needed)'
        Where = 'Reboot > F10 > Advanced/Power Management > Battery Health Manager > "Maximize my battery health" (~80%). Consumer models may only expose HP Support Assistant''s Adaptive Battery Optimizer.' }
    @{  Match = 'Acer'
        Tool = 'AcerSense / Acer Care Center (vendor app, from Acer support or the Store)'
        Where = 'Acer Care Center > Checkup/Battery > Battery Charge Limit (80%)' }
    @{  Match = 'Samsung'
        Tool = 'Samsung Settings (preinstalled on Galaxy Book)'
        Where = 'Samsung Settings > Battery and performance > Battery Protection (85% cap)' }
    @{  Match = 'LG'
        Tool = 'LG Smart Assistant (preinstalled on gram)'
        Where = 'LG Smart Assistant > Power Setting > Extend Battery Life (80%)' }
    @{  Match = 'Microsoft'
        Tool = 'Surface app / Surface UEFI'
        Where = 'Surface app > Battery & charging > Limit to 80%; or Surface UEFI (hold Vol-Up at boot) > Boot configuration > Enable Battery Limit' }
    @{  Match = 'Framework'
        Tool = 'UEFI firmware setting (no Windows app needed)'
        Where = 'Reboot > F2 > Advanced > Charge Limit' }
    @{  Match = 'Razer'
        Tool = 'Razer Synapse'
        Where = 'Synapse > System > Power > Battery Health Optimizer > charge limit' }
    # Clevo/Tongfang barebones sold under many badges. These almost always
    # expose the cap in firmware as "FlexiCharger" rather than in any app,
    # which is the better place for it anyway.
    @{  Match = 'MECHREVO|Clevo|TongFang|Hasee|Eluktronics|Schenker|XMG|Notebook|Standard'
        Tool = 'UEFI firmware setting - "FlexiCharger" (Clevo/Tongfang barebones)'
        Where = 'Reboot > F2/Del > Advanced (or Power) > FlexiCharger > Enabled, then set Start/Stop charge %' }
    @{  Match = 'HUAWEI|HONOR'
        Tool = 'Huawei/Honor PC Manager (vendor app, preinstalled)'
        Where = 'PC Manager > Settings > Battery > Smart charge / Battery care mode (70% or 80%)' }
    @{  Match = 'GIGABYTE|AORUS'
        Tool = 'GIGABYTE Control Center (vendor app)'
        Where = 'Control Center > Smart Utilities > Charge Mode > Custom / Charge Limit' }
    @{  Match = 'TUXEDO|System76'
        Tool = 'UEFI firmware setting (both ship coreboot/Clevo firmware with a charge cap)'
        Where = 'TUXEDO Control Center > System > Charging profiles; or System76 firmware setup > battery charge thresholds' }
    @{  Match = 'Dynabook|TOSHIBA'
        Tool = 'Dynabook Settings / eco Utility (vendor app)'
        Where = 'Dynabook Settings > Power > Battery Charge Mode (eco charge, ~80%)' }
)

# Design vs full-charge capacity, straight from the battery's own firmware.
# Read-only, and the one genuinely vendor-neutral battery fact Windows will
# hand over: worth printing because a heavily worn cell is the reason to
# start capping in the first place.
function Write-BatteryWearReport {
    try {
        $design = (Get-CimInstance -Namespace 'root\wmi' -ClassName 'BatteryStaticData' -ErrorAction Stop |
            Select-Object -First 1).DesignedCapacity
        $full = (Get-CimInstance -Namespace 'root\wmi' -ClassName 'BatteryFullChargedCapacity' -ErrorAction Stop |
            Select-Object -First 1).FullChargedCapacity
    } catch { return }
    if (-not $design -or -not $full -or $design -le 0) { return }
    $health = [math]::Round(100.0 * $full / $design, 1)
    Write-LogInfo "Battery health: ${full} mWh full charge vs ${design} mWh design = ${health}% of original capacity"
    if ($health -lt 80) {
        Write-LogWarn "This cell has already lost over 20% of its design capacity."
    }
}

function Step_battery_charge_limit {
    $battery = @(Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue)
    if ($battery.Count -eq 0) {
        Write-LogInfo "No battery detected (desktop); nothing to cap. Re-run this step on a laptop:"
        Write-LogInfo "  .\dev-setup.ps1 -Only battery_charge_limit"
        return $true
    }
    Import-EnvFile
    $limit = Get-Cfg 'BATTERY_CHARGE_LIMIT'
    if (-not $limit) { $limit = '80' }

    $mfg = ''
    $model = ''
    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $mfg = [string]$cs.Manufacturer
        $model = [string]$cs.Model
    } catch { }
    Write-LogInfo ("Laptop detected: {0} {1}" -f $mfg, $model).Trim()
    Write-BatteryWearReport
    Write-LogInfo "Windows has no OS-level charge-threshold API (unlike Linux's sysfs control that"
    Write-LogInfo "dev-setup.sh writes directly) - the cap lives in the embedded controller, so it has"
    Write-LogInfo "to come from firmware or your vendor's own free tool. Target from .env: ${limit}%."

    $match = $BatteryChargeTools | Where-Object { $mfg -match $_.Match } | Select-Object -First 1
    if (-not $match) {
        Write-LogWarn "No known free charge-limit tool for manufacturer '${mfg}'."
        Write-LogWarn "Check your UEFI setup screen for 'Battery Charge Threshold', 'FlexiCharger',"
        Write-LogWarn "'Battery Health' or 'Charge Limit' - a firmware cap survives OS reinstalls and"
        Write-LogWarn "keeps working while Windows is asleep or shut down."
        return $true
    }

    Write-LogOk "$($match.Tool)"
    Write-LogInfo "  $($match.Where)"
    if ($match.Contains('Alt')) {
        Write-LogInfo "Alternative: $($match.Alt)"
    }

    $installable = @()
    if ($match.Contains('Id')) {
        $installable += @{ Name = $match.Tool; Id = $match.Id; Source = $match.Source
                           Appx = if ($match.Contains('Appx')) { $match.Appx } else { '' } }
    }
    if ($match.Contains('AltId')) {
        $installable += @{ Name = $match.Alt; Id = $match.AltId; Source = $match.AltSource
                           Appx = if ($match.Contains('AltAppx')) { $match.AltAppx } else { '' } }
    }
    if ($installable.Count -eq 0) {
        Write-LogInfo "Nothing to install - this one is a firmware/preinstalled-app setting."
        return $true
    }

    # Store apps installed from the msstore source do not list under their
    # numeric product id in `winget list`, so an id-only check would keep
    # re-offering an app that is already there. Fall back to the MSIX package
    # name for those.
    $ok = $true
    $present = $installable | Where-Object {
        (Test-WingetInstalled $_.Id) -or
        ($_.Appx -and (Get-AppxPackage -Name $_.Appx -ErrorAction SilentlyContinue))
    } | Select-Object -First 1
    if ($present) {
        Write-LogInfo "$($present.Name) is already installed - set the ${limit}% cap there. This script"
        Write-LogInfo "cannot set it for you: none of these tools expose a scriptable interface."
    } else {
        $first = $installable[0]
        if (Confirm-Step "Install $($first.Name) so you can cap charging at ${limit}%?") {
            $ok = Install-Winget -Id $first.Id -Name $first.Name -Source $first.Source
            if ($ok) { Write-LogOk "Installed. Now open it and set the cap: $($match.Where)" }
        } else {
            Write-LogInfo "Skipped. Install it later with:"
            Write-LogInfo "  winget install --id $($first.Id) -e --source $($first.Source)"
        }
    }

    Write-LogInfo "Whatever you use, prefer the UEFI/firmware setting if your model has one: it survives"
    Write-LogInfo "OS reinstalls and applies while the machine is asleep or off."
    return $ok
}

# ---------------------------------------------------------------------------
# Power management: never sleep / never hibernate / never blank the screen
# (AC and DC), Ultimate Performance power plan. Desk workstation posture -
# same intent as Ubuntu power_management keeping AC plugged-in machines awake.
# ---------------------------------------------------------------------------

function Step_power_management {
    if ($DryRun) {
        Write-Host "  [dry-run] would set Ultimate Performance; never sleep/hibernate;" -ForegroundColor Yellow
        Write-Host "  [dry-run] never turn off the display (monitor-timeout AC+DC = 0); screensaver off;" -ForegroundColor Yellow
        Write-Host "  [dry-run] Fast Startup off; USB/PCIe power-saving off; extend multi-monitor if needed" -ForegroundColor Yellow
        return $true
    }

    # "Ultimate Performance" goes further than "High performance" (it also
    # disables the fine-grained core-parking/platform-idle throttling High
    # performance still allows) - normally Workstation/Enterprise-only, but
    # `-duplicatescheme` from its template GUID unlocks it on Pro too. That
    # command mints a NEW GUID every time it's run, so reuse an existing
    # "Ultimate Performance" scheme by name instead of piling up duplicates
    # on every re-run. Falls back to the always-present "High performance"
    # GUID if duplication isn't available on this edition.
    $existing = powercfg /list | Select-String -Pattern '([0-9a-fA-F-]{36}).*\(Ultimate Performance\)'
    if ($existing) {
        $ultimateGuid = $existing.Matches[0].Groups[1].Value
    } else {
        $dupOut = powercfg -duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61 | Out-String
        $ultimateGuid = if ($dupOut -match '([0-9a-fA-F-]{36})') { $Matches[1] } else { $null }
    }
    $targetGuid = if ($ultimateGuid) { $ultimateGuid } else { '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c' }
    $targetName = if ($ultimateGuid) { 'Ultimate Performance' } else { 'High performance' }
    powercfg /setactive $targetGuid
    if ($LASTEXITCODE -eq 0) {
        Write-LogOk "Active power plan set to $targetName"
    } else {
        Write-LogWarn "Could not activate the '$targetName' power plan; leaving the active plan as-is"
    }

    # Screen / sleep / disk: 0 = Never (Settings > System > Power >
    # "Turn my screen off after" and "Make my device sleep after").
    # Applied on both AC (plugged in) and DC (battery) so a laptop used as
    # a desk machine behaves the same while docked or undocked.
    powercfg /change monitor-timeout-ac 0
    powercfg /change monitor-timeout-dc 0
    powercfg /change standby-timeout-ac 0
    powercfg /change standby-timeout-dc 0
    powercfg /change hibernate-timeout-ac 0
    powercfg /change hibernate-timeout-dc 0
    powercfg /change disk-timeout-ac 0
    powercfg /change disk-timeout-dc 0
    # Also the "Console lock display off timeout" (blank after lock screen).
    powercfg /setacvalueindex SCHEME_CURRENT SUB_VIDEO VIDEOCONLOCK 0 | Out-Null
    powercfg /setdcvalueindex SCHEME_CURRENT SUB_VIDEO VIDEOCONLOCK 0 | Out-Null
    powercfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION 0 | Out-Null
    powercfg /setdcvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION 0 | Out-Null
    powercfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS PBUTTONACTION 0 | Out-Null
    powercfg /setdcvalueindex SCHEME_CURRENT SUB_BUTTONS PBUTTONACTION 0 | Out-Null

    # USB selective suspend + PCI Express link-state power management: off
    powercfg /setacvalueindex SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d8-59146f273967 0 | Out-Null
    powercfg /setdcvalueindex SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d8-59146f273967 0 | Out-Null
    powercfg /setacvalueindex SCHEME_CURRENT 501a4d13-42af-4619-9b6a-9e01328c7a85 ee12f906-d277-404b-b6da-e5fa1a576df5 0 | Out-Null
    powercfg /setdcvalueindex SCHEME_CURRENT 501a4d13-42af-4619-9b6a-9e01328c7a85 ee12f906-d277-404b-b6da-e5fa1a576df5 0 | Out-Null

    # Classic screensaver: off (separate from monitor-timeout above).
    Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name 'ScreenSaveActive' -Value '0' -ErrorAction SilentlyContinue
    Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name 'ScreenSaveTimeOut' -Value '0' -ErrorAction SilentlyContinue
    Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name 'ScreenSaverIsSecure' -Value '0' -ErrorAction SilentlyContinue

    # Hibernate + Fast Startup off - this is a desk workstation, not a laptop-on-battery box.
    powercfg /hibernate off
    try {
        New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name 'HiberbootEnabled' -Value 0 -PropertyType DWord -Force -ErrorAction Stop | Out-Null
        Write-LogOk "Disabled Fast Startup"
    } catch {
        Write-LogWarn "Could not disable Fast Startup (needs elevation)"
    }

    powercfg /setactive SCHEME_CURRENT
    Write-LogOk "Power: $targetName"
    Write-LogOk "Screen: never turn off (AC+DC monitor-timeout=0, lock-screen blank=0, screensaver off)"
    Write-LogOk "Sleep/hibernate: never (AC+DC); lid ignored; USB/PCIe power-saving off"

    Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
    $screenCount = [System.Windows.Forms.Screen]::AllScreens.Count
    if ($screenCount -gt 1) {
        Write-LogInfo "$screenCount displays detected - switching to Extend"
        Start-Process -FilePath "$env:SystemRoot\System32\DisplaySwitch.exe" -ArgumentList '/extend' -Wait
    }
    return $true
}

# ---------------------------------------------------------------------------
# Dev-workstation performance tuning. Windows Defender real-time exclusions
# are a real security-relevant trade-off (less AV coverage for faster
# builds/watchers), so this step only PRINTS the commands - it never runs
# Add-MpPreference itself. Run the printed commands yourself if you want them.
# ---------------------------------------------------------------------------

function Step_perf_tuning {
    if ($DryRun) {
        Write-Host "  [dry-run] would disable NTFS last-access timestamps and Windows' background-app power throttling" -ForegroundColor Yellow
        return $true
    }

    # NTFS updates a last-access timestamp on every file read by default -
    # pure overhead on a dev box (nothing here relies on atime), the closest
    # analogue to dev-setup.sh's inotify-watch-limit tuning: cutting per-file
    # I/O overhead rather than raising a watch ceiling, since Windows has no
    # such ceiling to raise. Needs elevation; a non-elevated run just warns.
    fsutil behavior set disablelastaccess 1 | Out-Host
    if ($LASTEXITCODE -eq 0) {
        Write-LogOk "Disabled NTFS last-access timestamp updates"
    } else {
        Write-LogWarn "Could not disable NTFS last-access timestamps (needs an elevated PowerShell)"
    }

    # Power Throttling (EcoQoS) deliberately slows down background/unfocused
    # processes to save power - exactly what NOT to want for a background
    # compile or watcher running in an unfocused terminal.
    try {
        New-Item -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling' -Force -ErrorAction Stop | Out-Null
        New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling' -Name 'PowerThrottlingOff' -Value 1 -PropertyType DWord -Force -ErrorAction Stop | Out-Null
        Write-LogOk "Disabled Power Throttling for background processes"
    } catch {
        Write-LogWarn "Could not disable Power Throttling (needs an elevated PowerShell)"
    }

    Write-LogInfo "Windows Defender real-time scanning of your source/build trees is a real security"
    Write-LogInfo "trade-off (less AV coverage for faster builds/watchers), so this step only prints"
    Write-LogInfo "the command rather than running it for you:"
    Write-LogInfo "  Add-MpPreference -ExclusionPath 'C:\path\to\your\repos'"
    Write-LogInfo "(run that yourself, scoped to folders you actually trust, from an elevated PowerShell)"

    if (-not (Test-CmdExists 'wsl')) {
        Write-LogInfo "Also consider enabling WSL2 (wsl --install) for any Linux-native toolchain work - it"
        Write-LogInfo "gives you a real inotify/ext4 filesystem for watchers that expect one."
    }
    return $true
}

# ---------------------------------------------------------------------------
# Health check: winget/npm/pip/composer packages this script manages -
# reports upgradable ones and applies the upgrade, mirroring dev-setup.sh's
# apt/snap health_check.
# ---------------------------------------------------------------------------

$ManagedWingetIds = @(
    'Git.Git', 'GitHub.cli', 'Microsoft.VisualStudio.2022.BuildTools', 'Kitware.CMake', 'Ninja-build.Ninja',
    'LLVM.LLVM', 'Ccache.Ccache', 'CodeBlocks.CodeBlocks.MinGW', 'EclipseAdoptium.Temurin.21.JDK', 'sbt.sbt', 'Microsoft.DotNet.SDK.10',
    'Python.Python.3.13', 'CoreyButler.NVMforWindows', 'PHP.PHP.8.4', 'Microsoft.VisualStudioCode',
    'Anysphere.Cursor', 'Notepad++.Notepad++', 'SumatraPDF.SumatraPDF', 'MarkText.MarkText', 'TheDocumentFoundation.LibreOffice',
    'Postman.Postman', 'Docker.DockerDesktop', 'Kubernetes.kubectl', '7zip.7zip', 'Google.Chrome',
    'GlavSoft.TightVNC', 'OBSProject.OBSStudio', 'Gyan.FFmpeg', 'ImageMagick.ImageMagick',
    'oschwartz10612.Poppler', 'QPDF.QPDF', 'UB-Mannheim.TesseractOCR',
    'SlackTechnologies.Slack', 'Microsoft.Teams', 'Notion.Notion', 'LinearOrbit.Linear',
    'Clockify.Clockify', 'Zoom.Zoom', 'dotPDN.PaintDotNet', 'IrfanSkiljan.IrfanView', 'IrfanSkiljan.IrfanView.PlugIns',
    'CodecGuide.K-LiteCodecPack.Mega'
) + ($CliToolsWinget | ForEach-Object { $_.Id })

# winget id -> process names whose running instance blocks that package's own
# in-place upgrade. An Inno Setup / NSIS installer asked to replace a running
# app pops a "close the application" prompt; with --silent that prompt is
# suppressed but the installer still sits there waiting on it, so the upgrade
# never returns. Detect these up front, then ask to close/kill or skip.
$WingetUpgradeBlockers = @{
    'Microsoft.VisualStudioCode'   = @('Code')
    'Anysphere.Cursor'             = @('Cursor')
    'Notepad++.Notepad++'          = @('notepad++')
    'SumatraPDF.SumatraPDF'        = @('SumatraPDF')
    'MarkText.MarkText'            = @('MarkText')
    'Google.Chrome'                = @('chrome')
    'Postman.Postman'              = @('Postman')
    'Docker.DockerDesktop'         = @('Docker Desktop', 'com.docker.backend', 'Docker Desktop Backend')
    'SlackTechnologies.Slack'      = @('slack')
    'Microsoft.Teams'              = @('ms-teams', 'Teams')
    'Notion.Notion'                = @('Notion')
    'LinearOrbit.Linear'           = @('Linear')
    'GlavSoft.TightVNC'            = @('tvnviewer', 'tvnserver')
    'OBSProject.OBSStudio'         = @('obs64', 'obs32', 'obs')
    'Gyan.FFmpeg'                  = @('ffmpeg')
    'ImageMagick.ImageMagick'      = @('magick')
    'TheDocumentFoundation.LibreOffice' = @('soffice', 'soffice.bin')
    'Zoom.Zoom'                    = @('Zoom')
    'dotPDN.PaintDotNet'           = @('PaintDotNet')
    'IrfanSkiljan.IrfanView'       = @('i_view64', 'i_view32')
    'IrfanSkiljan.IrfanView.PlugIns' = @('i_view64', 'i_view32')
    'Clockify.Clockify'            = @('ClockifyWindows')
    'AIMP.AIMP'                    = @('AIMP')
    'Microsoft.VisualStudio.2022.BuildTools' = @('vs_installer', 'devenv')
}

# `return ,@()`, never `return @()`: PowerShell unrolls a returned array into
# the pipeline, so returning an empty one emits *nothing* and the caller gets
# $null - and under Set-StrictMode -Version Latest, $null.Count is a
# terminating error, not 0. The unary comma wraps it so the empty array
# survives as a single output object.
#
# The flip side, and the reason callers below assign this plainly instead of
# writing @(Get-WingetUpgradeBlocker ...): the comma and a call-site @() do
# NOT compose. Wrapping an already-wrapped empty array yields a one-element
# array holding an empty array, i.e. Count 1, which would read as "blocked"
# for every package. Same convention as Get-WingetUpgradable above.
function Get-WingetUpgradeBlocker([string]$Id) {
    if (-not $WingetUpgradeBlockers.ContainsKey($Id)) { return ,@() }
    $running = @()
    foreach ($name in $WingetUpgradeBlockers[$Id]) {
        if (Get-Process -Name $name -ErrorAction SilentlyContinue) { $running += $name }
    }
    return ,$running
}

# True when this script is running *inside* one of the named processes (e.g.
# upgrading Cursor from a Cursor terminal). Killing that process would kill us.
function Test-IsHostingProcess([string[]]$ProcessNames) {
    $names = @()
    try { $names += (Get-Process -Id $PID -ErrorAction Stop).ProcessName } catch { }
    try {
        $parentId = (Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -ErrorAction Stop).ParentProcessId
        if ($parentId) {
            $parent = Get-Process -Id $parentId -ErrorAction SilentlyContinue
            if ($parent) { $names += $parent.ProcessName }
        }
    } catch { }
    foreach ($n in $ProcessNames) {
        if ($names -contains $n) { return $true }
    }
    return $false
}

function Stop-WingetBlockingProcesses([string[]]$ProcessNames, [string]$PackageId) {
    $still = @()
    foreach ($name in $ProcessNames) {
        $procs = @(Get-Process -Name $name -ErrorAction SilentlyContinue)
        if ($procs.Count -eq 0) { continue }
        Write-LogInfo "Stopping $name (pids $($procs.Id -join ',')) so $PackageId can upgrade..."
        foreach ($p in $procs) {
            try {
                $p.CloseMainWindow() | Out-Null
            } catch { }
        }
        Start-Sleep -Seconds 2
        $left = @(Get-Process -Name $name -ErrorAction SilentlyContinue)
        if ($left.Count -gt 0) {
            Write-LogWarn "$name did not exit after CloseMainWindow - forcing Stop-Process..."
            try {
                $left | Stop-Process -Force -ErrorAction Stop
            } catch {
                Write-LogWarn "Could not kill ${name}: $($_.Exception.Message)"
                $still += $name
                continue
            }
            Start-Sleep -Seconds 1
            if (Get-Process -Name $name -ErrorAction SilentlyContinue) { $still += $name }
        }
    }
    return ,$still
}

function Wait-WingetBlockersGone([string[]]$ProcessNames, [int]$TimeoutSec = 120) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $left = @()
        foreach ($name in $ProcessNames) {
            if (Get-Process -Name $name -ErrorAction SilentlyContinue) { $left += $name }
        }
        if ($left.Count -eq 0) { return $true }
        Write-LogInfo "Still waiting for: $($left -join ', ') (close the app window(s), or Ctrl+C to abort this wait)..."
        Start-Sleep -Seconds 3
    }
    return $false
}

# Returns $true if it is safe to run winget upgrade for $Id (blockers gone or none).
# Interactive: ask Close/kill, Skip, or Wait. -Yes: try kill (unless we are
# hosted inside that app). Never Kill the process hosting this script.
function Resolve-WingetRunningApps([string]$Id) {
    $blockers = Get-WingetUpgradeBlocker $Id
    if ($blockers.Count -eq 0) { return $true }

    Write-LogWarn "$Id cannot upgrade while these processes are running: $($blockers -join ', ')"
    Write-LogWarn "A silent winget install would hang on a suppressed 'close the application' prompt."

    if ($DryRun) {
        Write-Host "  [dry-run] would ask: [C]lose/kill and upgrade, [S]kip, or [W]ait for you to close them" -ForegroundColor Yellow
        return $true
    }

    $hosted = Test-IsHostingProcess $blockers
    if ($hosted) {
        Write-LogWarn "This script is running inside $($blockers -join '/'), so it will NOT kill that process"
        Write-LogWarn "(that would abort this run). Close other windows of it, or skip and re-run"
        Write-LogWarn "health_check from an external terminal (Windows Terminal / PowerShell outside the app)."
    }

    if ($Yes) {
        if ($hosted) {
            Write-LogWarn "-Yes: skipping $Id (cannot safely kill the host process). Re-run later from outside it."
            return $false
        }
        Write-LogInfo "-Yes: closing/killing $($blockers -join ', ') so $Id can upgrade..."
        $left = Stop-WingetBlockingProcesses -ProcessNames $blockers -PackageId $Id
        if ($left.Count -gt 0) {
            Write-LogWarn "Still running after kill attempt ($($left -join ', ')) - skipping $Id"
            return $false
        }
        return $true
    }

    Write-Host ''
    Write-Host "  $Id is open. Choose how to proceed:" -ForegroundColor Yellow
    if (-not $hosted) {
        Write-Host '    [C] Close/kill those processes, then upgrade   (default)'
    }
    Write-Host '    [S] Skip this package for now'
    Write-Host '    [W] Wait - I will close them myself, then continue'
    $prompt = if ($hosted) { 'Choice [S/w]' } else { 'Choice [C/s/w]' }
    $ans = Read-Host $prompt
    if ([string]::IsNullOrWhiteSpace($ans)) { $ans = if ($hosted) { 'S' } else { 'C' } }

    switch -Regex ($ans) {
        '^[Cc]' {
            if ($hosted) {
                Write-LogWarn "Refusing to kill the host process - skipping $Id"
                return $false
            }
            $left = Stop-WingetBlockingProcesses -ProcessNames $blockers -PackageId $Id
            if ($left.Count -gt 0) {
                Write-LogWarn "Still running ($($left -join ', ')) - skipping $Id"
                return $false
            }
            Write-LogOk "Processes closed; upgrading $Id"
            return $true
        }
        '^[Ww]' {
            Write-LogInfo "Waiting up to 2 minutes for you to close: $($blockers -join ', ')"
            if (Wait-WingetBlockersGone -ProcessNames $blockers -TimeoutSec 120) {
                Write-LogOk "Processes closed; upgrading $Id"
                return $true
            }
            Write-LogWarn "Timed out waiting - skipping $Id. Close it and re-run: .\dev-setup.ps1 -Only health_check"
            return $false
        }
        default {
            Write-LogInfo "Skipping $Id this run. Close it and re-run: .\dev-setup.ps1 -Only health_check"
            return $false
        }
    }
}

function Step_health_check {
    Write-LogInfo "Checking for winget package updates among everything this script manages..."
    $upgradable = Get-WingetUpgradable -Ids $ManagedWingetIds
    if ($upgradable.Count -gt 0) {
        Write-LogInfo "Updates available for: $($upgradable -join ', ')"
        if ($DryRun) {
            Write-Host "  [dry-run] would upgrade each package; if an app is running, ask Close/kill, Skip, or Wait" -ForegroundColor Yellow
            foreach ($id in $upgradable) {
                $blockers = Get-WingetUpgradeBlocker $id
                if ($blockers.Count -gt 0) {
                    Write-Host "  [dry-run] $id currently blocked by: $($blockers -join ', ')" -ForegroundColor Yellow
                }
            }
        } else {
            if (-not (Wait-InstallerIdle)) {
                Write-LogWarn "Another installer is still busy; skipping the winget upgrade pass this run."
                $upgradable = @()
            }
            foreach ($id in $upgradable) {
                if (-not (Resolve-WingetRunningApps -Id $id)) { continue }
                Write-LogInfo "Upgrading $id..."
                Invoke-WingetUpgrade -Id $id | Out-Null
            }
        }
    } else {
        Write-LogOk "All managed winget packages are already up to date"
    }

    if (Test-CmdExists 'npm') {
        Write-LogInfo "Updating global npm tools this script manages ($($NpmGlobalTools -join ', '))..."
        Invoke-Native 'npm' (@('update', '-g') + $NpmGlobalTools) | Out-Null
    }
    $pythonExe = Get-PythonExe
    if ($pythonExe) {
        Write-LogInfo "Updating global Python tools this script manages ($($PythonGlobalTools -join ', '))..."
        & $pythonExe -m pip install --user --upgrade @PythonGlobalTools | Out-Null
    }
    if (Test-CmdExists 'composer') {
        Write-LogInfo "Updating global composer tools this script manages ($($ComposerGlobalPackages -join ', '))..."
        Invoke-Native 'composer' (@('global', 'update') + $ComposerGlobalPackages) | Out-Null
    }
    return $true
}

# Start-Process -NoNewWindow -PassThru on Windows leaves ExitCode $null unless
# the process Handle is read first (PowerShell #5421 / #20716). On the
# WindowsApps winget.exe AppExecutionAlias that is the *common* case, and
# `$null -ne 0` is $true - so every successful "Successfully installed" was
# reported as a failure with an empty "(exit )" in the log. Touching .Handle
# before WaitForExit populates ExitCode correctly.
function Wait-ProcessExitCode {
    param(
        [Parameter(Mandatory)][System.Diagnostics.Process]$Process,
        [int]$TimeoutSec = 0,
        [int]$IdleGraceSec = 0
    )
    # Cache the handle BEFORE waiting - after exit it is too late.
    $null = $Process.Handle

    if ($TimeoutSec -le 0) {
        $Process.WaitForExit() | Out-Null
        return $Process.ExitCode
    }

    # Absolute ceiling so a wedged installer cannot swallow the whole run.
    # When IdleGraceSec > 0, also require the process to go idle (no CPU /
    # WorkingSet change) for that many seconds before timing out - a slow
    # download (Claude Code ~200MB, Docker Desktop ~600MB) must not be killed
    # while it is still making progress.
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $lastCpu = $null
    $lastWs = $null
    $idleSince = $null
    while (-not $Process.HasExited) {
        if ((Get-Date) -ge $deadline) {
            if ($IdleGraceSec -le 0) { return $null }
            try {
                $cpu = $Process.TotalProcessorTime.Ticks
                $ws = $Process.WorkingSet64
            } catch {
                return $null
            }
            $busy = ($null -eq $lastCpu) -or ($cpu -ne $lastCpu) -or ($ws -ne $lastWs)
            $lastCpu = $cpu
            $lastWs = $ws
            if ($busy) {
                $idleSince = $null
                # Still working past the soft deadline - keep waiting, but
                # never more than TimeoutSec past the last activity burst.
                $deadline = (Get-Date).AddSeconds([Math]::Max(60, [Math]::Min($TimeoutSec, 600)))
            } elseif (-not $idleSince) {
                $idleSince = Get-Date
            } elseif (((Get-Date) - $idleSince).TotalSeconds -ge $IdleGraceSec) {
                return $null
            }
        }
        Start-Sleep -Milliseconds 500
        try { $Process.Refresh() } catch { return $null }
    }
    # HasExited alone is not enough for ExitCode on some hosts; WaitForExit
    # drains the remaining state after the handle was cached above.
    $Process.WaitForExit() | Out-Null
    return $Process.ExitCode
}

# winget upgrade soft-success codes (not a real failure for our purposes).
# See https://github.com/microsoft/winget-cli/blob/master/doc/windows/package-manager/winget/returnCodes.md
$WingetUpgradeOkCodes = @(
    0,
    -1978335189,  # UPDATE_NOT_APPLICABLE - already newest / no applicable update
    -1978335153,  # UPGRADE_VERSION_NOT_NEWER
    -1978335135   # PACKAGE_ALREADY_INSTALLED
)

function Test-WingetUpgradeOk([object]$ExitCode) {
    if ($null -eq $ExitCode) { return $false }
    return ($WingetUpgradeOkCodes -contains [int]$ExitCode)
}

function Get-WingetExe {
    $cmd = Get-Command winget -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) { return $cmd.Source }
    return 'winget'
}

# Bounded upgrade: -NoNewWindow keeps winget's own progress on this console,
# -PassThru + Wait-ProcessExitCode gives a real exit code and an activity-
# aware timeout so a single wedged installer cannot swallow the rest of the run.
function Invoke-WingetUpgrade {
    param(
        [Parameter(Mandatory)][string]$Id,
        # Soft deadline; extended while winget is still using CPU / growing
        # WorkingSet (large downloads). Absolute hang = soft + IdleGraceSec.
        [int]$TimeoutSec = 1800,
        [int]$IdleGraceSec = 180
    )
    $wingetArgs = @('upgrade', '--id', $Id, '-e', '--accept-package-agreements',
        '--accept-source-agreements', '--silent', '--disable-interactivity')
    $wingetExe = Get-WingetExe
    $proc = Start-Process -FilePath $wingetExe -ArgumentList $wingetArgs -NoNewWindow -PassThru
    $code = Wait-ProcessExitCode -Process $proc -TimeoutSec $TimeoutSec -IdleGraceSec $IdleGraceSec
    if ($null -eq $code) {
        Write-LogWarn "winget upgrade for $Id is still running with no progress after ${TimeoutSec}s - leaving it"
        Write-LogWarn "alone (not killing mid-install) so the rest of this run can continue. Finish or cancel it"
        Write-LogWarn "yourself, then re-run: .\dev-setup.ps1 -Only health_check"
        Write-LogWarn "  winget upgrade --id $Id -e"
        return $false
    }
    if (-not (Test-WingetUpgradeOk $code)) {
        # Same Chrome catalog lag as Install-Winget: Google Update can be ahead
        # of winget, so upgrade/install of the MSI fails while Chrome is fine.
        if ($Id -eq 'Google.Chrome' -and (Test-ChromeInstalled)) {
            Write-LogWarn "Google.Chrome winget upgrade failed (exit $code) but Chrome is present - Google Update often ships ahead of the winget catalog. Treating as OK."
            return $true
        }
        Write-LogWarn "winget upgrade failed for $Id (exit $code)"
        return $false
    }
    if ($code -eq 0) {
        Write-LogOk "Upgraded $Id"
    } else {
        Write-LogInfo "$Id is already up to date (winget exit $code)"
    }
    return $true
}

# ---------------------------------------------------------------------------
# Pin apps: Windows 11 removed the programmatic "Pin to taskbar" verb in the
# 1809+ shell (to stop adware abusing it) - there is no supported API for
# taskbar pinning any more, unlike GNOME's favorite-apps gsettings key that
# pin_apps drives on Ubuntu. Start-menu pinning is still reachable via the
# classic shell verb, so this step does that instead and says so plainly.
# ---------------------------------------------------------------------------

# Type 'UWA' apps are Microsoft Store packages (ChatGPT, Teams) - they need
# their AppUserModelID (AUMID), not a file path: Windows already gives them
# a Start Menu entry on install, and WScript.Shell can't target a packaged
# app directly, only shell:AppsFolder\<AUMID> - which the layout XML wants
# anyway - so DesktopApp entries get both a shortcut and an XML pin; UWA
# entries only need the XML pin.
$PinCandidates = @(
    @{ Label = 'VS Code'; Type = 'DesktopApp'; Path = "$env:LOCALAPPDATA\Programs\Microsoft VS Code\Code.exe"; Flag = 'PIN_VSCODE' }
    @{ Label = 'Cursor'; Type = 'DesktopApp'; Path = "$env:LOCALAPPDATA\Programs\cursor\Cursor.exe"; Flag = 'PIN_CURSOR' }
    @{ Label = 'ChatGPT'; Type = 'UWA'; Path = 'OpenAI.ChatGPT-Desktop_2p2nqsd0c76g0!ChatGPT'; Flag = 'PIN_CHATGPT' }
    @{ Label = 'Chrome'; Type = 'DesktopApp'; Path = "$env:PROGRAMFILES\Google\Chrome\Application\chrome.exe"; Flag = 'PIN_CHROME' }
    @{ Label = 'LibreOffice'; Type = 'DesktopApp'; Path = "$env:PROGRAMFILES\LibreOffice\program\soffice.exe"; Flag = 'PIN_LIBREOFFICE' }
    @{ Label = 'Postman'; Type = 'DesktopApp'; Path = "$env:LOCALAPPDATA\Postman\Postman.exe"; Flag = 'PIN_POSTMAN' }
    @{ Label = 'TightVNC Viewer'; Type = 'DesktopApp'; Path = "$(if (Test-Path "${env:ProgramFiles}\TightVNC\tvnviewer.exe") { "${env:ProgramFiles}\TightVNC\tvnviewer.exe" } else { "${env:ProgramFiles(x86)}\TightVNC\tvnviewer.exe" })"; Flag = 'PIN_REMMINA' }
    @{ Label = 'Slack'; Type = 'DesktopApp'; Path = "$env:LOCALAPPDATA\slack\slack.exe"; Flag = 'PIN_SLACK' }
    @{ Label = 'Teams'; Type = 'UWA'; Path = 'MSTeams_8wekyb3d8bbwe!MSTeams'; Flag = 'PIN_TEAMS' }
    @{ Label = 'Notion'; Type = 'DesktopApp'; Path = "$env:LOCALAPPDATA\Programs\Notion\Notion.exe"; Flag = 'PIN_NOTION' }
    @{ Label = 'Pumble'; Type = 'DesktopApp'; Path = "$env:LOCALAPPDATA\Programs\pumble-desktop\Pumble.exe"; Flag = 'PIN_PUMBLE' }
    @{ Label = 'Linear'; Type = 'DesktopApp'; Path = "$env:LOCALAPPDATA\Programs\linear\Linear.exe"; Flag = 'PIN_LINEAR' }
    @{ Label = 'Clockify'; Type = 'DesktopApp'; Path = "$env:PROGRAMFILES\Clockify\ClockifyWindows.exe"; Flag = 'PIN_CLOCKIFY' }
    @{ Label = 'Notepad++'; Type = 'DesktopApp'; Path = "$env:PROGRAMFILES\Notepad++\notepad++.exe"; Flag = 'PIN_EDITOR_PDF' }
    @{ Label = 'SumatraPDF'; Type = 'DesktopApp'; Path = "$env:LOCALAPPDATA\SumatraPDF\SumatraPDF.exe"; Flag = 'PIN_EDITOR_PDF' }
    @{ Label = 'MarkText'; Type = 'DesktopApp'; Path = "$env:LOCALAPPDATA\Programs\MarkText\MarkText.exe"; Flag = 'PIN_EDITOR_PDF' }
)

function Step_pin_apps {
    Import-EnvFile
    Write-LogWarn "Windows 11 does not expose a supported API for scripted taskbar pinning (Microsoft"
    Write-LogWarn "removed it in the 1809 shell update); the taskbar layout file this step writes below"
    Write-LogWarn "is a best-effort, unsupported workaround Microsoft could break in a future update -"
    Write-LogWarn "right-click -> Pin to taskbar by hand is the one guaranteed-reliable option."

    $startApps = Get-StartApps
    $pinned = 0
    $taskbarPins = @()
    foreach ($c in $PinCandidates) {
        if (-not (Test-FlagEnabled (Get-Cfg $c.Flag) $true)) {
            Write-LogInfo "$($c.Label): $($c.Flag)=false in .env, skipping"
            continue
        }
        if ($c.Type -eq 'UWA') {
            if (-not ($startApps | Where-Object { $_.AppID -eq $c.Path })) {
                Write-LogWarn "$($c.Label): not installed, skipping"
                continue
            }
            $taskbarPins += "        <taskbar:UWA AppUserModelID=`"$($c.Path)`" />"
            $pinned++
            continue
        }
        if (-not (Test-Path $c.Path)) {
            Write-LogWarn "$($c.Label): not found at $($c.Path), skipping"
            continue
        }
        $lnkPath = Join-Path "$env:APPDATA\Microsoft\Windows\Start Menu\Programs" "$($c.Label).lnk"
        if ($DryRun) {
            Write-Host "  [dry-run] would create Start Menu shortcut: $lnkPath -> $($c.Path)" -ForegroundColor Yellow
            $pinned++
            continue
        }
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($lnkPath)
        $shortcut.TargetPath = $c.Path
        $shortcut.Save()
        $taskbarPins += "        <taskbar:DesktopApp DesktopApplicationLinkPath=`"$lnkPath`" />"
        $pinned++
    }
    Write-LogOk "$pinned Start Menu shortcut(s)/pin(s) ensured"

    if ($taskbarPins.Count -eq 0) { return $true }
    $layoutXml = @"
<?xml version="1.0" encoding="utf-8"?>
<LayoutModificationTemplate
    xmlns="http://schemas.microsoft.com/Start/2014/LayoutModification"
    xmlns:defaultlayout="http://schemas.microsoft.com/Start/2014/FullDefaultLayout"
    xmlns:start="http://schemas.microsoft.com/Start/2014/StartLayout"
    xmlns:taskbar="http://schemas.microsoft.com/Start/2014/TaskbarLayout"
    Version="1">
  <CustomTaskbarLayoutCollection>
    <defaultlayout:TaskbarLayout>
      <taskbar:TaskbarPinList>
$($taskbarPins -join "`n")
      </taskbar:TaskbarPinList>
    </defaultlayout:TaskbarLayout>
  </CustomTaskbarLayoutCollection>
</LayoutModificationTemplate>
"@
    $layoutDir = "$env:LOCALAPPDATA\Microsoft\Windows\Shell"
    $layoutPath = Join-Path $layoutDir 'LayoutModification.xml'
    if ($DryRun) {
        Write-Host "  [dry-run] would write $layoutPath with $($taskbarPins.Count) taskbar pin(s)" -ForegroundColor Yellow
        return $true
    }
    New-Item -ItemType Directory -Path $layoutDir -Force | Out-Null
    Set-Content -Path $layoutPath -Value $layoutXml -Encoding utf8
    Write-LogOk "Wrote taskbar layout to $layoutPath ($($taskbarPins.Count) pin(s))"
    Write-LogWarn "Sign out and back in (or restart explorer.exe from Task Manager) to see these pins -"
    Write-LogWarn "this step deliberately does NOT restart Explorer for you, since that closes and"
    Write-LogWarn "reopens the taskbar/desktop for your whole session without warning."
    return $true
}

function ConvertTo-CloudStoreVlq([long]$Value) {
    $bytes = New-Object System.Collections.Generic.List[byte]
    $v = [Math]::Max(0L, [long]$Value)
    while ($v -ge 0x80) {
        [void]$bytes.Add([byte](($v -band 0x7F) -bor 0x80))
        $v = $v -shr 7
    }
    [void]$bytes.Add([byte]$v)
    return , $bytes.ToArray()
}

function ConvertTo-NightLightTempVlq([int]$Kelvin) {
    # Bond CompactBinary zigzag of Kelvin (positive => n << 1), then VLQ.
    return , (ConvertTo-CloudStoreVlq ([long]$Kelvin -shl 1))
}

function ConvertFrom-NightLightStrengthToKelvin([int]$StrengthPercent) {
    # Windows Night Light strength slider: 0% = 6500K (cool), 100% = 1200K (warm).
    $pct = [Math]::Max(0, [Math]::Min(100, $StrengthPercent))
    return [int][Math]::Round(6500 - ($pct / 100.0) * 5300)
}

function Set-CloudStoreBinary([string]$KeyPath, [byte[]]$Data) {
    if (-not (Test-Path -LiteralPath $KeyPath)) {
        New-Item -Path $KeyPath -Force -ErrorAction Stop | Out-Null
    }
    Set-ItemProperty -LiteralPath $KeyPath -Name 'Data' -Value $Data -Type Binary -Force -ErrorAction Stop
}

# Always-on Night Light (blue-light filter) at the given strength %.
# Writes the Win11 CloudStore blobs under HKCU (same store Settings uses).
function Set-Win11NightLight {
    param([int]$StrengthPercent = 20)

    $kelvin = ConvertFrom-NightLightStrengthToKelvin $StrengthPercent
    $epoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 2
    $ts = ConvertTo-CloudStoreVlq $epoch

    # Settings: schedule active + explicit 00:00 -> 23:45 (full day), strength as Kelvin.
    # Minutes are limited to 0/15/30/45 in the older GUI encoding; 23:45 covers the day.
    $body = New-Object System.Collections.Generic.List[byte]
    foreach ($b in @(
            0x00, 0x02, 0x01, 0xC2, 0x0A, 0x00,
            0xCA, 0x14, 0x0E, 0x00, 0x00,
            0xCA, 0x1E, 0x0E, 0x17, 0x2E, 0x2D, 0x00,
            0xCF, 0x28
        )) { [void]$body.Add([byte]$b) }
    foreach ($b in (ConvertTo-NightLightTempVlq $kelvin)) { [void]$body.Add($b) }
    foreach ($b in @(0x00, 0x00, 0x00, 0x00)) { [void]$body.Add([byte]$b) }

    $settings = New-Object System.Collections.Generic.List[byte]
    foreach ($b in @(0x43, 0x42, 0x01, 0x00, 0x0A, 0x02, 0x01, 0x00, 0x2A, 0x06)) { [void]$settings.Add([byte]$b) }
    foreach ($b in $ts) { [void]$settings.Add($b) }
    [void]$settings.Add([byte]0x2A)
    [void]$settings.Add([byte]0x2B)
    [void]$settings.Add([byte]0x0E)
    [void]$settings.Add([byte]$body.Count)
    foreach ($b in @(0x43, 0x42, 0x01)) { [void]$settings.Add([byte]$b) }
    foreach ($b in $body) { [void]$settings.Add($b) }

    # State: Night Light currently ON (manual transition), so it is active now.
    $ft = ConvertTo-CloudStoreVlq ([DateTime]::Now.ToFileTime())
    $stateBody = New-Object System.Collections.Generic.List[byte]
    foreach ($b in @(0x00, 0x10, 0x00, 0xD0, 0x0A, 0x02, 0xC6, 0x14)) { [void]$stateBody.Add([byte]$b) }
    foreach ($b in $ft) { [void]$stateBody.Add($b) }
    foreach ($b in @(0x00, 0x00, 0x00, 0x00)) { [void]$stateBody.Add([byte]$b) }

    $state = New-Object System.Collections.Generic.List[byte]
    foreach ($b in @(0x43, 0x42, 0x01, 0x00, 0x0A, 0x02, 0x01, 0x00, 0x2A, 0x06)) { [void]$state.Add([byte]$b) }
    foreach ($b in $ts) { [void]$state.Add($b) }
    [void]$state.Add([byte]0x2A)
    [void]$state.Add([byte]0x2B)
    [void]$state.Add([byte]0x0E)
    [void]$state.Add([byte]$stateBody.Count)
    foreach ($b in @(0x43, 0x42, 0x01)) { [void]$state.Add([byte]$b) }
    foreach ($b in $stateBody) { [void]$state.Add($b) }

    $settingsKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudStore\Store\DefaultAccount\Current\default$windows.data.bluelightreduction.settings\windows.data.bluelightreduction.settings'
    $stateKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudStore\Store\DefaultAccount\Current\default$windows.data.bluelightreduction.bluelightreductionstate\windows.data.bluelightreduction.bluelightreductionstate'

    Set-CloudStoreBinary $settingsKey ($settings.ToArray())
    Set-CloudStoreBinary $stateKey ($state.ToArray())
    return @{ Kelvin = $kelvin; Strength = $StrengthPercent }
}

function Set-RegistryDword([string]$Path, [string]$Name, [int]$Value) {
    if ($DryRun) { return $true }
    if ($Path -like 'HKLM:\*' -and -not (Test-Admin)) { return $false }
    try {
        if (-not (Test-Path $Path)) {
            New-Item -Path $Path -Force -ErrorAction Stop | Out-Null
        }
        Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type DWord -Force -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

# Local-only Start/taskbar Search. Keys match the overlap of:
#   Raphire/Win11Debloat -DisableBing (default preset)
#   farag2/Sophia-Script BingSearch -Disable
#   ChrisTitusTech/winutil Start Menu Bing Search
#   Microsoft Search ADMX (DisableWebSearch, ConnectedSearchUseWeb, AllowCloudSearch)
# Does not stop the Windows Search indexer (WSearch) - local files/apps still work.
function Set-Win11SearchLocalOnly {
    $policy = Set-RegistryDword 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 1
    $ok = $true
    foreach ($pair in @(
        @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Search', 'BingSearchEnabled', 0),
        @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Search', 'CortanaConsent', 0),
        @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Search', 'AllowSearchToUseLocation', 0),
        @('HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings', 'IsDynamicSearchBoxEnabled', 0),
        @('HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings', 'IsAADCloudSearchEnabled', 0),
        @('HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings', 'IsMSACloudSearchEnabled', 0),
        @('HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings', 'IsDeviceSearchHistoryEnabled', 0)
    )) {
        if (-not (Set-RegistryDword $pair[0] $pair[1] $pair[2])) { $ok = $false }
    }
    $machine = $true
    $machine = (Set-RegistryDword 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'DisableWebSearch' 1) -and $machine
    $machine = (Set-RegistryDword 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'ConnectedSearchUseWeb' 0) -and $machine
    $machine = (Set-RegistryDword 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'AllowCortana' 0) -and $machine
    $machine = (Set-RegistryDword 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'AllowSearchToUseLocation' 0) -and $machine
    $machine = (Set-RegistryDword 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'AllowCloudSearch' 0) -and $machine
    $machine = (Set-RegistryDword 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'EnableDynamicContentInWSB' 0) -and $machine
    $machine = (Set-RegistryDword 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 1) -and $machine
    if (-not $machine) {
        Write-LogWarn "HKLM Windows Search policies were not written (need an elevated PowerShell). HKCU keys still apply for this user."
    }
    Get-Process -Name 'SearchHost','SearchApp','SearchUI' -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    if ($ok) {
        Write-LogOk "Start/Search: local apps/files/settings only (no Bing/web/cloud results, even with internet)"
    } else {
        Write-LogWarn "Some per-user Search settings could not be written"
    }
    if (-not $policy) {
        Write-LogWarn "Could not write DisableSearchBoxSuggestions (the policy that actually strips Bing from Start). Run this step as Administrator from a normal desktop PowerShell."
    }
}

# Win11Debloat default-preset extras that belong on a desk workstation.
# Skipped on purpose: global notification kill (Slack/Teams), Defender/Update disable, WSearch stop.
function Set-Win11WorkstationPrivacy {
    Set-RegistryDword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-310093Enabled' 0
    Set-RegistryDword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338387Enabled' 0
    Set-RegistryDword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338388Enabled' 0
    Set-RegistryDword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338389Enabled' 0
    Set-RegistryDword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338393Enabled' 0
    Set-RegistryDword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-353694Enabled' 0
    Set-RegistryDword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-353696Enabled' 0
    Set-RegistryDword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-353698Enabled' 0
    Set-RegistryDword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SystemPaneSuggestionsEnabled' 0
    Set-RegistryDword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SilentInstalledAppsEnabled' 0
    Set-RegistryDword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SoftLandingEnabled' 0
    Set-RegistryDword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'OemPreInstalledAppsEnabled' 0
    Set-RegistryDword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'PreInstalledAppsEnabled' 0
    Set-RegistryDword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'RotatingLockScreenEnabled' 0
    Set-RegistryDword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'RotatingLockScreenOverlayEnabled' 0
    Set-RegistryDword 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\UserProfileEngagement' 'ScoobeSystemSettingEnabled' 0
    Set-RegistryDword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'Start_TrackProgs' 0
    Set-RegistryDword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ShowSyncProviderNotifications' 0
    Set-RegistryDword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 0
    Set-RegistryDword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy' 'TailoredExperiencesWithDiagnosticDataEnabled' 0
    Set-RegistryDword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\SystemSettings\AccountNotifications' 'EnableAccountNotifications' 0
    Set-RegistryDword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.Suggested' 'Enabled' 0
    Set-RegistryDword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Mobility' 'OptedIn' 0
    Set-RegistryDword 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1
    Set-RegistryDword 'HKCU:\Software\Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis' 1
    Set-RegistryDword 'HKCU:\Software\Policies\Microsoft\Windows\WindowsAI' 'DisableClickToDo' 1
    Set-RegistryDword 'HKCU:\Software\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsSpotlightFeatures' 1
    Set-RegistryDword 'HKCU:\Software\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsSpotlightWindowsWelcomeExperience' 1
    Set-RegistryDword 'HKCU:\Software\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsSpotlightOnActionCenter' 1
    Set-RegistryDword 'HKCU:\Software\Policies\Microsoft\Windows\CloudContent' 'DisableTailoredExperiencesWithDiagnosticData' 1
    Set-RegistryDword 'HKCU:\Software\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 1
    Set-RegistryDword 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 1
    Set-RegistryDword 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableCloudOptimizedContent' 1
    Set-RegistryDword 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableSoftLanding' 1
    Set-RegistryDword 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'PublishUserActivities' 0
    Set-RegistryDword 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 0
    Set-RegistryDword 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection' 'AllowTelemetry' 0
    Set-RegistryDword 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1
    Set-RegistryDword 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Copilot' 'TurnOffWindowsCopilot' 1
    Set-RegistryDword 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis' 1
    Set-RegistryDword 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'DisableClickToDo' 1
    Set-RegistryDword 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'AllowRecallEnablement' 0
    Set-RegistryDword 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'TurnOffSavingSnapshots' 1
    Set-RegistryDword 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR' 0
    Set-RegistryDword 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 0
    Set-RegistryDword 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Feeds' 'EnableFeeds' 0
    Set-RegistryDword 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'NewTabPageContentEnabled' 0
    Set-RegistryDword 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'NewTabPageHideDefaultTopSites' 1
    Set-RegistryDword 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'HideFirstRunExperience' 1
    Set-RegistryDword 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'SpotlightExperiencesAndRecommendationsEnabled' 0
    Set-RegistryDword 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'ShowRecommendationsEnabled' 0
    Set-RegistryDword 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'PersonalizationReportingEnabled' 0
    Set-RegistryDword 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'DiagnosticData' 0
    Set-RegistryDword 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'DefaultBrowserSettingsCampaignEnabled' 0
    if (-not (Test-Admin)) {
        Write-LogWarn "HKLM privacy/Copilot/Recall/Edge policy keys skipped (need an elevated PowerShell)"
    }
}

# Smart App Control (Windows 11): blocks unsigned / "unrecognized" apps with
# "Smart App Control has blocked part of this app". Dev machines install a lot
# of winget/unsigned tooling, so leave it Off. Microsoft documents the state
# as VerifiedAndReputablePolicyState under CI\Policy (0=Off, 1=On, 2=Evaluation);
# CiTool -r reloads the policy without a reboot when available.
# https://learn.microsoft.com/en-us/windows/security/application-security/application-control/app-control-for-business/appcontrol
function Disable-SmartAppControl {
    $path = 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy'
    $name = 'VerifiedAndReputablePolicyState'
    if ($DryRun) {
        Write-Host "  [dry-run] would set $path\$name = 0 (Smart App Control Off) and run CiTool.exe -r" -ForegroundColor Yellow
        return $true
    }
    if (-not (Test-Admin)) {
        Write-LogWarn "Smart App Control: needs elevation to turn Off. Re-run:"
        Write-LogWarn "  .\dev-setup-admin.cmd -Only desktop_prefs"
        Write-LogWarn "Or: Windows Security > App & browser control > Smart App Control settings > Off"
        return $false
    }
    $current = $null
    try {
        $current = (Get-ItemProperty -Path $path -Name $name -ErrorAction SilentlyContinue).$name
    } catch { }
    if ($current -eq 0) {
        Write-LogOk "Smart App Control already Off (VerifiedAndReputablePolicyState=0)"
        return $true
    }
    if (-not (Set-RegistryDword $path $name 0)) {
        Write-LogWarn "Could not write Smart App Control Off registry value"
        return $false
    }
    $ci = Join-Path $env:SystemRoot 'System32\CiTool.exe'
    if (Test-Path -LiteralPath $ci) {
        & $ci -r 2>&1 | Out-Null
        Write-LogOk "Smart App Control set to Off (was $current); CiTool -r applied"
    } else {
        Write-LogOk "Smart App Control set to Off (was $current). Sign out or reboot if Windows Security still shows On/Evaluation."
    }
    Write-LogInfo "UI path (manual check): Windows Security > App & browser control > Smart App Control settings"
    return $true
}

function Step_desktop_prefs {
    Import-EnvFile
    $tz = Get-Cfg 'TIMEZONE'
    $nightStrength = 20
    $nightCfg = Get-Cfg 'NIGHT_LIGHT_STRENGTH'
    if (-not [string]::IsNullOrWhiteSpace($nightCfg) -and $nightCfg -match '^\d+$') {
        $nightStrength = [int]$nightCfg
    }
    if ($DryRun) {
        Write-Host "  [dry-run] would set timezone '$(if ($tz) { $tz } else { '(unchanged)' })', dark mode, solid-color wallpaper, local-only Start search (no Bing/web)," -ForegroundColor Yellow
        Write-Host "  [dry-run] Night Light on all day at ${nightStrength}% warmth, Win11Debloat-style ads/suggestions/Recall/Copilot off, Smart App Control Off" -ForegroundColor Yellow
        Disable-SmartAppControl | Out-Null
        return $true
    }

    if (-not [string]::IsNullOrWhiteSpace($tz)) {
        tzutil /s $tz
        if ($LASTEXITCODE -eq 0) {
            Write-LogOk "Timezone set to $tz"
        } else {
            Write-LogWarn "tzutil failed for '$tz'"
        }
    }

    Set-RegistryDword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'AppsUseLightTheme' 0
    Set-RegistryDword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'SystemUsesLightTheme' 0
    Write-LogOk "Dark mode (apps + system)"

    # Solid color, no wallpaper image.
    Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name Wallpaper -Value ''
    Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name WallpaperStyle -Value '0'
    Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name TileWallpaper -Value '0'
    if (-not (Test-Path 'HKCU:\Control Panel\Colors')) {
        New-Item -Path 'HKCU:\Control Panel\Colors' -Force | Out-Null
    }
    Set-ItemProperty -Path 'HKCU:\Control Panel\Colors' -Name Background -Value '32 32 32'
    if (-not ('WsWallpaper' -as [type])) {
        Add-Type -TypeDefinition @"
using System.Runtime.InteropServices;
public class WsWallpaper {
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
    public static extern bool SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni);
}
"@
    }
    [WsWallpaper]::SystemParametersInfo(20, 0, '', 3) | Out-Null
    Write-LogOk "Desktop background: solid #202020 (no image)"

    try {
        $nl = Set-Win11NightLight -StrengthPercent $nightStrength
        Write-LogOk ("Night Light on all day (schedule 00:00-23:45), warmth {0}% (~{1}K)" -f $nl.Strength, $nl.Kelvin)
    } catch {
        Write-LogWarn "Could not configure Night Light: $($_.Exception.Message)"
        Write-LogWarn "Set manually: Settings > System > Display > Night light (Strength ${nightStrength}%, Schedule on for the full day)"
    }

    Set-RegistryDword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'HideFileExt' 0
    Set-RegistryDword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'Hidden' 1
    Set-RegistryDword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarDa' 0
    Set-RegistryDword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ShowTaskViewButton' 0
    Set-RegistryDword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarMn' 0
    Set-RegistryDword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'LaunchTo' 1
    Set-RegistryDword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'Start_IrisRecommendations' 0
    Set-RegistryDword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'Start_AccountNotifications' 0
    Set-RegistryDword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ShowCopilotButton' 0
    Set-RegistryDword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'SearchboxTaskbarMode' 1
    Set-RegistryDword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Feeds' 'ShellFeedsTaskbarViewMode' 2

    Set-RegistryDword 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 0
    Set-RegistryDword 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 0

    Set-Win11SearchLocalOnly
    Set-Win11WorkstationPrivacy
    Disable-SmartAppControl | Out-Null

    $oneDrive = "$env:LOCALAPPDATA\Microsoft\Windows\Start Menu\Programs\Startup\OneDrive.lnk"
    if (Test-Path $oneDrive) { Remove-Item $oneDrive -Force -ErrorAction SilentlyContinue }
    Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'OneDrive' -ErrorAction SilentlyContinue
    Get-Process OneDrive -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Write-LogOk "Widgets/News, Spotlight, Game Bar, ads/suggestions, OneDrive autostart disabled"

    if (Test-CmdExists 'chrome') {
        Write-LogInfo "Windows 11 blocks scripted default-browser change. Set Chrome under Settings > Apps > Default apps (Chrome is installed by the chrome step)."
    }
    return $true
}

$Win11BloatIds = @(
    # News / Start / weather / search clutter
    'Microsoft.BingNews', 'Microsoft.BingWeather', 'Microsoft.BingSearch',
    'Microsoft.BingFinance', 'Microsoft.BingSports', 'Microsoft.BingTranslator',
    'Microsoft.BingTravel', 'Microsoft.BingFoodAndDrink', 'Microsoft.BingHealthAndFitness',
    'Microsoft.News', 'Microsoft.StartExperiencesApp', 'MicrosoftWindows.Client.WebExperience',
    # Games & Xbox
    'Microsoft.GamingApp', 'Microsoft.XboxApp', 'Microsoft.Xbox.TCUI',
    'Microsoft.XboxGamingOverlay', 'Microsoft.XboxGameOverlay',
    'Microsoft.XboxIdentityProvider', 'Microsoft.XboxSpeechToTextOverlay',
    'Microsoft.GamingServices', 'Microsoft.MicrosoftSolitaireCollection',
    # Office trial / Hub / mail noise (LibreOffice is the office suite we install)
    'Microsoft.MicrosoftOfficeHub', 'Microsoft.Todos', 'Microsoft.Office.OneNote',
    'Microsoft.Office.Sway', 'Microsoft.OutlookForWindows', 'microsoft.windowscommunicationsapps',
    'Microsoft.PowerAutomateDesktop', 'Microsoft.MicrosoftPowerBIForWindows', 'Microsoft.MicrosoftJournal',
    # Social / chat OEM noise
    '*LinkedIn*', '5319275A.WhatsAppDesktop', '*WhatsApp*',
    'FACEBOOK.FACEBOOK', 'Facebook.Instagram', 'BytedancePte.Ltd.TikTok',
    'Microsoft.SkypeApp', 'Microsoft.Messaging', 'Microsoft.OneConnect',
    # Media / consumer Store apps we replace elsewhere
    'Microsoft.ZuneMusic', 'Microsoft.ZuneVideo', 'Clipchamp.Clipchamp',
    'Microsoft.Windows.Photos', 'Microsoft.WindowsSoundRecorder',
    'Microsoft.Paint', 'Microsoft.MSPaint', 'SpotifyAB.SpotifyMusic',
    'Disney.37853FC22B2C', 'Netflix*', 'Amazon.com.Amazon', 'AmazonVideo.PrimeVideo',
    'DolbyLaboratories.DolbyAccess', 'HULULLC.HULUPLUS', 'iHeartRadio', 'Flipboard*',
    # Phone / cross-device / family / assist
    'Microsoft.YourPhone', 'MicrosoftWindows.CrossDevice', 'Microsoft.People',
    'MicrosoftCorporationII.MicrosoftFamily', 'MicrosoftCorporationII.QuickAssist',
    # Misc inbox clutter
    'Microsoft.WindowsMaps', 'Microsoft.GetHelp', 'Microsoft.Getstarted',
    'Microsoft.WindowsFeedbackHub', 'Microsoft.NetworkSpeedTest',
    'Microsoft.Print3D', 'Microsoft.3DBuilder', 'Microsoft.Microsoft3DViewer',
    'Microsoft.MixedReality.Portal', 'Microsoft.Windows.DevHome',
    'Microsoft.Windows.AIHub', 'Microsoft.Copilot', 'Microsoft.549981C3F5F10',
    'Microsoft.MicrosoftStickyNotes', 'Microsoft.WindowsAlarms',
    # Do NOT remove MicrosoftTeams / MSTeams here: comms_teams installs the real
    # Teams client (MSTeams_… Appx). Treating it as bloat made winget report OK
    # then Start search find nothing after this step ran.
    # OEM / candy games often preloaded
    'king.com.CandyCrushSaga', 'king.com.CandyCrushSodaSaga', 'king.com.BubbleWitch3Saga',
    'FarmVille2CountryEscape', 'MarchofEmpires', 'HiddenCity', 'EclipseManager'
)

function Test-AppxPackageRemovable($Package) {
    if (-not $Package) { return $false }
    $kind = [string]$Package.SignatureKind
    $loc = [string]$Package.InstallLocation
    $nonRemovable = $false
    try { $nonRemovable = [bool]$Package.NonRemovable } catch { $nonRemovable = $false }
    if ($nonRemovable) { return $false }
    if ($kind -eq 'System') { return $false }
    if ($Package.IsFramework) { return $false }
    if ($loc -like '*\Windows\SystemApps\*') { return $false }
    return $true
}

function Remove-Win11BloatPackage($Package) {
    $name = $Package.PackageFullName
    try {
        Remove-AppxPackage -Package $name -ErrorAction Stop
        return $true
    } catch {
        $msg = [string]$_.Exception.Message
        if ($msg -match '0x80070032|0x80073CFA|cannot be uninstalled|not supported') {
            Write-LogWarn "Skipping $($Package.Name) (Windows inbox/system package)"
            return $false
        }
        Write-LogWarn "Could not remove $($Package.Name): $msg"
        return $false
    }
}

function Step_win11_cleanup {
    if ($DryRun) {
        Write-Host "  [dry-run] would uninstall News/Weather/Solitaire/Office Hub/WhatsApp/LinkedIn/Xbox/Clipchamp/Photos/Spotify/TikTok and other consumer Store apps" -ForegroundColor Yellow
        Write-Host "  [dry-run] skips NonRemovable/System/SystemApps packages (XboxGameCallableUI and similar)" -ForegroundColor Yellow
        Write-Host "  [dry-run] media is K-Lite Mega + AIMP + OBS; photos IrfanView; browser Chrome; office LibreOffice" -ForegroundColor Yellow
        return $true
    }

    $removed = 0
    $skipped = 0
    $admin = Test-Admin
    foreach ($id in $Win11BloatIds) {
        $pkgs = @(Get-AppxPackage -Name $id -ErrorAction SilentlyContinue)
        if ($admin) {
            $pkgs += @(Get-AppxPackage -Name $id -AllUsers -ErrorAction SilentlyContinue)
        }
        $seen = @{}
        foreach ($p in $pkgs) {
            if (-not $p -or -not $p.PackageFullName) { continue }
            if ($seen.ContainsKey($p.PackageFullName)) { continue }
            $seen[$p.PackageFullName] = $true
            if (-not (Test-AppxPackageRemovable $p)) {
                Write-LogInfo "Skipping $($p.Name) (inbox/system, NonRemovable=$($p.NonRemovable), SignatureKind=$($p.SignatureKind))"
                $skipped++
                continue
            }
            Write-LogInfo "Removing $($p.Name)"
            if (Remove-Win11BloatPackage $p) { $removed++ } else { $skipped++ }
            if ($admin) {
                try {
                    Remove-AppxPackage -Package $p.PackageFullName -AllUsers -ErrorAction Stop | Out-Null
                } catch { }
            }
        }
        if ($admin) {
            Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -eq $id } |
                ForEach-Object {
                    Write-LogInfo "Deprovisioning $($_.DisplayName)"
                    try {
                        Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction Stop | Out-Null
                    } catch {
                        Write-LogWarn "Could not deprovision $($_.DisplayName): $($_.Exception.Message)"
                    }
                }
        }
    }

    if ($admin) {
        $optional = @('Microsoft.Windows.Media.Player', 'Microsoft.Windows.WordPad')
        foreach ($feat in $optional) {
            $cap = Get-WindowsCapability -Online -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "$feat*" -and $_.State -eq 'Installed' }
            foreach ($c in $cap) {
                Write-LogInfo "Removing capability $($c.Name)"
                try {
                    Remove-WindowsCapability -Online -Name $c.Name -ErrorAction Stop | Out-Null
                } catch {
                    Write-LogWarn "Could not remove capability $($c.Name)"
                }
            }
        }
    } else {
        Write-LogWarn "Not elevated: removed apps for this user only. Re-run -Only win11_cleanup as Administrator to deprovision for all users."
    }

    Write-LogOk "Windows 11 consumer apps pass done ($removed removed, $skipped skipped inbox/failed). Media: AIMP + K-Lite + OBS; images: IrfanView; web: Chrome; office: LibreOffice."
    return $true
}

# ---------------------------------------------------------------------------
# Step registry
# ---------------------------------------------------------------------------
$StepIds = @(
    'prereqs', 'path_check', 'git_gh', 'cpp_build', 'cpp_msvc', 'java_scala', 'dotnet', 'python', 'node_nvm', 'php',
    'docker', 'kubectl',
    'vscode', 'vscode_ext',
    'playwright', 'postman_newman',
    'cursor', 'chatgpt',
    'editor_pdf', 'libreoffice', 'archive_tools', 'cli_tools', 'ai_media',
    'chrome', 'vnc_viewer', 'media_apps', 'obs',
    'comms_zoom', 'comms_slack', 'comms_teams', 'comms_notion', 'comms_pumble', 'comms_linear', 'comms_clockify',
    'remote_ssh', 'remote_rdp', 'remote_vnc', 'remote_rustdesk', 'remote_dwservice', 'remote_check',
    'battery_charge_limit', 'power_management', 'desktop_prefs', 'win11_cleanup', 'perf_tuning', 'health_check', 'pin_apps'
)

# Optional steps: default N at the Y/n prompt, and skipped entirely under -Yes
# unless explicitly selected with -Only. Heavy / niche installs go here.
$OptInSteps = @('cpp_msvc')

$StepDesc = [ordered]@{
    prereqs                 = 'Base prerequisites check (winget, curl, tar)'
    path_check               = "Verify User PATH has this script's tool dirs, fixing/re-adding what's missing"
    git_gh                   = 'Git + GitHub CLI (gh); reads identity/token from .env, re-applies globally on change'
    cpp_build                 = 'C++ light toolchain (CMake, Ninja, LLVM/clang, ccache, Code::Blocks + MinGW) - no Windows SDK'
    cpp_msvc                  = 'OPTIONAL (default no): VS 2022 Build Tools C++ workload + Windows SDK (multi-GB, MSVC/cl.exe)'
    java_scala                = 'Java (Temurin LTS) + sbt (bootstraps Scala per-project)'
    dotnet                    = '.NET SDK (current LTS)'
    python                    = 'Python 3.13 (PrependPath) + poetry/ruff/black/mypy/httpie/ipython/pre-commit; ensures python/Scripts on User PATH'
    node_nvm                  = 'Node.js via nvm-windows (current LTS) + npm/pnpm/yarn/typescript/eslint/prettier'
    php                       = 'PHP + Composer + Laravel installer (Laravel/CodeIgniter development)'
    vscode                    = 'Visual Studio Code'
    vscode_ext                = 'VS Code extensions for the stacks present on this machine (-Skip docker/java_scala/... drops theirs)'
    cursor                    = 'Cursor (AI code editor)'
    chatgpt                   = 'ChatGPT desktop app (Microsoft Store)'
    editor_pdf                = 'Notepad++ + SumatraPDF + MarkText (Markdown; free editors only)'
    libreoffice                = 'LibreOffice'
    postman_newman             = 'Postman + Newman CLI'
    playwright                 = 'Playwright (CLI + browsers)'
    docker                    = 'Docker Desktop (needs WSL2 - enable that yourself: wsl --install)'
    kubectl                   = 'kubectl'
    archive_tools               = '7-Zip'
    cli_tools                  = 'CLI productivity/research tools (ripgrep, fd, bat, fzf, jq, yq, delta, lazygit, btop4win...)'
    chrome                    = 'Google Chrome'
    vnc_viewer                 = 'TightVNC Viewer only (client machines; use built-in mstsc for RDP). Alias: rdp_client'
    media_apps                 = 'Paint.NET, IrfanView + PlugIns, AIMP, K-Lite Mega Codec Pack (no Zoom)'
    obs                        = 'OBS Studio (screen recording / streaming)'
    ai_media                   = 'AI/media CLI: FFmpeg, ImageMagick, Poppler, QPDF, Tesseract OCR, ocrmypdf'
    comms_zoom                 = 'Zoom (optional; separate from media_apps)'
    comms_slack                = 'Slack'
    comms_teams                = 'Microsoft Teams'
    comms_notion                = 'Notion'
    comms_pumble                = 'Pumble'
    comms_linear                = 'Linear'
    comms_clockify              = 'Clockify (time tracking)'
    remote_ssh                 = 'SSH remote login (OpenSSH Server). Never creates an OS user unless you confirm after an existence check - needs elevation'
    remote_rdp                 = 'Windows Remote Desktop (RDP). Uses an existing account after the same confirm - needs elevation'
    remote_vnc                 = 'TightVNC Server only (share this desktop; password from .env). Skip on viewer-only machines'
    power_management            = 'Power: Ultimate Performance; never sleep/hibernate; never turn off screen (AC+DC); screensaver off'
    desktop_prefs              = 'Timezone from TIMEZONE, dark mode, Night Light all day (20% warm), solid wallpaper, local-only Start search, Smart App Control Off, no ads/widgets/Copilot/Recall'
    win11_cleanup               = 'Remove Windows 11 noise apps (News, Weather, Solitaire, Office Hub trial, WhatsApp, LinkedIn, Xbox, Spotify, TikTok, …)'
    remote_rustdesk             = 'RustDesk (permanent password from .env)'
    remote_dwservice             = 'DWService agent - interactive wizard only (silent not available for personal accounts); copies code to clipboard'
    remote_check                = 'Verify remote access is enabled and configured'
    battery_charge_limit        = 'Battery health: report wear and offer the free charge-limit tool for this laptop vendor'
    perf_tuning                 = 'Dev-workstation performance tuning guidance (Defender exclusions, WSL2)'
    health_check                = 'Check managed winget packages for updates and apply them; refresh npm/pip/composer tools'
    pin_apps                   = 'Create Start Menu shortcuts per PIN_* flags in .env (Windows 11 blocks scripted taskbar pinning)'
}

$StepFuncs = @{}
foreach ($id in $StepIds) {
    $StepFuncs[$id] = Get-Item "function:Step_$id"
}

function Show-Help {
    Write-Host "dev-setup.ps1 v$ScriptVersion - Windows 11 development environment bootstrapper"
    Write-Host ''
    Write-Host 'Installs a full dev workstation (languages, editors, Docker, CLI tools, comms'
    Write-Host 'apps, remote access, power/perf tuning) in one run, step by step and safe to'
    Write-Host 're-run. See README.md for full details.'
    Write-Host ''
    Write-Host 'Settings (git identity/token, remote-access credentials) are read from a .env'
    Write-Host 'file next to this script - copy .env-sample to .env and fill it in.'
    Write-Host ''
    Write-Host 'Usage: .\dev-setup.ps1 [options]'
    Write-Host ''
    Write-Host 'Options:'
    Write-Host '  -Yes            Non-interactive: assume yes for every step'
    Write-Host '  -DryRun         Print what would happen without changing anything'
    Write-Host '  -Only a,b,c     Only run these step ids'
    Write-Host '  -Skip a,b,c     Run everything except these step ids'
    Write-Host '  -Profile minimal  Core toolchain only'
    Write-Host '  -Profile server   Skip GUI/comms/media apps (Windows Server / headless)'
    Write-Host '  -Profile desktop  Full GUI set (default on Windows 11)'
    Write-Host '  -List           List step ids and descriptions, then exit'
    Write-Host '  -Help           Show this help'
    Write-Host ''
    Write-Host 'Step ids:'
    foreach ($id in $StepIds) {
        Write-Host ('  {0,-24} {1}' -f $id, $StepDesc[$id])
    }
}

if ($List) {
    foreach ($id in $StepIds) {
        Write-Output ('{0,-24} {1}' -f $id, $StepDesc[$id])
    }
    exit 0
}
if ($Help) { Show-Help; exit 0 }

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
function Main {
    Write-LogInfo "dev-setup.ps1 v$ScriptVersion - log file: $LogFile"
    if ($DryRun) { Write-LogWarn "DRY RUN: no changes will be made" }
    Test-Preconditions

    foreach ($id in $StepIds) {
        if ($Only.Count -gt 0 -and ($Only -notcontains $id)) { continue }
        if ($Skip.Count -gt 0 -and ($Skip -contains $id)) { continue }

        # Only skip extensions when VS Code genuinely is not on this machine.
        # Declining "Install Visual Studio Code?" because it is already
        # installed used to silently skip vscode_ext too, which is the
        # opposite of what answering "n" there means.
        if ($id -eq 'vscode_ext' -and $Results.Contains('vscode') -and $Results['vscode'] -eq 'skipped' `
            -and -not (Test-CmdExists 'code')) {
            Write-LogInfo "VS Code is not installed and the vscode step was skipped; skipping vscode_ext"
            $Results[$id] = 'skipped'
            continue
        }

        if ($Only.Count -eq 0) {
            if ($OptInSteps -contains $id) {
                # Optional / default-N: -Yes does not enable these; use -Only.
                if ($Yes) {
                    Write-LogInfo "Skipping optional step ${id} (default off under -Yes; pass -Only $id to install)"
                    $Results[$id] = 'skipped'
                    continue
                }
                if (-not (Confirm-DefaultNo "Install (optional, default no): $($StepDesc[$id])?")) {
                    $Results[$id] = 'skipped'
                    continue
                }
            } elseif (-not (Confirm-Step "Install: $($StepDesc[$id])?")) {
                $Results[$id] = 'skipped'
                continue
            }
        }
        Invoke-StepFunc -Id $id -Desc $StepDesc[$id] -Func $StepFuncs[$id].ScriptBlock
    }

    Write-Host ''
    Write-Host '=== Summary ===' -ForegroundColor White
    $failed = @()
    $needsElevation = @()
    foreach ($id in $StepIds) {
        $status = if ($Results.Contains($id)) { $Results[$id] } else { 'not run' }
        $color = 'Yellow'
        if ($status -eq 'OK' -or $status -eq 'dry-run') { $color = 'Green' }
        if ($status -eq 'FAILED' -or $status -eq 'dry-run-error') { $color = 'Red'; $failed += $id }
        if ($status -eq 'needs-elevation') { $color = 'Yellow'; $needsElevation += $id }
        Write-Host ('  {0,-24} ' -f $id) -NoNewline
        Write-Host $status -ForegroundColor $color
    }
    Write-Host "`nLog file: $LogFile"
    $script:FailedSteps = $failed
    if ($failed.Count -gt 0) {
        Write-LogWarn "Failed step(s): $($failed -join ', ')"
        Write-LogWarn "Re-run just those: .\dev-setup.ps1 -Only $($failed -join ',')"
    }
    if ($needsElevation.Count -gt 0) {
        Write-LogWarn "Needs elevation (not a bug - re-run elevated): $($needsElevation -join ', ')"
        Write-LogWarn "  .\dev-setup-admin.cmd -Only $($needsElevation -join ',')"
    }

    if (-not $DryRun) {
        Write-Host @'

Next steps:
  - Open a new terminal (or run `refreshenv`-equivalent: re-source PATH) to pick up nvm/dotnet/npm/pip changes.
  - If Docker Desktop was installed, make sure WSL2 is enabled (wsl --install, then reboot) and start Docker Desktop once by hand.
  - remote_ssh and remote_rdp need an elevated PowerShell - run them with -Only if you skipped them here.
  - If you set up remote access: run `.\dev-setup.ps1 -Only remote_check` any time to verify SSH/RDP/RustDesk/DWService status.
  - Your .env file holds plaintext credentials - keep it out of version control and delete it once you no longer need unattended access.
'@
    }
}

# Non-zero on failure so the .cmd launchers, CI, and any wrapper can tell a
# clean run from a partial one without scraping the log. Deliberately NOT
# `exit (Main)`: a PowerShell function returns every uncaptured pipeline
# object, so any stray output inside Main would ride along with the count.
Main
exit $script:FailedSteps.Count
