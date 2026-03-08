#Requires -Version 5.1
<#
.SYNOPSIS
    DFIR Drive Updater - Portable First-Run Setup Wizard
.DESCRIPTION
    Handles first-run configuration on a new Windows machine:
    - Checks/creates the auto-launch scheduled task
    - Sets the USB drive volume label to "DFIR" if needed
    - Validates the tools-config.json file
    - Tests network connectivity to GitHub
    - Displays a summary of what was configured
.NOTES
    Run this script from the DFIR-Updater folder on the USB drive.
    No administrative privileges required.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# ─── Dynamic Path Resolution ─────────────────────────────────────────────────
$script:ScriptDir = $PSScriptRoot
if (-not $script:ScriptDir) { $script:ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition }
$script:DriveRoot = Split-Path -Parent $script:ScriptDir
$script:DriveLetter = ($script:DriveRoot -replace '\\$', '').Substring(0, 1)

$script:ConfigPath       = Join-Path $script:ScriptDir 'tools-config.json'
$script:AutoLaunchScript = Join-Path $script:ScriptDir 'Setup-AutoLaunch.ps1'
$script:GUIScript        = Join-Path $script:ScriptDir 'DFIR-Updater-GUI.ps1'

# ─── Tracking ────────────────────────────────────────────────────────────────
$script:Actions = [System.Collections.Generic.List[string]]::new()

# ─── Helper Functions ─────────────────────────────────────────────────────────
function Write-Header {
    param([string]$Text)
    Write-Host ''
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host "  $('-' * $Text.Length)" -ForegroundColor DarkCyan
}

function Write-Ok {
    param([string]$Text)
    Write-Host "  [OK] $Text" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Text)
    Write-Host "  [!!] $Text" -ForegroundColor Yellow
}

function Write-Fail {
    param([string]$Text)
    Write-Host "  [XX] $Text" -ForegroundColor Red
}

function Write-Info {
    param([string]$Text)
    Write-Host "  [--] $Text" -ForegroundColor Gray
}

function Read-YesNo {
    param([string]$Prompt)
    do {
        Write-Host ''
        Write-Host "  $Prompt " -ForegroundColor White -NoNewline
        $answer = Read-Host
    } while ($answer -notmatch '^[YyNn]$')
    return $answer -match '^[Yy]$'
}

# ─── Banner ──────────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '  ============================================================' -ForegroundColor Cyan
Write-Host '   DFIR Drive Updater - Portable Setup Wizard'                  -ForegroundColor Cyan
Write-Host '  ============================================================' -ForegroundColor Cyan
Write-Host ''
Write-Host "   Drive Root  : $script:DriveRoot" -ForegroundColor White
Write-Host "   Script Dir  : $script:ScriptDir" -ForegroundColor White
Write-Host "   Computer    : $env:COMPUTERNAME" -ForegroundColor White
Write-Host "   User        : $env:USERNAME" -ForegroundColor White
Write-Host ''

# ─── Step 1: Check / Create Scheduled Task ────────────────────────────────────
Write-Header 'Step 1: Auto-Launch Scheduled Task'

$taskExists = $false
$existingTask = Get-ScheduledTask -TaskName 'DFIR-Drive-Updater' -ErrorAction SilentlyContinue
if ($null -ne $existingTask) {
    $taskExists = $true
    Write-Ok 'Scheduled task "DFIR-Drive-Updater" is already registered.'
    $script:Actions.Add('Auto-launch task: already configured (no changes)')
} else {
    Write-Warn 'Scheduled task "DFIR-Drive-Updater" is NOT registered on this machine.'
    Write-Info  'This task auto-launches the updater when the USB drive is plugged in.'

    if (Test-Path $script:AutoLaunchScript) {
        if (Read-YesNo 'Create the auto-launch task now? (Y/N)') {
            Write-Host ''
            Write-Info 'Running Setup-AutoLaunch.ps1...'
            try {
                & $script:AutoLaunchScript
                $taskExists = $true
                $script:Actions.Add('Auto-launch task: CREATED')
            } catch {
                Write-Fail "Failed to create scheduled task: $_"
                $script:Actions.Add('Auto-launch task: FAILED to create')
            }
        } else {
            Write-Info 'Skipped. You can set it up later with Setup-AutoLaunch.ps1'
            $script:Actions.Add('Auto-launch task: skipped by user')
        }
    } else {
        Write-Fail "Setup-AutoLaunch.ps1 not found at: $script:AutoLaunchScript"
        $script:Actions.Add('Auto-launch task: setup script missing')
    }
}

# ─── Step 2: Volume Label ────────────────────────────────────────────────────
Write-Header 'Step 2: Drive Volume Label'

$currentLabel = $null
try {
    $vol = Get-Volume -DriveLetter $script:DriveLetter -ErrorAction Stop
    $currentLabel = $vol.FileSystemLabel
} catch {
    Write-Warn "Could not read volume label for drive ${script:DriveLetter}:"
}

if ($currentLabel -eq 'DFIR') {
    Write-Ok "Volume label is already set to 'DFIR'."
    $script:Actions.Add('Volume label: already set to DFIR (no changes)')
} elseif ($null -ne $currentLabel) {
    $displayLabel = if ([string]::IsNullOrWhiteSpace($currentLabel)) { '(empty)' } else { "'$currentLabel'" }
    Write-Warn "Current volume label is $displayLabel (expected 'DFIR')."
    Write-Info  "The auto-launch task finds the drive by the 'DFIR' volume label."

    if (Read-YesNo "Set volume label to 'DFIR'? (Y/N)") {
        try {
            Set-Volume -DriveLetter $script:DriveLetter -NewFileSystemLabel 'DFIR' -ErrorAction Stop
            Write-Ok "Volume label set to 'DFIR'."
            $script:Actions.Add("Volume label: changed from $displayLabel to 'DFIR'")
        } catch {
            Write-Fail "Failed to set volume label: $_"
            Write-Info  "You may need to run this as Administrator, or set it manually:"
            Write-Info  "  label ${script:DriveLetter}: DFIR"
            $script:Actions.Add('Volume label: FAILED to set')
        }
    } else {
        Write-Info 'Skipped. The auto-launch task may not find this drive without the DFIR label.'
        $script:Actions.Add('Volume label: skipped by user')
    }
} else {
    $script:Actions.Add('Volume label: could not read')
}

# ─── Step 3: Validate tools-config.json ──────────────────────────────────────
Write-Header 'Step 3: Tools Configuration'

if (Test-Path $script:ConfigPath) {
    try {
        $raw = Get-Content -LiteralPath $script:ConfigPath -Raw -ErrorAction Stop
        $config = $raw | ConvertFrom-Json -ErrorAction Stop

        if ($null -eq $config) {
            Write-Fail 'tools-config.json parsed as null.'
            $script:Actions.Add('Config validation: FAILED (null)')
        } elseif (-not $config.tools) {
            Write-Fail 'tools-config.json has no "tools" array.'
            $script:Actions.Add('Config validation: FAILED (no tools array)')
        } else {
            $toolCount = @($config.tools).Count
            $githubCount = @($config.tools | Where-Object { $_.source_type -eq 'github' }).Count
            $webCount = @($config.tools | Where-Object { $_.source_type -eq 'web' }).Count

            Write-Ok "tools-config.json is valid."
            Write-Info "  Total tools : $toolCount"
            Write-Info "  GitHub tools: $githubCount (auto-check supported)"
            Write-Info "  Web tools   : $webCount (manual check required)"
            $script:Actions.Add("Config validation: OK ($toolCount tools)")
        }
    } catch {
        Write-Fail "tools-config.json is invalid: $_"
        $script:Actions.Add('Config validation: FAILED (parse error)')
    }
} else {
    Write-Fail "tools-config.json not found at: $script:ConfigPath"
    $script:Actions.Add('Config validation: FAILED (file missing)')
}

# ─── Step 4: Connectivity Test ───────────────────────────────────────────────
Write-Header 'Step 4: Network Connectivity'

Write-Info 'Testing connection to api.github.com...'
$githubOk = $false
try {
    $request = [System.Net.WebRequest]::Create('https://api.github.com')
    $request.Timeout = 8000
    $request.Method  = 'HEAD'
    $request.Headers.Add('User-Agent', 'DFIR-Updater/1.0')
    $response = $request.GetResponse()
    $response.Close()
    $githubOk = $true
    Write-Ok 'GitHub API is reachable.'
} catch {
    Write-Fail "Cannot reach GitHub API: $_"
    Write-Info  'Update checking requires an internet connection.'
}

Write-Info 'Testing general internet connectivity...'
$internetOk = $false
try {
    $request2 = [System.Net.WebRequest]::Create('https://www.google.com')
    $request2.Timeout = 8000
    $request2.Method  = 'HEAD'
    $response2 = $request2.GetResponse()
    $response2.Close()
    $internetOk = $true
    Write-Ok 'Internet connectivity is working.'
} catch {
    Write-Fail 'No internet connection detected.'
}

if ($githubOk) {
    $script:Actions.Add('Connectivity: GitHub API reachable')
} elseif ($internetOk) {
    $script:Actions.Add('Connectivity: Internet OK but GitHub blocked')
} else {
    $script:Actions.Add('Connectivity: No internet connection')
}

# ─── Step 5: Verify Key Files ───────────────────────────────────────────────
Write-Header 'Step 5: File Integrity Check'

$requiredFiles = @(
    @{ Name = 'GUI Script';           Path = $script:GUIScript }
    @{ Name = 'Auto-Launch Setup';    Path = $script:AutoLaunchScript }
    @{ Name = 'Tools Configuration';  Path = $script:ConfigPath }
    @{ Name = 'Update-Checker Module'; Path = (Join-Path $script:ScriptDir 'modules\Update-Checker.ps1') }
)

$missingCount = 0
foreach ($file in $requiredFiles) {
    if (Test-Path $file.Path) {
        Write-Ok "$($file.Name)"
    } else {
        Write-Fail "$($file.Name) - MISSING: $($file.Path)"
        $missingCount++
    }
}

if ($missingCount -eq 0) {
    $script:Actions.Add('File integrity: all required files present')
} else {
    $script:Actions.Add("File integrity: $missingCount file(s) missing")
}

# ─── Summary ─────────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '  ============================================================' -ForegroundColor Cyan
Write-Host '   Setup Summary'                                                -ForegroundColor Cyan
Write-Host '  ============================================================' -ForegroundColor Cyan
Write-Host ''

foreach ($action in $script:Actions) {
    $color = 'White'
    if ($action -match 'FAILED|missing') { $color = 'Red' }
    elseif ($action -match 'skipped')     { $color = 'Yellow' }
    elseif ($action -match 'OK|CREATED|already|reachable|present') { $color = 'Green' }
    Write-Host "    - $action" -ForegroundColor $color
}

Write-Host ''
Write-Host '  To launch the updater GUI, run Launch-Updater.bat' -ForegroundColor DarkGray
Write-Host '  or double-click it from Explorer.' -ForegroundColor DarkGray
Write-Host ''
