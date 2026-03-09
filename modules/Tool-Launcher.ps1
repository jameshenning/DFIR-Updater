#Requires -Version 5.1
<#
.SYNOPSIS
    Tool Launcher module - scans the DFIR drive for launchable tools.
.DESCRIPTION
    Provides Get-LaunchableTools which scans category folders, PortableApps,
    and standalone executables to build a list of tools that can be launched
    from the GUI. Read-only operation - safe for Forensic Mode.
#>

Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Well-known tool definitions (primary exe per directory)
# Maps relative path prefix -> array of {Name, ExeRelPath}
# ---------------------------------------------------------------------------
$script:KnownTools = @(
    @{ Name = 'Arsenal Image Mounter';    Path = '01_Acquisition/Arsenal-Image-Mounter'; Exe = 'ArsenalImageMounter.exe' }
    @{ Name = 'Encrypted Disk Detector';  Path = '01_Acquisition/EncryptedDiskDetector';  Exe = 'EDDv310.exe' }
    @{ Name = 'FTK Imager';              Path = '01_Acquisition/FTK Imager';             Exe = 'FTK Imager.exe' }
    @{ Name = 'KAPE (GUI)';              Path = '01_Acquisition/KAPE';                   Exe = 'kape/KAPE/gkape.exe' }
    @{ Name = 'KAPE (CLI)';              Path = '01_Acquisition/KAPE';                   Exe = 'kape/KAPE/kape.exe' }
    @{ Name = 'ExifTool';                Path = '02_Analysis/exiftool';                  Exe = 'exiftool(-k).exe' }
    @{ Name = 'hashcat';                 Path = '02_Analysis/hashcat';                   Exe = 'hashcat.exe' }
    @{ Name = 'HashMyFiles';             Path = '02_Analysis/HashMyFiles';               Exe = 'HashMyFiles.exe' }
    @{ Name = 'PhotoRec (GUI)';          Path = '02_Analysis/PhotoREC';                  Exe = 'qphotorec_win.exe' }
    @{ Name = 'PhotoRec (CLI)';          Path = '02_Analysis/PhotoREC';                  Exe = 'photorec_win.exe' }
    @{ Name = 'TestDisk';                Path = '02_Analysis/PhotoREC';                  Exe = 'testdisk_win.exe' }
    @{ Name = 'Timeline Explorer';       Path = '02_Analysis/TimelineExplorer';          Exe = 'TimelineExplorer.exe' }
    @{ Name = 'NetworkMiner';            Path = '03_Network/NetworkMiner';               Exe = 'NetworkMiner.exe' }
    @{ Name = 'Nmap';                    Path = '03_Network/nMAP';                       Exe = 'nmap.exe' }
    @{ Name = 'Zenmap (Nmap GUI)';       Path = '03_Network/nMAP';                       Exe = 'Zenmap.bat' }
    @{ Name = 'Network Diagnostic Tool'; Path = '03_Network';                            Exe = 'NetworkDiagnosticTool-GUI 1.0.0.145.exe' }
    @{ Name = 'Cellebrite WRAT';         Path = '04_Mobile-Forensics/WarrantReturnAutomationTool'; Exe = 'CellebriteWarrantReturnAutomationTool.exe' }
    @{ Name = 'UniGetUI';                Path = '08_Utilities/UniGetUI';                 Exe = 'UniGetUI.exe' }
    @{ Name = 'Encrypted Disk Hunter';   Path = '01_Acquisition';                        Exe = 'EncryptedDiskHunter_v1.10.exe' }
    @{ Name = 'Magnet RAM Capture';      Path = '01_Acquisition';                        Exe = 'MagnetRAMCapture_v120.exe' }
    @{ Name = 'HP USB Disk Format Tool'; Path = '01_Acquisition';                        Exe = 'HPUSBDisk.exe' }
    @{ Name = 'Hash Value Tool';         Path = '02_Analysis';                           Exe = 'HashValueTool.exe' }
    @{ Name = 'TimeApp';                 Path = '02_Analysis';                           Exe = 'TimeApp.exe' }
)

# ---------------------------------------------------------------------------
# PortableApps appinfo.ini parser
# ---------------------------------------------------------------------------
function Get-PortableAppInfo {
    param([string]$AppDir)
    $iniPath = Join-Path $AppDir 'App\AppInfo\appinfo.ini'
    if (-not (Test-Path -LiteralPath $iniPath)) { return $null }

    $info = @{ Name = ''; Exe = ''; Icon = '' }
    try {
        $lines = Get-Content -LiteralPath $iniPath -ErrorAction Stop
        foreach ($line in $lines) {
            if ($line -match '^\s*Name\s*=\s*(.+)$') {
                $info.Name = $Matches[1].Trim()
            }
            elseif ($line -match '^\s*AppID\s*=\s*(.+)$' -and -not $info.Name) {
                $info.Name = $Matches[1].Trim()
            }
        }
    } catch { return $null }

    # Find the main executable
    $exePattern = Join-Path $AppDir '*.exe'
    $topExes = @(Get-ChildItem -Path $exePattern -File -ErrorAction SilentlyContinue)
    if ($topExes.Count -gt 0) {
        $folderName = Split-Path $AppDir -Leaf
        $match = $topExes | Where-Object { $_.BaseName -eq $folderName } | Select-Object -First 1
        if (-not $match) { $match = $topExes[0] }
        $info.Exe = $match.FullName
    } else {
        $appSubExes = @(Get-ChildItem -Path (Join-Path $AppDir 'App') -Filter '*.exe' -Recurse -Depth 2 -File -ErrorAction SilentlyContinue)
        if ($appSubExes.Count -gt 0) {
            $info.Exe = $appSubExes[0].FullName
        }
    }

    if (-not $info.Exe) { return $null }

    # Look for icon
    $iconPng = Join-Path $AppDir 'App\AppInfo\appicon_32.png'
    if (Test-Path -LiteralPath $iconPng) {
        $info.Icon = $iconPng
    }

    if (-not $info.Name) {
        $info.Name = (Split-Path $AppDir -Leaf) -replace 'Portable$', ''
    }

    return $info
}

# ---------------------------------------------------------------------------
# Main scanning function
# ---------------------------------------------------------------------------
function Get-LaunchableTools {
    <#
    .SYNOPSIS
        Scans the DFIR drive for all launchable tools.
    .PARAMETER DriveRoot
        Root path of the DFIR drive (e.g. D:\).
    .OUTPUTS
        Array of PSCustomObjects with: Name, ExePath, IconPath, Category, Source
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DriveRoot
    )

    $tools = [System.Collections.Generic.List[PSCustomObject]]::new()
    $seenExes = @{}  # Dedup by full exe path (lowercased)

    # Category prefix -> display name
    $categoryMap = @{
        '01_Acquisition'     = 'Acquisition'
        '02_Analysis'        = 'Analysis'
        '03_Network'         = 'Network'
        '04_Mobile-Forensics'= 'Mobile'
        '05_Case-Files'      = $null
        '06_Training'        = $null
        '07_Documentation'   = $null
        '08_Utilities'       = 'Utilities'
    }

    # ── 1. Add well-known tools first (preferred names and exes) ──
    $knownDirs = @{}  # Track directories claimed by known tools
    foreach ($kt in $script:KnownTools) {
        # Find matching directory (prefix match to handle versioned folder names)
        $pathPrefix = $kt.Path -replace '/', '\'
        $parentDir = Join-Path $DriveRoot (Split-Path $pathPrefix -Parent)
        $dirLeaf = Split-Path $pathPrefix -Leaf

        # Try exact match first, then prefix match for versioned dirs
        $matchDir = $null
        $testExact = Join-Path $DriveRoot $pathPrefix
        if (Test-Path -LiteralPath $testExact -PathType Container) {
            $matchDir = $testExact
        } elseif (Test-Path -LiteralPath $parentDir -PathType Container) {
            $candidates = @(Get-ChildItem -Path $parentDir -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like "$dirLeaf*" })
            if ($candidates.Count -gt 0) {
                $matchDir = $candidates[0].FullName
            }
        }

        # For direct files in category folder (no subdirectory)
        if (-not $matchDir -and (Test-Path -LiteralPath $parentDir -PathType Container)) {
            $exeTest = Join-Path $parentDir $kt.Exe
            if (Test-Path -LiteralPath $exeTest) {
                $matchDir = $parentDir
            }
        }

        if (-not $matchDir) { continue }

        $exePath = Join-Path $matchDir $kt.Exe
        if (-not (Test-Path -LiteralPath $exePath)) { continue }

        $key = $exePath.ToLower()
        if ($seenExes.ContainsKey($key)) { continue }
        $seenExes[$key] = $true
        $knownDirs[$matchDir.ToLower()] = $true

        # Determine category from path
        $relPath = $exePath.Substring($DriveRoot.Length).TrimStart('\/')
        $firstSeg = ($relPath -split '[/\\]')[0]
        $cat = if ($categoryMap.ContainsKey($firstSeg)) { $categoryMap[$firstSeg] } else { 'Other' }

        $tools.Add([PSCustomObject]@{
            Name     = $kt.Name
            ExePath  = $exePath
            IconPath = ''
            Category = $cat
            Source   = 'KnownTool'
        })
    }

    # ── 2. Scan category folders for unknown tools ──
    foreach ($prefix in $categoryMap.Keys) {
        $category = $categoryMap[$prefix]
        if (-not $category) { continue }

        $catDir = Join-Path $DriveRoot $prefix
        if (-not (Test-Path -LiteralPath $catDir -PathType Container)) { continue }

        # Direct exe files in category root
        $directExes = @(Get-ChildItem -Path $catDir -Filter '*.exe' -File -ErrorAction SilentlyContinue)
        foreach ($exe in $directExes) {
            $key = $exe.FullName.ToLower()
            if ($seenExes.ContainsKey($key)) { continue }
            $seenExes[$key] = $true

            $name = $exe.BaseName -replace '_v?\d+[\d.]*$', '' -replace '_', ' '
            $tools.Add([PSCustomObject]@{
                Name     = $name
                ExePath  = $exe.FullName
                IconPath = ''
                Category = $category
                Source   = 'CategoryDirect'
            })
        }

        # Subdirectories - only scan dirs NOT already claimed by known tools
        $subDirs = @(Get-ChildItem -Path $catDir -Directory -ErrorAction SilentlyContinue)
        foreach ($subDir in $subDirs) {
            if ($knownDirs.ContainsKey($subDir.FullName.ToLower())) { continue }

            # For unknown subdirectories, pick only the primary exe
            # Heuristic: prefer exe matching folder name, else largest exe
            $subExes = @(Get-ChildItem -Path $subDir.FullName -Filter '*.exe' -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notmatch '^(unins|setup|install|update|7z|readme|changelog|license)' })

            if ($subExes.Count -eq 0) {
                # Check one level deeper
                $subExes = @(Get-ChildItem -Path $subDir.FullName -Filter '*.exe' -Recurse -Depth 2 -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -notmatch '^(unins|setup|install|update|7z|readme|changelog|license)' })
            }

            if ($subExes.Count -eq 0) { continue }

            # Pick the best primary exe
            $folderName = $subDir.Name -replace '[-_]v?\d+[\d.]*$', ''
            $primaryExe = $subExes | Where-Object { $_.BaseName -like "$folderName*" } | Select-Object -First 1
            if (-not $primaryExe) {
                $primaryExe = $subExes | Sort-Object Length -Descending | Select-Object -First 1
            }

            $key = $primaryExe.FullName.ToLower()
            if ($seenExes.ContainsKey($key)) { continue }
            $seenExes[$key] = $true

            $name = $subDir.Name -replace '[-_]v?\d+[\d.]*$', '' -replace '[_-]', ' '
            $tools.Add([PSCustomObject]@{
                Name     = $name
                ExePath  = $primaryExe.FullName
                IconPath = ''
                Category = $category
                Source   = 'CategorySub'
            })
        }
    }

    # ── 3. Scan PortableApps folder ──
    $paDir = Join-Path $DriveRoot 'PortableApps'
    if (Test-Path -LiteralPath $paDir -PathType Container) {
        $paDirs = @(Get-ChildItem -Path $paDir -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne 'CommonFiles' -and $_.Name -ne 'PortableApps.com' })

        foreach ($paAppDir in $paDirs) {
            $appInfo = Get-PortableAppInfo -AppDir $paAppDir.FullName
            if ($appInfo -and $appInfo.Exe) {
                $key = $appInfo.Exe.ToLower()
                if ($seenExes.ContainsKey($key)) { continue }
                $seenExes[$key] = $true

                $name = if ($appInfo.Name) { $appInfo.Name } else { ($paAppDir.Name -replace 'Portable$', '') }

                $tools.Add([PSCustomObject]@{
                    Name     = $name
                    ExePath  = $appInfo.Exe
                    IconPath = $appInfo.Icon
                    Category = 'PortableApps'
                    Source   = 'PortableApps'
                })
            } else {
                # Fallback: look for any exe in the folder root
                $fallbackExe = Get-ChildItem -Path $paAppDir.FullName -Filter '*.exe' -File -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($fallbackExe) {
                    $key = $fallbackExe.FullName.ToLower()
                    if ($seenExes.ContainsKey($key)) { continue }
                    $seenExes[$key] = $true

                    $tools.Add([PSCustomObject]@{
                        Name     = ($paAppDir.Name -replace 'Portable$', '')
                        ExePath  = $fallbackExe.FullName
                        IconPath = ''
                        Category = 'PortableApps'
                        Source   = 'PortableApps'
                    })
                }
            }
        }
    }

    # ── 4. Add Start.exe (PortableApps launcher) if present ──
    $startExe = Join-Path $DriveRoot 'Start.exe'
    if (Test-Path -LiteralPath $startExe) {
        $key = $startExe.ToLower()
        if (-not $seenExes.ContainsKey($key)) {
            $seenExes[$key] = $true
            $tools.Add([PSCustomObject]@{
                Name     = 'PortableApps Platform'
                ExePath  = $startExe
                IconPath = ''
                Category = 'Utilities'
                Source   = 'DriveRoot'
            })
        }
    }

    # Sort by category, then name
    $sorted = @($tools | Sort-Object Category, Name)
    return $sorted
}
