#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Toggles disk-level write protection on the DFIR USB drive.

.DESCRIPTION
    Uses Windows disk management to set or clear the readonly attribute on the
    USB drive. When enabled, the target computer's OS will treat the drive as
    read-only, preventing any writes.

    The script tries PowerShell Storage cmdlets first (Get-Disk / Set-Disk),
    then falls back to diskpart if the cmdlets are unavailable.

    IMPORTANT: This is a SOFTWARE-LEVEL disk attribute. It is NOT equivalent
    to a hardware write blocker for court-admissible evidence handling. Modern
    Windows generally honors the readonly attribute, but it is not enforced at
    the hardware/firmware level.

    Run this script from YOUR workstation BEFORE connecting to a target computer.

.PARAMETER DriveLetter
    The drive letter of the DFIR USB drive (without colon). If omitted, the
    script detects it from its own location.

.PARAMETER Status
    Check and display current write protection status without changing it.

.EXAMPLE
    .\Write-Protect.ps1
    Toggle write protection on/off.

.EXAMPLE
    .\Write-Protect.ps1 -Status
    Check current write protection status.

.EXAMPLE
    .\Write-Protect.ps1 -DriveLetter E
    Toggle write protection on drive E:.
#>

[CmdletBinding()]
param(
    [string]$DriveLetter,
    [switch]$Status
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ─── Resolve drive ─────────────────────────────────────────────────────────
if (-not $DriveLetter) {
    $scriptDir = $PSScriptRoot
    if (-not $scriptDir) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition }
    $DriveLetter = (Split-Path -Qualifier $scriptDir).TrimEnd(':')
}
$DriveLetter = $DriveLetter.TrimEnd(':').ToUpper()

# ─── Log directory (on the USB drive) ──────────────────────────────────────
$updaterDir = "${DriveLetter}:\DFIR-Updater"
$logDir = Join-Path $updaterDir 'write-protect-logs'

# ─── Display header ────────────────────────────────────────────────────────
Write-Host ''
Write-Host '  ============================================================' -ForegroundColor Cyan
Write-Host '   DFIR Drive - Write Protection Toggle' -ForegroundColor Cyan
Write-Host '  ============================================================' -ForegroundColor Cyan
Write-Host ''
Write-Host '  NOTE: This sets a software-level disk readonly attribute.' -ForegroundColor Yellow
Write-Host '  Modern Windows honors this, but it is NOT equivalent to a' -ForegroundColor Yellow
Write-Host '  hardware write blocker for court-admissible evidence.' -ForegroundColor Yellow
Write-Host ''

# ─── Disk discovery and management helpers ─────────────────────────────────
$script:UseCmdlets = $false
$script:DiskNum = $null
$script:DiskName = 'Unknown'
$script:DiskSize = 0
$script:IsReadOnly = $null

function Find-DiskInfo {
    # Tier 1: Try PowerShell Storage cmdlets
    try {
        $partition = Get-Partition -DriveLetter $DriveLetter -ErrorAction Stop
        $disk = Get-Disk -Number $partition.DiskNumber -ErrorAction Stop
        $script:DiskNum = $disk.Number
        $script:DiskName = $disk.FriendlyName
        $script:DiskSize = [math]::Round($disk.Size / 1GB, 1)
        $script:IsReadOnly = $disk.IsReadOnly
        $script:UseCmdlets = $true
        Write-Verbose 'Using Storage cmdlets (Get-Disk / Set-Disk).'
        return $true
    } catch {
        Write-Verbose "Storage cmdlets failed: $($_.Exception.Message)"
    }

    # Tier 2: WMI for disk discovery + diskpart for readonly status
    try {
        $wmiPartitions = Get-WmiObject -Query "ASSOCIATORS OF {Win32_LogicalDisk.DeviceID='${DriveLetter}:'} WHERE AssocClass=Win32_LogicalDiskToPartition" -ErrorAction Stop
        foreach ($wmiPart in $wmiPartitions) {
            $wmiDisks = Get-WmiObject -Query "ASSOCIATORS OF {Win32_DiskPartition.DeviceID='$($wmiPart.DeviceID)'} WHERE AssocClass=Win32_DiskDriveToDiskPartition" -ErrorAction Stop
            foreach ($wmiDisk in $wmiDisks) {
                $script:DiskNum = $wmiDisk.Index
                $script:DiskName = $wmiDisk.Caption
                $script:DiskSize = [math]::Round($wmiDisk.Size / 1GB, 1)
                break
            }
            if ($null -ne $script:DiskNum) { break }
        }
    } catch {
        Write-Verbose "WMI discovery failed: $($_.Exception.Message)"
    }

    if ($null -eq $script:DiskNum) {
        return $false
    }

    # Get readonly status via diskpart
    $script:IsReadOnly = Get-DiskpartReadonly -DiskNumber $script:DiskNum
    $script:UseCmdlets = $false
    Write-Verbose 'Using WMI + diskpart fallback.'
    return $true
}

function Get-DiskpartReadonly {
    param([int]$DiskNumber)
    $dpScript = Join-Path $env:TEMP 'dfir-wp-check.txt'
    try {
        @("select disk $DiskNumber", 'attributes disk') | Set-Content -Path $dpScript -Encoding ASCII
        $output = & diskpart /s $dpScript 2>&1
        Remove-Item -LiteralPath $dpScript -Force -ErrorAction SilentlyContinue
        # Parse: "Current Read-only State : Yes" or "Current Read-only State : No"
        foreach ($line in $output) {
            if ($line -match 'Current Read-only State\s*:\s*(Yes|No)') {
                return ($Matches[1] -eq 'Yes')
            }
        }
    } catch {
        Write-Verbose "diskpart check failed: $($_.Exception.Message)"
    }
    return $null
}

function Set-DiskReadonlyDiskpart {
    param([int]$DiskNumber, [bool]$ReadOnly)
    $dpScript = Join-Path $env:TEMP 'dfir-wp-set.txt'
    $action = if ($ReadOnly) { 'attributes disk set readonly' } else { 'attributes disk clear readonly' }
    @("select disk $DiskNumber", $action) | Set-Content -Path $dpScript -Encoding ASCII
    $output = & diskpart /s $dpScript 2>&1
    Remove-Item -LiteralPath $dpScript -Force -ErrorAction SilentlyContinue
    # Check for success message
    $success = $false
    foreach ($line in $output) {
        if ($line -match 'successfully') { $success = $true; break }
    }
    return $success
}

# ─── Find disk ─────────────────────────────────────────────────────────────
$found = Find-DiskInfo
if (-not $found -or $null -eq $script:DiskNum) {
    Write-Host "  ERROR: Could not find disk for drive ${DriveLetter}:" -ForegroundColor Red
    Write-Host '  Make sure the drive is connected and try again.' -ForegroundColor Red
    Write-Host ''
    Read-Host '  Press Enter to exit'
    exit 1
}

if ($null -eq $script:IsReadOnly) {
    Write-Host '  ERROR: Could not determine current write protection status.' -ForegroundColor Red
    Write-Host ''
    Read-Host '  Press Enter to exit'
    exit 1
}

Write-Host "  Drive : ${DriveLetter}:" -ForegroundColor White
Write-Host "  Disk  : #$($script:DiskNum) - $($script:DiskName) ($($script:DiskSize) GB)" -ForegroundColor White
$methodStr = if ($script:UseCmdlets) { 'Storage cmdlets' } else { 'diskpart' }
Write-Host "  Method: $methodStr" -ForegroundColor DarkGray

if ($script:IsReadOnly) {
    Write-Host '  Status: WRITE-PROTECTED (Read-Only)' -ForegroundColor Green
} else {
    Write-Host '  Status: WRITABLE (Read-Write)' -ForegroundColor Yellow
}
Write-Host ''

# ─── Status-only mode ─────────────────────────────────────────────────────
if ($Status) {
    Read-Host '  Press Enter to exit'
    exit 0
}

# ─── Log helper ────────────────────────────────────────────────────────────
function Write-ProtectLog {
    param([string]$Action, [string]$Result)
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $entry = "[$timestamp] Computer: $env:COMPUTERNAME | User: $env:USERNAME | Disk: #$($script:DiskNum) $($script:DiskName) | $Action | $Result"
    try {
        if (-not (Test-Path -LiteralPath $logDir)) {
            New-Item -Path $logDir -ItemType Directory -Force | Out-Null
        }
        $logFile = Join-Path $logDir 'write-protect.log'
        Add-Content -LiteralPath $logFile -Value $entry -ErrorAction Stop
        Write-Host "  Log saved: $logFile" -ForegroundColor DarkGray
    } catch {
        Write-Host "  Could not save log (drive may be read-only)." -ForegroundColor DarkGray
    }
    Write-Host "  $entry" -ForegroundColor DarkGray
}

# ─── Toggle ────────────────────────────────────────────────────────────────
if ($script:IsReadOnly) {
    # ── Currently read-only -> make writable ──────────────────────────────
    Write-Host '  Clearing write protection...' -ForegroundColor White
    $success = $false
    if ($script:UseCmdlets) {
        try {
            Set-Disk -Number $script:DiskNum -IsReadOnly $false -ErrorAction Stop
            $success = $true
        } catch {
            Write-Host "  Set-Disk failed: $($_.Exception.Message)" -ForegroundColor Yellow
            Write-Host '  Falling back to diskpart...' -ForegroundColor Yellow
            $success = Set-DiskReadonlyDiskpart -DiskNumber $script:DiskNum -ReadOnly $false
        }
    } else {
        $success = Set-DiskReadonlyDiskpart -DiskNumber $script:DiskNum -ReadOnly $false
    }

    if ($success) {
        # Verify
        $verifyReadOnly = if ($script:UseCmdlets) {
            (Get-Disk -Number $script:DiskNum).IsReadOnly
        } else {
            Get-DiskpartReadonly -DiskNumber $script:DiskNum
        }

        Write-Host ''
        if ($verifyReadOnly -eq $false) {
            Write-Host '  [OFF] Write Protection: OFF - Drive is now WRITABLE.' -ForegroundColor Yellow
            Write-Host '        You can now run the updater and write to this drive.' -ForegroundColor DarkGray
            Write-Host ''
            Write-ProtectLog -Action 'Write-Protect OFF' -Result 'Verified'
        } else {
            Write-Host '  WARNING: Verification failed. The drive may still be read-only.' -ForegroundColor Red
            Write-Host '  Try ejecting and reinserting the drive.' -ForegroundColor Red
            Write-Host ''
            Write-ProtectLog -Action 'Write-Protect OFF' -Result 'VERIFICATION FAILED'
        }
    } else {
        Write-Host ''
        Write-Host '  ERROR: Failed to clear write protection.' -ForegroundColor Red
        Write-Host '  The drive may not support software write protection toggling.' -ForegroundColor Red
    }
} else {
    # ── Currently writable -> make read-only ──────────────────────────────
    # Write log BEFORE setting readonly (drive is still writable)
    Write-ProtectLog -Action 'Write-Protect ON' -Result 'Setting...'

    Write-Host ''
    Write-Host '  Setting write protection...' -ForegroundColor White
    $success = $false
    if ($script:UseCmdlets) {
        try {
            Set-Disk -Number $script:DiskNum -IsReadOnly $true -ErrorAction Stop
            $success = $true
        } catch {
            Write-Host "  Set-Disk failed: $($_.Exception.Message)" -ForegroundColor Yellow
            Write-Host '  Falling back to diskpart...' -ForegroundColor Yellow
            $success = Set-DiskReadonlyDiskpart -DiskNumber $script:DiskNum -ReadOnly $true
        }
    } else {
        $success = Set-DiskReadonlyDiskpart -DiskNumber $script:DiskNum -ReadOnly $true
    }

    if ($success) {
        # Verify
        $verifyReadOnly = if ($script:UseCmdlets) {
            (Get-Disk -Number $script:DiskNum).IsReadOnly
        } else {
            Get-DiskpartReadonly -DiskNumber $script:DiskNum
        }

        Write-Host ''
        if ($verifyReadOnly -eq $true) {
            Write-Host '  [ON]  Write Protection: ON - Drive is now READ-ONLY.' -ForegroundColor Green
            Write-Host '        The target computer cannot write to this drive.' -ForegroundColor DarkGray
        } else {
            Write-Host ''
            Write-Host '  WARNING: Verification failed. The drive may still be writable.' -ForegroundColor Red
            Write-Host '  Some USB controllers do not support software readonly.' -ForegroundColor Red
        }
    } else {
        Write-Host ''
        Write-Host '  ERROR: Failed to set write protection.' -ForegroundColor Red
        Write-Host '  The drive may not support software write protection toggling.' -ForegroundColor Red
    }
}

Write-Host ''
Read-Host '  Press Enter to exit'
