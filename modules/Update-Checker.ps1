#Requires -Version 5.1
<#
.SYNOPSIS
    DFIR tool update checking and installation functions.

.DESCRIPTION
    Provides functions for loading tool configuration, querying GitHub for
    latest releases, comparing version strings, reporting update status for
    all configured tools, and installing updates.
#>

Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
$script:ConfigPath   = Join-Path (Split-Path -Parent $PSScriptRoot) 'tools-config.json'
if (-not (Test-Path $script:ConfigPath)) {
    # Fallback: try the directory of this script's parent
    $script:ModuleDir = $PSScriptRoot
    if (-not $script:ModuleDir) { $script:ModuleDir = Split-Path -Parent $MyInvocation.MyCommand.Definition }
    $script:ConfigPath = Join-Path (Split-Path -Parent $script:ModuleDir) 'tools-config.json'
}
if (-not (Test-Path $script:ConfigPath)) {
    # Last resort: search for DFIR volume, then fall back to D:\
    $dfirVol = Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.FileSystemLabel -eq 'DFIR' -and $_.DriveLetter } | Select-Object -First 1
    if ($dfirVol) {
        $script:ConfigPath = "$($dfirVol.DriveLetter):\DFIR-Updater\tools-config.json"
    } else {
        $script:ConfigPath = 'D:\DFIR-Updater\tools-config.json'
    }
}
$script:UserAgent    = 'DFIR-Updater/1.0 (PowerShell)'
$script:TempRoot     = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), 'DFIR-Updater')

# Ensure TLS 1.2 is available for HTTPS requests
try {
    [System.Net.ServicePointManager]::SecurityProtocol =
        [System.Net.ServicePointManager]::SecurityProtocol -bor
        [System.Net.SecurityProtocolType]::Tls12
} catch { }

# ---------------------------------------------------------------------------
# 1. Get-ToolConfig
# ---------------------------------------------------------------------------
function Get-ToolConfig {
    <#
    .SYNOPSIS
        Loads and parses the tools-config.json file.

    .DESCRIPTION
        Reads the JSON configuration from D:\DFIR-Updater\tools-config.json
        and returns it as a PowerShell object.

    .OUTPUTS
        PSCustomObject  The parsed configuration object.

    .EXAMPLE
        $config = Get-ToolConfig
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$Path = $script:ConfigPath
    )

    Write-Verbose "Loading tool configuration from '$Path'."

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Configuration file not found: $Path"
    }

    try {
        $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        $config = $raw | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Failed to parse configuration file '$Path': $_"
    }

    if ($null -eq $config) {
        throw "Configuration file '$Path' produced a null object."
    }

    Write-Verbose "Configuration loaded successfully."
    return $config
}

# ---------------------------------------------------------------------------
# 2. Get-GitHubLatestRelease
# ---------------------------------------------------------------------------
function Get-GitHubLatestRelease {
    <#
    .SYNOPSIS
        Queries the GitHub API for the latest release of a repository.

    .DESCRIPTION
        Calls https://api.github.com/repos/{owner}/{repo}/releases/latest
        and returns version tag, matching asset URLs, and published date.
        Handles rate-limiting (HTTP 403 with X-RateLimit-Remaining: 0) and
        common error codes (404, etc.).

    .PARAMETER OwnerRepo
        GitHub owner/repo string, e.g. "EricZimmerman/Get-ZimmermanTools".

    .PARAMETER AssetPattern
        Optional regex pattern to filter asset download URLs.
        When omitted, all assets are returned.

    .PARAMETER GitHubToken
        Optional personal access token for authenticated requests
        (raises rate limit from 60 to 5 000 req/hr).

    .OUTPUTS
        PSCustomObject with properties: TagName, Assets, PublishedDate, RateLimitRemaining.

    .EXAMPLE
        Get-GitHubLatestRelease -OwnerRepo 'EricZimmerman/RECmd' -AssetPattern '\.zip$'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[^/]+/[^/]+$')]
        [string]$OwnerRepo,

        [Parameter()]
        [string]$AssetPattern,

        [Parameter()]
        [string]$GitHubToken
    )

    $apiUrl = "https://api.github.com/repos/$OwnerRepo/releases/latest"
    Write-Verbose "Querying GitHub API: $apiUrl"

    $headers = @{
        'Accept'     = 'application/vnd.github+json'
        'User-Agent' = $script:UserAgent
    }

    if ($GitHubToken) {
        $headers['Authorization'] = "Bearer $GitHubToken"
    }

    # Use Invoke-WebRequest for PS 5.1 compatibility (Invoke-RestMethod
    # does not support -ResponseHeadersVariable until PS 7).
    $webResponse = $null
    $rateLimitRemaining = $null

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

            Write-Warning "GitHub API rate limit exceeded for '$OwnerRepo'. Resets at $resetTime."
            return [PSCustomObject]@{
                TagName            = $null
                Assets             = @()
                PublishedDate      = $null
                RateLimitRemaining = 0
                Error              = 'RateLimitExceeded'
            }
        }

        # --- 404: repo or release not found ---
        if ($statusCode -eq 404) {
            Write-Warning "No releases found for '$OwnerRepo' (HTTP 404)."
            return [PSCustomObject]@{
                TagName            = $null
                Assets             = @()
                PublishedDate      = $null
                RateLimitRemaining = $null
                Error              = 'NotFound'
            }
        }

        # --- Any other error ---
        Write-Warning "GitHub API request failed for '$OwnerRepo': $_"
        return [PSCustomObject]@{
            TagName            = $null
            Assets             = @()
            PublishedDate      = $null
            RateLimitRemaining = $null
            Error              = "$($_.Exception.Message)"
        }
    }

    # --- Parse response body ---
    $response = $webResponse.Content | ConvertFrom-Json

    # --- Parse rate-limit info from response headers ---
    try {
        $rlHeader = $webResponse.Headers['X-RateLimit-Remaining']
        if ($rlHeader) {
            $rateLimitRemaining = [int]$rlHeader
            Write-Verbose "GitHub API rate-limit remaining: $rateLimitRemaining"
        }
    } catch { }

    # --- Build asset list ---
    $assets = @()
    $responseAssets = $response.PSObject.Properties['assets']
    if ($responseAssets -and $responseAssets.Value) {
        foreach ($asset in $response.assets) {
            $include = $true
            if ($AssetPattern) {
                $include = $asset.browser_download_url -match $AssetPattern
            }
            if ($include) {
                $assets += [PSCustomObject]@{
                    Name        = $asset.name
                    DownloadUrl = $asset.browser_download_url
                    Size        = $asset.size
                    ContentType = $asset.content_type
                }
            }
        }
    }

    $publishedDate = $null
    $pubProp = $response.PSObject.Properties['published_at']
    if ($pubProp -and $pubProp.Value) {
        $publishedDate = [datetime]::Parse($response.published_at)
    }

    $tagName = $null
    $tagProp = $response.PSObject.Properties['tag_name']
    if ($tagProp) { $tagName = $tagProp.Value }

    return [PSCustomObject]@{
        TagName            = $tagName
        Assets             = $assets
        PublishedDate      = $publishedDate
        RateLimitRemaining = $rateLimitRemaining
        Error              = $null
    }
}

# ---------------------------------------------------------------------------
# 3. Compare-Versions
# ---------------------------------------------------------------------------
function Compare-Versions {
    <#
    .SYNOPSIS
        Compares two version strings and returns $true when an update is available.

    .DESCRIPTION
        Strips a leading "v" (case-insensitive), splits on "." and compares
        each numeric segment left-to-right. Returns $true when LatestVersion
        is greater than CurrentVersion.

    .PARAMETER CurrentVersion
        The currently-installed version string (e.g. "v3.11.307" or "6.2.6").

    .PARAMETER LatestVersion
        The latest available version string.

    .OUTPUTS
        System.Boolean  $true if LatestVersion > CurrentVersion.

    .EXAMPLE
        Compare-Versions -CurrentVersion 'v3.11.307' -LatestVersion 'v3.12.0'
        # Returns $true
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$CurrentVersion,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$LatestVersion
    )

    if ([string]::IsNullOrWhiteSpace($CurrentVersion) -or
        [string]::IsNullOrWhiteSpace($LatestVersion)) {
        Write-Verbose 'One or both version strings are empty; returning $false.'
        return $false
    }

    # Strip leading "v" or "V" and normalize hyphens to dots (e.g. "3-0" → "3.0")
    $current = ($CurrentVersion -replace '^[vV]', '') -replace '-', '.'
    $latest  = ($LatestVersion  -replace '^[vV]', '') -replace '-', '.'

    # Split into numeric segments; treat non-numeric segments as 0
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
            return $true
        }
        if ($l -lt $c) {
            return $false
        }
    }

    # Versions are identical
    return $false
}

# ---------------------------------------------------------------------------
# 3b. Get-WebLatestVersion
# ---------------------------------------------------------------------------
function Get-WebLatestVersion {
    <#
    .SYNOPSIS
        Scrapes a web page for the latest version number using a regex pattern.

    .DESCRIPTION
        Downloads the HTML content of a URL and applies a regex pattern to find
        version strings. Returns the highest version found. Useful for tools
        that do not publish GitHub releases but display version info on their
        download page (e.g. NirSoft, exiftool.org, nmap.org).

    .PARAMETER Url
        The URL to fetch and search for version information.

    .PARAMETER VersionPattern
        Regex pattern with a capture group for the version string.
        e.g. 'exiftool-([\d.]+)' or 'nmap-([\d.]+)-setup\.exe'

    .OUTPUTS
        PSCustomObject with Version (string or $null) and Error (string or $null).

    .EXAMPLE
        Get-WebLatestVersion -Url 'https://exiftool.org' -VersionPattern 'exiftool-([\d.]+)'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Url,

        [Parameter(Mandatory)]
        [string]$VersionPattern
    )

    Write-Verbose "Scraping '$Url' for version pattern: $VersionPattern"

    $html = $null
    try {
        $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 10 `
                        -UserAgent $script:UserAgent -ErrorAction Stop
        $html = $response.Content
    }
    catch {
        Write-Warning "Failed to fetch '$Url': $_"
        return [PSCustomObject]@{
            Version = $null
            Error   = "Fetch failed: $($_.Exception.Message)"
        }
    }

    if ([string]::IsNullOrWhiteSpace($html)) {
        return [PSCustomObject]@{
            Version = $null
            Error   = 'Empty response from server.'
        }
    }

    # Find all version matches in the page
    $regexMatches = [regex]::Matches($html, $VersionPattern)
    if ($regexMatches.Count -eq 0) {
        return [PSCustomObject]@{
            Version = $null
            Error   = 'No version match found on page.'
        }
    }

    # Extract unique version strings from capture group 1
    $versions = @{}
    foreach ($m in $regexMatches) {
        if ($m.Groups.Count -gt 1 -and $m.Groups[1].Value) {
            $ver = $m.Groups[1].Value
            if (-not $versions.ContainsKey($ver)) {
                $versions[$ver] = $true
            }
        }
    }

    if ($versions.Count -eq 0) {
        return [PSCustomObject]@{
            Version = $null
            Error   = 'Pattern matched but no capture group found.'
        }
    }

    # Sort versions descending and return the highest
    $sorted = @($versions.Keys) | Sort-Object {
        $normalized = ($_ -replace '-', '.').Split('.')
        $padded = @()
        foreach ($p in $normalized) {
            $n = 0
            if ([int]::TryParse($p, [ref]$n)) {
                $padded += $n.ToString().PadLeft(10, '0')
            } else {
                $padded += $p.PadLeft(10, '0')
            }
        }
        while ($padded.Count -lt 5) { $padded += '0000000000' }
        $padded -join '.'
    } -Descending

    $highest = $sorted | Select-Object -First 1

    Write-Verbose "Highest version found: $highest (from $($versions.Count) unique match(es))"

    return [PSCustomObject]@{
        Version = $highest
        Error   = $null
    }
}

# ---------------------------------------------------------------------------
# 4. Get-AllUpdateStatus
# ---------------------------------------------------------------------------
function Get-AllUpdateStatus {
    <#
    .SYNOPSIS
        Checks every tool in the configuration for available updates.

    .DESCRIPTION
        Iterates through all tools defined in tools-config.json.  For tools
        with a GitHub source, the latest release is queried via the API.
        For web-only tools the status is flagged as "check manually".

        Returns an array of status objects.

    .PARAMETER ConfigPath
        Path to the tools-config.json file.  Defaults to
        D:\DFIR-Updater\tools-config.json.

    .PARAMETER GitHubToken
        Optional GitHub personal access token for higher rate limits.

    .OUTPUTS
        PSCustomObject[]  One object per tool with update status details.

    .EXAMPLE
        Get-AllUpdateStatus | Format-Table -AutoSize
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$ConfigPath = $script:ConfigPath,

        [Parameter()]
        [string]$GitHubToken
    )

    $config = Get-ToolConfig -Path $ConfigPath
    $results = [System.Collections.Generic.List[PSCustomObject]]::new()

    # The config is expected to have a "tools" array.  Each tool object should
    # contain at minimum: name, currentVersion, sourceType, installType.
    # GitHub tools additionally have: githubRepo, assetPattern.
    # Web tools additionally have: downloadUrl.
    $tools = $config.tools
    if (-not $tools) {
        Write-Warning 'No tools found in configuration.'
        return @()
    }

    $toolCount = @($tools).Count
    $index = 0

    foreach ($tool in $tools) {
        $index++
        $toolName       = $tool.name
        $currentVersion = $tool.current_version
        $sourceType     = $tool.source_type        # "github" or "web"
        $installType    = $tool.install_type        # "extract_zip", "copy_exe", "manual"

        Write-Verbose "[$index/$toolCount] Checking $toolName ..."

        $latestVersion  = $null
        $updateAvail    = $null
        $downloadUrl    = $null
        $notes          = ''

        switch ($sourceType) {
            'github' {
                $releaseParams = @{
                    OwnerRepo = $tool.github_repo
                }
                if ($tool.github_asset_pattern) {
                    $releaseParams['AssetPattern'] = $tool.github_asset_pattern
                }
                if ($GitHubToken) {
                    $releaseParams['GitHubToken'] = $GitHubToken
                }

                $release = Get-GitHubLatestRelease @releaseParams

                if ($release.Error) {
                    $notes = "GitHub API error: $($release.Error)"
                    $updateAvail = $null
                }
                else {
                    $latestVersion = $release.TagName
                    $updateAvail   = Compare-Versions -CurrentVersion $currentVersion `
                                                      -LatestVersion  $latestVersion

                    if ($release.Assets.Count -gt 0) {
                        $downloadUrl = ($release.Assets | Select-Object -First 1).DownloadUrl
                    }
                    else {
                        $notes = 'No matching assets found in latest release.'
                    }
                }

                # Warn when rate-limit is getting low
                if ($release.RateLimitRemaining -ne $null -and $release.RateLimitRemaining -lt 10) {
                    Write-Warning "GitHub API rate-limit is low ($($release.RateLimitRemaining) remaining)."
                }
            }

            'web' {
                $downloadUrl    = $tool.download_url
                $versionPattern = $tool.version_pattern

                # Prefer version_check_url over download_url for scraping
                $checkUrl = $null
                $checkUrlProp = $tool.PSObject.Properties['version_check_url']
                if ($checkUrlProp -and $checkUrlProp.Value) {
                    $checkUrl = $checkUrlProp.Value
                } else {
                    $checkUrl = $downloadUrl
                }

                # Attempt automated web scraping if we have a URL and regex pattern
                if ($checkUrl -and $versionPattern) {
                    $webResult = Get-WebLatestVersion -Url $checkUrl -VersionPattern $versionPattern

                    if ($webResult.Version) {
                        $latestVersion = $webResult.Version

                        if ($currentVersion) {
                            $updateAvail = Compare-Versions -CurrentVersion $currentVersion `
                                                            -LatestVersion  $latestVersion
                        } else {
                            # Found latest but don't know current — can't compare
                            $updateAvail = $null
                            $notes = "Latest version found: $latestVersion. Current version unknown."
                        }
                    } else {
                        # Scraping failed — fall back to manual
                        $notes = "Auto-check failed ($($webResult.Error)). Check manually."
                        $updateAvail = $null
                    }
                } else {
                    # No pattern or URL available for scraping
                    if (-not $currentVersion) {
                        $notes = 'No current version recorded - check manually.'
                    } elseif (-not $versionPattern) {
                        $notes = 'No version pattern configured - check manually.'
                    } elseif (-not $checkUrl) {
                        $notes = 'No check URL available - check manually.'
                    } else {
                        $notes = 'Web source - check manually for updates.'
                    }
                    $updateAvail = $null
                }
            }

            default {
                $notes = "Unknown source type: $sourceType"
            }
        }

        $results.Add([PSCustomObject]@{
            ToolName        = $toolName
            CurrentVersion  = $currentVersion
            LatestVersion   = $latestVersion
            UpdateAvailable = $updateAvail
            DownloadUrl     = $downloadUrl
            SourceType      = $sourceType
            InstallType     = $installType
            Notes           = $notes
        })
    }

    return $results.ToArray()
}

# ---------------------------------------------------------------------------
# 5. Install-ToolUpdate
# ---------------------------------------------------------------------------
function Install-ToolUpdate {
    <#
    .SYNOPSIS
        Downloads and installs a tool update.

    .DESCRIPTION
        Supports three install types:
          - extract_zip : downloads a ZIP to a temp folder, backs up the
                          current tool directory, then extracts the new files.
          - copy_exe    : downloads a single executable, backs up the current
                          file, and writes the new one.
          - manual      : opens the download URL in the default browser.

        A ".bak" backup of the existing tool location is created before any
        files are overwritten.

    .PARAMETER ToolName
        Display name of the tool (used for logging).

    .PARAMETER DownloadUrl
        Direct download URL for the update artifact.

    .PARAMETER InstallPath
        Destination directory (extract_zip) or file path (copy_exe).

    .PARAMETER InstallType
        One of: extract_zip, copy_exe, manual.

    .OUTPUTS
        PSCustomObject with Success (bool) and Message (string).

    .EXAMPLE
        Install-ToolUpdate -ToolName 'RECmd' `
                           -DownloadUrl 'https://github.com/.../RECmd.zip' `
                           -InstallPath 'D:\Tools\RECmd' `
                           -InstallType 'extract_zip'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$ToolName,

        [Parameter(Mandatory)]
        [string]$DownloadUrl,

        [Parameter(Mandatory)]
        [string]$InstallPath,

        [Parameter(Mandatory)]
        [ValidateSet('extract_zip', 'copy_exe', 'manual')]
        [string]$InstallType
    )

    # --- Helper: return a result object ---
    function New-Result ([bool]$Success, [string]$Message) {
        [PSCustomObject]@{ Success = $Success; Message = $Message }
    }

    Write-Verbose "Installing update for '$ToolName' (type: $InstallType)."

    # ------------------------------------------------------------------
    # manual: just open the URL
    # ------------------------------------------------------------------
    if ($InstallType -eq 'manual') {
        Write-Verbose "Opening download URL in default browser: $DownloadUrl"
        try {
            Start-Process $DownloadUrl -ErrorAction Stop
            return New-Result $true "Opened download URL for '$ToolName' in default browser."
        }
        catch {
            return New-Result $false "Failed to open URL for '$ToolName': $_"
        }
    }

    # ------------------------------------------------------------------
    # Validate download URL
    # ------------------------------------------------------------------
    if ([string]::IsNullOrWhiteSpace($DownloadUrl)) {
        return New-Result $false "No download URL provided for '$ToolName'."
    }

    # ------------------------------------------------------------------
    # Prepare temp directory
    # ------------------------------------------------------------------
    if (-not (Test-Path -LiteralPath $script:TempRoot)) {
        New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null
    }

    $timestamp   = Get-Date -Format 'yyyyMMdd_HHmmss'
    $tempFile    = Join-Path $script:TempRoot "$ToolName`_$timestamp`_$(Split-Path $DownloadUrl -Leaf)"

    # ------------------------------------------------------------------
    # Download with progress
    # ------------------------------------------------------------------
    Write-Verbose "Downloading '$DownloadUrl' -> '$tempFile'"
    try {
        $webClient = New-Object System.Net.WebClient
        $webClient.Headers.Add('User-Agent', $script:UserAgent)

        # Wire up progress reporting
        $downloadComplete = $false
        $eventId = "DFIR_Download_$timestamp"

        Register-ObjectEvent -InputObject $webClient `
            -EventName DownloadProgressChanged `
            -SourceIdentifier $eventId `
            -Action {
                $pct = $EventArgs.ProgressPercentage
                Write-Progress -Activity "Downloading $ToolName" `
                               -Status "$pct% complete" `
                               -PercentComplete $pct
            } | Out-Null

        if ($PSCmdlet.ShouldProcess($DownloadUrl, "Download update for $ToolName")) {
            $webClient.DownloadFile($DownloadUrl, $tempFile)
        }
        else {
            Unregister-Event -SourceIdentifier $eventId -ErrorAction SilentlyContinue
            return New-Result $false 'Download skipped (WhatIf).'
        }

        Unregister-Event -SourceIdentifier $eventId -ErrorAction SilentlyContinue
        Write-Progress -Activity "Downloading $ToolName" -Completed
    }
    catch {
        Write-Progress -Activity "Downloading $ToolName" -Completed
        return New-Result $false "Download failed for '$ToolName': $_"
    }
    finally {
        if ($webClient) { $webClient.Dispose() }
    }

    if (-not (Test-Path -LiteralPath $tempFile)) {
        return New-Result $false "Downloaded file not found at '$tempFile'."
    }

    # ------------------------------------------------------------------
    # Backup existing installation
    # ------------------------------------------------------------------
    $backupPath = "$InstallPath.bak_$timestamp"
    if (Test-Path -LiteralPath $InstallPath) {
        Write-Verbose "Backing up existing installation: '$InstallPath' -> '$backupPath'"
        try {
            if (Test-Path -LiteralPath $InstallPath -PathType Container) {
                Copy-Item -LiteralPath $InstallPath -Destination $backupPath `
                          -Recurse -Force -ErrorAction Stop
            }
            else {
                Copy-Item -LiteralPath $InstallPath -Destination $backupPath `
                          -Force -ErrorAction Stop
            }
        }
        catch {
            return New-Result $false "Backup failed for '$ToolName': $_"
        }
    }

    # ------------------------------------------------------------------
    # Install based on type
    # ------------------------------------------------------------------
    switch ($InstallType) {
        'extract_zip' {
            Write-Verbose "Extracting '$tempFile' -> '$InstallPath'"
            try {
                if (-not (Test-Path -LiteralPath $InstallPath)) {
                    New-Item -ItemType Directory -Path $InstallPath -Force | Out-Null
                }

                # Use Expand-Archive; -Force overwrites existing files
                Expand-Archive -LiteralPath $tempFile -DestinationPath $InstallPath `
                               -Force -ErrorAction Stop

                Write-Verbose "Extraction complete for '$ToolName'."
                return New-Result $true "Successfully updated '$ToolName' (extract_zip) to '$InstallPath'. Backup at '$backupPath'."
            }
            catch {
                # Attempt rollback
                Write-Warning "Extraction failed for '$ToolName'. Attempting rollback."
                if (Test-Path -LiteralPath $backupPath) {
                    try {
                        Remove-Item -LiteralPath $InstallPath -Recurse -Force -ErrorAction SilentlyContinue
                        Rename-Item -LiteralPath $backupPath -NewName (Split-Path $InstallPath -Leaf) -ErrorAction Stop
                    }
                    catch {
                        Write-Warning "Rollback also failed: $_"
                    }
                }
                return New-Result $false "Extraction failed for '$ToolName': $_"
            }
            finally {
                Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
            }
        }

        'copy_exe' {
            Write-Verbose "Copying '$tempFile' -> '$InstallPath'"
            try {
                $parentDir = Split-Path $InstallPath -Parent
                if (-not (Test-Path -LiteralPath $parentDir)) {
                    New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
                }

                Copy-Item -LiteralPath $tempFile -Destination $InstallPath `
                          -Force -ErrorAction Stop

                Write-Verbose "Copy complete for '$ToolName'."
                return New-Result $true "Successfully updated '$ToolName' (copy_exe) to '$InstallPath'. Backup at '$backupPath'."
            }
            catch {
                # Attempt rollback
                Write-Warning "Copy failed for '$ToolName'. Attempting rollback."
                if (Test-Path -LiteralPath $backupPath) {
                    try {
                        Remove-Item -LiteralPath $InstallPath -Force -ErrorAction SilentlyContinue
                        Rename-Item -LiteralPath $backupPath -NewName (Split-Path $InstallPath -Leaf) -ErrorAction Stop
                    }
                    catch {
                        Write-Warning "Rollback also failed: $_"
                    }
                }
                return New-Result $false "Copy failed for '$ToolName': $_"
            }
            finally {
                Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
