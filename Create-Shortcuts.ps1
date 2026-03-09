#Requires -Version 5.1
<#
.SYNOPSIS
    Creates shortcuts in D:\Shortcuts for all DFIR tools on the drive.
.DESCRIPTION
    Scans the drive for known tool executables and creates .lnk shortcuts
    in the Shortcuts folder. Skips PortableApps (managed by its own launcher).
    Safe to run multiple times — existing shortcuts are overwritten.
#>

$DriveRoot = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path $DriveRoot)) { $DriveRoot = 'D:\' }

$ShortcutDir = Join-Path $DriveRoot 'Shortcuts'
if (-not (Test-Path $ShortcutDir)) {
    New-Item -ItemType Directory -Path $ShortcutDir -Force | Out-Null
}

$WshShell = New-Object -ComObject WScript.Shell

function New-Shortcut {
    param(
        [string]$Name,
        [string]$TargetPath,
        [string]$Arguments = '',
        [string]$WorkingDir = '',
        [string]$IconPath = ''
    )

    $fullTarget = Join-Path $DriveRoot $TargetPath
    if (-not (Test-Path -LiteralPath $fullTarget)) {
        Write-Host "  SKIP: $Name (not found: $TargetPath)" -ForegroundColor Yellow
        return
    }

    $lnkPath = Join-Path $ShortcutDir "$Name.lnk"
    $shortcut = $WshShell.CreateShortcut($lnkPath)
    $shortcut.TargetPath = $fullTarget
    if ($Arguments) { $shortcut.Arguments = $Arguments }
    if ($WorkingDir) {
        $shortcut.WorkingDirectory = Join-Path $DriveRoot $WorkingDir
    } else {
        $shortcut.WorkingDirectory = Split-Path $fullTarget -Parent
    }
    if ($IconPath) {
        $shortcut.IconLocation = Join-Path $DriveRoot $IconPath
    }
    $shortcut.Save()
    Write-Host "  OK:   $Name" -ForegroundColor Green
}

Write-Host "`nCreating DFIR tool shortcuts in: $ShortcutDir`n" -ForegroundColor Cyan

# ── 01_Acquisition ──
Write-Host "Acquisition Tools:" -ForegroundColor White
New-Shortcut -Name 'Arsenal Image Mounter'    -TargetPath '01_Acquisition\Arsenal-Image-Mounter-v3.12.331\ArsenalImageMounter.exe'
New-Shortcut -Name 'Encrypted Disk Detector'  -TargetPath '01_Acquisition\EncryptedDiskDetector\EDDv310.exe'
New-Shortcut -Name 'Encrypted Disk Hunter'    -TargetPath '01_Acquisition\EncryptedDiskHunter_v1.10.exe'
New-Shortcut -Name 'FTK Imager'               -TargetPath '01_Acquisition\FTK Imager\FTK Imager.exe'
New-Shortcut -Name 'KAPE (GUI)'               -TargetPath '01_Acquisition\KAPE\kape\KAPE\gkape.exe'
New-Shortcut -Name 'KAPE (CLI)'               -TargetPath '01_Acquisition\KAPE\kape\KAPE\kape.exe'
New-Shortcut -Name 'Magnet RAM Capture'        -TargetPath '01_Acquisition\MagnetRAMCapture_v120.exe'
New-Shortcut -Name 'HP USB Disk Format Tool'   -TargetPath '01_Acquisition\HPUSBDisk.exe'

# ── 02_Analysis ──
Write-Host "`nAnalysis Tools:" -ForegroundColor White
New-Shortcut -Name 'ExifTool'                 -TargetPath '02_Analysis\exiftool-13.28_64\exiftool(-k).exe'
New-Shortcut -Name 'hashcat'                  -TargetPath '02_Analysis\hashcat-6.2.6\hashcat.exe'
New-Shortcut -Name 'HashMyFiles'              -TargetPath '02_Analysis\HashMyFiles\HashMyFiles.exe'
New-Shortcut -Name 'Hash Value Tool'          -TargetPath '02_Analysis\HashValueTool.exe'
New-Shortcut -Name 'PhotoRec (GUI)'           -TargetPath '02_Analysis\PhotoREC\qphotorec_win.exe'
New-Shortcut -Name 'PhotoRec (CLI)'           -TargetPath '02_Analysis\PhotoREC\photorec_win.exe'
New-Shortcut -Name 'TestDisk'                 -TargetPath '02_Analysis\PhotoREC\testdisk_win.exe'
New-Shortcut -Name 'TimeApp'                  -TargetPath '02_Analysis\TimeApp.exe'
New-Shortcut -Name 'Timeline Explorer'        -TargetPath '02_Analysis\TimelineExplorer\TimelineExplorer.exe'

# ── 03_Network ──
Write-Host "`nNetwork Tools:" -ForegroundColor White
New-Shortcut -Name 'NetworkDiagnosticTool'    -TargetPath '03_Network\NetworkDiagnosticTool-GUI 1.0.0.145.exe'
New-Shortcut -Name 'NetworkMiner'             -TargetPath '03_Network\NetworkMiner_3-1\NetworkMiner.exe'
New-Shortcut -Name 'Nmap'                     -TargetPath '03_Network\nMAP\nmap.exe'
New-Shortcut -Name 'Zenmap (Nmap GUI)'        -TargetPath '03_Network\nMAP\Zenmap.bat' -IconPath '03_Network\nMAP\icon1.ico'

# ── 04_Mobile-Forensics ──
Write-Host "`nMobile Forensics Tools:" -ForegroundColor White
New-Shortcut -Name 'Cellebrite WRAT'          -TargetPath '04_Mobile-Forensics\WarrantReturnAutomationTool_1.1.7\CellebriteWarrantReturnAutomationTool.exe'

# ── 08_Utilities ──
Write-Host "`nUtilities:" -ForegroundColor White
New-Shortcut -Name 'UniGetUI'                 -TargetPath '08_Utilities\UniGetUI\UniGetUI.exe'

# ── DFIR Updater ──
Write-Host "`nDFIR Updater:" -ForegroundColor White
New-Shortcut -Name 'DFIR Drive Updater'       -TargetPath 'DFIR-Updater\Launch-Updater.bat' -IconPath 'DFIR-Updater\modules\Update-Checker.ps1'

Write-Host "`nDone! Shortcuts created in: $ShortcutDir" -ForegroundColor Cyan
Write-Host "Note: PortableApps are managed by the PortableApps.com launcher (D:\Start.exe)`n" -ForegroundColor Gray
