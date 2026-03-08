#Requires -Version 5.1
<#
.SYNOPSIS
    Initializes the DFIR-Updater folder as a Git repository and pushes to GitHub.

.DESCRIPTION
    Walks through the process of:
      1. Verifying that git and gh (GitHub CLI) are installed
      2. Initializing a Git repository in the DFIR-Updater folder
      3. Adding the .gitignore file
      4. Staging and committing all framework files
      5. Creating a new GitHub repository (public or private)
      6. Pushing the initial commit to GitHub

    This enables version-controlling the DFIR-Updater framework so it can be
    cloned onto new machines and used with Bootstrap-DFIR-Drive.ps1 to set up
    fresh DFIR USB drives.

.PARAMETER RepoName
    Name for the GitHub repository. Defaults to "DFIR-Updater".

.PARAMETER Visibility
    Repository visibility: "private" or "public". Defaults to "private".

.PARAMETER SkipPush
    Initialize the local repo and commit, but do not create or push to GitHub.

.EXAMPLE
    .\Init-GitRepo.ps1
    Initializes repo with default name "DFIR-Updater" (private).

.EXAMPLE
    .\Init-GitRepo.ps1 -RepoName "my-dfir-tools" -Visibility public
    Creates a public repo named "my-dfir-tools".

.EXAMPLE
    .\Init-GitRepo.ps1 -SkipPush
    Initializes the local Git repo and commits files without pushing to GitHub.

.NOTES
    Requires: git, gh (GitHub CLI, authenticated via 'gh auth login')
    Run from the DFIR-Updater directory on the USB drive.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$RepoName = 'DFIR-Updater',

    [Parameter()]
    [ValidateSet('private', 'public')]
    [string]$Visibility = 'private',

    [switch]$SkipPush
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# =============================================================================
# Path Resolution
# =============================================================================
$script:ScriptDir = $PSScriptRoot
if (-not $script:ScriptDir) { $script:ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition }

# =============================================================================
# Helper Functions
# =============================================================================
function Write-Header {
    param([string]$Text)
    Write-Host ''
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host "  $('-' * $Text.Length)" -ForegroundColor DarkCyan
}

function Write-Ok {
    param([string]$Text)
    Write-Host "  [OK] $Text" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Text)
    Write-Host "  [!!] $Text" -ForegroundColor Yellow
}

function Write-Fail {
    param([string]$Text)
    Write-Host "  [XX] $Text" -ForegroundColor Red
}

function Write-Info {
    param([string]$Text)
    Write-Host "  [--] $Text" -ForegroundColor Gray
}

function Write-Step {
    param([string]$Text)
    Write-Host "  [>>] $Text" -ForegroundColor White
}

function Read-YesNo {
    param([string]$Prompt)
    do {
        Write-Host ''
        Write-Host "  $Prompt " -ForegroundColor White -NoNewline
        $answer = Read-Host
    } while ($answer -notmatch '^[YyNn]$')
    return $answer -match '^[Yy]$'
}

function Test-CommandExists {
    param([string]$Command)
    $null -ne (Get-Command -Name $Command -ErrorAction SilentlyContinue)
}

# =============================================================================
# Banner
# =============================================================================
Write-Host ''
Write-Host '  ============================================================' -ForegroundColor Cyan
Write-Host '   DFIR-Updater - Git Repository Initialization'               -ForegroundColor Cyan
Write-Host '  ============================================================' -ForegroundColor Cyan
Write-Host ''
Write-Host "   Directory  : $($script:ScriptDir)" -ForegroundColor White
Write-Host "   Repo Name  : $RepoName" -ForegroundColor White
Write-Host "   Visibility : $Visibility" -ForegroundColor White
Write-Host ''

# =============================================================================
# Step 1: Check Prerequisites
# =============================================================================
Write-Header 'Step 1: Checking Prerequisites'

# --- Git ---
if (-not (Test-CommandExists 'git')) {
    Write-Fail 'git is not installed or not in PATH.'
    Write-Host ''
    Write-Host '  To install git:' -ForegroundColor Yellow
    Write-Host '    Option 1: Download from https://git-scm.com/downloads' -ForegroundColor Gray
    Write-Host '    Option 2: winget install Git.Git' -ForegroundColor Gray
    Write-Host '    Option 3: choco install git' -ForegroundColor Gray
    Write-Host ''
    Write-Fail 'Cannot continue without git. Aborting.'
    exit 1
}
$gitVersion = & git --version 2>&1
Write-Ok "git found: $gitVersion"

# --- GitHub CLI ---
if (-not $SkipPush) {
    if (-not (Test-CommandExists 'gh')) {
        Write-Fail 'gh (GitHub CLI) is not installed or not in PATH.'
        Write-Host ''
        Write-Host '  To install GitHub CLI:' -ForegroundColor Yellow
        Write-Host '    Option 1: Download from https://cli.github.com/' -ForegroundColor Gray
        Write-Host '    Option 2: winget install GitHub.cli' -ForegroundColor Gray
        Write-Host '    Option 3: choco install gh' -ForegroundColor Gray
        Write-Host ''
        Write-Host '  After installing, authenticate with: gh auth login' -ForegroundColor Yellow
        Write-Host ''
        Write-Fail 'Cannot create GitHub repo without gh. Aborting.'
        Write-Info 'Tip: Use -SkipPush to initialize the local repo only.'
        exit 1
    }
    $ghVersion = & gh --version 2>&1 | Select-Object -First 1
    Write-Ok "gh found: $ghVersion"

    # Check gh auth status
    $authStatus = & gh auth status 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Fail 'gh is not authenticated. Please run: gh auth login'
        Write-Host ''
        foreach ($line in $authStatus) {
            Write-Host "    $line" -ForegroundColor Gray
        }
        Write-Host ''
        Write-Fail 'Cannot continue without GitHub authentication. Aborting.'
        exit 1
    }
    Write-Ok 'gh is authenticated.'
}

# =============================================================================
# Step 2: Check for Existing Git Repo
# =============================================================================
Write-Header 'Step 2: Initializing Git Repository'

$gitDir = Join-Path $script:ScriptDir '.git'
$isExistingRepo = Test-Path -LiteralPath $gitDir

if ($isExistingRepo) {
    Write-Warn 'A .git directory already exists in this folder.'
    $remotes = & git -C $script:ScriptDir remote -v 2>&1
    if ($remotes) {
        Write-Info 'Current remotes:'
        foreach ($line in $remotes) {
            Write-Host "    $line" -ForegroundColor Gray
        }
    }

    if (-not (Read-YesNo 'Continue with existing repo? (Y/N)')) {
        Write-Info 'Aborting. No changes made.'
        exit 0
    }
} else {
    # Initialize new repo
    Write-Step 'Running: git init'
    $initOutput = & git -C $script:ScriptDir init 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "git init failed: $initOutput"
        exit 1
    }
    Write-Ok 'Git repository initialized.'
}

# =============================================================================
# Step 3: Verify .gitignore
# =============================================================================
Write-Header 'Step 3: Checking .gitignore'

$gitignorePath = Join-Path $script:ScriptDir '.gitignore'
if (Test-Path -LiteralPath $gitignorePath) {
    Write-Ok '.gitignore is present.'
} else {
    Write-Warn '.gitignore not found. Creating a default one.'
    $defaultGitignore = @(
        '# Backup files from updates'
        '*.bak_*'
        ''
        '# Machine-specific'
        'scan-manifest.json'
        'setup-log.txt'
        ''
        '# Temp files'
        '*.tmp'
        '*.temp'
        '~$*'
        ''
        '# Python'
        '__pycache__/'
        '*.pyc'
        '*.pyo'
        ''
        '# OS files'
        '.DS_Store'
        'Thumbs.db'
        'desktop.ini'
        ''
        '# Logs'
        '*.log'
    )
    try {
        Set-Content -LiteralPath $gitignorePath -Value $defaultGitignore -ErrorAction Stop
        Write-Ok '.gitignore created.'
    }
    catch {
        Write-Fail "Failed to create .gitignore: $_"
    }
}

# =============================================================================
# Step 4: Stage and Commit
# =============================================================================
Write-Header 'Step 4: Staging and Committing Files'

# Stage all files
Write-Step 'Running: git add -A'
$addOutput = & git -C $script:ScriptDir add -A 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Fail "git add failed: $addOutput"
    exit 1
}

# Show what is staged
$statusOutput = & git -C $script:ScriptDir status --short 2>&1
$stagedCount = @($statusOutput | Where-Object { $_ -match '\S' }).Count

if ($stagedCount -eq 0) {
    Write-Info 'No changes to commit (working tree clean).'

    # Check if there are existing commits
    $logCheck = & git -C $script:ScriptDir log --oneline -1 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Warn 'No commits exist and nothing to commit. The repo is empty.'
        Write-Fail 'Aborting: nothing to push.'
        exit 1
    }

    Write-Ok 'Existing commits found. Proceeding to push.'
} else {
    Write-Info "$stagedCount file(s) staged:"
    foreach ($line in $statusOutput) {
        if ($line -match '\S') {
            Write-Host "    $line" -ForegroundColor Gray
        }
    }

    # Commit
    $commitMsg = "Initial commit: DFIR-Updater framework`n`nIncludes tool configuration, update checker, auto-discovery module,`nGUI launcher, portable setup, auto-launch setup, and bootstrap scripts."

    Write-Step 'Committing...'
    $commitOutput = & git -C $script:ScriptDir commit -m $commitMsg 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "git commit failed: $commitOutput"
        exit 1
    }
    Write-Ok 'Files committed.'
}

# Ensure we are on 'main' branch
$currentBranch = & git -C $script:ScriptDir branch --show-current 2>&1
if ($currentBranch -ne 'main') {
    Write-Info "Current branch is '$currentBranch'. Renaming to 'main'."
    & git -C $script:ScriptDir branch -M main 2>&1 | Out-Null
    Write-Ok "Branch renamed to 'main'."
}

# =============================================================================
# Step 5: Ask for Repo Details (if pushing)
# =============================================================================
if (-not $SkipPush) {
    Write-Header 'Step 5: GitHub Repository Setup'

    # Check if user wants to customize the repo name
    Write-Host ''
    Write-Host "  Repo name  : " -ForegroundColor White -NoNewline
    Write-Host $RepoName -ForegroundColor Yellow
    Write-Host "  Visibility : " -ForegroundColor White -NoNewline
    Write-Host $Visibility -ForegroundColor Yellow

    if (Read-YesNo "Create GitHub repo '$RepoName' ($Visibility)? (Y/N)") {
        # Create the GitHub repo
        Write-Step "Creating GitHub repository: $RepoName ($Visibility)"

        $ghArgs = @(
            'repo', 'create', $RepoName,
            "--$Visibility",
            '--source', $script:ScriptDir,
            '--remote', 'origin',
            '--description', 'DFIR Drive Updater - Portable forensics USB drive management framework'
        )

        $createOutput = & gh @ghArgs 2>&1
        if ($LASTEXITCODE -ne 0) {
            # Check if remote origin already exists
            $existingRemote = & git -C $script:ScriptDir remote get-url origin 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Warn "Remote 'origin' already exists: $existingRemote"
                Write-Info 'Attempting to push to existing remote.'
            } else {
                Write-Fail "Failed to create GitHub repository:"
                foreach ($line in $createOutput) {
                    Write-Host "    $line" -ForegroundColor Red
                }
                Write-Host ''
                Write-Info 'You can manually create the repo and add the remote:'
                Write-Info "  gh repo create $RepoName --$Visibility"
                Write-Info "  git remote add origin https://github.com/<user>/$RepoName.git"
                Write-Info '  git push -u origin main'
                exit 1
            }
        } else {
            Write-Ok 'GitHub repository created.'
        }

        # =============================================================================
        # Step 6: Push to GitHub
        # =============================================================================
        Write-Header 'Step 6: Pushing to GitHub'

        Write-Step 'Running: git push -u origin main'
        $pushOutput = & git -C $script:ScriptDir push -u origin main 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Fail "git push failed:"
            foreach ($line in $pushOutput) {
                Write-Host "    $line" -ForegroundColor Red
            }
            Write-Host ''
            Write-Info 'You can retry manually with: git push -u origin main'
            exit 1
        }
        Write-Ok 'Pushed to GitHub successfully.'

        # =============================================================================
        # Step 7: Show Repo URL
        # =============================================================================
        Write-Header 'Repository Details'

        $repoUrl = & gh repo view --json url -q '.url' 2>&1
        if ($LASTEXITCODE -eq 0 -and $repoUrl) {
            Write-Host ''
            Write-Host "  Repository URL : " -ForegroundColor White -NoNewline
            Write-Host $repoUrl -ForegroundColor Green
            Write-Host ''
            Write-Host '  Clone command  : ' -ForegroundColor White -NoNewline
            Write-Host "git clone $repoUrl" -ForegroundColor Gray
            Write-Host ''
        } else {
            # Fallback: construct URL from remote
            $remoteUrl = & git -C $script:ScriptDir remote get-url origin 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Host ''
                Write-Host "  Remote URL : " -ForegroundColor White -NoNewline
                Write-Host $remoteUrl -ForegroundColor Green
                Write-Host ''
            }
        }
    } else {
        Write-Info 'Skipped GitHub repo creation.'
        Write-Info 'Your local Git repo is ready. You can push later with:'
        Write-Info "  gh repo create $RepoName --$Visibility --source . --remote origin"
        Write-Info '  git push -u origin main'
    }
} else {
    Write-Header 'Step 5: Push Skipped'
    Write-Ok 'Local Git repository is ready.'
    Write-Info 'To push to GitHub later, run:'
    Write-Info "  gh repo create $RepoName --$Visibility --source . --remote origin"
    Write-Info '  git push -u origin main'
}

# =============================================================================
# Done
# =============================================================================
Write-Host ''
Write-Host '  ============================================================' -ForegroundColor Cyan
Write-Host '   Git Repository Initialization Complete'                      -ForegroundColor Cyan
Write-Host '  ============================================================' -ForegroundColor Cyan
Write-Host ''

# Show what to do next
Write-Host '  Next steps:' -ForegroundColor White
Write-Host '    1. Clone the repo on a new machine:' -ForegroundColor Gray
Write-Host "       git clone <repo-url>" -ForegroundColor DarkGray
Write-Host '    2. Run Bootstrap-DFIR-Drive.ps1 to set up a new USB drive:' -ForegroundColor Gray
Write-Host '       .\Bootstrap-DFIR-Drive.ps1 -DriveLetter E' -ForegroundColor DarkGray
Write-Host ''
