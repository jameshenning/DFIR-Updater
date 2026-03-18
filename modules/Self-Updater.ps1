#Requires -Version 5.1
<#
.SYNOPSIS
    Self-update capability for the DFIR-Updater application.
.DESCRIPTION
    Provides functions to check for new releases of DFIR-Updater itself,
    download and install updates from GitHub, and run headless update checks
    suitable for Task Scheduler or unattended operation.
#>

Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
$script:SelfRepo     = 'jameshenning/DFIR-Updater'
$script:UserAgent    = 'DFIR-Updater/1.0 (PowerShell)'
$script:TempRoot     = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), 'DFIR-Updater')

# Resolve ScriptDir and project root
$script:ModuleDir = $PSScriptRoot
if (-not $script:ModuleDir) { $script:ModuleDir = Split-Path -Parent $MyInvocation.MyCommand.Definition }
$script:ScriptDir = Split-Path -Parent $script:ModuleDir

# Path to the VERSION file at the project root
$script:VersionFilePath = Join-Path $script:ScriptDir 'VERSION'

# Path to tools-config.json (fallback version source)
$script:ConfigPath = Join-Path $script:ScriptDir 'tools-config.json'
if (-not (Test-Path $script:ConfigPath)) {
    $dfirVol = Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.FileSystemLabel -eq 'DFIR' -and $_.DriveLetter } | Select-Object -First 1
    if ($dfirVol) {
        $script:ConfigPath = "$($dfirVol.DriveLetter):\DFIR-Updater\tools-config.json"
    } else {
        $script:ConfigPath = 'D:\DFIR-Updater\tools-config.json'
    }
}

# Ensure TLS 1.2 is available for HTTPS requests
try {
    [System.Net.ServicePointManager]::SecurityProtocol =
        [System.Net.ServicePointManager]::SecurityProtocol -bor
        [System.Net.SecurityProtocolType]::Tls12
} catch { }

# Files and directories to preserve during self-update
$script:PreserveItems = @(
    'tools-config.json',
    'debug.log',
    'VERSION',
    'FORENSIC_MODE',
    'user-settings.json'
)

# ---------------------------------------------------------------------------
# 1. Get-DfirUpdaterCurrentVersion
# ---------------------------------------------------------------------------
function Get-DfirUpdaterCurrentVersion {
    <#
    .SYNOPSIS
        Reads the currently installed version of DFIR-Updater.

    .DESCRIPTION
        Attempts to read the version string from the VERSION file at the
        project root ($ScriptDir/VERSION).  If the file is missing or
        unreadable, falls back to parsing the "version" field from
        tools-config.json.

    .OUTPUTS
        System.String  The current version string (e.g. "1.0.0"), or
        $null if no version can be determined.

    .EXAMPLE
        $ver = Get-DfirUpdaterCurrentVersion
        Write-Host "Current version: $ver"
    #>
    [CmdletBinding()]
    param()

    # Primary source: VERSION file
    if (Test-Path -LiteralPath $script:VersionFilePath) {
        try {
            $raw = (Get-Content -LiteralPath $script:VersionFilePath -Raw -ErrorAction Stop).Trim()
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                Write-Verbose "Version from VERSION file: $raw"
                return $raw
            }
        }
        catch {
            Write-Verbose "Failed to read VERSION file: $_"
        }
    }

    # Fallback: tools-config.json "version" field
    if (Test-Path -LiteralPath $script:ConfigPath) {
        try {
            $config = Get-Content -LiteralPath $script:ConfigPath -Raw -ErrorAction Stop |
                      ConvertFrom-Json -ErrorAction Stop
            $verProp = $config.PSObject.Properties['version']
            if ($verProp -and $verProp.Value) {
                $ver = [string]$verProp.Value
                Write-Verbose "Version from tools-config.json: $ver"
                return $ver
            }
        }
        catch {
            Write-Verbose "Failed to parse tools-config.json for version: $_"
        }
    }

    Write-Warning 'Could not determine DFIR-Updater current version.'
    return $null
}

# ---------------------------------------------------------------------------
# 2. Get-DfirUpdaterLatestVersion
# ---------------------------------------------------------------------------
function Get-DfirUpdaterLatestVersion {
    <#
    .SYNOPSIS
        Queries the GitHub API for the latest DFIR-Updater release.

    .DESCRIPTION
        Calls https://api.github.com/repos/jameshenning/DFIR-Updater/releases/latest
        and extracts the tag name (stripping a leading "v"), release body,
        asset download URLs, and published date.

        Handles rate limiting (HTTP 403), 404 errors, and network failures
        gracefully by returning a result object with an Error property.

    .PARAMETER GitHubToken
        Optional personal access token for authenticated requests
        (raises the rate limit from 60 to 5 000 requests per hour).

    .OUTPUTS
        PSCustomObject with properties:
            Version      - The version string (tag_name with leading "v" stripped).
            TagName      - The raw tag_name from the release.
            ReleaseUrl   - The HTML URL of the release page.
            Assets       - Array of PSCustomObjects (Name, DownloadUrl, Size, ContentType).
            PublishedAt  - DateTime of the release publication.
            Body         - Release notes / description text.
            Error        - Error string, or $null on success.

    .EXAMPLE
        $latest = Get-DfirUpdaterLatestVersion
        if (-not $latest.Error) {
            Write-Host "Latest version: $($latest.Version)"
        }
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$GitHubToken
    )

    $apiUrl = "https://api.github.com/repos/$($script:SelfRepo)/releases/latest"
    Write-Verbose "Querying GitHub API: $apiUrl"

    $headers = @{
        'Accept'     = 'application/vnd.github+json'
        'User-Agent' = $script:UserAgent
    }

    if ($GitHubToken) {
        $headers['Authorization'] = "Bearer $GitHubToken"
    }

    $webResponse = $null

    try {
        $webResponse = Invoke-WebRequest -Uri $apiUrl -Headers $headers `
                            -UseBasicParsing -ErrorAction Stop
    }
    catch {
        $statusCode = $null
        try { $statusCode = [int]$_.Exception.Response.StatusCode } catch { }

        # --- Rate-limit handling ---
        if ($statusCode -eq 403) {
            $resetTime = 'unknown'
            try {
                $resetHeader = $_.Exception.Response.Headers['X-RateLimit-Reset']
                if ($resetHeader) {
                    $resetTime = ([DateTimeOffset]::FromUnixTimeSeconds([long]$resetHeader)).LocalDateTime.ToString('HH:mm:ss')
                }
            } catch { }

            Write-Warning "GitHub API rate limit exceeded. Resets at $resetTime."
            return [PSCustomObject]@{
                Version     = $null
                TagName     = $null
                ReleaseUrl  = $null
                Assets      = @()
                PublishedAt = $null
                Body        = $null
                Error       = 'RateLimitExceeded'
            }
        }

        # --- 404: repo or release not found ---
        if ($statusCode -eq 404) {
            Write-Warning "No releases found for '$($script:SelfRepo)' (HTTP 404)."
            return [PSCustomObject]@{
                Version     = $null
                TagName     = $null
                ReleaseUrl  = $null
                Assets      = @()
                PublishedAt = $null
                Body        = $null
                Error       = 'NotFound'
            }
        }

        # --- Any other error ---
        Write-Warning "GitHub API request failed: $_"
        return [PSCustomObject]@{
            Version     = $null
            TagName     = $null
            ReleaseUrl  = $null
            Assets      = @()
            PublishedAt = $null
            Body        = $null
            Error       = "$($_.Exception.Message)"
        }
    }

    # --- Parse response body ---
    $response = $webResponse.Content | ConvertFrom-Json

    # --- Tag name and version ---
    $tagName = $null
    $tagProp = $response.PSObject.Properties['tag_name']
    if ($tagProp) { $tagName = $tagProp.Value }

    $version = $null
    if ($tagName) {
        $version = $tagName -replace '^[vV]', ''
    }

    # --- Release URL ---
    $releaseUrl = $null
    $urlProp = $response.PSObject.Properties['html_url']
    if ($urlProp) { $releaseUrl = $urlProp.Value }

    # --- Published date ---
    $publishedAt = $null
    $pubProp = $response.PSObject.Properties['published_at']
    if ($pubProp -and $pubProp.Value) {
        $publishedAt = [datetime]::Parse($response.published_at)
    }

    # --- Body / release notes ---
    $body = $null
    $bodyProp = $response.PSObject.Properties['body']
    if ($bodyProp) { $body = $bodyProp.Value }

    # --- Build asset list ---
    $assets = @()
    $responseAssets = $response.PSObject.Properties['assets']
    if ($responseAssets -and $responseAssets.Value) {
        foreach ($asset in $response.assets) {
            $assets += [PSCustomObject]@{
                Name        = $asset.name
                DownloadUrl = $asset.browser_download_url
                Size        = $asset.size
                ContentType = $asset.content_type
            }
        }
    }

    return [PSCustomObject]@{
        Version     = $version
        TagName     = $tagName
        ReleaseUrl  = $releaseUrl
        Assets      = $assets
        PublishedAt = $publishedAt
        Body        = $body
        Error       = $null
    }
}

# ---------------------------------------------------------------------------
# 3. Test-SelfUpdateAvailable
# ---------------------------------------------------------------------------
function Test-SelfUpdateAvailable {
    <#
    .SYNOPSIS
        Checks whether a newer version of DFIR-Updater is available on GitHub.

    .DESCRIPTION
        Retrieves the current version from the local installation and the
        latest version from the GitHub releases API.  Compares them
        segment-by-segment (stripping leading "v", splitting on ".",
        comparing each numeric segment left-to-right).

        Returns a result object indicating whether an update is available.

    .PARAMETER GitHubToken
        Optional personal access token for authenticated requests.

    .OUTPUTS
        PSCustomObject with properties:
            UpdateAvailable - $true if the latest version is greater.
            CurrentVersion  - The locally installed version string.
            LatestVersion   - The version string from GitHub.
            ReleaseUrl      - The HTML URL of the latest release page.

    .EXAMPLE
        $check = Test-SelfUpdateAvailable
        if ($check.UpdateAvailable) {
            Write-Host "Update available: $($check.LatestVersion)"
        }
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$GitHubToken
    )

    $currentVersion = Get-DfirUpdaterCurrentVersion
    Write-Verbose "Current version: $currentVersion"

    $latestParams = @{}
    if ($GitHubToken) { $latestParams['GitHubToken'] = $GitHubToken }
    $latestInfo = Get-DfirUpdaterLatestVersion @latestParams

    if ($latestInfo.Error) {
        Write-Warning "Could not retrieve latest version: $($latestInfo.Error)"
        return [PSCustomObject]@{
            UpdateAvailable = $false
            CurrentVersion  = $currentVersion
            LatestVersion   = $null
            ReleaseUrl      = $null
        }
    }

    $latestVersion = $latestInfo.Version
    Write-Verbose "Latest version: $latestVersion"

    # --- Segment-by-segment version comparison ---
    $updateAvailable = $false
    if (-not [string]::IsNullOrWhiteSpace($currentVersion) -and
        -not [string]::IsNullOrWhiteSpace($latestVersion)) {

        # Use Compare-Versions from Update-Checker if available
        $compareCmd = Get-Command 'Compare-Versions' -ErrorAction SilentlyContinue
        if ($compareCmd) {
            $updateAvailable = Compare-Versions -CurrentVersion $currentVersion `
                                                -LatestVersion  $latestVersion
        }
        else {
            # Inline comparison: same logic as Update-Checker.ps1
            $current = ($currentVersion -replace '^[vV]', '') -replace '-', '.'
            $latest  = ($latestVersion  -replace '^[vV]', '') -replace '-', '.'

            $currentParts = $current.Split('.') | ForEach-Object {
                $n = 0
                if ([int]::TryParse($_, [ref]$n)) { $n } else { 0 }
            }
            $latestParts  = $latest.Split('.')  | ForEach-Object {
                $n = 0
                if ([int]::TryParse($_, [ref]$n)) { $n } else { 0 }
            }

            $maxLen = [Math]::Max($currentParts.Count, $latestParts.Count)

            for ($i = 0; $i -lt $maxLen; $i++) {
                $c = if ($i -lt $currentParts.Count) { $currentParts[$i] } else { 0 }
                $l = if ($i -lt $latestParts.Count)  { $latestParts[$i]  } else { 0 }

                if ($l -gt $c) {
                    $updateAvailable = $true
                    break
                }
                if ($l -lt $c) {
                    break
                }
            }
        }
    }

    return [PSCustomObject]@{
        UpdateAvailable = $updateAvailable
        CurrentVersion  = $currentVersion
        LatestVersion   = $latestVersion
        ReleaseUrl      = $latestInfo.ReleaseUrl
    }
}

# ---------------------------------------------------------------------------
# 4. Update-DfirUpdater
# ---------------------------------------------------------------------------
function Update-DfirUpdater {
    <#
    .SYNOPSIS
        Downloads and installs the latest DFIR-Updater release from GitHub.

    .DESCRIPTION
        Performs a full self-update of the DFIR-Updater application:
          1. Creates a timestamped backup of the current installation.
          2. Downloads the latest release ZIP from GitHub.
          3. Extracts to a temporary directory.
          4. Copies updated files over the current installation while
             preserving user data (tools-config.json, debug.log, VERSION,
             FORENSIC_MODE, user-settings.json).

        Supports -WhatIf via SupportsShouldProcess to preview changes
        without modifying the file system.

    .PARAMETER GitHubToken
        Optional personal access token for authenticated requests.

    .PARAMETER Force
        Bypasses the update-available check and forces a re-install of
        the latest release.

    .OUTPUTS
        System.Boolean  $true on success, $false on failure.

    .EXAMPLE
        Update-DfirUpdater
        # Checks for an update and installs it if available.

    .EXAMPLE
        Update-DfirUpdater -WhatIf
        # Shows what would happen without making changes.

    .EXAMPLE
        Update-DfirUpdater -Force
        # Re-installs the latest release regardless of current version.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter()]
        [string]$GitHubToken,

        [Parameter()]
        [switch]$Force
    )

    # --- Helper: return result with logging ---
    function Write-Result ([bool]$Success, [string]$Message) {
        if ($Success) { Write-Verbose $Message } else { Write-Warning $Message }
        return $Success
    }

    # ------------------------------------------------------------------
    # Check whether an update is actually available (unless -Force)
    # ------------------------------------------------------------------
    if (-not $Force) {
        $checkParams = @{}
        if ($GitHubToken) { $checkParams['GitHubToken'] = $GitHubToken }
        $status = Test-SelfUpdateAvailable @checkParams

        if (-not $status.UpdateAvailable) {
            Write-Verbose 'DFIR-Updater is already up to date.'
            return $true
        }

        Write-Verbose "Update available: $($status.CurrentVersion) -> $($status.LatestVersion)"
    }

    # ------------------------------------------------------------------
    # Retrieve the latest release info for asset URLs
    # ------------------------------------------------------------------
    $latestParams = @{}
    if ($GitHubToken) { $latestParams['GitHubToken'] = $GitHubToken }
    $release = Get-DfirUpdaterLatestVersion @latestParams

    if ($release.Error) {
        return (Write-Result $false "Failed to query latest release: $($release.Error)")
    }

    # Find a ZIP asset; fall back to the GitHub-generated source zipball
    $downloadUrl = $null
    foreach ($asset in $release.Assets) {
        if ($asset.Name -match '\.zip$') {
            $downloadUrl = $asset.DownloadUrl
            break
        }
    }
    if (-not $downloadUrl) {
        # GitHub auto-generates a zipball for every release
        $downloadUrl = "https://github.com/$($script:SelfRepo)/archive/refs/tags/$($release.TagName).zip"
        Write-Verbose "No ZIP asset found; using GitHub source archive: $downloadUrl"
    }

    # ------------------------------------------------------------------
    # Prepare temp directory
    # ------------------------------------------------------------------
    if (-not (Test-Path -LiteralPath $script:TempRoot)) {
        New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null
    }

    $timestamp   = Get-Date -Format 'yyyyMMdd_HHmmss'
    $tempZip     = Join-Path $script:TempRoot "DFIR-Updater_$timestamp.zip"
    $tempExtract = Join-Path $script:TempRoot "DFIR-Updater_$timestamp"

    # ------------------------------------------------------------------
    # Download the release ZIP
    # ------------------------------------------------------------------
    Write-Verbose "Downloading '$downloadUrl' -> '$tempZip'"

    if (-not $PSCmdlet.ShouldProcess($downloadUrl, 'Download latest DFIR-Updater release')) {
        return (Write-Result $false 'Download skipped (WhatIf).')
    }

    $webClient = $null
    try {
        $webClient = New-Object System.Net.WebClient
        $webClient.Headers.Add('User-Agent', $script:UserAgent)
        $webClient.DownloadFile($downloadUrl, $tempZip)
    }
    catch {
        return (Write-Result $false "Download failed: $_")
    }
    finally {
        if ($webClient) { $webClient.Dispose() }
    }

    if (-not (Test-Path -LiteralPath $tempZip)) {
        return (Write-Result $false "Downloaded file not found at '$tempZip'.")
    }

    # ------------------------------------------------------------------
    # Extract to temp directory
    # ------------------------------------------------------------------
    Write-Verbose "Extracting '$tempZip' -> '$tempExtract'"
    try {
        New-Item -ItemType Directory -Path $tempExtract -Force | Out-Null
        Expand-Archive -LiteralPath $tempZip -DestinationPath $tempExtract `
                       -Force -ErrorAction Stop
    }
    catch {
        Remove-Item -LiteralPath $tempZip -Force -ErrorAction SilentlyContinue
        return (Write-Result $false "Extraction failed: $_")
    }

    # Flatten if the ZIP contained a single root folder (common with
    # GitHub source archives, e.g. "DFIR-Updater-v1.2.0/")
    $extractedItems = @(Get-ChildItem -LiteralPath $tempExtract -Force -ErrorAction SilentlyContinue)
    if ($extractedItems.Count -eq 1 -and $extractedItems[0].PSIsContainer) {
        $nested = $extractedItems[0].FullName
        Write-Verbose "Flattening nested folder: '$nested'"
        $flatTemp = Join-Path $script:TempRoot "DFIR-Updater_flat_$timestamp"
        Rename-Item -LiteralPath $nested -NewName (Split-Path $flatTemp -Leaf) -Force
        # The flat folder is now directly inside TempRoot; point to it
        Remove-Item -LiteralPath $tempExtract -Recurse -Force -ErrorAction SilentlyContinue
        $tempExtract = $flatTemp
    }

    # ------------------------------------------------------------------
    # Backup current installation
    # ------------------------------------------------------------------
    $backupDir = Join-Path (Split-Path -Parent $script:ScriptDir) "DFIR-Updater.bak_$timestamp"
    Write-Verbose "Backing up current installation: '$($script:ScriptDir)' -> '$backupDir'"

    if (-not $PSCmdlet.ShouldProcess($script:ScriptDir, "Backup current installation to '$backupDir'")) {
        Remove-Item -LiteralPath $tempExtract -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $tempZip -Force -ErrorAction SilentlyContinue
        return (Write-Result $false 'Backup skipped (WhatIf).')
    }

    try {
        Copy-Item -LiteralPath $script:ScriptDir -Destination $backupDir `
                  -Recurse -Force -ErrorAction Stop
    }
    catch {
        Remove-Item -LiteralPath $tempExtract -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $tempZip -Force -ErrorAction SilentlyContinue
        return (Write-Result $false "Backup failed: $_")
    }

    # ------------------------------------------------------------------
    # Copy updated files, preserving user data
    # ------------------------------------------------------------------
    Write-Verbose 'Copying updated files over current installation.'

    if (-not $PSCmdlet.ShouldProcess($script:ScriptDir, 'Overwrite with updated files')) {
        Remove-Item -LiteralPath $tempExtract -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $tempZip -Force -ErrorAction SilentlyContinue
        return (Write-Result $false 'File copy skipped (WhatIf).')
    }

    try {
        # Build a set of items to preserve (relative names, case-insensitive)
        $preserveSet = @{}
        foreach ($item in $script:PreserveItems) {
            $preserveSet[$item.ToLowerInvariant()] = $true
        }

        # Copy each item from the extracted release into ScriptDir
        $sourceItems = Get-ChildItem -LiteralPath $tempExtract -Force -ErrorAction Stop
        foreach ($item in $sourceItems) {
            $relativeName = $item.Name.ToLowerInvariant()

            # Skip items that should be preserved (do not overwrite)
            if ($preserveSet.ContainsKey($relativeName)) {
                Write-Verbose "Preserving existing '$($item.Name)' - skipped."
                continue
            }

            $destPath = Join-Path $script:ScriptDir $item.Name

            if ($item.PSIsContainer) {
                # Directory: remove the old copy then copy the new one
                if (Test-Path -LiteralPath $destPath) {
                    Remove-Item -LiteralPath $destPath -Recurse -Force -ErrorAction Stop
                }
                Copy-Item -LiteralPath $item.FullName -Destination $destPath `
                          -Recurse -Force -ErrorAction Stop
            }
            else {
                # File: overwrite
                Copy-Item -LiteralPath $item.FullName -Destination $destPath `
                          -Force -ErrorAction Stop
            }
        }

        # Update the VERSION file to reflect the new version
        if ($release.Version) {
            $newVersionPath = Join-Path $script:ScriptDir 'VERSION'
            Set-Content -LiteralPath $newVersionPath -Value $release.Version `
                        -Encoding UTF8 -ErrorAction Stop
            Write-Verbose "Updated VERSION file to '$($release.Version)'."
        }
    }
    catch {
        # Attempt rollback from backup
        Write-Warning "File copy failed: $_. Attempting rollback from backup."
        try {
            # Remove partially copied files
            $rollbackItems = Get-ChildItem -LiteralPath $backupDir -Force -ErrorAction SilentlyContinue
            foreach ($item in $rollbackItems) {
                $destPath = Join-Path $script:ScriptDir $item.Name
                if (Test-Path -LiteralPath $destPath) {
                    Remove-Item -LiteralPath $destPath -Recurse -Force -ErrorAction SilentlyContinue
                }
                Copy-Item -LiteralPath $item.FullName -Destination $destPath `
                          -Recurse -Force -ErrorAction SilentlyContinue
            }
            Write-Verbose 'Rollback completed.'
        }
        catch {
            Write-Warning "Rollback also failed: $_. Manual restore from '$backupDir' may be required."
        }

        Remove-Item -LiteralPath $tempExtract -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $tempZip -Force -ErrorAction SilentlyContinue
        return $false
    }

    # ------------------------------------------------------------------
    # Cleanup temp files and old backups (keep only the latest)
    # ------------------------------------------------------------------
    Remove-Item -LiteralPath $tempExtract -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tempZip -Force -ErrorAction SilentlyContinue

    $parentDir = Split-Path -Parent $script:ScriptDir
    $bakPattern = 'DFIR-Updater.bak_*'
    $backups = @(Get-ChildItem -LiteralPath $parentDir -Filter $bakPattern -Directory -ErrorAction SilentlyContinue |
                 Sort-Object Name -Descending)
    if ($backups.Count -gt 1) {
        foreach ($old in $backups[1..($backups.Count - 1)]) {
            Write-Verbose "Removing old backup: '$($old.FullName)'"
            Remove-Item -LiteralPath $old.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Verbose "DFIR-Updater updated successfully to version $($release.Version)."
    return $true
}

# ---------------------------------------------------------------------------
# 5. Invoke-SilentUpdateCheck
# ---------------------------------------------------------------------------
function Invoke-SilentUpdateCheck {
    <#
    .SYNOPSIS
        Runs a headless update check for all configured DFIR tools.

    .DESCRIPTION
        Designed for unattended or scheduled operation (e.g. Task Scheduler).
        Loads the Update-Checker module, calls Get-AllUpdateStatus to check
        every tool in the configuration, and outputs results to the console.
        Optionally writes results to a log file and auto-installs available
        updates when the -UpdateAll switch is provided.

        This function does not require or display any GUI elements.

    .PARAMETER DriveRoot
        Root path of the DFIR drive.  Defaults to the parent of the
        DFIR-Updater script directory.

    .PARAMETER ConfigPath
        Path to tools-config.json.  Defaults to the standard location.

    .PARAMETER LogPath
        Optional file path to write results.  When omitted, output goes
        only to the console (stdout).

    .PARAMETER GitHubToken
        Optional GitHub personal access token for higher rate limits.

    .PARAMETER UpdateAll
        When specified, automatically installs all available updates after
        the check completes.

    .OUTPUTS
        PSCustomObject[]  The array of tool status objects from
        Get-AllUpdateStatus (same format as the GUI displays).

    .EXAMPLE
        Invoke-SilentUpdateCheck
        # Checks all tools and prints results to the console.

    .EXAMPLE
        Invoke-SilentUpdateCheck -LogPath 'C:\Logs\dfir-update.log' -UpdateAll
        # Checks all tools, logs results, and installs available updates.

    .EXAMPLE
        # Task Scheduler action (run with powershell.exe):
        #   powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "& { . 'D:\DFIR-Updater\modules\Self-Updater.ps1'; Invoke-SilentUpdateCheck -UpdateAll }"
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$DriveRoot,

        [Parameter()]
        [string]$ConfigPath,

        [Parameter()]
        [string]$LogPath,

        [Parameter()]
        [string]$GitHubToken,

        [Parameter()]
        [switch]$UpdateAll
    )

    $runTimestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

    # --- Helper: write output to console and optionally to log ---
    function Write-LogLine ([string]$Line) {
        Write-Output $Line
        if ($LogPath) {
            try {
                Add-Content -LiteralPath $LogPath -Value $Line -Encoding UTF8 -ErrorAction Stop
            }
            catch {
                Write-Warning "Failed to write to log '$LogPath': $_"
            }
        }
    }

    Write-LogLine "=== DFIR-Updater Silent Check - $runTimestamp ==="

    # --- Resolve paths ---
    if (-not $DriveRoot) {
        $DriveRoot = Split-Path -Parent $script:ScriptDir
        if (-not $DriveRoot -or -not (Test-Path $DriveRoot)) {
            $dfirVol = Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.FileSystemLabel -eq 'DFIR' -and $_.DriveLetter } | Select-Object -First 1
            if ($dfirVol) {
                $DriveRoot = "$($dfirVol.DriveLetter):\"
            } else {
                $DriveRoot = 'D:\'
            }
        }
    }

    if (-not $ConfigPath) {
        $ConfigPath = $script:ConfigPath
    }

    Write-LogLine "Drive root : $DriveRoot"
    Write-LogLine "Config     : $ConfigPath"

    # --- Ensure Update-Checker module is loaded ---
    $updateCheckerPath = Join-Path $script:ModuleDir 'Update-Checker.ps1'
    if (-not (Get-Command 'Get-AllUpdateStatus' -ErrorAction SilentlyContinue)) {
        if (Test-Path -LiteralPath $updateCheckerPath) {
            Write-Verbose "Loading Update-Checker module from '$updateCheckerPath'."
            . $updateCheckerPath
        }
        else {
            Write-LogLine "ERROR: Update-Checker module not found at '$updateCheckerPath'."
            Write-Warning "Update-Checker module not found at '$updateCheckerPath'."
            return @()
        }
    }

    # --- Run update check ---
    Write-LogLine ''
    Write-LogLine 'Checking all tools for updates...'

    $statusParams = @{
        ConfigPath = $ConfigPath
    }
    if ($GitHubToken) { $statusParams['GitHubToken'] = $GitHubToken }

    $results = @()
    try {
        $results = @(Get-AllUpdateStatus @statusParams)
    }
    catch {
        Write-LogLine "ERROR: Update check failed: $_"
        Write-Warning "Update check failed: $_"
        return @()
    }

    # --- Format and output results ---
    $updatesAvailable = @($results | Where-Object { $_.UpdateAvailable -eq $true })
    $upToDate         = @($results | Where-Object { $_.UpdateAvailable -eq $false })
    $unknown          = @($results | Where-Object { $null -eq $_.UpdateAvailable })

    Write-LogLine ''
    Write-LogLine "Total tools checked : $($results.Count)"
    Write-LogLine "Up to date          : $($upToDate.Count)"
    Write-LogLine "Updates available   : $($updatesAvailable.Count)"
    Write-LogLine "Check manually      : $($unknown.Count)"

    if ($updatesAvailable.Count -gt 0) {
        Write-LogLine ''
        Write-LogLine '--- Updates Available ---'
        foreach ($tool in $updatesAvailable) {
            Write-LogLine "  $($tool.ToolName): $($tool.CurrentVersion) -> $($tool.LatestVersion)"
        }
    }

    if ($unknown.Count -gt 0) {
        Write-LogLine ''
        Write-LogLine '--- Manual Check Required ---'
        foreach ($tool in $unknown) {
            $note = if ($tool.Notes) { " ($($tool.Notes))" } else { '' }
            Write-LogLine "  $($tool.ToolName)$note"
        }
    }

    # --- Auto-install updates if requested ---
    if ($UpdateAll -and $updatesAvailable.Count -gt 0) {
        Write-LogLine ''
        Write-LogLine '--- Installing Updates ---'

        # Ensure Install-ToolUpdate is available
        if (-not (Get-Command 'Install-ToolUpdate' -ErrorAction SilentlyContinue)) {
            Write-LogLine 'ERROR: Install-ToolUpdate function not available.'
            Write-Warning 'Install-ToolUpdate function not available.'
        }
        else {
            foreach ($tool in $updatesAvailable) {
                if (-not $tool.DownloadUrl) {
                    Write-LogLine "  SKIP $($tool.ToolName): No download URL available."
                    continue
                }

                # Resolve the install path relative to DriveRoot
                $toolConfig = $null
                try {
                    $cfg = Get-Content -LiteralPath $ConfigPath -Raw -ErrorAction Stop |
                           ConvertFrom-Json -ErrorAction Stop
                    $toolConfig = $cfg.tools | Where-Object { $_.name -eq $tool.ToolName } | Select-Object -First 1
                }
                catch {
                    Write-Verbose "Could not reload config for install path: $_"
                }

                $installPath = $null
                if ($toolConfig -and $toolConfig.path) {
                    $installPath = Join-Path $DriveRoot $toolConfig.path
                }

                if (-not $installPath) {
                    Write-LogLine "  SKIP $($tool.ToolName): Cannot determine install path."
                    continue
                }

                Write-LogLine "  Installing $($tool.ToolName) ($($tool.LatestVersion))..."

                try {
                    $installResult = Install-ToolUpdate -ToolName $tool.ToolName `
                                        -DownloadUrl $tool.DownloadUrl `
                                        -InstallPath $installPath `
                                        -InstallType $tool.InstallType

                    if ($installResult.Success) {
                        Write-LogLine "    OK: $($installResult.Message)"
                    }
                    else {
                        Write-LogLine "    FAIL: $($installResult.Message)"
                    }
                }
                catch {
                    Write-LogLine "    ERROR: $_"
                }
            }
        }
    }

    Write-LogLine ''
    Write-LogLine "=== Check complete - $runTimestamp ==="

    return $results
}
