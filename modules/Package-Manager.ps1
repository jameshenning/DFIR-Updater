#Requires -Version 5.1
<#
.SYNOPSIS
    Package manager integration for DFIR Drive Updater.
.DESCRIPTION
    Detects and wraps winget, scoop, and chocolatey for version checking
    and one-click updates. Provides a unified interface so the GUI can
    use the best available package manager for each tool.
#>

Set-StrictMode -Version Latest

# ─── Detection ────────────────────────────────────────────────────────────────

function Get-AvailablePackageManagers {
    <#
    .SYNOPSIS
        Detects which package managers are installed and returns their info.
    .OUTPUTS
        Array of hashtables with Name, Path, Version, Available properties.
    #>
    $managers = @()

    # winget
    $wingetPath = Get-Command winget -ErrorAction SilentlyContinue
    if ($wingetPath) {
        $ver = 'Unknown'
        try {
            $verOutput = & winget --version 2>$null
            if ($verOutput) { $ver = ($verOutput | Select-Object -First 1).Trim().TrimStart('v') }
        } catch { }
        $managers += @{
            Name      = 'winget'
            Path      = $wingetPath.Source
            Version   = $ver
            Available = $true
        }
    }

    # scoop
    $scoopPath = Get-Command scoop -ErrorAction SilentlyContinue
    if ($scoopPath) {
        $ver = 'Unknown'
        try {
            $verOutput = & scoop --version 2>$null
            if ($verOutput) { $ver = ($verOutput | Select-Object -First 1).Trim() }
        } catch { }
        $managers += @{
            Name      = 'scoop'
            Path      = $scoopPath.Source
            Version   = $ver
            Available = $true
        }
    }

    # chocolatey
    $chocoPath = Get-Command choco -ErrorAction SilentlyContinue
    if ($chocoPath) {
        $ver = 'Unknown'
        try {
            $verOutput = & choco --version 2>$null
            if ($verOutput) { $ver = ($verOutput | Select-Object -First 1).Trim() }
        } catch { }
        $managers += @{
            Name      = 'choco'
            Path      = $chocoPath.Source
            Version   = $ver
            Available = $true
        }
    }

    return $managers
}

function Test-PackageManager {
    <#
    .SYNOPSIS
        Tests if a specific package manager is available.
    .PARAMETER Name
        The package manager name: winget, scoop, or choco.
    #>
    param([ValidateSet('winget','scoop','choco')][string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

# ─── Winget Operations ────────────────────────────────────────────────────────

function Get-WingetPackageVersion {
    <#
    .SYNOPSIS
        Gets the latest available version of a winget package.
    #>
    param([string]$PackageId)
    if (-not (Test-PackageManager 'winget')) { return $null }
    try {
        $output = & winget show --id $PackageId --accept-source-agreements 2>$null
        foreach ($line in $output) {
            if ($line -match '^\s*Version:\s*(.+)$') {
                return $Matches[1].Trim()
            }
        }
    } catch { }
    return $null
}

function Install-WingetPackage {
    <#
    .SYNOPSIS
        Updates a package via winget. Returns success/failure hashtable.
    .PARAMETER PackageId
        The winget package identifier.
    .PARAMETER TargetDir
        Optional installation directory override.
    #>
    param(
        [string]$PackageId,
        [string]$TargetDir
    )
    if (-not (Test-PackageManager 'winget')) {
        return @{ Success = $false; Message = "winget is not available." }
    }
    try {
        $args = @('upgrade', '--id', $PackageId, '--silent', '--accept-package-agreements', '--accept-source-agreements')
        if ($TargetDir) {
            $args += @('--location', $TargetDir)
        }
        $output = & winget @args 2>&1
        $exitCode = $LASTEXITCODE
        $outputText = ($output | Out-String).Trim()

        if ($exitCode -eq 0 -or $outputText -match 'successfully installed|No applicable update found') {
            return @{ Success = $true; Message = "winget: $outputText" }
        } else {
            return @{ Success = $false; Message = "winget exit code $exitCode`: $outputText" }
        }
    } catch {
        return @{ Success = $false; Message = "winget error: $($_.Exception.Message)" }
    }
}

# ─── Scoop Operations ─────────────────────────────────────────────────────────

function Get-ScoopPackageVersion {
    <#
    .SYNOPSIS
        Gets the latest available version of a scoop package.
    #>
    param([string]$PackageId)
    if (-not (Test-PackageManager 'scoop')) { return $null }
    try {
        $output = & scoop info $PackageId 2>$null
        foreach ($line in $output) {
            if ($line -match '^\s*Version:\s*(.+)$') {
                return $Matches[1].Trim()
            }
        }
    } catch { }
    return $null
}

function Install-ScoopPackage {
    <#
    .SYNOPSIS
        Updates a package via scoop. Returns success/failure hashtable.
    #>
    param([string]$PackageId)
    if (-not (Test-PackageManager 'scoop')) {
        return @{ Success = $false; Message = "scoop is not available." }
    }
    try {
        $output = & scoop update $PackageId 2>&1
        $exitCode = $LASTEXITCODE
        $outputText = ($output | Out-String).Trim()

        if ($exitCode -eq 0 -or $outputText -match "is already installed|Latest version") {
            return @{ Success = $true; Message = "scoop: $outputText" }
        } else {
            return @{ Success = $false; Message = "scoop exit code $exitCode`: $outputText" }
        }
    } catch {
        return @{ Success = $false; Message = "scoop error: $($_.Exception.Message)" }
    }
}

# ─── Unified Interface ────────────────────────────────────────────────────────

function Get-BestUpdateMethod {
    <#
    .SYNOPSIS
        Determines the best update method for a tool based on available
        package managers and tool configuration.
    .PARAMETER Tool
        A tool configuration object with optional winget_id, scoop_id,
        github_repo, and source_type properties.
    .OUTPUTS
        Hashtable with Method (winget|scoop|github|web|manual) and Id.
    #>
    param([PSCustomObject]$Tool)

    # Priority: scoop (portable) > winget > github > web > manual
    if ($Tool.scoop_id -and (Test-PackageManager 'scoop')) {
        return @{ Method = 'scoop'; Id = $Tool.scoop_id }
    }
    if ($Tool.winget_id -and (Test-PackageManager 'winget')) {
        return @{ Method = 'winget'; Id = $Tool.winget_id }
    }
    if ($Tool.github_repo -and $Tool.github_asset_pattern) {
        return @{ Method = 'github'; Id = $Tool.github_repo }
    }
    if ($Tool.source_type -eq 'web' -and $Tool.download_url) {
        return @{ Method = 'web'; Id = $Tool.download_url }
    }
    return @{ Method = 'manual'; Id = $null }
}

function Update-ToolViaPackageManager {
    <#
    .SYNOPSIS
        Attempts to update a tool using the best available package manager.
    .PARAMETER Tool
        Tool configuration object.
    .PARAMETER InstallPath
        Target installation path (for winget --location).
    .OUTPUTS
        Hashtable with Success (bool), Message (string), Method (string).
    #>
    param(
        [PSCustomObject]$Tool,
        [string]$InstallPath
    )

    $best = Get-BestUpdateMethod -Tool $Tool

    switch ($best.Method) {
        'scoop' {
            $result = Install-ScoopPackage -PackageId $best.Id
            $result.Method = 'scoop'
            return $result
        }
        'winget' {
            $result = Install-WingetPackage -PackageId $best.Id -TargetDir $InstallPath
            $result.Method = 'winget'
            return $result
        }
        default {
            return @{
                Success = $false
                Message = "No package manager available for this tool. Using direct download."
                Method  = $best.Method
            }
        }
    }
}
