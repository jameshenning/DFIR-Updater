#Requires -Version 5.1
<#
.SYNOPSIS
    Bootstraps a fresh DFIR USB drive from scratch.

.DESCRIPTION
    Sets up a new USB drive with the standard DFIR folder structure, copies
    the DFIR-Updater framework, and optionally downloads all GitHub-sourced
    tools defined in tools-config.json.

    This script is designed to be run from a cloned DFIR-Updater Git
    repository or from an existing DFIR drive to replicate the framework
    onto a new USB drive.

.PARAMETER DriveLetter
    The target drive letter (e.g., "E"). Do not include a colon or backslash.

.PARAMETER SkipDownloads
    Only create the folder structure and copy the updater framework.
    Do not download any tools.

.PARAMETER ToolsOnly
    Only download tools. Assumes the folder structure and updater framework
    already exist on the target drive.

.PARAMETER GitHubToken
    Optional GitHub personal access token for authenticated API requests
    (raises rate limit from 60 to 5,000 requests/hour).

.EXAMPLE
    .\Bootstrap-DFIR-Drive.ps1 -DriveLetter E
    Full bootstrap: creates structure, copies updater, downloads tools.

.EXAMPLE
    .\Bootstrap-DFIR-Drive.ps1 -DriveLetter F -SkipDownloads
    Creates folder structure and copies updater without downloading tools.

.EXAMPLE
    .\Bootstrap-DFIR-Drive.ps1 -DriveLetter E -ToolsOnly
    Downloads tools only, assuming the drive is already set up.

.NOTES
    Requires internet connectivity for tool downloads.
    Run from the DFIR-Updater directory (or a Git clone of it).
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z]$')]
    [string]$DriveLetter,

    [switch]$SkipDownloads,

    [switch]$ToolsOnly,

    [Parameter()]
    [string]$GitHubToken
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# =============================================================================
# Path Resolution
# =============================================================================
$script:ScriptDir = $PSScriptRoot
if (-not $script:ScriptDir) { $script:ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition }

$DriveLetter       = $DriveLetter.ToUpper()
$script:TargetRoot = "${DriveLetter}:\"
$script:TargetUpdaterDir = Join-Path $script:TargetRoot 'DFIR-Updater'
$script:ConfigPath = Join-Path $script:ScriptDir 'tools-config.json'
$script:ModulesDir = Join-Path $script:ScriptDir 'modules'
$script:UpdateCheckerPath = Join-Path $script:ModulesDir 'Update-Checker.ps1'
$script:LogPath    = Join-Path $script:TargetUpdaterDir 'setup-log.txt'
$script:StartTime  = Get-Date

# Counters
$script:ToolsDownloaded = 0
$script:ToolsFailed     = 0
$script:ToolsManual     = 0
$script:ToolsSkipped    = 0

# =============================================================================
# Helper Functions
# =============================================================================
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

function Write-Step {
    param([string]$Text)
    Write-Host "  [>>] $Text" -ForegroundColor White
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

function Write-Log {
    <#
    .SYNOPSIS
        Appends a timestamped line to the setup log file.
    #>
    param([string]$Message)
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$timestamp] $Message"
    try {
        $logDir = Split-Path $script:LogPath -Parent
        if (-not (Test-Path -LiteralPath $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
        Add-Content -LiteralPath $script:LogPath -Value $line -ErrorAction Stop
    }
    catch {
        # Silently continue if we can't write to the log yet
    }
}

# =============================================================================
# Validation
# =============================================================================
function Test-Prerequisites {
    Write-Header 'Validating Prerequisites'

    # Check target drive exists
    if (-not (Test-Path -LiteralPath $script:TargetRoot)) {
        Write-Fail "Drive ${DriveLetter}: does not exist or is not accessible."
        Write-Info 'Please insert the target USB drive and try again.'
        return $false
    }
    Write-Ok "Drive ${DriveLetter}: is accessible."

    # Check we are not targeting the system drive
    $systemDrive = $env:SystemDrive.Substring(0, 1)
    if ($DriveLetter -eq $systemDrive) {
        Write-Fail "Drive ${DriveLetter}: appears to be the system drive. Aborting."
        return $false
    }
    Write-Ok 'Target is not the system drive.'

    # Check tools-config.json exists (needed for downloads)
    if (-not $SkipDownloads) {
        if (-not (Test-Path -LiteralPath $script:ConfigPath)) {
            Write-Fail "tools-config.json not found at: $($script:ConfigPath)"
            Write-Info 'Cannot download tools without a configuration file.'
            if (-not $ToolsOnly) {
                Write-Info 'You can re-run with -SkipDownloads to create the folder structure only.'
            }
            return $false
        }
        Write-Ok 'tools-config.json found.'
    }

    # Check Update-Checker.ps1 exists (needed for download functions)
    if (-not $SkipDownloads) {
        if (-not (Test-Path -LiteralPath $script:UpdateCheckerPath)) {
            Write-Warn "Update-Checker.ps1 not found at: $($script:UpdateCheckerPath)"
            Write-Info 'GitHub API functions will be unavailable. Tool downloads may fail.'
        } else {
            Write-Ok 'Update-Checker.ps1 module found.'
        }
    }

    # Check free space (warn if < 2 GB)
    try {
        $drive = Get-PSDrive -Name $DriveLetter -ErrorAction Stop
        $freeGB = [math]::Round($drive.Free / 1GB, 2)
        if ($freeGB -lt 2) {
            Write-Warn "Only ${freeGB} GB free on ${DriveLetter}:. Some tools may not fit."
        } else {
            Write-Ok "${freeGB} GB free on ${DriveLetter}:."
        }
    }
    catch {
        Write-Info 'Could not determine free space (non-critical).'
    }

    return $true
}

# =============================================================================
# Step 1: Create Folder Structure
# =============================================================================
function New-DFIRFolderStructure {
    Write-Header 'Step 1: Creating DFIR Folder Structure'

    $folders = @(
        '01_Acquisition'
        '02_Analysis'
        '03_Network'
        '04_Mobile-Forensics'
        '05_Case-Files'
        '06_Training'
        '07_Documentation'
        '08_Utilities'
        'PortableApps'
        'Shortcuts'
        'Documents'
        'DFIR-Updater'
    )

    $created = 0
    $existed = 0

    foreach ($folder in $folders) {
        $fullPath = Join-Path $script:TargetRoot $folder
        if (Test-Path -LiteralPath $fullPath) {
            Write-Info "$folder (already exists)"
            $existed++
        } else {
            try {
                New-Item -ItemType Directory -Path $fullPath -Force | Out-Null
                Write-Ok "$folder"
                $created++
                Write-Log "Created folder: $fullPath"
            }
            catch {
                Write-Fail "Failed to create $folder : $_"
                Write-Log "FAILED to create folder: $fullPath - $_"
            }
        }
    }

    Write-Host ''
    Write-Info "Folders created: $created | Already existed: $existed"
    Write-Log "Folder structure: $created created, $existed already existed."
}

# =============================================================================
# Step 2: Copy DFIR-Updater Framework
# =============================================================================
function Copy-UpdaterFramework {
    Write-Header 'Step 2: Copying DFIR-Updater Framework'

    # Check if we are running from a DFIR-Updater directory with the expected files
    $requiredFiles = @('tools-config.json')
    $hasFramework = $true
    foreach ($file in $requiredFiles) {
        if (-not (Test-Path -LiteralPath (Join-Path $script:ScriptDir $file))) {
            $hasFramework = $false
            break
        }
    }

    if (-not $hasFramework) {
        Write-Warn 'This script does not appear to be running from a complete DFIR-Updater directory.'
        Write-Info 'Skipping framework copy. You may need to manually copy files.'
        Write-Log 'Framework copy skipped: source directory incomplete.'
        return
    }

    # Don't copy onto ourselves
    $sourceNorm = $script:ScriptDir.TrimEnd('\', '/').ToLower()
    $targetNorm = $script:TargetUpdaterDir.TrimEnd('\', '/').ToLower()
    if ($sourceNorm -eq $targetNorm) {
        Write-Info 'Source and target are the same directory. Skipping copy.'
        Write-Log 'Framework copy skipped: source equals target.'
        return
    }

    Write-Step "Copying from: $($script:ScriptDir)"
    Write-Step "Copying to  : $($script:TargetUpdaterDir)"

    $filesCopied = 0
    $filesSkipped = 0

    # Get all files to copy (exclude .git directory, backup files, logs)
    $itemsToCopy = Get-ChildItem -LiteralPath $script:ScriptDir -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object {
            $rel = $_.FullName.Substring($script:ScriptDir.Length).TrimStart('\', '/')
            # Exclude .git internals, backups, logs, scan-manifest
            $rel -notmatch '^\.git[\\/]' -and
            $rel -notmatch '\.bak_' -and
            $rel -notmatch '\.log$' -and
            $rel -ne 'scan-manifest.json' -and
            $rel -ne 'setup-log.txt'
        }

    foreach ($item in $itemsToCopy) {
        $relativePath = $item.FullName.Substring($script:ScriptDir.Length).TrimStart('\', '/')
        $destPath = Join-Path $script:TargetUpdaterDir $relativePath
        $destDir  = Split-Path $destPath -Parent

        try {
            if (-not (Test-Path -LiteralPath $destDir)) {
                New-Item -ItemType Directory -Path $destDir -Force | Out-Null
            }
            Copy-Item -LiteralPath $item.FullName -Destination $destPath -Force -ErrorAction Stop
            Write-Ok $relativePath
            $filesCopied++
        }
        catch {
            Write-Fail "Failed to copy ${relativePath}: $_"
            $filesSkipped++
        }
    }

    Write-Host ''
    Write-Info "Files copied: $filesCopied | Failed: $filesSkipped"
    Write-Log "Framework copy: $filesCopied files copied, $filesSkipped failed."
}

# =============================================================================
# Step 3: Download Tools
# =============================================================================
function Install-Tools {
    Write-Header 'Step 3: Downloading and Installing Tools'

    # Dot-source Update-Checker.ps1 for its functions
    if (Test-Path -LiteralPath $script:UpdateCheckerPath) {
        try {
            . $script:UpdateCheckerPath
            Write-Ok 'Loaded Update-Checker.ps1 module.'
        }
        catch {
            Write-Fail "Failed to load Update-Checker.ps1: $_"
            Write-Log "FAILED to load Update-Checker.ps1: $_"
            return
        }
    } else {
        Write-Fail 'Update-Checker.ps1 not found. Cannot download tools.'
        Write-Log 'Tool download aborted: Update-Checker.ps1 missing.'
        return
    }

    # Load config
    $config = $null
    try {
        $config = Get-ToolConfig -Path $script:ConfigPath
    }
    catch {
        Write-Fail "Failed to load tools-config.json: $_"
        Write-Log "FAILED to load tools-config.json: $_"
        return
    }

    $tools = $config.tools
    if (-not $tools -or @($tools).Count -eq 0) {
        Write-Warn 'No tools found in configuration.'
        Write-Log 'No tools found in configuration.'
        return
    }

    $totalTools = @($tools).Count
    $index = 0

    # Collect manual-download tools for the report
    $manualDownloads = [System.Collections.Generic.List[PSCustomObject]]::new()

    Write-Info "Processing $totalTools tools..."
    Write-Host ''

    foreach ($tool in $tools) {
        $index++
        $toolName   = $tool.name
        $sourceType = $tool.source_type
        $installType = $tool.install_type

        # Progress bar
        $pctComplete = [int](($index / $totalTools) * 100)
        Write-Progress -Activity 'Bootstrapping DFIR Tools' `
                       -Status "[$index/$totalTools] $toolName" `
                       -PercentComplete $pctComplete

        Write-Host "  [$index/$totalTools] " -ForegroundColor DarkGray -NoNewline
        Write-Host "$toolName" -ForegroundColor White -NoNewline
        Write-Host " ($sourceType / $installType)" -ForegroundColor DarkGray

        # --- GitHub source tools ---
        if ($sourceType -eq 'github') {
            if ([string]::IsNullOrWhiteSpace($tool.github_repo)) {
                Write-Warn "  No github_repo configured. Skipping."
                Write-Log "SKIPPED $toolName : no github_repo."
                $script:ToolsSkipped++
                continue
            }

            # Query latest release
            $releaseParams = @{ OwnerRepo = $tool.github_repo }
            if ($tool.github_asset_pattern) {
                $releaseParams['AssetPattern'] = $tool.github_asset_pattern
            }
            if ($GitHubToken) {
                $releaseParams['GitHubToken'] = $GitHubToken
            }

            $release = $null
            try {
                $release = Get-GitHubLatestRelease @releaseParams
            }
            catch {
                Write-Fail "  GitHub API error: $_"
                Write-Log "FAILED $toolName : GitHub API error - $_"
                $script:ToolsFailed++
                continue
            }

            if ($release.Error) {
                Write-Fail "  GitHub API: $($release.Error)"
                Write-Log "FAILED $toolName : GitHub API - $($release.Error)"
                $script:ToolsFailed++
                continue
            }

            if ($release.Assets.Count -eq 0) {
                Write-Warn "  No matching assets found in latest release ($($release.TagName))."
                Write-Log "SKIPPED $toolName : no matching assets in $($release.TagName)."
                $script:ToolsSkipped++
                continue
            }

            $asset = $release.Assets | Select-Object -First 1
            $downloadUrl = $asset.DownloadUrl
            $assetName   = $asset.Name

            # Determine install path on target drive
            $installPath = Join-Path $script:TargetRoot $tool.path

            Write-Info "  Latest: $($release.TagName) | Asset: $assetName"

            # Handle 'manual' install type -- just log it
            if ($installType -eq 'manual') {
                Write-Warn "  Install type is 'manual'. Logging for manual action."
                $manualDownloads.Add([PSCustomObject]@{
                    Name = $toolName
                    URL  = $downloadUrl
                    Note = $tool.notes
                })
                $script:ToolsManual++
                Write-Log "MANUAL $toolName : $downloadUrl"
                continue
            }

            # Download and install using Install-ToolUpdate
            try {
                $result = Install-ToolUpdate -ToolName $toolName `
                                             -DownloadUrl $downloadUrl `
                                             -InstallPath $installPath `
                                             -InstallType $installType `
                                             -Confirm:$false

                if ($result.Success) {
                    Write-Ok "  $($result.Message)"
                    Write-Log "OK $toolName : $($result.Message)"
                    $script:ToolsDownloaded++
                } else {
                    Write-Fail "  $($result.Message)"
                    Write-Log "FAILED $toolName : $($result.Message)"
                    $script:ToolsFailed++
                }
            }
            catch {
                Write-Fail "  Install error: $_"
                Write-Log "FAILED $toolName : Install error - $_"
                $script:ToolsFailed++
            }
        }
        # --- Web source tools ---
        elseif ($sourceType -eq 'web') {
            $url = $tool.download_url
            if ([string]::IsNullOrWhiteSpace($url)) { $url = '(no URL provided)' }

            Write-Warn "  Requires manual download: $url"
            $manualDownloads.Add([PSCustomObject]@{
                Name = $toolName
                URL  = $url
                Note = $tool.notes
            })
            $script:ToolsManual++
            Write-Log "MANUAL $toolName : $url"
        }
        # --- Unknown source type ---
        else {
            Write-Warn "  Unknown source_type '$sourceType'. Skipping."
            Write-Log "SKIPPED $toolName : unknown source_type '$sourceType'."
            $script:ToolsSkipped++
        }
    }

    Write-Progress -Activity 'Bootstrapping DFIR Tools' -Completed

    # --- Manual download report ---
    if ($manualDownloads.Count -gt 0) {
        Write-Host ''
        Write-Header 'Manual Downloads Required'
        Write-Info 'The following tools must be downloaded manually:'
        Write-Host ''
        foreach ($md in $manualDownloads) {
            Write-Host "    $($md.Name)" -ForegroundColor Yellow
            Write-Host "      URL  : $($md.URL)" -ForegroundColor Gray
            if ($md.Note) {
                Write-Host "      Note : $($md.Note)" -ForegroundColor DarkGray
            }
        }

        # Also write manual downloads to a file on the target drive
        $manualListPath = Join-Path $script:TargetUpdaterDir 'manual-downloads.txt'
        try {
            $manualLines = @("DFIR Drive Bootstrap - Manual Downloads Required", "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')", "")
            foreach ($md in $manualDownloads) {
                $manualLines += "$($md.Name)"
                $manualLines += "  URL  : $($md.URL)"
                if ($md.Note) { $manualLines += "  Note : $($md.Note)" }
                $manualLines += ""
            }
            Set-Content -LiteralPath $manualListPath -Value $manualLines -ErrorAction Stop
            Write-Host ''
            Write-Info "Manual download list saved to: $manualListPath"
        }
        catch {
            Write-Warn "Could not save manual download list: $_"
        }
    }
}

# =============================================================================
# Step 4: Volume Label
# =============================================================================
function Set-DFIRVolumeLabel {
    Write-Header 'Step 4: Volume Label'

    $currentLabel = $null
    try {
        $vol = Get-Volume -DriveLetter $DriveLetter -ErrorAction Stop
        $currentLabel = $vol.FileSystemLabel
    }
    catch {
        Write-Warn "Could not read volume label for ${DriveLetter}:."
        Write-Log 'Volume label: could not read current label.'
        return
    }

    if ($currentLabel -eq 'DFIR') {
        Write-Ok "Volume label is already 'DFIR'."
        Write-Log 'Volume label: already DFIR.'
        return
    }

    $displayLabel = if ([string]::IsNullOrWhiteSpace($currentLabel)) { '(empty)' } else { "'$currentLabel'" }
    Write-Info "Current volume label: $displayLabel"

    if (Read-YesNo "Set volume label to 'DFIR'? (Y/N)") {
        try {
            Set-Volume -DriveLetter $DriveLetter -NewFileSystemLabel 'DFIR' -ErrorAction Stop
            Write-Ok "Volume label set to 'DFIR'."
            Write-Log "Volume label: changed from $displayLabel to 'DFIR'."
        }
        catch {
            Write-Fail "Failed to set volume label: $_"
            Write-Info 'You may need to run as Administrator, or set it manually:'
            Write-Info "  label ${DriveLetter}: DFIR"
            Write-Log "Volume label: FAILED to set - $_"
        }
    } else {
        Write-Info 'Skipped volume label change.'
        Write-Log 'Volume label: skipped by user.'
    }
}

# =============================================================================
# Step 5: Offer Auto-Launch Setup
# =============================================================================
function Invoke-AutoLaunchOffer {
    Write-Header 'Step 5: Auto-Launch Setup'

    $autoLaunchScript = Join-Path $script:TargetUpdaterDir 'Setup-AutoLaunch.ps1'

    if (-not (Test-Path -LiteralPath $autoLaunchScript)) {
        # Fall back to source directory
        $autoLaunchScript = Join-Path $script:ScriptDir 'Setup-AutoLaunch.ps1'
    }

    if (-not (Test-Path -LiteralPath $autoLaunchScript)) {
        Write-Warn 'Setup-AutoLaunch.ps1 not found. Skipping.'
        Write-Log 'Auto-launch: script not found.'
        return
    }

    Write-Info 'The auto-launch task makes the updater GUI pop up when you plug in the drive.'

    # Check if already configured
    $existingTask = Get-ScheduledTask -TaskName 'DFIR-Drive-Updater' -ErrorAction SilentlyContinue
    if ($null -ne $existingTask) {
        Write-Ok 'Auto-launch task is already registered on this machine.'
        Write-Log 'Auto-launch: already registered.'
        return
    }

    if (Read-YesNo 'Set up auto-launch on THIS machine? (Y/N)') {
        try {
            & $autoLaunchScript
            Write-Ok 'Auto-launch task created.'
            Write-Log 'Auto-launch: task created.'
        }
        catch {
            Write-Fail "Failed to set up auto-launch: $_"
            Write-Log "Auto-launch: FAILED - $_"
        }
    } else {
        Write-Info 'Skipped. Run Setup-AutoLaunch.ps1 later on any machine.'
        Write-Log 'Auto-launch: skipped by user.'
    }
}

# =============================================================================
# Summary Report
# =============================================================================
function Show-Summary {
    $elapsed = (Get-Date) - $script:StartTime

    Write-Host ''
    Write-Host ''
    Write-Host '  ============================================================' -ForegroundColor Cyan
    Write-Host '   DFIR Drive Bootstrap - Complete'                              -ForegroundColor Cyan
    Write-Host '  ============================================================' -ForegroundColor Cyan
    Write-Host ''
    Write-Host "   Target Drive   : ${DriveLetter}:\" -ForegroundColor White
    Write-Host "   Elapsed Time   : $([math]::Round($elapsed.TotalSeconds, 1)) seconds" -ForegroundColor White

    if (-not $SkipDownloads) {
        Write-Host '' -ForegroundColor White
        Write-Host "   Tools downloaded   : $($script:ToolsDownloaded)" -ForegroundColor Green
        Write-Host "   Tools failed       : $($script:ToolsFailed)" -ForegroundColor $(if ($script:ToolsFailed -gt 0) { 'Red' } else { 'White' })
        Write-Host "   Manual downloads   : $($script:ToolsManual)" -ForegroundColor Yellow
        Write-Host "   Skipped            : $($script:ToolsSkipped)" -ForegroundColor Gray
    }

    Write-Host ''
    Write-Host "   Setup log : $($script:LogPath)" -ForegroundColor DarkGray
    Write-Host ''

    $summaryLine = "Bootstrap complete. Downloaded: $($script:ToolsDownloaded), Failed: $($script:ToolsFailed), Manual: $($script:ToolsManual), Skipped: $($script:ToolsSkipped). Elapsed: $([math]::Round($elapsed.TotalSeconds, 1))s."
    Write-Log $summaryLine
}

# =============================================================================
# Main Execution
# =============================================================================

# Banner
Write-Host ''
Write-Host '  ============================================================' -ForegroundColor Cyan
Write-Host '   DFIR Drive Bootstrap'                                        -ForegroundColor Cyan
Write-Host '   Replicate your DFIR framework onto a new USB drive'          -ForegroundColor Cyan
Write-Host '  ============================================================' -ForegroundColor Cyan
Write-Host ''
Write-Host "   Source    : $($script:ScriptDir)" -ForegroundColor White
Write-Host "   Target    : ${DriveLetter}:\" -ForegroundColor White
Write-Host "   Mode      : $(if ($SkipDownloads) { 'Structure only (no downloads)' } elseif ($ToolsOnly) { 'Tools only (assume structure exists)' } else { 'Full bootstrap' })" -ForegroundColor White
Write-Host ''

# Validate
if (-not (Test-Prerequisites)) {
    Write-Host ''
    Write-Fail 'Prerequisites not met. Aborting.'
    exit 1
}

# Initialize log
Write-Log '================================================================'
Write-Log "DFIR Drive Bootstrap started on $env:COMPUTERNAME by $env:USERNAME"
Write-Log "Source: $($script:ScriptDir)"
Write-Log "Target: ${DriveLetter}:\"
Write-Log "Mode: $(if ($SkipDownloads) { 'SkipDownloads' } elseif ($ToolsOnly) { 'ToolsOnly' } else { 'Full' })"

# Execute steps based on mode
if (-not $ToolsOnly) {
    New-DFIRFolderStructure
    Copy-UpdaterFramework
}

if (-not $SkipDownloads) {
    Install-Tools
}

if (-not $ToolsOnly) {
    Set-DFIRVolumeLabel
    Invoke-AutoLaunchOffer
}

# Show summary
Show-Summary

Write-Host '  Your DFIR drive is ready.' -ForegroundColor Green
Write-Host ''
