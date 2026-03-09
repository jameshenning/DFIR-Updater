#Requires -Version 5.1
<#
.SYNOPSIS
    Sets up (or removes) automatic launching of the DFIR Drive Updater when the
    USB drive is plugged in.

.DESCRIPTION
    Creates a Windows Task Scheduler task that triggers on USB device connection
    events (Event ID 112 from DeviceSetupManager). When triggered, the task
    searches for the DFIR drive by volume label and launches the updater GUI.

    The task runs under the current user's context and does not require
    administrative privileges.

.PARAMETER Remove
    Unregisters the scheduled task instead of creating it.

.PARAMETER Check
    Reports whether the scheduled task is registered. Returns $true/$false.

.EXAMPLE
    .\Setup-AutoLaunch.ps1
    Creates the DFIR-Drive-Updater scheduled task.

.EXAMPLE
    .\Setup-AutoLaunch.ps1 -Check
    Returns $true if the task exists, $false otherwise.

.EXAMPLE
    .\Setup-AutoLaunch.ps1 -Remove
    Removes the DFIR-Drive-Updater scheduled task.
#>

[CmdletBinding()]
param(
    [switch]$Remove,
    [switch]$Check
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$TaskName = 'DFIR-Drive-Updater'
$TaskDescription = 'Automatically launches the DFIR Drive Updater GUI when a USB storage device is connected.'

# ---------------------------------------------------------------------------
# Dynamic path resolution (never hardcode drive letter)
# ---------------------------------------------------------------------------
$script:SetupScriptDir = $PSScriptRoot
if (-not $script:SetupScriptDir) { $script:SetupScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition }
$script:SetupDriveRoot = Split-Path -Parent $script:SetupScriptDir

# ---------------------------------------------------------------------------
# Check mode: report whether the task is registered and exit
# ---------------------------------------------------------------------------
if ($Check) {
    $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($null -ne $existing) {
        Write-Host "[OK] Scheduled task '$TaskName' is registered." -ForegroundColor Green
        return $true
    } else {
        Write-Host "[--] Scheduled task '$TaskName' is NOT registered." -ForegroundColor Yellow
        return $false
    }
}

# ---------------------------------------------------------------------------
# Remove mode
# ---------------------------------------------------------------------------
if ($Remove) {
    $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($null -eq $existing) {
        Write-Host "[!] Scheduled task '$TaskName' does not exist. Nothing to remove." -ForegroundColor Yellow
    } else {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "[+] Scheduled task '$TaskName' has been removed." -ForegroundColor Green
    }
    return
}

# ---------------------------------------------------------------------------
# Build the action command
# ---------------------------------------------------------------------------
# The drive letter may change between USB insertions, so the action scans all
# volumes for the DFIR label and then verifies the updater script exists.
$ActionCommand = @'
Get-Volume | Where-Object { $_.FileSystemLabel -eq 'DFIR' } | ForEach-Object {
    $drive = $_.DriveLetter + ':\'
    $forensicFlag = Join-Path $drive 'FORENSIC_MODE'
    if (Test-Path $forensicFlag) {
        # Forensic mode active: re-enforce write protection silently, skip GUI
        try {
            $p = Get-Partition -DriveLetter $_.DriveLetter -ErrorAction Stop
            Set-Disk -Number $p.DiskNumber -IsReadOnly $true -ErrorAction SilentlyContinue
        } catch { }
        return
    }
    $script = Join-Path $drive 'DFIR-Updater\DFIR-Updater-GUI.ps1'
    if (Test-Path $script) { & $script }
}
if (-not (Get-Variable -Name script -ErrorAction SilentlyContinue) -or -not (Test-Path $script -ErrorAction SilentlyContinue)) {
    # Fallback: search every drive for the DFIR-Updater folder
    Get-PSDrive -PSProvider FileSystem | ForEach-Object {
        $forensicFlag = Join-Path $_.Root 'FORENSIC_MODE'
        if (Test-Path $forensicFlag) {
            try {
                $dl = $_.Root.TrimEnd('\').TrimEnd(':')
                $p = Get-Partition -DriveLetter $dl -ErrorAction Stop
                Set-Disk -Number $p.DiskNumber -IsReadOnly $true -ErrorAction SilentlyContinue
            } catch { }
            return
        }
        $candidate = Join-Path $_.Root 'DFIR-Updater\DFIR-Updater-GUI.ps1'
        if (Test-Path $candidate) { & $candidate; break }
    }
}
'@

# Collapse to a single line for the task action argument
$ActionCommandOneLine = ($ActionCommand -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }) -join '; '

# ---------------------------------------------------------------------------
# Build the scheduled task components
# ---------------------------------------------------------------------------

# Trigger: USB device installation complete
# Log:      Microsoft-Windows-DeviceSetupManager/Admin
# Source:   DeviceSetupManager
# Event ID: 112
$triggerXml = @"
<QueryList>
  <Query Id="0" Path="Microsoft-Windows-DeviceSetupManager/Admin">
    <Select Path="Microsoft-Windows-DeviceSetupManager/Admin">
      *[System[Provider[@Name='DeviceSetupManager'] and EventID=112]]
    </Select>
  </Query>
</QueryList>
"@

$trigger = New-ScheduledTaskTrigger -AtLogOn  # placeholder; replaced by CIM below

$actionArgs = "-ExecutionPolicy Bypass -WindowStyle Hidden -Command `"$ActionCommandOneLine`""
$action  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $actionArgs

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 30)

$principal = New-ScheduledTaskPrincipal -UserId ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) `
    -LogonType Interactive `
    -RunLevel Limited

# ---------------------------------------------------------------------------
# Register the task
# ---------------------------------------------------------------------------
$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($null -ne $existing) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "[*] Existing task '$TaskName' removed; re-creating." -ForegroundColor Cyan
}

$task = Register-ScheduledTask `
    -TaskName $TaskName `
    -Description $TaskDescription `
    -Action $action `
    -Settings $settings `
    -Principal $principal `
    -Force

# Replace the placeholder trigger with the real event-based trigger via CIM.
# The ScheduledTask cmdlets do not natively expose event triggers, so we patch
# the task XML directly.
$taskXmlRaw = Export-ScheduledTask -TaskName $TaskName

# Parse and inject the EventTrigger
[xml]$taskXml = $taskXmlRaw
$ns = New-Object System.Xml.XmlNamespaceManager($taskXml.NameTable)
$ns.AddNamespace('t', 'http://schemas.microsoft.com/windows/2004/02/mit/task')

$triggersNode = $taskXml.SelectSingleNode('//t:Triggers', $ns)

# Remove any existing triggers (the placeholder AtLogOn)
$triggersNode.RemoveAll()

# Create the EventTrigger element
$eventTrigger = $taskXml.CreateElement('EventTrigger', 'http://schemas.microsoft.com/windows/2004/02/mit/task')

$enabledEl = $taskXml.CreateElement('Enabled', 'http://schemas.microsoft.com/windows/2004/02/mit/task')
$enabledEl.InnerText = 'true'
$eventTrigger.AppendChild($enabledEl) | Out-Null

# Add a short delay so the drive has time to be assigned a letter
$delayEl = $taskXml.CreateElement('Delay', 'http://schemas.microsoft.com/windows/2004/02/mit/task')
$delayEl.InnerText = 'PT10S'
$eventTrigger.AppendChild($delayEl) | Out-Null

$subscriptionEl = $taskXml.CreateElement('Subscription', 'http://schemas.microsoft.com/windows/2004/02/mit/task')
$subscriptionEl.InnerText = $triggerXml
$eventTrigger.AppendChild($subscriptionEl) | Out-Null

$triggersNode.AppendChild($eventTrigger) | Out-Null

# Re-register with the corrected XML
Register-ScheduledTask -TaskName $TaskName -Xml $taskXml.OuterXml -Force | Out-Null

# ---------------------------------------------------------------------------
# Confirmation
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '  [OK] Auto-Launch Configured Successfully' -ForegroundColor Green
Write-Host ''
Write-Host "  Task Name  : $TaskName" -ForegroundColor White
Write-Host "  Trigger    : USB device connected (Event ID 112)" -ForegroundColor White
Write-Host "  Delay      : 10 seconds (allows drive letter assignment)" -ForegroundColor White
Write-Host "  Drive Match: Volume label 'DFIR' (fallback: folder scan)" -ForegroundColor White
Write-Host "  User       : $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)" -ForegroundColor White
Write-Host "  Script Dir : $script:SetupScriptDir" -ForegroundColor White
Write-Host ''
Write-Host '  To check status : .\Setup-AutoLaunch.ps1 -Check' -ForegroundColor DarkGray
Write-Host '  To remove       : .\Setup-AutoLaunch.ps1 -Remove' -ForegroundColor DarkGray
Write-Host ''
