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
                    # GitHub API failed — try web fallback if tool has a download page and version pattern
                    if ($tool.download_url -and $tool.version_pattern) {
                        $webFallback = Get-WebLatestVersion -Url $tool.download_url -VersionPattern $tool.version_pattern
                        if ($webFallback.Version) {
                            $latestVersion = $webFallback.Version
                            $updateAvail   = Compare-Versions -CurrentVersion $currentVersion `
                                                              -LatestVersion  $latestVersion
                            $downloadUrl   = $tool.download_url
                            $notes         = "Checked via web (GitHub unavailable)."
                        } else {
                            $notes = "GitHub API error: $($release.Error)"
                            $updateAvail = $null
                        }
                    } else {
                        $notes = "GitHub API error: $($release.Error)"
                        $updateAvail = $null
                    }
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

                        # Build download URL from template if available
                        $templateProp = $tool.PSObject.Properties['download_url_template']
                        if ($templateProp -and $templateProp.Value -and $latestVersion) {
                            $downloadUrl = $templateProp.Value -replace '\{version\}', $latestVersion
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
# 4b. Get-AllUpdateStatusParallel
# ---------------------------------------------------------------------------
function Get-AllUpdateStatusParallel {
    <#
    .SYNOPSIS
        Checks every tool in the configuration for available updates using
        parallel runspaces for faster execution.

    .DESCRIPTION
        Performs the same update checks as Get-AllUpdateStatus but uses a
        RunspacePool (default throttle limit of 5) to query multiple tools
        concurrently.  Each runspace executes the version check logic for
        one tool.  Results are collected and returned in the same format as
        Get-AllUpdateStatus.

        If RunspacePool creation fails, the function falls back to the
        sequential Get-AllUpdateStatus automatically.

    .PARAMETER ConfigPath
        Path to the tools-config.json file.  Defaults to
        D:\DFIR-Updater\tools-config.json.

    .PARAMETER GitHubToken
        Optional GitHub personal access token for higher rate limits.

    .PARAMETER ThrottleLimit
        Maximum number of concurrent runspaces.  Defaults to 5.

    .OUTPUTS
        PSCustomObject[]  One object per tool with update status details,
        identical in schema to Get-AllUpdateStatus output.

    .EXAMPLE
        Get-AllUpdateStatusParallel -ThrottleLimit 8 | Format-Table -AutoSize
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$ConfigPath = $script:ConfigPath,

        [Parameter()]
        [string]$GitHubToken,

        [Parameter()]
        [ValidateRange(1, 20)]
        [int]$ThrottleLimit = 5
    )

    $config = Get-ToolConfig -Path $ConfigPath
    $tools  = $config.tools
    if (-not $tools) {
        Write-Warning 'No tools found in configuration.'
        return @()
    }

    # ------------------------------------------------------------------
    # Attempt to create a RunspacePool; fall back to sequential on failure
    # ------------------------------------------------------------------
    $pool = $null
    try {
        $sessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
        $pool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(
            1, $ThrottleLimit, $sessionState, $Host)
        $pool.Open()
        Write-Verbose "RunspacePool created with throttle limit $ThrottleLimit."
    }
    catch {
        Write-Warning "Failed to create RunspacePool: $_  Falling back to sequential check."
        $fallbackParams = @{ ConfigPath = $ConfigPath }
        if ($GitHubToken) { $fallbackParams['GitHubToken'] = $GitHubToken }
        return Get-AllUpdateStatus @fallbackParams
    }

    # ------------------------------------------------------------------
    # Script block executed inside each runspace
    # ------------------------------------------------------------------
    $scriptBlock = {
        param(
            [object]$Tool,
            [string]$GitHubToken,
            [string]$UserAgent
        )

        # --- TLS 1.2 ---
        try {
            [System.Net.ServicePointManager]::SecurityProtocol =
                [System.Net.ServicePointManager]::SecurityProtocol -bor
                [System.Net.SecurityProtocolType]::Tls12
        } catch { }

        $toolName       = $Tool.name
        $currentVersion = $Tool.current_version
        $sourceType     = $Tool.source_type
        $installType    = $Tool.install_type

        $latestVersion  = $null
        $updateAvail    = $null
        $downloadUrl    = $null
        $notes          = ''

        # --- Inline Compare-Versions (runspaces lack module scope) ---
        function Local:Compare-Ver ([string]$Current, [string]$Latest) {
            if ([string]::IsNullOrWhiteSpace($Current) -or
                [string]::IsNullOrWhiteSpace($Latest)) { return $false }
            $c = ($Current -replace '^[vV]', '') -replace '-', '.'
            $l = ($Latest  -replace '^[vV]', '') -replace '-', '.'
            $cp = $c.Split('.') | ForEach-Object { $n = 0; if ([int]::TryParse($_, [ref]$n)) { $n } else { 0 } }
            $lp = $l.Split('.') | ForEach-Object { $n = 0; if ([int]::TryParse($_, [ref]$n)) { $n } else { 0 } }
            $max = [Math]::Max($cp.Count, $lp.Count)
            for ($i = 0; $i -lt $max; $i++) {
                $cv = if ($i -lt $cp.Count) { $cp[$i] } else { 0 }
                $lv = if ($i -lt $lp.Count) { $lp[$i] } else { 0 }
                if ($lv -gt $cv) { return $true  }
                if ($lv -lt $cv) { return $false }
            }
            return $false
        }

        # --- Inline web scraper ---
        function Local:Get-WebVer ([string]$Url, [string]$Pattern, [string]$UA) {
            try {
                $resp = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 10 `
                            -UserAgent $UA -ErrorAction Stop
                $html = $resp.Content
            } catch {
                return [PSCustomObject]@{ Version = $null; Error = "$_" }
            }
            if ([string]::IsNullOrWhiteSpace($html)) {
                return [PSCustomObject]@{ Version = $null; Error = 'Empty response.' }
            }
            $matches_ = [regex]::Matches($html, $Pattern)
            if ($matches_.Count -eq 0) {
                return [PSCustomObject]@{ Version = $null; Error = 'No match.' }
            }
            $vers = @{}
            foreach ($m in $matches_) {
                if ($m.Groups.Count -gt 1 -and $m.Groups[1].Value) {
                    $vers[$m.Groups[1].Value] = $true
                }
            }
            if ($vers.Count -eq 0) {
                return [PSCustomObject]@{ Version = $null; Error = 'No capture group.' }
            }
            $sorted = @($vers.Keys) | Sort-Object {
                $norm = ($_ -replace '-', '.').Split('.')
                $pad = @()
                foreach ($p in $norm) {
                    $n = 0
                    if ([int]::TryParse($p, [ref]$n)) { $pad += $n.ToString().PadLeft(10, '0') }
                    else { $pad += $p.PadLeft(10, '0') }
                }
                while ($pad.Count -lt 5) { $pad += '0000000000' }
                $pad -join '.'
            } -Descending
            return [PSCustomObject]@{ Version = $sorted[0]; Error = $null }
        }

        switch ($sourceType) {
            'github' {
                $apiUrl  = "https://api.github.com/repos/$($Tool.github_repo)/releases/latest"
                $headers = @{
                    'Accept'     = 'application/vnd.github+json'
                    'User-Agent' = $UserAgent
                }
                if ($GitHubToken) { $headers['Authorization'] = "Bearer $GitHubToken" }

                try {
                    $webResp  = Invoke-WebRequest -Uri $apiUrl -Headers $headers `
                                    -UseBasicParsing -ErrorAction Stop
                    $response = $webResp.Content | ConvertFrom-Json

                    $latestVersion = $null
                    $tagProp = $response.PSObject.Properties['tag_name']
                    if ($tagProp) { $latestVersion = $tagProp.Value }

                    $updateAvail = Local:Compare-Ver $currentVersion $latestVersion

                    $assets = @()
                    $aProp  = $response.PSObject.Properties['assets']
                    if ($aProp -and $aProp.Value) {
                        foreach ($a in $response.assets) {
                            $inc = $true
                            if ($Tool.github_asset_pattern) {
                                $inc = $a.browser_download_url -match $Tool.github_asset_pattern
                            }
                            if ($inc) { $assets += $a.browser_download_url }
                        }
                    }
                    if ($assets.Count -gt 0) { $downloadUrl = $assets[0] }
                    else { $notes = 'No matching assets found in latest release.' }
                }
                catch {
                    # Try web fallback
                    if ($Tool.download_url -and $Tool.version_pattern) {
                        $wb = Local:Get-WebVer $Tool.download_url $Tool.version_pattern $UserAgent
                        if ($wb.Version) {
                            $latestVersion = $wb.Version
                            $updateAvail   = Local:Compare-Ver $currentVersion $latestVersion
                            $downloadUrl   = $Tool.download_url
                            $notes         = 'Checked via web (GitHub unavailable).'
                        } else {
                            $notes = "GitHub API error: $_"
                        }
                    } else {
                        $notes = "GitHub API error: $_"
                    }
                }
            }

            'web' {
                $downloadUrl    = $Tool.download_url
                $versionPattern = $Tool.version_pattern

                $checkUrl = $null
                $cuProp   = $Tool.PSObject.Properties['version_check_url']
                if ($cuProp -and $cuProp.Value) { $checkUrl = $cuProp.Value }
                else { $checkUrl = $downloadUrl }

                if ($checkUrl -and $versionPattern) {
                    $webResult = Local:Get-WebVer $checkUrl $versionPattern $UserAgent
                    if ($webResult.Version) {
                        $latestVersion = $webResult.Version
                        if ($currentVersion) {
                            $updateAvail = Local:Compare-Ver $currentVersion $latestVersion
                        } else {
                            $notes = "Latest version found: $latestVersion. Current version unknown."
                        }
                        $tplProp = $Tool.PSObject.Properties['download_url_template']
                        if ($tplProp -and $tplProp.Value -and $latestVersion) {
                            $downloadUrl = $tplProp.Value -replace '\{version\}', $latestVersion
                        }
                    } else {
                        $notes = "Auto-check failed ($($webResult.Error)). Check manually."
                    }
                } else {
                    if (-not $currentVersion) { $notes = 'No current version recorded - check manually.' }
                    elseif (-not $versionPattern) { $notes = 'No version pattern configured - check manually.' }
                    elseif (-not $checkUrl) { $notes = 'No check URL available - check manually.' }
                    else { $notes = 'Web source - check manually for updates.' }
                }
            }

            default {
                $notes = "Unknown source type: $sourceType"
            }
        }

        return [PSCustomObject]@{
            ToolName        = $toolName
            CurrentVersion  = $currentVersion
            LatestVersion   = $latestVersion
            UpdateAvailable = $updateAvail
            DownloadUrl     = $downloadUrl
            SourceType      = $sourceType
            InstallType     = $installType
            Notes           = $notes
        }
    }

    # ------------------------------------------------------------------
    # Launch one runspace per tool
    # ------------------------------------------------------------------
    $runspaces = [System.Collections.Generic.List[PSCustomObject]]::new()
    $toolList  = @($tools)
    $toolCount = $toolList.Count

    Write-Verbose "Launching $toolCount parallel version checks (throttle: $ThrottleLimit)."

    foreach ($tool in $toolList) {
        $ps = [PowerShell]::Create()
        $ps.RunspacePool = $pool

        [void]$ps.AddScript($scriptBlock)
        [void]$ps.AddParameter('Tool',        $tool)
        [void]$ps.AddParameter('GitHubToken',  $GitHubToken)
        [void]$ps.AddParameter('UserAgent',    $script:UserAgent)

        $handle = $ps.BeginInvoke()

        $runspaces.Add([PSCustomObject]@{
            PowerShell = $ps
            Handle     = $handle
            ToolName   = $tool.name
        })
    }

    # ------------------------------------------------------------------
    # Collect results
    # ------------------------------------------------------------------
    $results = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($rs in $runspaces) {
        try {
            $output = $rs.PowerShell.EndInvoke($rs.Handle)
            if ($output -and $output.Count -gt 0) {
                $results.Add($output[0])
            }

            if ($rs.PowerShell.Streams.Error.Count -gt 0) {
                foreach ($err in $rs.PowerShell.Streams.Error) {
                    Write-Warning "[$($rs.ToolName)] $err"
                }
            }
        }
        catch {
            Write-Warning "Failed to collect result for '$($rs.ToolName)': $_"
            $results.Add([PSCustomObject]@{
                ToolName        = $rs.ToolName
                CurrentVersion  = $null
                LatestVersion   = $null
                UpdateAvailable = $null
                DownloadUrl     = $null
                SourceType      = $null
                InstallType     = $null
                Notes           = "Parallel check failed: $_"
            })
        }
        finally {
            $rs.PowerShell.Dispose()
        }
    }

    # ------------------------------------------------------------------
    # Clean up pool
    # ------------------------------------------------------------------
    try {
        $pool.Close()
        $pool.Dispose()
    } catch { }

    Write-Verbose "Parallel update check complete. $($results.Count) tool(s) checked."
    return $results.ToArray()
}

# ---------------------------------------------------------------------------
# 4c. Invoke-NativeToolUpdate
# ---------------------------------------------------------------------------
function Invoke-NativeToolUpdate {
    <#
    .SYNOPSIS
        Executes a tool's built-in (native) update command after installation.

    .DESCRIPTION
        Some tools ship with a self-update or sync command (e.g.
        "EvtxECmd.exe --sync", "RECmd.exe --sync",
        "zircolite.exe --update-rules").  When the tool configuration
        contains a "native_update_cmd" field, this function resolves the
        command path relative to the tool's install directory and runs it.

    .PARAMETER ToolConfig
        A tool configuration PSCustomObject from tools-config.json.
        Must contain "name" and "path" properties.  The optional
        "native_update_cmd" property triggers execution (e.g.
        "EvtxECmd.exe --sync").

    .PARAMETER TimeoutSeconds
        Maximum time in seconds to wait for the native command to finish.
        Defaults to 120.

    .OUTPUTS
        PSCustomObject with properties:
          Success  [bool]   - Whether the command completed successfully.
          Output   [string] - Combined stdout/stderr from the command.
          Command  [string] - The full command line that was executed.

    .EXAMPLE
        $tool = ($config.tools | Where-Object name -eq 'EvtxECmd')
        Invoke-NativeToolUpdate -ToolConfig $tool
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$ToolConfig,

        [Parameter()]
        [ValidateRange(1, 3600)]
        [int]$TimeoutSeconds = 120
    )

    $toolName = $ToolConfig.name

    # Check for native_update_cmd property
    $cmdProp = $ToolConfig.PSObject.Properties['native_update_cmd']
    if (-not $cmdProp -or [string]::IsNullOrWhiteSpace($cmdProp.Value)) {
        Write-Verbose "No native_update_cmd configured for '$toolName'. Skipping."
        return [PSCustomObject]@{
            Success = $true
            Output  = 'No native update command configured.'
            Command = $null
        }
    }

    $nativeCmd = $cmdProp.Value.Trim()
    Write-Verbose "Native update command for '$toolName': $nativeCmd"

    # Resolve install directory from tool path
    $toolPath = $ToolConfig.path
    if (-not [System.IO.Path]::IsPathRooted($toolPath)) {
        # tools-config.json stores relative paths; resolve against DFIR drive
        $dfirVol = Get-Volume -ErrorAction SilentlyContinue |
                   Where-Object { $_.FileSystemLabel -eq 'DFIR' -and $_.DriveLetter } |
                   Select-Object -First 1
        $driveLetter = if ($dfirVol) { $dfirVol.DriveLetter } else { 'D' }
        $toolPath = Join-Path "$($driveLetter):\" $toolPath
    }

    # Determine install directory (if path points to a file, use its parent)
    if (Test-Path -LiteralPath $toolPath -PathType Leaf) {
        $installDir = Split-Path $toolPath -Parent
    } else {
        $installDir = $toolPath
    }

    if (-not (Test-Path -LiteralPath $installDir)) {
        Write-Warning "Install directory not found for '$toolName': $installDir"
        return [PSCustomObject]@{
            Success = $false
            Output  = "Install directory not found: $installDir"
            Command = $nativeCmd
        }
    }

    # Parse the command: first token is the executable, rest are arguments
    $cmdParts = $nativeCmd -split '\s+', 2
    $exeName  = $cmdParts[0]
    $cmdArgs  = if ($cmdParts.Count -gt 1) { $cmdParts[1] } else { '' }

    # Resolve executable path relative to install directory
    $exePath = Join-Path $installDir $exeName
    if (-not (Test-Path -LiteralPath $exePath)) {
        Write-Warning "Native command executable not found: $exePath"
        return [PSCustomObject]@{
            Success = $false
            Output  = "Executable not found: $exePath"
            Command = $nativeCmd
        }
    }

    $fullCommand = "`"$exePath`" $cmdArgs"
    Write-Verbose "Executing: $fullCommand (timeout: ${TimeoutSeconds}s)"

    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName               = $exePath
        $psi.Arguments              = $cmdArgs
        $psi.WorkingDirectory       = $installDir
        $psi.UseShellExecute        = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.CreateNoWindow         = $true

        $proc = [System.Diagnostics.Process]::Start($psi)

        # Read output streams to avoid deadlocks
        $stdout = $proc.StandardOutput.ReadToEndAsync()
        $stderr = $proc.StandardError.ReadToEndAsync()

        $exited = $proc.WaitForExit($TimeoutSeconds * 1000)

        if (-not $exited) {
            try { $proc.Kill() } catch { }
            Write-Warning "Native update command for '$toolName' timed out after ${TimeoutSeconds}s."
            return [PSCustomObject]@{
                Success = $false
                Output  = "Command timed out after ${TimeoutSeconds} seconds."
                Command = $fullCommand
            }
        }

        # Ensure async reads complete
        [void]$stdout.Wait(5000)
        [void]$stderr.Wait(5000)

        $outText = $stdout.Result
        $errText = $stderr.Result
        $combined = @($outText, $errText) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        $combinedOutput = ($combined -join "`n").Trim()

        $success = $proc.ExitCode -eq 0

        if ($success) {
            Write-Verbose "Native update command for '$toolName' completed successfully."
        } else {
            Write-Warning "Native update command for '$toolName' exited with code $($proc.ExitCode)."
        }

        return [PSCustomObject]@{
            Success = $success
            Output  = $combinedOutput
            Command = $fullCommand
        }
    }
    catch {
        Write-Warning "Failed to execute native update command for '$toolName': $_"
        return [PSCustomObject]@{
            Success = $false
            Output  = "Execution error: $_"
            Command = $fullCommand
        }
    }
}

# ---------------------------------------------------------------------------
# 4d. Update-ToolAncillaryConfigs
# ---------------------------------------------------------------------------
function Update-ToolAncillaryConfigs {
    <#
    .SYNOPSIS
        Downloads and installs ancillary configuration files for a tool.

    .DESCRIPTION
        Some tools rely on external configuration artefacts such as YARA
        rules, EvtxECmd maps, KAPE targets/modules, or Sigma rule packs.
        When a tool's configuration object contains an "ancillary_configs"
        array, this function iterates through each entry and downloads the
        latest version.

        Each ancillary config entry is expected to have:
          name        - Human-readable name (e.g. "EvtxECmd Maps").
          source_type - "github" (latest release zip) or "url" (direct link).
          source      - GitHub owner/repo string or direct download URL.
          destination - Relative path (from the tool install dir) where the
                        files should be placed.
          type        - Category hint: "maps", "rules", "modules", "targets",
                        or any descriptive string.

        Optional properties on each entry:
          asset_pattern - Regex to filter GitHub release assets (source_type
                          "github" only).
          branch        - Branch name for GitHub archive downloads when the
                          repo has no formal releases (defaults to "main").

    .PARAMETER ToolConfig
        A tool configuration PSCustomObject from tools-config.json.

    .OUTPUTS
        PSCustomObject[] summarising what was updated.  Each object has:
          Name    [string] - Ancillary config name.
          Success [bool]   - Whether the download and extraction succeeded.
          Message [string] - Details or error information.

    .EXAMPLE
        $tool = ($config.tools | Where-Object name -eq 'KAPE')
        Update-ToolAncillaryConfigs -ToolConfig $tool
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$ToolConfig
    )

    $toolName = $ToolConfig.name

    # Check for ancillary_configs property
    $acProp = $ToolConfig.PSObject.Properties['ancillary_configs']
    if (-not $acProp -or -not $acProp.Value -or @($acProp.Value).Count -eq 0) {
        Write-Verbose "No ancillary_configs configured for '$toolName'. Skipping."
        return @()
    }

    $ancillaryList = @($acProp.Value)

    # Resolve install directory from tool path
    $toolPath = $ToolConfig.path
    if (-not [System.IO.Path]::IsPathRooted($toolPath)) {
        $dfirVol = Get-Volume -ErrorAction SilentlyContinue |
                   Where-Object { $_.FileSystemLabel -eq 'DFIR' -and $_.DriveLetter } |
                   Select-Object -First 1
        $driveLetter = if ($dfirVol) { $dfirVol.DriveLetter } else { 'D' }
        $toolPath = Join-Path "$($driveLetter):\" $toolPath
    }

    if (Test-Path -LiteralPath $toolPath -PathType Leaf) {
        $installDir = Split-Path $toolPath -Parent
    } else {
        $installDir = $toolPath
    }

    $results = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($ac in $ancillaryList) {
        $acName       = $ac.name
        $acSourceType = $ac.source_type   # "github" or "url"
        $acSource     = $ac.source
        $acDest       = $ac.destination   # relative path from install dir
        $acType       = $ac.type          # descriptive: maps, rules, modules, targets

        Write-Verbose "Processing ancillary config '$acName' (type: $acType) for '$toolName'."

        # Resolve destination to absolute path
        $destPath = Join-Path $installDir $acDest

        # Ensure destination directory exists
        if (-not (Test-Path -LiteralPath $destPath)) {
            try {
                New-Item -ItemType Directory -Path $destPath -Force | Out-Null
            }
            catch {
                $results.Add([PSCustomObject]@{
                    Name    = $acName
                    Success = $false
                    Message = "Failed to create destination directory '$destPath': $_"
                })
                continue
            }
        }

        # Prepare temp file
        $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        if (-not (Test-Path -LiteralPath $script:TempRoot)) {
            New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null
        }

        switch ($acSourceType) {
            'github' {
                # Download latest release asset or source archive from GitHub
                $downloadUrl = $null

                # Check for asset_pattern to pick a release asset
                $assetPatternProp = $ac.PSObject.Properties['asset_pattern']
                $assetPattern     = if ($assetPatternProp) { $assetPatternProp.Value } else { $null }

                if ($assetPattern) {
                    # Query GitHub releases API for matching asset
                    $apiUrl  = "https://api.github.com/repos/$acSource/releases/latest"
                    $headers = @{
                        'Accept'     = 'application/vnd.github+json'
                        'User-Agent' = $script:UserAgent
                    }

                    try {
                        $webResp  = Invoke-WebRequest -Uri $apiUrl -Headers $headers `
                                        -UseBasicParsing -ErrorAction Stop
                        $response = $webResp.Content | ConvertFrom-Json

                        foreach ($asset in $response.assets) {
                            if ($asset.browser_download_url -match $assetPattern) {
                                $downloadUrl = $asset.browser_download_url
                                break
                            }
                        }

                        if (-not $downloadUrl) {
                            $results.Add([PSCustomObject]@{
                                Name    = $acName
                                Success = $false
                                Message = "No release asset matching pattern '$assetPattern' found in $acSource."
                            })
                            continue
                        }
                    }
                    catch {
                        $results.Add([PSCustomObject]@{
                            Name    = $acName
                            Success = $false
                            Message = "GitHub API request failed for '$acSource': $_"
                        })
                        continue
                    }
                }
                else {
                    # No asset pattern: download source archive (zip of branch)
                    $branchProp = $ac.PSObject.Properties['branch']
                    $branch     = if ($branchProp -and $branchProp.Value) { $branchProp.Value } else { 'main' }
                    $downloadUrl = "https://github.com/$acSource/archive/refs/heads/$branch.zip"
                }

                # Download and extract
                $tempFile = Join-Path $script:TempRoot "ac_${timestamp}_$(Split-Path $downloadUrl -Leaf)"

                try {
                    Write-Verbose "Downloading ancillary '$acName': $downloadUrl"
                    $wc = New-Object System.Net.WebClient
                    $wc.Headers.Add('User-Agent', $script:UserAgent)
                    $wc.DownloadFile($downloadUrl, $tempFile)
                    $wc.Dispose()

                    # Determine if archive or single file
                    if ($tempFile -match '\.(zip|7z)$') {
                        # Extract to a staging directory first
                        $stageDir = Join-Path $script:TempRoot "ac_stage_$timestamp`_$acName"
                        New-Item -ItemType Directory -Path $stageDir -Force | Out-Null

                        Expand-Archive -LiteralPath $tempFile -DestinationPath $stageDir `
                                       -Force -ErrorAction Stop

                        # Flatten single nested folder (common in GitHub archives)
                        $stageItems = @(Get-ChildItem -LiteralPath $stageDir -Force -ErrorAction SilentlyContinue)
                        $copySource = $stageDir
                        if ($stageItems.Count -eq 1 -and $stageItems[0].PSIsContainer) {
                            $copySource = $stageItems[0].FullName
                        }

                        # Copy contents to destination, overwriting existing files
                        Get-ChildItem -LiteralPath $copySource -Force | ForEach-Object {
                            Copy-Item -LiteralPath $_.FullName -Destination $destPath `
                                      -Recurse -Force -ErrorAction Stop
                        }

                        # Clean up staging directory
                        Remove-Item -LiteralPath $stageDir -Recurse -Force -ErrorAction SilentlyContinue
                    }
                    else {
                        # Single file: copy directly
                        Copy-Item -LiteralPath $tempFile -Destination $destPath `
                                  -Force -ErrorAction Stop
                    }

                    $results.Add([PSCustomObject]@{
                        Name    = $acName
                        Success = $true
                        Message = "Successfully updated '$acName' ($acType) from GitHub ($acSource)."
                    })
                }
                catch {
                    $results.Add([PSCustomObject]@{
                        Name    = $acName
                        Success = $false
                        Message = "Failed to download or extract '$acName': $_"
                    })
                }
                finally {
                    Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
                }
            }

            'url' {
                # Direct URL download
                $tempFile = Join-Path $script:TempRoot "ac_${timestamp}_$(Split-Path $acSource -Leaf)"

                try {
                    Write-Verbose "Downloading ancillary '$acName': $acSource"
                    $wc = New-Object System.Net.WebClient
                    $wc.Headers.Add('User-Agent', $script:UserAgent)
                    $wc.DownloadFile($acSource, $tempFile)
                    $wc.Dispose()

                    if ($tempFile -match '\.(zip|7z)$') {
                        $stageDir = Join-Path $script:TempRoot "ac_stage_$timestamp`_$acName"
                        New-Item -ItemType Directory -Path $stageDir -Force | Out-Null

                        Expand-Archive -LiteralPath $tempFile -DestinationPath $stageDir `
                                       -Force -ErrorAction Stop

                        $stageItems = @(Get-ChildItem -LiteralPath $stageDir -Force -ErrorAction SilentlyContinue)
                        $copySource = $stageDir
                        if ($stageItems.Count -eq 1 -and $stageItems[0].PSIsContainer) {
                            $copySource = $stageItems[0].FullName
                        }

                        Get-ChildItem -LiteralPath $copySource -Force | ForEach-Object {
                            Copy-Item -LiteralPath $_.FullName -Destination $destPath `
                                      -Recurse -Force -ErrorAction Stop
                        }

                        Remove-Item -LiteralPath $stageDir -Recurse -Force -ErrorAction SilentlyContinue
                    }
                    else {
                        Copy-Item -LiteralPath $tempFile -Destination $destPath `
                                  -Force -ErrorAction Stop
                    }

                    $results.Add([PSCustomObject]@{
                        Name    = $acName
                        Success = $true
                        Message = "Successfully updated '$acName' ($acType) from URL."
                    })
                }
                catch {
                    $results.Add([PSCustomObject]@{
                        Name    = $acName
                        Success = $false
                        Message = "Failed to download or extract '$acName': $_"
                    })
                }
                finally {
                    Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
                }
            }

            default {
                $results.Add([PSCustomObject]@{
                    Name    = $acName
                    Success = $false
                    Message = "Unknown ancillary source type: $acSourceType"
                })
            }
        }
    }

    Write-Verbose "Ancillary config update complete for '$toolName'. $($results.Count) item(s) processed."
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
        [ValidateSet('extract_zip', 'extract_7z', 'copy_exe', 'manual')]
        [string]$InstallType,

        [Parameter()]
        [PSCustomObject]$ToolConfig
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
    # Backup existing installation (move, not copy — avoids duplicates)
    # ------------------------------------------------------------------
    $backupPath = "$InstallPath.bak_$timestamp"
    if (Test-Path -LiteralPath $InstallPath) {
        Write-Verbose "Backing up existing installation: '$InstallPath' -> '$backupPath'"
        try {
            Rename-Item -LiteralPath $InstallPath -NewName (Split-Path $backupPath -Leaf) `
                        -Force -ErrorAction Stop
        }
        catch {
            return New-Result $false "Backup failed for '$ToolName': $_"
        }
    }

    # ------------------------------------------------------------------
    # Helper: flatten single nested folder after extraction
    #   Many ZIPs contain a single root folder (e.g., exiftool-13.52_64/).
    #   Move its contents up so tools live directly in $InstallPath.
    # ------------------------------------------------------------------
    function Resolve-NestedFolder ([string]$Path) {
        $items = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)
        if ($items.Count -eq 1 -and $items[0].PSIsContainer) {
            $nested = $items[0].FullName
            Write-Verbose "Flattening nested folder: '$nested' -> '$Path'"
            # Rename within $Path so it stays as a child of $Path
            $tempName = "_flatten_$([guid]::NewGuid().ToString('N').Substring(0,8))"
            $tempMove = Join-Path $Path $tempName
            Rename-Item -LiteralPath $nested -NewName $tempName -Force
            # Move all contents from the temp folder up into $Path
            Get-ChildItem -LiteralPath $tempMove -Force | ForEach-Object {
                Move-Item -LiteralPath $_.FullName -Destination $Path -Force
            }
            Remove-Item -LiteralPath $tempMove -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # ------------------------------------------------------------------
    # Helper: clean up old .bak_ directories (keep only the latest)
    # ------------------------------------------------------------------
    function Remove-OldBackups ([string]$BasePath) {
        $parentDir  = Split-Path $BasePath -Parent
        $baseName   = Split-Path $BasePath -Leaf
        $bakPattern = "$baseName.bak_*"
        $backups = @(Get-ChildItem -LiteralPath $parentDir -Filter $bakPattern -Directory -ErrorAction SilentlyContinue |
                     Sort-Object Name -Descending)
        # Keep only the most recent backup, remove the rest
        if ($backups.Count -gt 1) {
            foreach ($old in $backups[1..($backups.Count - 1)]) {
                Write-Verbose "Removing old backup: '$($old.FullName)'"
                Remove-Item -LiteralPath $old.FullName -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    # ------------------------------------------------------------------
    # Install based on type
    # ------------------------------------------------------------------
    switch ($InstallType) {
        'extract_zip' {
            Write-Verbose "Extracting '$tempFile' -> '$InstallPath'"
            try {
                # Create a clean target directory
                New-Item -ItemType Directory -Path $InstallPath -Force | Out-Null

                Expand-Archive -LiteralPath $tempFile -DestinationPath $InstallPath `
                               -Force -ErrorAction Stop

                # Flatten if the ZIP contained a single root folder
                Resolve-NestedFolder $InstallPath

                # Clean up old backups (keep only the latest)
                Remove-OldBackups $InstallPath

                Write-Verbose "Extraction complete for '$ToolName'."
                $installResult = New-Result $true "Successfully updated '$ToolName' (extract_zip)."
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

        'extract_7z' {
            Write-Verbose "Extracting 7z archive '$tempFile' -> '$InstallPath'"
            try {
                # Create a clean target directory
                New-Item -ItemType Directory -Path $InstallPath -Force | Out-Null

                # Try 7z.exe from common locations
                $sevenZip = Get-Command '7z' -ErrorAction SilentlyContinue
                if (-not $sevenZip) {
                    $sevenZip = @(
                        "$env:ProgramFiles\7-Zip\7z.exe",
                        "${env:ProgramFiles(x86)}\7-Zip\7z.exe"
                    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
                }

                if ($sevenZip) {
                    $szPath = if ($sevenZip -is [System.Management.Automation.CommandInfo]) { $sevenZip.Source } else { $sevenZip }
                    $proc = Start-Process -FilePath $szPath `
                        -ArgumentList "x `"$tempFile`" -o`"$InstallPath`" -y" `
                        -Wait -PassThru -NoNewWindow -ErrorAction Stop
                    if ($proc.ExitCode -ne 0) {
                        throw "7z exited with code $($proc.ExitCode)"
                    }
                } else {
                    # Fallback: try Expand-Archive in case file is actually a zip
                    Expand-Archive -LiteralPath $tempFile -DestinationPath $InstallPath `
                                   -Force -ErrorAction Stop
                }

                # Flatten if the archive contained a single root folder
                Resolve-NestedFolder $InstallPath

                # Clean up old backups (keep only the latest)
                Remove-OldBackups $InstallPath

                Write-Verbose "Extraction complete for '$ToolName'."
                $installResult = New-Result $true "Successfully updated '$ToolName' (extract_7z)."
            }
            catch {
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

                # Clean up old backups for this file (keep only latest)
                Remove-OldBackups $InstallPath

                Write-Verbose "Copy complete for '$ToolName'."
                $installResult = New-Result $true "Successfully updated '$ToolName' (copy_exe)."
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

    # ------------------------------------------------------------------
    # Post-install: run native update command and ancillary config updates
    # ------------------------------------------------------------------
    if ($installResult -and $installResult.Success -and $ToolConfig) {
        # Native tool update command (e.g. --sync, --update-rules)
        $nativeCmdProp = $ToolConfig.PSObject.Properties['native_update_cmd']
        if ($nativeCmdProp -and -not [string]::IsNullOrWhiteSpace($nativeCmdProp.Value)) {
            Write-Verbose "Running native update command for '$ToolName'."
            $nativeResult = Invoke-NativeToolUpdate -ToolConfig $ToolConfig
            if ($nativeResult.Success) {
                $installResult.Message += " Native update command succeeded."
            } else {
                Write-Warning "Native update command failed for '$ToolName': $($nativeResult.Output)"
                $installResult.Message += " WARNING: Native update command failed: $($nativeResult.Output)"
            }
        }

        # Ancillary config updates (maps, rules, modules, targets)
        $acProp = $ToolConfig.PSObject.Properties['ancillary_configs']
        if ($acProp -and $acProp.Value -and @($acProp.Value).Count -gt 0) {
            Write-Verbose "Updating ancillary configs for '$ToolName'."
            $acResults = Update-ToolAncillaryConfigs -ToolConfig $ToolConfig
            $acSucceeded = @($acResults | Where-Object { $_.Success }).Count
            $acFailed    = @($acResults | Where-Object { -not $_.Success }).Count
            if ($acFailed -gt 0) {
                Write-Warning "Ancillary config update for '$ToolName': $acSucceeded succeeded, $acFailed failed."
                $failedNames = ($acResults | Where-Object { -not $_.Success } | ForEach-Object { $_.Name }) -join ', '
                $installResult.Message += " Ancillary configs: $acSucceeded OK, $acFailed failed ($failedNames)."
            } elseif ($acSucceeded -gt 0) {
                $installResult.Message += " Ancillary configs: $acSucceeded updated."
            }
        }
    }

    return $installResult
}
