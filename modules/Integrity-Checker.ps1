#Requires -Version 5.1
<#
.SYNOPSIS
    Integrity verification, PE version detection, ETag caching, and network
    pre-flight checking for the DFIR Drive Updater.

.DESCRIPTION
    Provides functions for verifying file integrity via SHA-256 hashes,
    extracting version information from PE (Portable Executable) metadata,
    caching and comparing HTTP ETags for efficient change detection, and
    testing network connectivity before update operations.
#>

Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Constants / Paths
# ---------------------------------------------------------------------------
$script:UpdaterRoot = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path $script:UpdaterRoot)) {
    $script:UpdaterRoot = 'D:\DFIR-Updater'
}
$script:ETagCachePath = Join-Path $script:UpdaterRoot 'etag-cache.json'
$script:UserAgent     = 'DFIR-Updater/1.0 (PowerShell)'

# Drive root is the parent of the updater folder (typically D:\)
$script:DriveRoot = Split-Path -Parent $script:UpdaterRoot
if (-not (Test-Path $script:DriveRoot)) {
    $script:DriveRoot = 'D:\'
}

# Ensure TLS 1.2 is available for HTTPS requests
try {
    [System.Net.ServicePointManager]::SecurityProtocol =
        [System.Net.ServicePointManager]::SecurityProtocol -bor
        [System.Net.SecurityProtocolType]::Tls12
} catch { }

# ---------------------------------------------------------------------------
# Internal helper: logging
# ---------------------------------------------------------------------------
function Write-Log {
    <#
    .SYNOPSIS
        Internal helper that delegates to Write-DebugLog if available,
        otherwise falls back to Write-Verbose.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet('INFO','WARN','ERROR','DEBUG')]
        [string]$Level = 'INFO'
    )

    if (Get-Command -Name 'Write-DebugLog' -ErrorAction SilentlyContinue) {
        Write-DebugLog -Message $Message -Level $Level
    }
    else {
        Write-Verbose "[$Level] $Message"
    }
}

# ---------------------------------------------------------------------------
# 1. Get-ExeFileVersion
# ---------------------------------------------------------------------------
function Get-ExeFileVersion {
    <#
    .SYNOPSIS
        Extracts the product or file version from a PE executable.

    .DESCRIPTION
        Uses [System.Diagnostics.FileVersionInfo]::GetVersionInfo() to read
        version metadata embedded in a .exe file.  Returns the ProductVersion
        string if available, falling back to FileVersion.  Returns $null when
        no version information is present or the file cannot be read.

    .PARAMETER Path
        Full path to the .exe file to inspect.

    .OUTPUTS
        System.String  The version string, or $null if unavailable.

    .EXAMPLE
        Get-ExeFileVersion -Path 'D:\Tools\Autopsy\bin\autopsy64.exe'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Verbose "File not found: '$Path'"
        return $null
    }

    try {
        $versionInfo = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
    }
    catch {
        Write-Verbose "Failed to read version info from '$Path': $_"
        return $null
    }

    # Prefer ProductVersion; fall back to FileVersion
    if (-not [string]::IsNullOrWhiteSpace($versionInfo.ProductVersion)) {
        $version = $versionInfo.ProductVersion.Trim()
        Write-Verbose "ProductVersion for '$Path': $version"
        return $version
    }

    if (-not [string]::IsNullOrWhiteSpace($versionInfo.FileVersion)) {
        $version = $versionInfo.FileVersion.Trim()
        Write-Verbose "FileVersion for '$Path': $version"
        return $version
    }

    Write-Verbose "No version information found in '$Path'."
    return $null
}

# ---------------------------------------------------------------------------
# 2. Get-InstalledToolVersion
# ---------------------------------------------------------------------------
function Get-InstalledToolVersion {
    <#
    .SYNOPSIS
        Detects the installed version of a DFIR tool using multiple strategies.

    .DESCRIPTION
        Given a tool configuration object (from tools-config.json) and the
        drive root path, resolves the tool's install directory and attempts
        to determine its version through three strategies in order:

          1. PE metadata  -- scans .exe files for embedded version info.
          2. Filename      -- extracts version from filename patterns such
                              as "tool-1.2.3.exe" or "tool_v2.0".
          3. Config        -- falls back to the current_version field in the
                              tool configuration.

        Returns a PSCustomObject with the detected Version and the Source
        strategy that produced it.

    .PARAMETER ToolConfig
        A tool configuration object as loaded from tools-config.json.
        Must have at minimum a 'path' property and optionally 'current_version'.

    .PARAMETER DriveRoot
        The root path of the DFIR drive (e.g. "D:\").  The tool's relative
        path from the config is joined to this root.

    .OUTPUTS
        PSCustomObject with properties: Version (string), Source (string).

    .EXAMPLE
        $config = Get-ToolConfig
        Get-InstalledToolVersion -ToolConfig $config.tools[0] -DriveRoot 'D:\'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$ToolConfig,

        [Parameter()]
        [string]$DriveRoot = $script:DriveRoot
    )

    $toolPath = Join-Path $DriveRoot $ToolConfig.path
    $toolName = $ToolConfig.name

    Write-Verbose "Detecting installed version for '$toolName' at '$toolPath'."

    # --- Strategy 1: PE metadata from .exe files ---
    if (Test-Path -LiteralPath $toolPath) {
        $exeFiles = @()

        if ((Get-Item -LiteralPath $toolPath).PSIsContainer) {
            $exeFiles = @(Get-ChildItem -LiteralPath $toolPath -Filter '*.exe' `
                              -Recurse -ErrorAction SilentlyContinue |
                          Select-Object -First 20)
        }
        elseif ($toolPath -like '*.exe') {
            $exeFiles = @(Get-Item -LiteralPath $toolPath -ErrorAction SilentlyContinue)
        }

        foreach ($exe in $exeFiles) {
            $version = Get-ExeFileVersion -Path $exe.FullName
            if ($version) {
                Write-Log "Version '$version' detected from PE metadata: $($exe.FullName)" 'INFO'
                return [PSCustomObject]@{
                    Version = $version
                    Source  = 'PE metadata'
                }
            }
        }
    }

    # --- Strategy 2: Filename pattern extraction ---
    $pathLeaf = Split-Path $toolPath -Leaf
    # Match patterns like: tool-1.2.3, tool_v1.2.3, tool_1.2.3, toolv1.2
    $filenamePatterns = @(
        '[-_]v?(\d+\.\d+(?:\.\d+)*)',     # tool-1.2.3 or tool_v1.2.3
        'v(\d+\.\d+(?:\.\d+)*)',           # toolv1.2.3
        '(\d+\.\d+\.\d+)'                  # bare 1.2.3 anywhere in name
    )

    foreach ($pattern in $filenamePatterns) {
        if ($pathLeaf -match $pattern) {
            $version = $Matches[1]
            Write-Log "Version '$version' extracted from filename: $pathLeaf" 'INFO'
            return [PSCustomObject]@{
                Version = $version
                Source  = 'filename'
            }
        }
    }

    # --- Strategy 3: Config fallback ---
    $currentVersionProp = $ToolConfig.PSObject.Properties['current_version']
    if ($currentVersionProp -and -not [string]::IsNullOrWhiteSpace($currentVersionProp.Value)) {
        $version = $currentVersionProp.Value
        Write-Log "Version '$version' taken from config for '$toolName'." 'DEBUG'
        return [PSCustomObject]@{
            Version = $version
            Source  = 'config'
        }
    }

    Write-Verbose "No version detected for '$toolName'."
    return [PSCustomObject]@{
        Version = $null
        Source  = $null
    }
}

# ---------------------------------------------------------------------------
# 3. Test-FileHash
# ---------------------------------------------------------------------------
function Test-FileHash {
    <#
    .SYNOPSIS
        Verifies a file's SHA-256 hash against an expected value.

    .DESCRIPTION
        Computes the SHA-256 hash of the specified file using Get-FileHash
        and compares it to the expected hash string.  The comparison is
        case-insensitive.  Logs the result via Write-DebugLog when available,
        otherwise falls back to Write-Verbose.

    .PARAMETER Path
        Full path to the file to verify.

    .PARAMETER ExpectedHash
        The expected SHA-256 hash string (64 hex characters).

    .OUTPUTS
        System.Boolean  $true if the computed hash matches the expected hash.

    .EXAMPLE
        Test-FileHash -Path 'D:\Tools\tool.zip' -ExpectedHash 'A1B2C3...'
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$ExpectedHash
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Log "File not found for hash verification: '$Path'" 'ERROR'
        return $false
    }

    if ([string]::IsNullOrWhiteSpace($ExpectedHash)) {
        Write-Log "Expected hash is empty; cannot verify '$Path'." 'WARN'
        return $false
    }

    try {
        $computed = (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash
    }
    catch {
        Write-Log "Failed to compute SHA-256 for '$Path': $_" 'ERROR'
        return $false
    }

    $match = $computed -eq $ExpectedHash.Trim()

    if ($match) {
        Write-Log "Hash MATCH for '$Path'. SHA-256: $computed" 'INFO'
    }
    else {
        Write-Log "Hash MISMATCH for '$Path'. Expected: $($ExpectedHash.Trim()) Got: $computed" 'WARN'
    }

    return $match
}

# ---------------------------------------------------------------------------
# 4. Get-GitHubReleaseHash
# ---------------------------------------------------------------------------
function Get-GitHubReleaseHash {
    <#
    .SYNOPSIS
        Parses a SHA-256 hash for a specific asset from GitHub release notes.

    .DESCRIPTION
        Examines the body text of a GitHub release for common hash patterns
        associated with the given asset filename.  Supports:

          - "sha256: <hash>" lines mentioning the filename
          - sha256sum-style output: "<hash>  filename" or "<hash> filename"
          - Markdown table rows containing the hash and filename

        Returns the first matching 64-character hex string, or $null if no
        hash is found.

    .PARAMETER ReleaseBody
        The full text body of a GitHub release (from the API response).

    .PARAMETER AssetFilename
        The filename of the release asset to find a hash for.

    .OUTPUTS
        System.String  The SHA-256 hash string, or $null if not found.

    .EXAMPLE
        $release = Get-GitHubLatestRelease -OwnerRepo 'EricZimmerman/RECmd'
        $body = (Invoke-RestMethod "https://api.github.com/repos/EricZimmerman/RECmd/releases/latest").body
        Get-GitHubReleaseHash -ReleaseBody $body -AssetFilename 'RECmd.zip'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$ReleaseBody,

        [Parameter(Mandatory)]
        [string]$AssetFilename
    )

    if ([string]::IsNullOrWhiteSpace($ReleaseBody)) {
        Write-Verbose 'Release body is empty; no hash to extract.'
        return $null
    }

    if ([string]::IsNullOrWhiteSpace($AssetFilename)) {
        Write-Verbose 'Asset filename is empty; cannot search for hash.'
        return $null
    }

    $escapedName = [regex]::Escape($AssetFilename)

    # Split body into lines for line-by-line analysis
    $lines = $ReleaseBody -split '\r?\n'

    foreach ($line in $lines) {
        # Skip lines that do not mention the asset filename
        if ($line -notmatch $escapedName) {
            continue
        }

        # Pattern 1: "sha256: <hash>" or "SHA256: <hash>" on the same line
        if ($line -match 'sha\s*-?\s*256\s*[:=]\s*([0-9a-fA-F]{64})') {
            $hash = $Matches[1]
            Write-Verbose "Found hash via sha256-label pattern: $hash"
            return $hash
        }

        # Pattern 2: sha256sum format -- "<hash>  <filename>" or "<hash> <filename>"
        if ($line -match '([0-9a-fA-F]{64})\s+\S*' + $escapedName) {
            $hash = $Matches[1]
            Write-Verbose "Found hash via sha256sum-style pattern: $hash"
            return $hash
        }

        # Pattern 3: Markdown table row -- "| <hash> | <filename> |" or reverse
        if ($line -match '\|\s*([0-9a-fA-F]{64})\s*\|') {
            $hash = $Matches[1]
            Write-Verbose "Found hash via Markdown table pattern: $hash"
            return $hash
        }

        # Pattern 4: Any 64-char hex string on a line with the filename
        if ($line -match '([0-9a-fA-F]{64})') {
            $hash = $Matches[1]
            Write-Verbose "Found hash via generic 64-char hex pattern: $hash"
            return $hash
        }
    }

    Write-Verbose "No SHA-256 hash found for '$AssetFilename' in release body."
    return $null
}

# ---------------------------------------------------------------------------
# 5a. Get-CachedETag
# ---------------------------------------------------------------------------
function Get-CachedETag {
    <#
    .SYNOPSIS
        Retrieves a cached ETag value for a URL from the local ETag cache file.

    .DESCRIPTION
        Reads the etag-cache.json file and returns the stored ETag string for
        the specified URL.  Returns $null if the cache file does not exist or
        the URL has no cached entry.

    .PARAMETER Url
        The URL whose cached ETag should be retrieved.

    .PARAMETER CachePath
        Path to the ETag cache JSON file.  Defaults to
        $ScriptDir/etag-cache.json.

    .OUTPUTS
        System.String  The cached ETag value, or $null.

    .EXAMPLE
        Get-CachedETag -Url 'https://api.github.com/repos/owner/repo/releases/latest'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Url,

        [Parameter()]
        [string]$CachePath = $script:ETagCachePath
    )

    if (-not (Test-Path -LiteralPath $CachePath)) {
        Write-Verbose "ETag cache file not found: '$CachePath'"
        return $null
    }

    try {
        $raw   = Get-Content -LiteralPath $CachePath -Raw -ErrorAction Stop
        $cache = $raw | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        Write-Verbose "Failed to read ETag cache: $_"
        return $null
    }

    $etagProp = $cache.PSObject.Properties[$Url]
    if ($etagProp -and -not [string]::IsNullOrWhiteSpace($etagProp.Value)) {
        Write-Verbose "Cached ETag for '$Url': $($etagProp.Value)"
        return $etagProp.Value
    }

    Write-Verbose "No cached ETag found for '$Url'."
    return $null
}

# ---------------------------------------------------------------------------
# 5b. Save-CachedETag
# ---------------------------------------------------------------------------
function Save-CachedETag {
    <#
    .SYNOPSIS
        Saves an ETag value for a URL to the local ETag cache file.

    .DESCRIPTION
        Reads the existing etag-cache.json (or creates a new object), sets
        the ETag for the specified URL, and writes the file back to disk.

    .PARAMETER Url
        The URL to associate with the ETag value.

    .PARAMETER ETag
        The ETag string to cache.

    .PARAMETER CachePath
        Path to the ETag cache JSON file.  Defaults to
        $ScriptDir/etag-cache.json.

    .OUTPUTS
        None.

    .EXAMPLE
        Save-CachedETag -Url 'https://api.github.com/repos/owner/repo/releases/latest' -ETag '"abc123"'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Url,

        [Parameter(Mandatory)]
        [string]$ETag,

        [Parameter()]
        [string]$CachePath = $script:ETagCachePath
    )

    # Load existing cache or create a new object
    $cache = $null
    if (Test-Path -LiteralPath $CachePath) {
        try {
            $raw   = Get-Content -LiteralPath $CachePath -Raw -ErrorAction Stop
            $cache = $raw | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            Write-Verbose "ETag cache unreadable; creating new cache."
            $cache = $null
        }
    }

    if ($null -eq $cache) {
        $cache = [PSCustomObject]@{}
    }

    # Add or update the URL entry
    $existingProp = $cache.PSObject.Properties[$Url]
    if ($existingProp) {
        $existingProp.Value = $ETag
    }
    else {
        $cache | Add-Member -MemberType NoteProperty -Name $Url -Value $ETag
    }

    try {
        $json = $cache | ConvertTo-Json -Depth 10 -ErrorAction Stop
        Set-Content -LiteralPath $CachePath -Value $json -Encoding UTF8 -ErrorAction Stop
        Write-Verbose "Saved ETag for '$Url' to cache."
    }
    catch {
        Write-Warning "Failed to write ETag cache to '$CachePath': $_"
    }
}

# ---------------------------------------------------------------------------
# 5c. Test-ETagChanged
# ---------------------------------------------------------------------------
function Test-ETagChanged {
    <#
    .SYNOPSIS
        Checks whether a remote resource has changed since the last cached ETag.

    .DESCRIPTION
        Sends an HTTP HEAD request to the specified URL with an If-None-Match
        header set to the provided ETag value.  Returns $true if the server
        responds with HTTP 200 (resource has changed) or $false if the server
        responds with HTTP 304 (resource unchanged).

        When no cached ETag is provided, the function returns $true (assume
        the resource may have changed).

    .PARAMETER Url
        The URL to check.

    .PARAMETER ETag
        The previously cached ETag value to send in the If-None-Match header.

    .OUTPUTS
        System.Boolean  $true if the resource has changed or ETag is unknown.

    .EXAMPLE
        $etag = Get-CachedETag -Url 'https://api.github.com/repos/owner/repo/releases/latest'
        Test-ETagChanged -Url 'https://api.github.com/repos/owner/repo/releases/latest' -ETag $etag
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$Url,

        [Parameter()]
        [string]$ETag
    )

    if ([string]::IsNullOrWhiteSpace($ETag)) {
        Write-Verbose "No ETag provided for '$Url'; assuming resource may have changed."
        return $true
    }

    Write-Verbose "Checking ETag for '$Url' (If-None-Match: $ETag)"

    try {
        $headers = @{
            'User-Agent'    = $script:UserAgent
            'If-None-Match' = $ETag
        }

        # Invoke-WebRequest does not support -Method Head in PS 5.1 via
        # the standard parameter set, so use a WebRequest manually.
        $request = [System.Net.HttpWebRequest]::Create($Url)
        $request.Method    = 'HEAD'
        $request.UserAgent = $script:UserAgent
        $request.Timeout   = 10000   # 10 seconds
        $request.Headers.Add('If-None-Match', $ETag)

        $response = $null
        try {
            $response = $request.GetResponse()
            $statusCode = [int]$response.StatusCode
        }
        catch [System.Net.WebException] {
            $webEx = $_.Exception
            if ($webEx.Response) {
                $statusCode = [int]$webEx.Response.StatusCode
            }
            else {
                Write-Verbose "HEAD request failed for '$Url': $_"
                return $true
            }
        }
        finally {
            if ($response) { $response.Close() }
        }

        if ($statusCode -eq 304) {
            Write-Verbose "Resource unchanged (HTTP 304) for '$Url'."
            return $false
        }

        Write-Verbose "Resource may have changed (HTTP $statusCode) for '$Url'."
        return $true
    }
    catch {
        Write-Verbose "ETag check failed for '$Url': $_"
        return $true
    }
}

# ---------------------------------------------------------------------------
# 6. Test-NetworkConnectivity
# ---------------------------------------------------------------------------
function Test-NetworkConnectivity {
    <#
    .SYNOPSIS
        Tests basic internet and GitHub connectivity before update operations.

    .DESCRIPTION
        Performs lightweight HTTP HEAD requests to github.com and
        www.microsoft.com to verify network availability.  Each check uses
        a 3-second timeout to keep the pre-flight fast.

        Returns a PSCustomObject with overall connectivity status, GitHub
        reachability, and a human-readable details string.

    .OUTPUTS
        PSCustomObject with properties:
          IsConnected     [bool]   - $true if at least one host is reachable.
          GitHubReachable [bool]   - $true if github.com responded.
          Details         [string] - Summary of the connectivity test.

    .EXAMPLE
        $net = Test-NetworkConnectivity
        if (-not $net.IsConnected) { Write-Warning $net.Details }
    #>
    [CmdletBinding()]
    param()

    $githubReachable = $false
    $altReachable    = $false
    $details         = @()

    $timeoutMs = 3000   # 3-second timeout per host

    # --- Test github.com ---
    try {
        $request = [System.Net.HttpWebRequest]::Create('https://github.com')
        $request.Method    = 'HEAD'
        $request.Timeout   = $timeoutMs
        $request.UserAgent = $script:UserAgent

        $response = $null
        try {
            $response   = $request.GetResponse()
            $statusCode = [int]$response.StatusCode
            if ($statusCode -lt 400) {
                $githubReachable = $true
                $details += "github.com: reachable (HTTP $statusCode)"
            }
            else {
                $details += "github.com: unexpected status (HTTP $statusCode)"
            }
        }
        catch [System.Net.WebException] {
            $webEx = $_.Exception
            if ($webEx.Response) {
                $statusCode = [int]$webEx.Response.StatusCode
                # Even a 403 means the host is reachable
                $githubReachable = $true
                $details += "github.com: reachable (HTTP $statusCode)"
            }
            else {
                $details += "github.com: unreachable ($($webEx.Message))"
            }
        }
        finally {
            if ($response) { $response.Close() }
        }
    }
    catch {
        $details += "github.com: unreachable ($_)"
    }

    # --- Test alternate host (www.microsoft.com) ---
    try {
        $request = [System.Net.HttpWebRequest]::Create('https://www.microsoft.com')
        $request.Method    = 'HEAD'
        $request.Timeout   = $timeoutMs
        $request.UserAgent = $script:UserAgent

        $response = $null
        try {
            $response   = $request.GetResponse()
            $statusCode = [int]$response.StatusCode
            if ($statusCode -lt 400) {
                $altReachable = $true
                $details += "www.microsoft.com: reachable (HTTP $statusCode)"
            }
            else {
                $details += "www.microsoft.com: unexpected status (HTTP $statusCode)"
            }
        }
        catch [System.Net.WebException] {
            $webEx = $_.Exception
            if ($webEx.Response) {
                $statusCode = [int]$webEx.Response.StatusCode
                $altReachable = $true
                $details += "www.microsoft.com: reachable (HTTP $statusCode)"
            }
            else {
                $details += "www.microsoft.com: unreachable ($($webEx.Message))"
            }
        }
        finally {
            if ($response) { $response.Close() }
        }
    }
    catch {
        $details += "www.microsoft.com: unreachable ($_)"
    }

    $isConnected = $githubReachable -or $altReachable
    $summary     = $details -join '; '

    if ($isConnected) {
        Write-Verbose "Network connectivity OK: $summary"
    }
    else {
        Write-Verbose "Network connectivity FAILED: $summary"
    }

    return [PSCustomObject]@{
        IsConnected     = $isConnected
        GitHubReachable = $githubReachable
        Details         = $summary
    }
}
