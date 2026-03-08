#Requires -Version 5.1
<#
.SYNOPSIS
    Securely removes DFIR Drive Updater artifacts from the TARGET computer.

.DESCRIPTION
    Scans the local machine for temporary files, prefetch data, and recent-file
    entries created by the DFIR Drive Updater. Artifacts are overwritten with
    zeros before deletion to hinder trivial recovery.

    IMPORTANT: This script removes UPDATER artifacts only. Windows USB plug-in
    artifacts (registry, setupapi logs) are NOT removed as they may be needed
    for your forensic timeline.

    Running this script does NOT make the examination forensically sound
    retroactively. It only reduces the updater's footprint on the target system.

.PARAMETER ReportOnly
    Scan and report artifacts without deleting anything.

.PARAMETER WhatIf
    Show what would happen without performing any changes.

.PARAMETER Confirm
    Prompt for confirmation before each deletion.

.PARAMETER Verbose
    Show detailed output during execution.

.EXAMPLE
    .\Forensic-Cleanup.ps1
    Scan and securely delete all updater artifacts.

.EXAMPLE
    .\Forensic-Cleanup.ps1 -ReportOnly
    List artifacts without deleting them.

.EXAMPLE
    .\Forensic-Cleanup.ps1 -WhatIf
    Preview what would be deleted.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$ReportOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# ─── Resolve USB drive paths ────────────────────────────────────────────────
$script:ScriptDir = $PSScriptRoot
if (-not $script:ScriptDir) { $script:ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition }
$script:DriveRoot = Split-Path -Parent $script:ScriptDir
$script:ReportDir = Join-Path $script:ScriptDir 'cleanup-reports'

# ─── Display warnings ───────────────────────────────────────────────────────
Write-Host ''
Write-Host '  ============================================================' -ForegroundColor Cyan
Write-Host '   DFIR Drive Updater - Forensic Cleanup' -ForegroundColor Cyan
Write-Host '  ============================================================' -ForegroundColor Cyan
Write-Host ''
Write-Host '  WARNING: This script removes UPDATER artifacts only.' -ForegroundColor Yellow
Write-Host '  Windows USB plug-in artifacts (registry, setupapi logs) are' -ForegroundColor Yellow
Write-Host '  NOT removed as they may be needed for your forensic timeline.' -ForegroundColor Yellow
Write-Host ''
Write-Host '  NOTE: Running this script does NOT make the examination' -ForegroundColor Yellow
Write-Host '  forensically sound retroactively.' -ForegroundColor Yellow
Write-Host ''

if ($ReportOnly) {
    Write-Host '  MODE: Report Only (no files will be deleted)' -ForegroundColor Magenta
    Write-Host ''
}

# ─── Artifact tracking ──────────────────────────────────────────────────────
$script:Artifacts = [System.Collections.ArrayList]::new()

function Add-Artifact {
    param(
        [string]$Path,
        [long]$Size,
        [string]$Category,
        [string]$Action
    )
    [void]$script:Artifacts.Add([PSCustomObject]@{
        Path     = $Path
        Size     = $Size
        Category = $Category
        Action   = $Action
    })
}

# ─── Secure deletion helper ─────────────────────────────────────────────────
function Remove-FileSecurely {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,

        [string]$Category = 'General'
    )

    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) { return }

    $fileInfo = Get-Item -LiteralPath $FilePath -Force -ErrorAction SilentlyContinue
    if (-not $fileInfo) { return }

    $fileSize = $fileInfo.Length

    if ($ReportOnly) {
        Add-Artifact -Path $FilePath -Size $fileSize -Category $Category -Action 'Found (report only)'
        Write-Verbose "  [REPORT] $FilePath ($fileSize bytes)"
        return
    }

    if ($PSCmdlet.ShouldProcess($FilePath, 'Securely delete')) {
        try {
            # Overwrite file contents with zeros
            if ($fileSize -gt 0) {
                $zeroBuffer = [byte[]]::new($fileSize)
                [System.IO.File]::WriteAllBytes($FilePath, $zeroBuffer)
                Write-Verbose "  [ZERO]   Overwrote $fileSize bytes: $FilePath"
            }

            # Delete the file
            Remove-Item -LiteralPath $FilePath -Force -ErrorAction Stop
            Add-Artifact -Path $FilePath -Size $fileSize -Category $Category -Action 'Securely deleted'
            Write-Verbose "  [DEL]    Deleted: $FilePath"
        }
        catch {
            Add-Artifact -Path $FilePath -Size $fileSize -Category $Category -Action "FAILED: $($_.Exception.Message)"
            Write-Warning "  Failed to delete: $FilePath - $($_.Exception.Message)"
        }
    }
}

# ─── 1. Scan DFIR-Updater temp folder ───────────────────────────────────────
Write-Host '  [1/4] Scanning TEMP folder for DFIR-Updater artifacts...' -ForegroundColor White

$tempUpdaterDir = Join-Path $env:TEMP 'DFIR-Updater'
if (Test-Path -LiteralPath $tempUpdaterDir) {
    Write-Host "        Found: $tempUpdaterDir" -ForegroundColor Green
    $tempFiles = Get-ChildItem -LiteralPath $tempUpdaterDir -Recurse -File -Force -ErrorAction SilentlyContinue
    foreach ($file in $tempFiles) {
        Remove-FileSecurely -FilePath $file.FullName -Category 'Temp Downloads'
    }

    # Remove empty directories (bottom-up) if not report-only
    if (-not $ReportOnly) {
        $tempDirs = Get-ChildItem -LiteralPath $tempUpdaterDir -Recurse -Directory -Force -ErrorAction SilentlyContinue |
                    Sort-Object { $_.FullName.Length } -Descending
        foreach ($dir in $tempDirs) {
            if ($PSCmdlet.ShouldProcess($dir.FullName, 'Remove empty directory')) {
                Remove-Item -LiteralPath $dir.FullName -Force -ErrorAction SilentlyContinue
            }
        }
        if ($PSCmdlet.ShouldProcess($tempUpdaterDir, 'Remove DFIR-Updater temp directory')) {
            Remove-Item -LiteralPath $tempUpdaterDir -Force -ErrorAction SilentlyContinue
            Add-Artifact -Path $tempUpdaterDir -Size 0 -Category 'Temp Downloads' -Action 'Directory removed'
        }
    }
} else {
    Write-Host '        Not found (clean).' -ForegroundColor DarkGray
}

# ─── 2. Scan Prefetch files ─────────────────────────────────────────────────
Write-Host '  [2/4] Scanning Prefetch for updater-related entries...' -ForegroundColor White

$prefetchDir = Join-Path $env:SystemRoot 'Prefetch'
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)

if (-not $isAdmin) {
    Write-Host '        Prefetch cleanup requires administrator privileges.' -ForegroundColor Yellow
    Write-Host '        Scanning with limited access...' -ForegroundColor Yellow
}

$prefetchPatterns = @(
    'DFIR-UPDATER*',
    'POWERSHELL*DFIR*'
)

$prefetchFound = $false
foreach ($pattern in $prefetchPatterns) {
    $prefetchFiles = Get-ChildItem -Path $prefetchDir -Filter $pattern -File -Force -ErrorAction SilentlyContinue
    foreach ($pf in $prefetchFiles) {
        $prefetchFound = $true
        Write-Host "        Found: $($pf.Name)" -ForegroundColor Green
        if ($isAdmin) {
            Remove-FileSecurely -FilePath $pf.FullName -Category 'Prefetch'
        } else {
            Add-Artifact -Path $pf.FullName -Size $pf.Length -Category 'Prefetch' -Action 'Found (requires admin to delete)'
        }
    }
}

if (-not $prefetchFound) {
    Write-Host '        No matching prefetch files found.' -ForegroundColor DarkGray
}

# ─── 3. Scan Recent files ───────────────────────────────────────────────────
Write-Host '  [3/4] Scanning Recent files for DFIR-Updater references...' -ForegroundColor White

$recentDir = [System.Environment]::GetFolderPath('Recent')
if (Test-Path -LiteralPath $recentDir) {
    $recentFiles = Get-ChildItem -LiteralPath $recentDir -Filter '*DFIR*Updater*' -File -Force -ErrorAction SilentlyContinue
    $recentFound = $false
    foreach ($rf in $recentFiles) {
        $recentFound = $true
        Write-Host "        Found: $($rf.Name)" -ForegroundColor Green
        Remove-FileSecurely -FilePath $rf.FullName -Category 'Recent Files'
    }

    if (-not $recentFound) {
        Write-Host '        No matching recent file entries found.' -ForegroundColor DarkGray
    }
} else {
    Write-Host '        Recent folder not accessible.' -ForegroundColor DarkGray
}

# ─── 4. Check Event Logs ────────────────────────────────────────────────────
Write-Host '  [4/4] Checking DeviceSetupManager event log entries...' -ForegroundColor White

try {
    $usbEvents = Get-WinEvent -FilterHashtable @{
        LogName      = 'Microsoft-Windows-DeviceSetupManager/Admin'
        ProviderName = 'DeviceSetupManager'
        Id           = 112
    } -MaxEvents 10 -ErrorAction SilentlyContinue

    if ($usbEvents -and $usbEvents.Count -gt 0) {
        Write-Host "        Found $($usbEvents.Count) USB device setup event(s) (showing last 10)." -ForegroundColor Green
        foreach ($evt in $usbEvents) {
            $evtInfo = "Event ID 112 at $($evt.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'))"
            Add-Artifact -Path "EventLog: DeviceSetupManager" -Size 0 -Category 'Event Log' -Action "Informational - $evtInfo"
            Write-Verbose "        $evtInfo"
        }
        Write-Host '        Event log entries cannot be selectively cleared.' -ForegroundColor Yellow
        Write-Host '        Full log clearing requires administrator privileges.' -ForegroundColor Yellow
    } else {
        Write-Host '        No DeviceSetupManager events found.' -ForegroundColor DarkGray
    }
} catch {
    Write-Host '        Could not query event logs (may require admin).' -ForegroundColor Yellow
}

# ─── Generate cleanup report ────────────────────────────────────────────────
Write-Host ''
Write-Host '  ============================================================' -ForegroundColor Cyan
Write-Host '   Cleanup Report' -ForegroundColor Cyan
Write-Host '  ============================================================' -ForegroundColor Cyan
Write-Host ''

if ($script:Artifacts.Count -eq 0) {
    Write-Host '  No artifacts found. The target system appears clean.' -ForegroundColor Green
} else {
    foreach ($artifact in $script:Artifacts) {
        $sizeStr = if ($artifact.Size -gt 0) { "$($artifact.Size) bytes" } else { '-' }
        $color = switch -Wildcard ($artifact.Action) {
            'Securely deleted'      { 'Green' }
            'Directory removed'     { 'Green' }
            'Found (report only)'   { 'Cyan' }
            'Informational*'        { 'DarkGray' }
            'Found (requires*'      { 'Yellow' }
            'FAILED*'               { 'Red' }
            default                 { 'White' }
        }
        Write-Host "  [$($artifact.Category)]" -ForegroundColor $color -NoNewline
        Write-Host " $($artifact.Path)" -ForegroundColor White
        Write-Host "    Size: $sizeStr | Action: $($artifact.Action)" -ForegroundColor DarkGray
    }
}

Write-Host ''
Write-Host "  Total artifacts: $($script:Artifacts.Count)" -ForegroundColor White
Write-Host ''

# ─── Save report to USB drive ───────────────────────────────────────────────
try {
    if (-not (Test-Path -LiteralPath $script:ReportDir)) {
        New-Item -Path $script:ReportDir -ItemType Directory -Force | Out-Null
    }

    $timestamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
    $reportFile = Join-Path $script:ReportDir "cleanup-$timestamp.txt"

    $reportLines = [System.Collections.ArrayList]::new()
    [void]$reportLines.Add("DFIR Drive Updater - Forensic Cleanup Report")
    [void]$reportLines.Add("Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    [void]$reportLines.Add("Computer : $env:COMPUTERNAME")
    [void]$reportLines.Add("User     : $env:USERNAME")
    [void]$reportLines.Add("Mode     : $(if ($ReportOnly) { 'Report Only' } else { 'Cleanup' })")
    [void]$reportLines.Add("=" * 60)
    [void]$reportLines.Add("")

    if ($script:Artifacts.Count -eq 0) {
        [void]$reportLines.Add("No artifacts found. Target system appears clean.")
    } else {
        foreach ($artifact in $script:Artifacts) {
            $sizeStr = if ($artifact.Size -gt 0) { "$($artifact.Size) bytes" } else { '-' }
            [void]$reportLines.Add("[$($artifact.Category)] $($artifact.Path)")
            [void]$reportLines.Add("  Size: $sizeStr | Action: $($artifact.Action)")
            [void]$reportLines.Add("")
        }
    }

    [void]$reportLines.Add("")
    [void]$reportLines.Add("Total artifacts: $($script:Artifacts.Count)")

    $reportLines | Out-File -FilePath $reportFile -Encoding UTF8

    Write-Host "  Report saved: $reportFile" -ForegroundColor Green
} catch {
    Write-Warning "  Could not save report: $($_.Exception.Message)"
}

Write-Host ''
