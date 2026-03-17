#Requires -Version 5.1
<#
.SYNOPSIS
    Build script for DFIR-Updater - compiles the application into a distributable .exe.
.DESCRIPTION
    1. Merges all module files into the main GUI script (inline)
    2. Embeds tools-config.json as a fallback default
    3. Compiles the merged script to .exe using PS2EXE
    4. Packages the .exe + config into a distributable zip
.NOTES
    Requires: PS2EXE module (Install-Module ps2exe -Scope CurrentUser)
#>
param(
    [string]$OutputDir = (Join-Path $PSScriptRoot 'dist'),
    [switch]$SkipZip
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$scriptDir   = $PSScriptRoot
$mainScript  = Join-Path $scriptDir 'DFIR-Updater-GUI.ps1'
$configFile  = Join-Path $scriptDir 'tools-config.json'
$modulesDir  = Join-Path $scriptDir 'modules'

# Module files in load order
$moduleFiles = @(
    'Update-Checker.ps1'
    'Auto-Discovery.ps1'
    'Tool-Launcher.ps1'
    'Package-Manager.ps1'
)

# -- Validate prerequisites --------------------------------------------------
Write-Host '=== DFIR-Updater Build Script ===' -ForegroundColor Cyan

if (-not (Get-Module ps2exe -ListAvailable)) {
    Write-Host 'ERROR: PS2EXE module not found. Install with:' -ForegroundColor Red
    Write-Host '  Install-Module ps2exe -Scope CurrentUser' -ForegroundColor Yellow
    exit 1
}

if (-not (Test-Path $mainScript)) {
    Write-Host "ERROR: Main script not found: $mainScript" -ForegroundColor Red
    exit 1
}

# -- Create output directory -------------------------------------------------
if (-not (Test-Path $OutputDir)) {
    New-Item -Path $OutputDir -ItemType Directory -Force | Out-Null
}

$mergedScript = Join-Path $OutputDir 'DFIR-Updater-Merged.ps1'
$exeOutput    = Join-Path $OutputDir 'DFIR-Updater.exe'

# -- Step 1: Read and merge modules ------------------------------------------
Write-Host '[1/4] Merging modules into single script...' -ForegroundColor Yellow

$mainContent = Get-Content -LiteralPath $mainScript -Raw

# Read each module's content (strip #Requires lines and comment-based help blocks at the very top)
$moduleContents = @{}
foreach ($modFile in $moduleFiles) {
    $modPath = Join-Path $modulesDir $modFile
    if (Test-Path $modPath) {
        $content = Get-Content -LiteralPath $modPath -Raw
        # Strip leading #Requires line
        $content = $content -replace '(?m)^#Requires\s+-Version\s+\S+\r?\n', ''
        # Strip Set-StrictMode at the top of modules (the main script manages this)
        $content = $content -replace '(?m)^Set-StrictMode\s+-Version\s+Latest\r?\n', ''
        $moduleContents[$modFile] = $content
        Write-Host "  + $modFile ($((($content -split "`n").Count)) lines)" -ForegroundColor Gray
    } else {
        Write-Host "  - $modFile (not found, skipping)" -ForegroundColor DarkYellow
        $moduleContents[$modFile] = ''
    }
}

# Build the merged script:
# 1. Replace the dot-source loading section with inline module content
# 2. Keep everything else intact

$merged = [System.Text.StringBuilder]::new(($mainContent.Length + 200000))

# Split the main script into lines for surgical replacement
$lines = $mainContent -split "`r?`n"
$i = 0
$skipUntilBlank = $false
$inModuleLoadSection = $false

while ($i -lt $lines.Count) {
    $line = $lines[$i]

    # Detect start of module path definitions
    if ($line -match '^\$script:ModulePath\s*=') {
        # We're entering the module loading section - emit the inlined modules instead
        # Skip all module path assignments
        while ($i -lt $lines.Count -and $lines[$i] -match '^\$script:(ModulePath|AutoDiscoveryPath|ToolLauncherPath|PkgManagerPath|ConfigPath)\s*=') {
            $i++
        }

        # Keep ConfigPath but make it work for both .exe and .ps1 contexts
        [void]$merged.AppendLine('$script:ConfigPath          = Join-Path $script:ScriptDir "tools-config.json"')
        [void]$merged.AppendLine('')

        # Skip Has* test lines
        while ($i -lt $lines.Count -and $lines[$i] -match '^\$script:Has(Module|AutoDiscovery|ToolLauncher|PkgManager)\s*=') {
            $i++
        }

        # Skip blank line after Has* assignments
        if ($i -lt $lines.Count -and $lines[$i].Trim() -eq '') { $i++ }

        # Now emit inlined module content
        [void]$merged.AppendLine('# =========================================================================')
        [void]$merged.AppendLine('# INLINED MODULES (merged at build time)')
        [void]$merged.AppendLine('# =========================================================================')
        [void]$merged.AppendLine('')

        foreach ($modFile in $moduleFiles) {
            if ($moduleContents[$modFile]) {
                $modName = [System.IO.Path]::GetFileNameWithoutExtension($modFile)
                [void]$merged.AppendLine("# --- BEGIN MODULE: $modName ---")
                [void]$merged.AppendLine($moduleContents[$modFile].TrimEnd())
                [void]$merged.AppendLine("# --- END MODULE: $modName ---")
                [void]$merged.AppendLine('')
            }
        }

        [void]$merged.AppendLine('Set-StrictMode -Off')
        [void]$merged.AppendLine('')

        # Skip past all the dot-source blocks (lines 95-125 area)
        while ($i -lt $lines.Count) {
            if ($lines[$i] -match '^\s*\.\s+\$script:(ModulePath|AutoDiscoveryPath|ToolLauncherPath|PkgManagerPath)') {
                $i++; continue
            }
            if ($lines[$i] -match '^\$script:Has(Module|AutoDiscovery|ToolLauncher|PkgManager)') {
                $i++; continue
            }
            if ($lines[$i] -match 'Set-StrictMode\s+-Off' -and $inModuleLoadSection) {
                $i++; continue
            }
            if ($lines[$i] -match 'Write-DebugLog.*Modules:') {
                $i++; continue
            }
            if ($lines[$i] -match 'Write-DebugLog.*Loaded.*module') {
                $i++; continue
            }
            if ($lines[$i] -match 'Write-Warning.*Update-Checker module not found') {
                $i++; continue
            }
            if ($lines[$i] -match 'Write-Warning.*UI-preview mode') {
                $i++; continue
            }
            if ($lines[$i] -match 'Write-DebugLog.*NOT FOUND.*preview') {
                $i++; continue
            }
            if ($lines[$i] -match '^\s*#.*dot-source|module sets Set-StrictMode|via dot-sourcing') {
                $i++; continue
            }
            if ($lines[$i] -match '^\s*if\s+\(\$script:Has(Module|AutoDiscovery|ToolLauncher|PkgManager)\)') {
                # Skip the entire if block
                $depth = 0
                while ($i -lt $lines.Count) {
                    if ($lines[$i] -match '\{') { $depth++ }
                    if ($lines[$i] -match '\}') { $depth-- }
                    $i++
                    if ($depth -le 0) { break }
                }
                # Also skip trailing Set-StrictMode -Off after module load
                while ($i -lt $lines.Count -and ($lines[$i] -match 'Set-StrictMode\s+-Off' -or $lines[$i].Trim() -eq '')) {
                    if ($lines[$i] -match 'Set-StrictMode') { $i++; continue }
                    if ($lines[$i].Trim() -eq '') { $i++; break }
                    break
                }
                continue
            }

            # If we hit the C# class definition or next major section, we're done
            if ($lines[$i] -match '^#.*Observable Tool Item|^Add-Type -Language CSharp') {
                break
            }

            # Skip misc comment/blank lines in the loading section
            if ($lines[$i].Trim() -eq '' -or $lines[$i] -match '^\s*#') {
                $i++
                continue
            }

            break
        }

        $inModuleLoadSection = $false
        continue
    }

    # For later dot-source calls (re-loading modules in background workers etc.)
    # Replace with inline comment since modules are already loaded
    if ($line -match '^\s*\.\s+\$(ModulePath|PkgManagerPath)\s*$') {
        [void]$merged.AppendLine("    # Module already inlined - no dot-source needed")
        $i++
        continue
    }
    if ($line -match '^\s*try\s*\{\s*\.\s+\$PkgManagerPath') {
        $fixedLine = $line -replace '\.\s+\$PkgManagerPath', '# (Package-Manager already inlined)'
        [void]$merged.AppendLine($fixedLine)
        $i++
        continue
    }

    [void]$merged.AppendLine($line)
    $i++
}

$mergedText = $merged.ToString()

# Remove the leading #Requires from merged script (PS2EXE doesn't need it)
$mergedText = $mergedText -replace '(?m)^#Requires\s+-Version\s+\S+\r?\n', ''

Set-Content -LiteralPath $mergedScript -Value $mergedText -Encoding UTF8 -NoNewline
$mergedLines = ($mergedText -split "`n").Count
Write-Host "  Merged script: $mergedLines lines" -ForegroundColor Green

# -- Step 2: Compile to EXE --------------------------------------------------
Write-Host '[2/4] Compiling to .exe with PS2EXE...' -ForegroundColor Yellow

$ps2exeParams = @{
    InputFile        = $mergedScript
    OutputFile       = $exeOutput
    NoConsole        = $true
    Title            = 'DFIR Drive Updater'
    Description      = 'Digital Forensics & Incident Response Drive Update Tool'
    Company          = 'DFIR-Updater'
    Product          = 'DFIR-Updater'
    Version          = '1.0.0.0'
    Copyright        = "Copyright $(Get-Date -Format yyyy)"
    RequireAdmin     = $false
    STA              = $true
    ErrorAction      = 'Stop'
}

try {
    Invoke-PS2EXE @ps2exeParams
    $exeSize = [math]::Round((Get-Item $exeOutput).Length / 1MB, 2)
    Write-Host "  Output: $exeOutput ($exeSize MB)" -ForegroundColor Green
} catch {
    Write-Host "ERROR: PS2EXE compilation failed: $_" -ForegroundColor Red
    exit 1
}

# -- Step 3: Copy supporting files -------------------------------------------
Write-Host '[3/4] Copying supporting files...' -ForegroundColor Yellow

# Copy config file alongside the exe
Copy-Item -LiteralPath $configFile -Destination (Join-Path $OutputDir 'tools-config.json') -Force
Write-Host '  + tools-config.json' -ForegroundColor Gray

# Copy modules folder (for re-dot-source scenarios in background workers)
$distModules = Join-Path $OutputDir 'modules'
if (-not (Test-Path $distModules)) {
    New-Item -Path $distModules -ItemType Directory -Force | Out-Null
}
foreach ($modFile in $moduleFiles) {
    $src = Join-Path $modulesDir $modFile
    if (Test-Path $src) {
        Copy-Item -LiteralPath $src -Destination (Join-Path $distModules $modFile) -Force
        Write-Host "  + modules/$modFile" -ForegroundColor Gray
    }
}

# -- Step 4: Create distributable zip ----------------------------------------
if (-not $SkipZip) {
    Write-Host '[4/4] Creating distributable zip...' -ForegroundColor Yellow

    $zipPath = Join-Path $scriptDir 'dist\DFIR-Updater-Portable.zip'
    if (Test-Path $zipPath) { Remove-Item $zipPath -Force }

    # Create a temp staging directory with clean structure
    $stagingDir = Join-Path $OutputDir '_staging'
    if (Test-Path $stagingDir) { Remove-Item $stagingDir -Recurse -Force }
    New-Item -Path $stagingDir -ItemType Directory -Force | Out-Null

    $appDir = Join-Path $stagingDir 'DFIR-Updater'
    New-Item -Path $appDir -ItemType Directory -Force | Out-Null

    Copy-Item -LiteralPath $exeOutput -Destination $appDir -Force
    Copy-Item -LiteralPath (Join-Path $OutputDir 'tools-config.json') -Destination $appDir -Force

    $stageModules = Join-Path $appDir 'modules'
    New-Item -Path $stageModules -ItemType Directory -Force | Out-Null
    foreach ($modFile in $moduleFiles) {
        $src = Join-Path $distModules $modFile
        if (Test-Path $src) {
            Copy-Item -LiteralPath $src -Destination (Join-Path $stageModules $modFile) -Force
        }
    }

    # Create a README for the distribution
    $readmeContent = @"
DFIR Drive Updater - Portable Distribution
===========================================

INSTALLATION:
1. Copy the entire 'DFIR-Updater' folder to your DFIR drive root.
   Example: D:\DFIR-Updater\

2. Your DFIR drive should have tool folders like:
   D:\01_Acquisition\
   D:\02_Analysis\
   D:\03_Network\
   etc.

3. Run DFIR-Updater.exe to launch the application.

REQUIREMENTS:
- Windows 10/11
- PowerShell 5.1+ (built into Windows)
- .NET Framework 4.5+ (built into Windows)

FILES:
- DFIR-Updater.exe    - Main application
- tools-config.json   - Tool update configuration
- modules\            - PowerShell modules (used by background workers)
"@
    Set-Content -LiteralPath (Join-Path $appDir 'README.txt') -Value $readmeContent

    Compress-Archive -Path "$appDir\*" -DestinationPath $zipPath -CompressionLevel Optimal -Force
    Remove-Item $stagingDir -Recurse -Force

    $zipSize = [math]::Round((Get-Item $zipPath).Length / 1MB, 2)
    Write-Host "  Zip: $zipPath ($zipSize MB)" -ForegroundColor Green
} else {
    Write-Host '[4/4] Skipping zip (use -SkipZip:$false to enable)' -ForegroundColor DarkYellow
}

# -- Done -------------------------------------------------------------------
Write-Host ''
Write-Host '=== Build Complete ===' -ForegroundColor Green
Write-Host ''
Write-Host 'To distribute:' -ForegroundColor Cyan
Write-Host "  1. Share: $zipPath" -ForegroundColor White
Write-Host '  2. Recipients extract to their DFIR drive root' -ForegroundColor White
Write-Host '  3. Run DFIR-Updater.exe' -ForegroundColor White
Write-Host ''
