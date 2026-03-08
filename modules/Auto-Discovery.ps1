#Requires -Version 5.1
<#
.SYNOPSIS
    Auto-discovery module for the DFIR Drive Updater.

.DESCRIPTION
    Automatically detects new tools, programs, and documents added to the
    D:/ DFIR drive that are not already tracked in tools-config.json.
    Scans organized category folders up to 2 levels deep, extracts version
    information from filenames, matches against a known DFIR GitHub repo
    lookup table, and generates pre-filled config entries.

    Also maintains a scan manifest (scan-manifest.json) so that subsequent
    scans only flag truly new items.
#>

Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Constants / Paths
# ---------------------------------------------------------------------------
$script:UpdaterRoot   = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path $script:UpdaterRoot)) {
    $script:UpdaterRoot = 'D:\DFIR-Updater'
}
$script:ConfigPath    = Join-Path $script:UpdaterRoot 'tools-config.json'
$script:ManifestPath  = Join-Path $script:UpdaterRoot 'scan-manifest.json'

# Drive root is the parent of the updater folder (typically D:\)
$script:DriveRoot = Split-Path -Parent $script:UpdaterRoot
if (-not (Test-Path $script:DriveRoot)) {
    $script:DriveRoot = 'D:\'
}

# Category folders to scan (relative to drive root)
$script:ScanFolders = @(
    '01_Acquisition'
    '02_Analysis'
    '03_Network'
    '04_Mobile-Forensics'
    '05_Case-Files'
    '06_Training'
    '07_Documentation'
    '08_Utilities'
    # Note: PortableApps is excluded — it is managed by the PortableApps.com platform
)

# Map folder prefixes to friendly category names
$script:CategoryMap = @{
    '01_Acquisition'     = 'Acquisition'
    '02_Analysis'        = 'Analysis'
    '03_Network'         = 'Network'
    '04_Mobile-Forensics'= 'Mobile Forensics'
    '05_Case-Files'      = 'Case Files'
    '06_Training'        = 'Training'
    '07_Documentation'   = 'Documentation'
    '08_Utilities'       = 'Utilities'
    'PortableApps'       = 'Portable Apps'
}

# File extensions to look for
$script:ExeExtensions = @('.exe')
$script:DocExtensions = @('.pdf', '.docx', '.xlsx', '.zip', '.7z')
$script:AllExtensions = $script:ExeExtensions + $script:DocExtensions

# Version extraction patterns (ordered by specificity)
$script:VersionPatterns = @(
    # tool-name-v1.2.3 or tool_name_v1.2.3
    '[-_]v(\d+\.\d+(?:\.\d+)*(?:[-_.]\w+)?)\s*$'
    # tool-name-1.2.3 or tool_name-1.2.3 (version at end after separator)
    '[-_](\d+\.\d+(?:\.\d+)*)\s*$'
    # tool-name 1.2.3 (space before version)
    '\s+v?(\d+\.\d+(?:\.\d+)*)\s*$'
    # toolname_v1.2.3 (underscore before v-prefix)
    '_v(\d+\.\d+(?:\.\d+)*)'
    # toolname-v1.2.3 (hyphen before v-prefix)
    '-v(\d+\.\d+(?:\.\d+)*)'
    # embedded version like ToolName1.2.3 (capital letter then digits)
    '[A-Za-z](\d+\.\d+(?:\.\d+)*)$'
    # NetworkMiner_3-0 style (underscores/hyphens as dot separators)
    '[-_](\d+[-_]\d+(?:[-_]\d+)*)$'
)

# ---------------------------------------------------------------------------
# Known DFIR GitHub Repositories Lookup Table
# ---------------------------------------------------------------------------
function Get-KnownDFIRRepos {
    <#
    .SYNOPSIS
        Returns a hashtable mapping tool name patterns to GitHub owner/repo strings.

    .DESCRIPTION
        Contains a curated list of 50+ common DFIR, forensics, incident response,
        and reverse-engineering tools and their corresponding GitHub repositories.
        Keys are lowercase name patterns; values are "owner/repo" strings.

    .OUTPUTS
        System.Collections.Hashtable

    .EXAMPLE
        $repos = Get-KnownDFIRRepos
        $repos['autopsy']  # Returns 'sleuthkit/autopsy'
    #>
    [CmdletBinding()]
    param()

    return @{
        # --- Disk / Memory Acquisition ---
        'arsenal-image-mounter'   = 'ArsenalRecon/Arsenal-Image-Mounter'
        'encrypteddiskhunter'     = 'yourealwaysbe/EncryptedDiskHunter'
        'youreallywaysbe'         = 'yourealwaysbe/EncryptedDiskHunter'

        # --- Analysis / Forensics Suites ---
        'autopsy'                 = 'sleuthkit/autopsy'
        'sleuthkit'               = 'sleuthkit/sleuthkit'
        'volatility3'             = 'volatilityfoundation/volatility3'
        'volatility'              = 'volatilityfoundation/volatility'
        'plaso'                   = 'log2timeline/plaso'
        'log2timeline'            = 'log2timeline/plaso'
        'bulk_extractor'          = 'simsong/bulk_extractor'
        'bulk-extractor'          = 'simsong/bulk_extractor'
        'bulkextractor'           = 'simsong/bulk_extractor'
        'exiftool'                = 'exiftool/exiftool'
        'hashcat'                 = 'hashcat/hashcat'
        'cyberchef'               = 'gchq/CyberChef'

        # --- Eric Zimmerman Tools ---
        'recmd'                   = 'EricZimmerman/RECmd'
        'mftecmd'                 = 'EricZimmerman/MFTECmd'
        'pecmd'                   = 'EricZimmerman/PECmd'
        'lecmd'                   = 'EricZimmerman/LECmd'
        'timelineexplorer'        = 'EricZimmerman/TimelineExplorer'
        'timeline-explorer'       = 'EricZimmerman/TimelineExplorer'
        'shellbags-explorer'      = 'EricZimmerman/ShellBags'
        'shellbagsexplorer'       = 'EricZimmerman/ShellBags'
        'amcacheparser'           = 'EricZimmerman/AmcacheParser'
        'appcompatcacheparser'    = 'EricZimmerman/AppCompatCacheParser'
        'evtxecmd'                = 'EricZimmerman/evtx'
        'jlecmd'                  = 'EricZimmerman/JLECmd'
        'rbcmd'                   = 'EricZimmerman/RBCmd'
        'sumecmd'                 = 'EricZimmerman/SUMECmd'
        'wxtcmd'                  = 'EricZimmerman/WxTCmd'
        'registryexplorer'        = 'EricZimmerman/RegistryExplorer'
        'sqlecmd'                 = 'EricZimmerman/SQLECmd'
        'get-zimmermantools'      = 'EricZimmerman/Get-ZimmermanTools'
        'kapefiles'               = 'EricZimmerman/KapeFiles'

        # --- YARA / Malware Analysis ---
        'yara'                    = 'VirusTotal/yara'
        'yara-x'                  = 'VirusTotal/yara-x'
        'capa'                    = 'mandiant/capa'
        'floss'                   = 'mandiant/flare-floss'
        'flare-floss'             = 'mandiant/flare-floss'
        'die'                     = 'horsicq/DIE-engine'
        'detect-it-easy'          = 'horsicq/DIE-engine'
        'pestudio'                = $null  # No GitHub; pestudio.winitor.com
        'pe-bear'                 = 'hasherezade/pe-bear'
        'pebear'                  = 'hasherezade/pe-bear'
        'pe-sieve'                = 'hasherezade/pe-sieve'
        'hollows-hunter'          = 'hasherezade/hollows_hunter'

        # --- Reverse Engineering / Debugging ---
        'ghidra'                  = 'NationalSecurityAgency/ghidra'
        'radare2'                 = 'radareorg/radare2'
        'r2'                      = 'radareorg/radare2'
        'iaito'                   = 'radareorg/iaito'
        'cutter'                  = 'rizinorg/cutter'
        'rizin'                   = 'rizinorg/rizin'
        'x64dbg'                  = 'x64dbg/x64dbg'
        'x32dbg'                  = 'x64dbg/x64dbg'
        'dnspy'                   = 'dnSpy/dnSpy'
        'ilspy'                   = 'icsharpcode/ILSpy'
        'binary-ninja'            = $null  # Commercial; no public GitHub releases
        'ida'                     = $null  # Commercial; no public GitHub releases

        # --- Network Analysis ---
        'wireshark'               = 'wireshark/wireshark'
        'networkminer'            = $null  # netresec.com, no GitHub releases
        'nmap'                    = 'nmap/nmap'
        'zeek'                    = 'zeek/zeek'
        'bro'                     = 'zeek/zeek'
        'suricata'                = 'OISF/suricata'
        'arkime'                  = 'arkime/arkime'
        'moloch'                  = 'arkime/arkime'
        'termshark'               = 'gcla/termshark'
        'netcat'                  = $null  # Various sources
        'tcpdump'                 = $null  # tcpdump.org

        # --- Mobile Forensics ---
        'aleapp'                  = 'abrignoni/ALEAPP'
        'ileapp'                  = 'abrignoni/iLEAPP'
        'vleapp'                  = 'abrignoni/VLEAPP'
        'rleapp'                  = 'abrignoni/RLEAPP'
        'cleapp'                  = 'markmckinnon/cLeapp'
        'mvt'                     = 'mvt-project/mvt'
        'libimobiledevice'        = 'libimobiledevice/libimobiledevice'
        'ideviceinstaller'        = 'libimobiledevice/ideviceinstaller'
        'iphonebackupanalyzer'    = $null  # iPBA2
        'oxygen-forensics'        = $null  # Commercial

        # --- Sysinternals ---
        'sysinternals'            = $null  # Microsoft; download from live.sysinternals.com
        'procmon'                 = $null  # Part of Sysinternals
        'procexp'                 = $null  # Part of Sysinternals
        'autoruns'                = $null  # Part of Sysinternals
        'tcpview'                 = $null  # Part of Sysinternals
        'process-monitor'         = $null  # Part of Sysinternals
        'process-explorer'        = $null  # Part of Sysinternals
        'psexec'                  = $null  # Part of Sysinternals
        'handle'                  = $null  # Part of Sysinternals
        'sysmon'                  = $null  # Part of Sysinternals

        # --- NirSoft ---
        'nirsoft'                 = $null  # nirsoft.net; no GitHub
        'hashmyfiles'             = $null  # NirSoft tool
        'browsinghistoryview'     = $null  # NirSoft tool
        'fulleventlogview'        = $null  # NirSoft tool
        'usbdeview'               = $null  # NirSoft tool
        'wirelesskeyview'         = $null  # NirSoft tool

        # --- IR / Threat Hunting ---
        'velociraptor'            = 'Velocidex/velociraptor'
        'chainsaw'                = 'WithSecureLabs/chainsaw'
        'hayabusa'                = 'Yamato-Security/hayabusa'
        'deepbluecli'             = 'sans-blue-team/DeepBlueCLI'
        'sigma'                   = 'SigmaHQ/sigma'
        'thor'                    = $null  # Commercial; Nextron Systems
        'loki'                    = 'Neo23x0/Loki'
        'fenrir'                  = 'Neo23x0/Fenrir'
        'zimmerman-tools'         = $null  # Meta; use individual repos

        # --- Utilities ---
        'unigetui'                = 'marticliment/UniGetUI'
        'wingetui'                = 'marticliment/UniGetUI'
        '7zip'                    = $null  # 7-zip.org
        '7-zip'                   = $null  # 7-zip.org
        'notepad++'               = 'notepad-plus-plus/notepad-plus-plus'
        'notepadplusplus'         = 'notepad-plus-plus/notepad-plus-plus'
        'everything'              = $null  # voidtools.com
        'hxd'                     = $null  # mh-nexus.de

        # --- Disk / Partition ---
        'ftk-imager'              = $null  # Exterro; requires download form
        'photorec'                = $null  # cgsecurity.org
        'testdisk'                = $null  # cgsecurity.org
        'recuva'                  = $null  # ccleaner.com

        # --- Password / Credential ---
        'mimikatz'                = 'gentilkiwi/mimikatz'
        'lazagne'                 = 'AlessandroZ/LaZagne'
        'john'                    = 'openwall/john'
        'john-the-ripper'         = 'openwall/john'
        'ophcrack'                = $null  # ophcrack.sourceforge.net
        'ntdsxtract'              = 'csababarta/ntdsxtract'
        'impacket'                = 'fortra/impacket'

        # --- Log / Timeline ---
        'logparser'               = $null  # Microsoft; download center
        'event-log-explorer'      = $null  # eventlogxp.com

        # --- Browser Forensics ---
        'hindsight'               = 'obsidianforensics/hindsight'
        'dumpzilla'               = $null  # Various sources

        # --- Memory Forensics ---
        'winpmem'                 = 'Velocidex/WinPmem'
        'rekall'                  = 'google/rekall'
        'memoryze'                = $null  # Mandiant/FireEye legacy

        # --- Steganography ---
        'steghide'                = $null  # steghide.sourceforge.net
        'openstego'               = 'syvaidya/openstego'
        'zsteg'                   = 'zed-0xff/zsteg'
    }
}

# ---------------------------------------------------------------------------
# Internal Helpers
# ---------------------------------------------------------------------------

function _Get-CategoryFromPath {
    <#
    .SYNOPSIS
        Extracts the human-friendly category name from a relative path.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RelativePath
    )

    $topFolder = ($RelativePath -split '[/\\]')[0]
    if ($script:CategoryMap.ContainsKey($topFolder)) {
        return $script:CategoryMap[$topFolder]
    }
    return $topFolder
}


function _Extract-VersionFromName {
    <#
    .SYNOPSIS
        Attempts to extract a version string from a file or folder name.

    .OUTPUTS
        String or $null.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    # Strip common extensions before version extraction
    $baseName = $Name -replace '\.(exe|zip|7z|msi|pdf|docx|xlsx)$', ''

    foreach ($pattern in $script:VersionPatterns) {
        if ($baseName -match $pattern) {
            $ver = $Matches[1]
            # Normalize hyphens/underscores to dots in version strings
            $ver = $ver -replace '[-_]', '.'
            Write-Verbose "  Version extracted from '$Name': $ver (pattern: $pattern)"
            return $ver
        }
    }

    Write-Verbose "  No version found in '$Name'."
    return $null
}


function _Get-CleanToolName {
    <#
    .SYNOPSIS
        Derives a clean display name from a file or folder name.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    $clean = $Name

    # Strip file extension
    $clean = $clean -replace '\.(exe|zip|7z|msi|pdf|docx|xlsx)$', ''

    # Strip trailing version patterns (various forms)
    $clean = $clean -replace '[-_]v?\d+\.\d+[\d.]*[-_\w]*$', ''
    $clean = $clean -replace '\s+v?\d+\.\d+[\d.]*$', ''
    $clean = $clean -replace '[-_]\d+[-_]\d+(?:[-_]\d+)*$', ''

    # Replace separators with spaces
    $clean = $clean -replace '[-_]', ' '

    # Trim and collapse whitespace
    $clean = ($clean -replace '\s+', ' ').Trim()

    # Title-case if entirely lowercase
    if ($clean -ceq $clean.ToLower() -and $clean.Length -gt 0) {
        $clean = (Get-Culture).TextInfo.ToTitleCase($clean)
    }

    if ([string]::IsNullOrWhiteSpace($clean)) {
        return $Name
    }

    return $clean
}


function _Match-KnownRepo {
    <#
    .SYNOPSIS
        Tries to match a tool name against the known DFIR repos lookup table.

    .OUTPUTS
        PSCustomObject with MatchedKey and GitHubRepo, or $null.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ToolName
    )

    $repos = Get-KnownDFIRRepos
    $normalized = $ToolName.ToLower().Trim()

    # Try exact match first
    if ($repos.ContainsKey($normalized)) {
        return [PSCustomObject]@{
            MatchedKey = $normalized
            GitHubRepo = $repos[$normalized]
        }
    }

    # Try with common transformations
    $variations = @(
        $normalized
        ($normalized -replace '\s+', '-')
        ($normalized -replace '\s+', '_')
        ($normalized -replace '\s+', '')
        ($normalized -replace '[-_\s]+', '-')
        ($normalized -replace '[-_\s]+', '')
    )

    foreach ($variant in $variations) {
        if ($repos.ContainsKey($variant)) {
            return [PSCustomObject]@{
                MatchedKey = $variant
                GitHubRepo = $repos[$variant]
            }
        }
    }

    # Try substring/partial match — check if any key is contained in the name
    foreach ($key in $repos.Keys) {
        if ($key.Length -ge 4 -and $normalized -like "*$key*") {
            return [PSCustomObject]@{
                MatchedKey = $key
                GitHubRepo = $repos[$key]
            }
        }
    }

    return $null
}


function _Determine-InstallType {
    <#
    .SYNOPSIS
        Determines the install_type based on item characteristics.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ItemPath,

        [Parameter()]
        [bool]$IsDirectory = $false,

        [Parameter()]
        [string]$Extension = ''
    )

    if ($IsDirectory) {
        return 'extract_zip'
    }

    switch ($Extension.ToLower()) {
        '.exe'  { return 'copy_exe' }
        '.zip'  { return 'extract_zip' }
        '.7z'   { return 'extract_zip' }
        '.msi'  { return 'manual' }
        '.pdf'  { return 'manual' }
        '.docx' { return 'manual' }
        '.xlsx' { return 'manual' }
        default { return 'manual' }
    }
}


function _Build-AssetPattern {
    <#
    .SYNOPSIS
        Generates a plausible github_asset_pattern for a tool.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ToolName,

        [Parameter()]
        [string]$Extension = '.zip'
    )

    # Create a pattern from the tool name that allows version wildcards
    $escaped = [regex]::Escape($ToolName)
    # Replace spaces/separators with flexible matchers
    $escaped = $escaped -replace '[\s_-]+', '[-_.]?'

    $extEscaped = [regex]::Escape($Extension)
    return "${escaped}.*${extEscaped}"
}

# ---------------------------------------------------------------------------
# 1. Get-ScanManifest
# ---------------------------------------------------------------------------
function Get-ScanManifest {
    <#
    .SYNOPSIS
        Loads the scan manifest from disk, or returns a new empty manifest.

    .DESCRIPTION
        The scan manifest records the last scan timestamp, all known paths
        (both from config and previously scanned), and paths that have been
        explicitly marked as ignored.

    .PARAMETER Path
        Path to the manifest file. Defaults to D:\DFIR-Updater\scan-manifest.json.

    .OUTPUTS
        PSCustomObject with properties: last_scan, known_paths, ignored_paths.

    .EXAMPLE
        $manifest = Get-ScanManifest
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$Path = $script:ManifestPath
    )

    if (Test-Path -LiteralPath $Path) {
        Write-Verbose "Loading scan manifest from '$Path'."
        try {
            $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
            $manifest = $raw | ConvertFrom-Json -ErrorAction Stop

            # Ensure required properties exist (handle older manifest versions)
            if ($null -eq $manifest.known_paths) {
                $manifest | Add-Member -NotePropertyName 'known_paths' -NotePropertyValue @() -Force
            }
            if ($null -eq $manifest.ignored_paths) {
                $manifest | Add-Member -NotePropertyName 'ignored_paths' -NotePropertyValue @() -Force
            }
            if ($null -eq $manifest.last_scan) {
                $manifest | Add-Member -NotePropertyName 'last_scan' -NotePropertyValue $null -Force
            }

            Write-Verbose "Manifest loaded: $(@($manifest.known_paths).Count) known, $(@($manifest.ignored_paths).Count) ignored."
            return $manifest
        }
        catch {
            Write-Warning "Failed to parse manifest at '$Path': $_. Creating a fresh manifest."
        }
    }
    else {
        Write-Verbose "No manifest found at '$Path'. Creating a new one."
    }

    # Return a fresh empty manifest
    return [PSCustomObject]@{
        last_scan     = $null
        known_paths   = @()
        ignored_paths = @()
    }
}

# ---------------------------------------------------------------------------
# 2. Save-ScanManifest
# ---------------------------------------------------------------------------
function Save-ScanManifest {
    <#
    .SYNOPSIS
        Saves the scan manifest to disk.

    .PARAMETER Manifest
        The manifest object to save.

    .PARAMETER Path
        Destination file path. Defaults to D:\DFIR-Updater\scan-manifest.json.

    .EXAMPLE
        Save-ScanManifest -Manifest $manifest
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Manifest,

        [Parameter()]
        [string]$Path = $script:ManifestPath
    )

    Write-Verbose "Saving scan manifest to '$Path'."

    try {
        $parentDir = Split-Path -Parent $Path
        if (-not (Test-Path -LiteralPath $parentDir)) {
            New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
        }

        $json = $Manifest | ConvertTo-Json -Depth 10
        Set-Content -LiteralPath $Path -Value $json -Encoding UTF8 -ErrorAction Stop

        Write-Verbose "Manifest saved successfully."
    }
    catch {
        Write-Error "Failed to save manifest to '$Path': $_"
    }
}

# ---------------------------------------------------------------------------
# 3. Find-NewTools
# ---------------------------------------------------------------------------
function Find-NewTools {
    <#
    .SYNOPSIS
        Scans the DFIR drive and returns items not tracked in tools-config.json.

    .DESCRIPTION
        Recursively scans the organized folders on the DFIR drive (up to 2 levels
        deep) looking for executables, tool directories, and documents. Compares
        findings against the existing tools-config.json paths and the scan manifest.
        Returns pre-filled config entry objects for each newly discovered item.

    .PARAMETER ConfigPath
        Path to tools-config.json. Defaults to D:\DFIR-Updater\tools-config.json.

    .PARAMETER DriveRoot
        Root path of the DFIR drive. Defaults to D:\.

    .PARAMETER IncludeIgnored
        If set, also returns items previously marked as ignored in the manifest.

    .PARAMETER UpdateManifest
        If set, automatically updates the manifest with newly discovered paths.
        Defaults to $true.

    .OUTPUTS
        PSCustomObject[] — Array of discovered tool entry objects matching the
        tools-config.json schema, with an additional "discovery_status" property.

    .EXAMPLE
        Find-NewTools -Verbose
    .EXAMPLE
        Find-NewTools -IncludeIgnored | Format-Table name, path, source_type
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$ConfigPath = $script:ConfigPath,

        [Parameter()]
        [string]$DriveRoot = $script:DriveRoot,

        [Parameter()]
        [switch]$IncludeIgnored,

        [Parameter()]
        [bool]$UpdateManifest = $true
    )

    # --- Load existing config ---
    $configPaths = @()
    if (Test-Path -LiteralPath $ConfigPath) {
        try {
            $raw = Get-Content -LiteralPath $ConfigPath -Raw -ErrorAction Stop
            $config = $raw | ConvertFrom-Json -ErrorAction Stop
            if ($config.tools) {
                $configPaths = @($config.tools | ForEach-Object { $_.path })
            }
            Write-Verbose "Loaded $($configPaths.Count) tool paths from config."
        }
        catch {
            Write-Warning "Failed to load config from '$ConfigPath': $_"
        }
    }
    else {
        Write-Warning "Config file not found: $ConfigPath"
    }

    # Normalize config paths for comparison (lowercase, forward slashes)
    $normalizedConfigPaths = $configPaths | ForEach-Object {
        $_.ToLower().Replace('\', '/')
    }

    # --- Load manifest ---
    $manifest = Get-ScanManifest

    $normalizedIgnored = @()
    if ($manifest.ignored_paths) {
        $normalizedIgnored = @($manifest.ignored_paths | ForEach-Object {
            $_.ToLower().Replace('\', '/')
        })
    }

    $normalizedKnown = @()
    if ($manifest.known_paths) {
        $normalizedKnown = @($manifest.known_paths | ForEach-Object {
            $_.ToLower().Replace('\', '/')
        })
    }

    # --- Scan folders ---
    $discovered = [System.Collections.Generic.List[PSCustomObject]]::new()
    $allScannedPaths = [System.Collections.Generic.List[string]]::new()
    $today = Get-Date -Format 'yyyy-MM-dd'

    foreach ($folder in $script:ScanFolders) {
        $folderPath = Join-Path $DriveRoot $folder
        if (-not (Test-Path -LiteralPath $folderPath)) {
            Write-Verbose "Scan folder does not exist, skipping: $folderPath"
            continue
        }

        Write-Verbose "Scanning: $folderPath"

        # --- Level 1: Direct children ---
        $level1Items = @()
        try {
            $level1Items = Get-ChildItem -LiteralPath $folderPath -ErrorAction SilentlyContinue
        }
        catch {
            Write-Warning "Error scanning '$folderPath': $_"
            continue
        }

        foreach ($item in $level1Items) {
            $relativePath = Join-Path $folder $item.Name

            # Track all scanned paths
            $allScannedPaths.Add($relativePath)

            $normalizedRelative = $relativePath.ToLower().Replace('\', '/')

            # Check if already in config
            $inConfig = $normalizedConfigPaths -contains $normalizedRelative
            if ($inConfig) {
                Write-Verbose "  [TRACKED] $relativePath"
                continue
            }

            # Check if ignored (skip unless -IncludeIgnored)
            $isIgnored = $normalizedIgnored -contains $normalizedRelative
            if ($isIgnored -and -not $IncludeIgnored) {
                Write-Verbose "  [IGNORED] $relativePath"
                continue
            }

            # Check if already known from a previous scan (and still not in config)
            $isKnown = $normalizedKnown -contains $normalizedRelative

            # --- Process the item ---
            if ($item.PSIsContainer) {
                # It is a directory. Check if it contains executables (a tool folder).
                $hasExes = $false
                try {
                    $childExes = Get-ChildItem -LiteralPath $item.FullName -Filter '*.exe' `
                                    -Recurse -Depth 1 -ErrorAction SilentlyContinue |
                                    Select-Object -First 1
                    $hasExes = ($null -ne $childExes)
                }
                catch { }

                # Also check for documents
                $hasDocs = $false
                if (-not $hasExes) {
                    foreach ($ext in $script:DocExtensions) {
                        try {
                            $childDocs = Get-ChildItem -LiteralPath $item.FullName -Filter "*$ext" `
                                            -Recurse -Depth 1 -ErrorAction SilentlyContinue |
                                            Select-Object -First 1
                            if ($null -ne $childDocs) {
                                $hasDocs = $true
                                break
                            }
                        }
                        catch { }
                    }
                }

                if (-not $hasExes -and -not $hasDocs) {
                    Write-Verbose "  [SKIP] Directory with no tools/docs: $relativePath"
                    continue
                }

                $version     = _Extract-VersionFromName -Name $item.Name
                $cleanName   = _Get-CleanToolName -Name $item.Name
                $category    = _Get-CategoryFromPath -RelativePath $relativePath
                $repoMatch   = _Match-KnownRepo -ToolName $cleanName
                $installType = if ($hasExes) { 'extract_zip' } else { 'manual' }

                $entry = [PSCustomObject]@{
                    name                 = $cleanName
                    path                 = $relativePath
                    source_type          = if ($repoMatch -and $repoMatch.GitHubRepo) { 'github' } else { 'web' }
                    github_repo          = if ($repoMatch) { $repoMatch.GitHubRepo } else { $null }
                    github_asset_pattern = if ($repoMatch -and $repoMatch.GitHubRepo) {
                                               _Build-AssetPattern -ToolName $cleanName
                                           } else { $null }
                    download_url         = $null
                    current_version      = $version
                    version_pattern      = 'v?([\d.]+)'
                    install_type         = $installType
                    notes                = "Auto-discovered on $today"
                    discovery_status     = if ($isIgnored) { 'ignored' }
                                           elseif ($isKnown) { 'known-untracked' }
                                           else { 'new' }
                    category             = $category
                }

                $discovered.Add($entry)
                Write-Verbose "  [NEW] $relativePath -> $cleanName"
            }
            else {
                # It is a file
                $ext = $item.Extension.ToLower()
                if ($ext -notin $script:AllExtensions) {
                    Write-Verbose "  [SKIP] Unsupported extension: $relativePath"
                    continue
                }

                $version     = _Extract-VersionFromName -Name $item.Name
                $cleanName   = _Get-CleanToolName -Name $item.Name
                $category    = _Get-CategoryFromPath -RelativePath $relativePath
                $repoMatch   = _Match-KnownRepo -ToolName $cleanName
                $installType = _Determine-InstallType -ItemPath $relativePath -Extension $ext

                $entry = [PSCustomObject]@{
                    name                 = $cleanName
                    path                 = $relativePath
                    source_type          = if ($repoMatch -and $repoMatch.GitHubRepo) { 'github' } else { 'web' }
                    github_repo          = if ($repoMatch) { $repoMatch.GitHubRepo } else { $null }
                    github_asset_pattern = if ($repoMatch -and $repoMatch.GitHubRepo -and $ext -eq '.exe') {
                                               _Build-AssetPattern -ToolName $cleanName -Extension '.exe'
                                           }
                                           elseif ($repoMatch -and $repoMatch.GitHubRepo) {
                                               _Build-AssetPattern -ToolName $cleanName
                                           }
                                           else { $null }
                    download_url         = $null
                    current_version      = $version
                    version_pattern      = 'v?([\d.]+)'
                    install_type         = $installType
                    notes                = "Auto-discovered on $today"
                    discovery_status     = if ($isIgnored) { 'ignored' }
                                           elseif ($isKnown) { 'known-untracked' }
                                           else { 'new' }
                    category             = $category
                }

                $discovered.Add($entry)
                Write-Verbose "  [NEW] $relativePath -> $cleanName ($ext)"
            }
        }

        # --- Level 2: Children of subdirectories (only scan immediate children of level-1 dirs) ---
        $level1Dirs = $level1Items | Where-Object { $_.PSIsContainer }

        foreach ($subDir in $level1Dirs) {
            # Skip level 2 scanning if the parent directory is already tracked in config
            $parentRelPath = (Join-Path $folder $subDir.Name).ToLower().Replace('\', '/')
            if ($normalizedConfigPaths -contains $parentRelPath) {
                Write-Verbose "  [SKIP L2] Parent is tracked: $parentRelPath"
                continue
            }

            $level2Items = @()
            try {
                $level2Items = Get-ChildItem -LiteralPath $subDir.FullName -ErrorAction SilentlyContinue
            }
            catch {
                Write-Verbose "  Error scanning level 2 '$($subDir.FullName)': $_"
                continue
            }

            foreach ($item in $level2Items) {
                $relativePath = Join-Path $folder (Join-Path $subDir.Name $item.Name)
                $allScannedPaths.Add($relativePath)

                $normalizedRelative = $relativePath.ToLower().Replace('\', '/')

                # Skip if already in config
                if ($normalizedConfigPaths -contains $normalizedRelative) {
                    continue
                }

                # Skip if ignored (unless -IncludeIgnored)
                $isIgnored = $normalizedIgnored -contains $normalizedRelative
                if ($isIgnored -and -not $IncludeIgnored) {
                    continue
                }

                $isKnown = $normalizedKnown -contains $normalizedRelative

                if ($item.PSIsContainer) {
                    # Level 2 directory: check for exes
                    $hasExes = $false
                    try {
                        $childExes = Get-ChildItem -LiteralPath $item.FullName -Filter '*.exe' `
                                        -ErrorAction SilentlyContinue | Select-Object -First 1
                        $hasExes = ($null -ne $childExes)
                    }
                    catch { }

                    if (-not $hasExes) {
                        continue
                    }

                    $version     = _Extract-VersionFromName -Name $item.Name
                    $cleanName   = _Get-CleanToolName -Name $item.Name
                    $category    = _Get-CategoryFromPath -RelativePath $relativePath
                    $repoMatch   = _Match-KnownRepo -ToolName $cleanName
                    $installType = 'extract_zip'

                    $entry = [PSCustomObject]@{
                        name                 = $cleanName
                        path                 = $relativePath
                        source_type          = if ($repoMatch -and $repoMatch.GitHubRepo) { 'github' } else { 'web' }
                        github_repo          = if ($repoMatch) { $repoMatch.GitHubRepo } else { $null }
                        github_asset_pattern = if ($repoMatch -and $repoMatch.GitHubRepo) {
                                                   _Build-AssetPattern -ToolName $cleanName
                                               } else { $null }
                        download_url         = $null
                        current_version      = $version
                        version_pattern      = 'v?([\d.]+)'
                        install_type         = $installType
                        notes                = "Auto-discovered on $today"
                        discovery_status     = if ($isIgnored) { 'ignored' }
                                               elseif ($isKnown) { 'known-untracked' }
                                               else { 'new' }
                        category             = $category
                    }

                    $discovered.Add($entry)
                    Write-Verbose "  [NEW-L2] $relativePath -> $cleanName"
                }
                else {
                    $ext = $item.Extension.ToLower()
                    if ($ext -notin $script:AllExtensions) {
                        continue
                    }

                    $version     = _Extract-VersionFromName -Name $item.Name
                    $cleanName   = _Get-CleanToolName -Name $item.Name
                    $category    = _Get-CategoryFromPath -RelativePath $relativePath
                    $repoMatch   = _Match-KnownRepo -ToolName $cleanName
                    $installType = _Determine-InstallType -ItemPath $relativePath -Extension $ext

                    $entry = [PSCustomObject]@{
                        name                 = $cleanName
                        path                 = $relativePath
                        source_type          = if ($repoMatch -and $repoMatch.GitHubRepo) { 'github' } else { 'web' }
                        github_repo          = if ($repoMatch) { $repoMatch.GitHubRepo } else { $null }
                        github_asset_pattern = if ($repoMatch -and $repoMatch.GitHubRepo -and $ext -eq '.exe') {
                                                   _Build-AssetPattern -ToolName $cleanName -Extension '.exe'
                                               }
                                               elseif ($repoMatch -and $repoMatch.GitHubRepo) {
                                                   _Build-AssetPattern -ToolName $cleanName
                                               }
                                               else { $null }
                        download_url         = $null
                        current_version      = $version
                        version_pattern      = 'v?([\d.]+)'
                        install_type         = $installType
                        notes                = "Auto-discovered on $today"
                        discovery_status     = if ($isIgnored) { 'ignored' }
                                               elseif ($isKnown) { 'known-untracked' }
                                               else { 'new' }
                        category             = $category
                    }

                    $discovered.Add($entry)
                    Write-Verbose "  [NEW-L2] $relativePath -> $cleanName ($ext)"
                }
            }
        }
    }

    # --- Update manifest ---
    if ($UpdateManifest) {
        # Merge all scanned paths into known_paths (union with existing)
        $existingKnown = @()
        if ($manifest.known_paths) {
            $existingKnown = @($manifest.known_paths)
        }

        $allKnown = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase
        )

        foreach ($p in $existingKnown) { [void]$allKnown.Add($p) }
        foreach ($p in $allScannedPaths) { [void]$allKnown.Add($p) }
        foreach ($p in $configPaths) { [void]$allKnown.Add($p) }

        $manifest.last_scan   = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')
        $manifest.known_paths = @($allKnown | Sort-Object)

        Save-ScanManifest -Manifest $manifest
    }

    # --- Summary ---
    $newCount     = @($discovered | Where-Object { $_.discovery_status -eq 'new' }).Count
    $knownCount   = @($discovered | Where-Object { $_.discovery_status -eq 'known-untracked' }).Count
    $ignoredCount = @($discovered | Where-Object { $_.discovery_status -eq 'ignored' }).Count

    Write-Verbose "Scan complete: $newCount new, $knownCount previously seen (untracked), $ignoredCount ignored."
    Write-Verbose "Total discovered items: $($discovered.Count)"

    return $discovered.ToArray()
}

# ---------------------------------------------------------------------------
# 4. Add-ToolToConfig
# ---------------------------------------------------------------------------
function Add-ToolToConfig {
    <#
    .SYNOPSIS
        Adds a new tool entry to tools-config.json.

    .DESCRIPTION
        Appends a tool object to the "tools" array in tools-config.json.
        The entry can be a PSCustomObject matching the config schema (the
        extra discovery_status and category properties are stripped before saving).
        If a tool with the same path already exists, the operation is skipped
        unless -Force is specified.

    .PARAMETER ToolEntry
        A PSCustomObject with tool configuration properties.
        Accepts output from Find-NewTools directly.

    .PARAMETER ConfigPath
        Path to tools-config.json. Defaults to D:\DFIR-Updater\tools-config.json.

    .PARAMETER Force
        Overwrite an existing entry with the same path.

    .OUTPUTS
        System.Boolean — $true if the entry was added, $false otherwise.

    .EXAMPLE
        $newTools = Find-NewTools
        $newTools[0] | Add-ToolToConfig

    .EXAMPLE
        Add-ToolToConfig -ToolEntry $entry -Force
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [PSCustomObject]$ToolEntry,

        [Parameter()]
        [string]$ConfigPath = $script:ConfigPath,

        [Parameter()]
        [switch]$Force
    )

    process {
        if (-not (Test-Path -LiteralPath $ConfigPath)) {
            Write-Error "Config file not found: $ConfigPath"
            return $false
        }

        # Load current config
        try {
            $raw = Get-Content -LiteralPath $ConfigPath -Raw -ErrorAction Stop
            $config = $raw | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            Write-Error "Failed to load config: $_"
            return $false
        }

        if ($null -eq $config.tools) {
            Write-Error "Config does not contain a 'tools' array."
            return $false
        }

        $entryPath = $ToolEntry.path
        $entryName = $ToolEntry.name

        # Check for duplicate path
        $existingIdx = -1
        for ($i = 0; $i -lt @($config.tools).Count; $i++) {
            if ($config.tools[$i].path -eq $entryPath) {
                $existingIdx = $i
                break
            }
        }

        if ($existingIdx -ge 0 -and -not $Force) {
            Write-Warning "Tool with path '$entryPath' already exists in config. Use -Force to overwrite."
            return $false
        }

        # Build a clean entry object (strip non-schema properties)
        $cleanEntry = [PSCustomObject]@{
            name                 = $ToolEntry.name
            path                 = $ToolEntry.path
            source_type          = $ToolEntry.source_type
            github_repo          = $ToolEntry.github_repo
            github_asset_pattern = $ToolEntry.github_asset_pattern
            download_url         = $ToolEntry.download_url
            current_version      = $ToolEntry.current_version
            version_pattern      = $ToolEntry.version_pattern
            install_type         = $ToolEntry.install_type
            notes                = $ToolEntry.notes
        }

        if ($PSCmdlet.ShouldProcess("$entryName ($entryPath)", "Add to tools-config.json")) {
            if ($existingIdx -ge 0) {
                # Replace existing entry
                $toolsList = [System.Collections.ArrayList]@($config.tools)
                $toolsList[$existingIdx] = $cleanEntry
                $config.tools = $toolsList.ToArray()
                Write-Verbose "Replaced existing entry for '$entryName' at index $existingIdx."
            }
            else {
                # Append new entry
                $toolsList = [System.Collections.ArrayList]@($config.tools)
                [void]$toolsList.Add($cleanEntry)
                $config.tools = $toolsList.ToArray()
                Write-Verbose "Added new entry for '$entryName'."
            }

            # Update last_updated timestamp
            $config.last_updated = (Get-Date).ToString('yyyy-MM-dd')

            try {
                $json = $config | ConvertTo-Json -Depth 10
                Set-Content -LiteralPath $ConfigPath -Value $json -Encoding UTF8 -ErrorAction Stop
                Write-Verbose "Config saved to '$ConfigPath'."
                return $true
            }
            catch {
                Write-Error "Failed to save config: $_"
                return $false
            }
        }

        return $false
    }
}

# ---------------------------------------------------------------------------
# 5. Remove-IgnoredItem (Add to ignore list)
# ---------------------------------------------------------------------------
function Remove-IgnoredItem {
    <#
    .SYNOPSIS
        Marks an item as "ignored" in the scan manifest so it will not be
        flagged as new in future scans.

    .DESCRIPTION
        Adds the specified path to the ignored_paths list in scan-manifest.json.
        The item will no longer appear in Find-NewTools output unless the
        -IncludeIgnored switch is used.

        Despite the name (which follows PowerShell Remove-* convention for
        removing items from the "new" results), this function adds to the
        ignore list. To un-ignore a path, use the -Undo switch.

    .PARAMETER Path
        Relative path of the item to ignore (as it appears in discovery results).

    .PARAMETER Undo
        If specified, removes the path from the ignored list (un-ignores it).

    .PARAMETER ManifestPath
        Path to the scan manifest. Defaults to D:\DFIR-Updater\scan-manifest.json.

    .OUTPUTS
        System.Boolean — $true if the operation succeeded.

    .EXAMPLE
        Remove-IgnoredItem -Path '02_Analysis/SomeTool'

    .EXAMPLE
        Remove-IgnoredItem -Path '02_Analysis/SomeTool' -Undo
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('ItemPath')]
        [string]$Path,

        [Parameter()]
        [switch]$Undo,

        [Parameter()]
        [string]$ManifestPath = $script:ManifestPath
    )

    process {
        $manifest = Get-ScanManifest -Path $ManifestPath

        # Ensure ignored_paths is a mutable list
        $ignoredList = [System.Collections.Generic.List[string]]::new()
        if ($manifest.ignored_paths) {
            foreach ($p in $manifest.ignored_paths) {
                $ignoredList.Add($p)
            }
        }

        $normalizedPath = $Path.Replace('\', '/')

        if ($Undo) {
            # Remove from ignored list
            $removed = $false
            $toRemove = @()
            for ($i = 0; $i -lt $ignoredList.Count; $i++) {
                if ($ignoredList[$i].Replace('\', '/') -eq $normalizedPath) {
                    $toRemove += $i
                }
            }
            # Remove in reverse order to preserve indices
            for ($i = $toRemove.Count - 1; $i -ge 0; $i--) {
                $ignoredList.RemoveAt($toRemove[$i])
                $removed = $true
            }

            if (-not $removed) {
                Write-Warning "Path '$Path' was not in the ignored list."
                return $false
            }

            Write-Verbose "Un-ignored: $Path"
        }
        else {
            # Add to ignored list (avoid duplicates)
            $alreadyIgnored = $ignoredList | Where-Object {
                $_.Replace('\', '/') -eq $normalizedPath
            }

            if ($alreadyIgnored) {
                Write-Verbose "Path '$Path' is already in the ignored list."
                return $true
            }

            $ignoredList.Add($Path)
            Write-Verbose "Ignored: $Path"
        }

        $manifest.ignored_paths = @($ignoredList.ToArray())

        try {
            Save-ScanManifest -Manifest $manifest -Path $ManifestPath
            return $true
        }
        catch {
            Write-Error "Failed to update manifest: $_"
            return $false
        }
    }
}

# ---------------------------------------------------------------------------
# Export summary (informational, for dot-sourcing)
# ---------------------------------------------------------------------------
Write-Verbose @"
Auto-Discovery module loaded. Available functions:
  Find-NewTools         - Scan the drive for untracked tools/documents
  Get-ScanManifest      - Load the scan manifest
  Save-ScanManifest     - Save the scan manifest
  Add-ToolToConfig      - Add a discovered tool to tools-config.json
  Remove-IgnoredItem    - Mark/unmark items as ignored in the manifest
  Get-KnownDFIRRepos    - Return the DFIR GitHub repos lookup table
"@
