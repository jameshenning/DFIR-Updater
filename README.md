# DFIR Drive Updater

A portable, self-contained update manager for DFIR (Digital Forensics & Incident Response) USB toolkits. Plug in your drive, and it automatically checks for updates to your forensic tools — then lets you pick which ones to update with a single click.

---

## Glossary

| Term | Definition |
|---|---|
| **DFIR** | Digital Forensics & Incident Response — the discipline of collecting, preserving, and analyzing digital evidence from computers, networks, and devices. |
| **Write blocker** | A hardware device or software mechanism that prevents any data from being written to a storage device, preserving the original contents for forensic integrity. Hardware write blockers are physically enforced; software write blockers rely on the operating system honoring a read-only flag. |
| **Volume label** | A user-assigned name for a disk drive (e.g., "DFIR"). Windows displays it in File Explorer next to the drive letter. The updater uses it to find your USB drive regardless of which letter Windows assigns. You can set it in File Explorer by right-clicking the drive and choosing Properties. |
| **Lockfile** | A small file whose mere presence signals a state. The `FORENSIC_MODE` file on the drive root acts as a lockfile — when it exists, the updater knows to block itself. No data inside the file matters; only its existence or absence. |
| **WPF** | Windows Presentation Foundation — a Microsoft UI framework built into Windows. The updater uses it to render its dark-themed GUI window with buttons, checkboxes, progress bars, and data grids. No installation needed — WPF is included in every Windows 10/11 system. |
| **Task Scheduler** | A built-in Windows service that runs programs on a schedule or in response to events (like a USB device being plugged in). The updater registers a scheduled task so it can auto-launch when the drive is connected. |
| **Event ID 112** | A Windows log event fired by the DeviceSetupManager service when a new device (such as a USB drive) finishes its setup and installation. The updater's scheduled task listens for this event as its trigger to launch. |
| **UAC** | User Account Control — a Windows security feature that prompts for confirmation before allowing programs to run with administrator privileges. Write Protection requires a UAC prompt because changing disk attributes needs elevated access. |
| **Prefetch** | A Windows performance feature that caches information about recently run programs in `C:\Windows\Prefetch\`. Forensic examiners check these files to determine what software has been executed on a system. The forensic cleanup script removes any prefetch entries left by the updater. |
| **Regex** | Regular expression — a pattern-matching syntax used to identify text strings. The updater uses regex patterns in `tools-config.json` to match release asset filenames (e.g., `hashcat-[\d.]+\.7z` matches `hashcat-7.1.2.7z`) and to extract version numbers from file or folder names. |
| **GitHub API** | A web interface provided by GitHub that allows programs to query repository data (releases, tags, file lists) without using a browser. The updater calls the GitHub API to check if a newer release exists for each GitHub-sourced tool. |
| **GitHub release** | A tagged version of a software project on GitHub, often accompanied by downloadable binary files (called "assets"). The updater checks the latest release for each GitHub-sourced tool and compares its version tag against the locally installed version. |

---

## Features

- **Automatic update checking** — Queries GitHub releases and known download sources for newer versions of your tools
- **WPF GUI** — Dark-themed, professional interface with color-coded status rows, checkboxes for selective updates, a progress bar, and a live scrolling log panel
- **Auto-discovery** — Scans your drive for newly added tools and offers to add them to the update tracker with pre-filled configuration, matching against a database of 133+ known DFIR GitHub repositories
- **Auto-launch on plug-in** — Registers a Windows Task Scheduler event that triggers when any USB device is connected, then finds your DFIR drive by volume label
- **Fully portable** — Runs from the USB drive on any Windows 10/11 machine with no installation required
- **Backup & rollback** — Creates timestamped backups before every update and rolls back automatically on failure
- **Dynamic drive detection** — Works regardless of which drive letter Windows assigns
- **Tool Launcher** — Browse and launch any tool on the drive with a visual tile-based interface, organized by category with search and filtering
- **Shortcut creation** — Generates `.lnk` shortcuts for all DFIR tools in a `Shortcuts` folder
- **Forensic mode** — Prevents the updater from running on target/evidence computers while keeping all DFIR tools accessible
- **Write protection** — Sets a disk-level readonly attribute to prevent any program from writing to the drive (requires admin)

---

## Quick Start

### First Time Setup

1. Plug in your DFIR USB drive
2. Open `DFIR-Updater\Launch-Updater.bat` (double-click)
3. The launcher will ask if you want to set up auto-launch — say **Y**
4. The GUI will open and begin checking for updates

### Subsequent Use

- **Automatic**: Just plug in the drive. The updater launches itself after a 10-second delay.
- **Manual**: Double-click `Launch-Updater.bat` at any time.

### On a New Computer

1. Double-click `Launch-Updater.bat` — it detects this is a new machine and offers to register the auto-launch task
2. Or run `Portable-Setup.ps1` in PowerShell for a guided first-run wizard that also verifies connectivity and drive label

---

## The GUI

When the updater launches, it opens a dark-themed WPF window with the following elements:

- **Tool list (data grid)** — Each row shows a tool with columns for: checkbox (select for update), tool name, current version, latest version, status, and source type. Rows are color-coded:
  - **Green background** — Tool is up to date (latest version matches current version)
  - **Yellow background** — Update available (a newer version was found on GitHub)
  - **Gray background** — Manual check required (web-sourced tool with no API, or check failed)
- **"Check for Updates" button** — Queries all GitHub-sourced tools for their latest release and compares versions. Web-sourced tools are flagged as "Check manually" with a clickable link to their download page.
- **"Update Selected" button** — Downloads and installs updates for all tools with checked checkboxes. For each selected tool, the updater: (1) downloads the release asset to a temp folder, (2) creates a timestamped backup of the existing files, (3) extracts or copies the new files into place, (4) verifies the update succeeded. If any step fails, it automatically restores from the backup.
- **"Scan for New Tools" button** — Runs the auto-discovery module to detect tools on the drive that aren't yet tracked in `tools-config.json`. Displays results in a popup where you can review and add them with one click.
- **"Tool Launcher" button** — Opens a separate window that displays every launchable tool on the drive as a clickable tile with its icon. Supports category filtering and search. Automatically discovers new tools when you add them to the drive.
- **Progress bar** — Shows download and installation progress during updates.
- **Log panel** — A scrolling text area at the bottom that displays real-time status messages, API responses, errors, and version comparison results as the updater works.
- **Forensic Mode badge** — A green "FORENSIC MODE: OFF" label in the header. Click to toggle. When active, all update/modification buttons are disabled.
- **Right-click context menu** — On any tool row: open download page, mark as updated, or set a custom version number.

---

## Forensic Mode

Forensic Mode blocks ONLY the updater system (auto-launch, update checks, downloads) while keeping all DFIR tools fully functional. Use it to prevent the updater from writing artifacts to a target or evidence computer.

### How It Works

Forensic Mode uses a **lockfile** — a file named `FORENSIC_MODE` at the drive root (e.g., `D:\FORENSIC_MODE`). Every entry point in the updater system (`Launch-Updater.bat`, `DFIR-Updater-GUI.ps1`, the scheduled task action) checks for this file before proceeding. If the file exists, the updater refuses to run and displays a warning message.

Because the lockfile lives **on the USB drive itself** (not on any computer), it travels with the drive and stays active on every computer you plug into — until you explicitly toggle it off.

### Toggling Forensic Mode

- **Double-click `Forensic-Mode.bat`** to toggle ON/OFF. The script will confirm the current state.
- **Or manually** create or delete a `FORENSIC_MODE` file at the drive root (e.g., `D:\FORENSIC_MODE`). The file contents do not matter — only its presence or absence.

### What It Blocks vs. What Still Works

| Component | Forensic Mode OFF | Forensic Mode ON |
|---|---|---|
| FTK Imager, KAPE, all DFIR tools | Works | Works |
| Auto-launch on USB insert | Runs | Blocked |
| Update checker / downloads | Runs | Blocked |
| Updater GUI | Runs | Blocked |

### Forensic Cleanup

If you forgot to enable Forensic Mode before plugging into a target, use `Forensic-Cleanup.ps1` to remove updater artifacts from the target computer. The script scans four categories of artifacts:

1. **Temp files** — Checks `%TEMP%\DFIR-Updater\` for downloaded files and extracts left behind by the updater
2. **Prefetch entries** — Scans `C:\Windows\Prefetch\` for cached execution records matching DFIR-Updater patterns (requires admin to delete)
3. **Recent file shortcuts** — Checks the Windows Recent Items folder for `.lnk` references to DFIR-Updater files
4. **Event log entries** — Queries DeviceSetupManager Event ID 112 entries (informational only — event logs cannot be selectively cleared)

Found files are **securely deleted**: their contents are overwritten with zeros before deletion to hinder trivial recovery. A cleanup report is saved to the `cleanup-reports/` directory on the USB drive.

**Usage:**

```powershell
# Full cleanup with report
.\Forensic-Cleanup.ps1

# Report only — show what would be cleaned without deleting anything
.\Forensic-Cleanup.ps1 -ReportOnly

# Preview what would be deleted without performing any changes
.\Forensic-Cleanup.ps1 -WhatIf

# Prompt for confirmation before each deletion
.\Forensic-Cleanup.ps1 -Confirm
```

### Best Practice Workflow

```
1. At YOUR workstation  → Plug in drive, double-click Forensic-Mode.bat (ON)
2. Eject drive           → FORENSIC_MODE lockfile is now on the drive
3. At TARGET computer    → Plug in drive, use your tools (FTK Imager, KAPE, etc.)
                            The updater will NOT run — forensic mode is active
4. Eject from target     → Unplug when done
5. At YOUR workstation   → Plug in drive, double-click Forensic-Mode.bat (OFF)
6. Updater launches      → Checks for updates as normal
```

**Important:** Always toggle forensic mode ON from your own machine *before* approaching the target. The lockfile persists on the drive across all computers until you explicitly remove it.

---

## Write Protection

Write Protection sets a **disk-level readonly attribute** on the USB drive using Windows disk management. When enabled, the operating system on the target computer will refuse to write any data to the drive — no files can be created, modified, or deleted by any program.

### How It Works

The script uses the Windows `Set-Disk -IsReadOnly` PowerShell cmdlet to toggle the disk's readonly flag. If the Storage cmdlets are unavailable (older systems or certain disk configurations), it automatically falls back to `diskpart` (the Windows command-line disk partitioning utility) with `attributes disk set readonly` / `attributes disk clear readonly`.

The readonly attribute is stored in the Windows disk management layer. When you set it on your workstation, the flag tells the operating system to deny write operations to that disk. The script verifies the change took effect after toggling.

> **Important:** This is a software-level protection. It is **not equivalent to a hardware write blocker** for court-admissible evidence handling. Modern Windows generally honors the readonly attribute, but it is not enforced at the hardware/firmware level — a compromised or non-Windows OS could potentially bypass it. For maximum forensic soundness, use a USB drive with a physical write-protect switch (e.g., Kanguru FlashBlu30) or a dedicated hardware write blocker.

### Toggling Write Protection

- **Double-click `Write-Protect.bat`** — the script requests administrator privileges via a UAC prompt (required for disk attribute changes), then toggles the readonly attribute on or off.
- The script identifies the correct disk for the drive letter, displays its current status (disk number, name, size, and readonly state), toggles it, and verifies the change.

**Why admin is required:** Changing disk-level attributes affects the entire disk, not just individual files. Windows requires administrator privileges for this operation to prevent unprivileged programs from locking or unlocking drives.

### Check Status Only

```powershell
# Run as administrator:
.\Write-Protect.ps1 -Status

# Check a specific drive letter:
.\Write-Protect.ps1 -DriveLetter E -Status
```

### What It Does

| State | Effect |
|---|---|
| **Write Protection ON** | Windows treats the entire USB drive as read-only. No files can be created, modified, or deleted on the drive by any program. |
| **Write Protection OFF** | Normal read-write access. The updater and other tools can write to the drive. |

### Combining with Forensic Mode

Write Protection and Forensic Mode serve complementary purposes and are designed to be used together:

| Layer | What It Protects | How | Admin Required? |
|---|---|---|---|
| **Forensic Mode** | Prevents the *updater* from running | Lockfile checked by updater scripts | No |
| **Write Protection** | Prevents *any program* from writing to the drive | OS-level disk readonly attribute | Yes |

Forensic Mode alone is sufficient if you only want to stop the updater. Write Protection adds a second layer that blocks all writes from any source — the operating system itself enforces the restriction.

**Recommended workflow for target examinations:**

```
1. At YOUR workstation  → Double-click Forensic-Mode.bat (ON)
2. At YOUR workstation  → Double-click Write-Protect.bat (ON, click Yes on UAC prompt)
3. Eject drive           → Drive is now locked: updater blocked + disk read-only
4. At TARGET computer    → Plug in drive, use your tools (FTK Imager, KAPE, etc.)
                            Nothing can write to your drive
5. Eject from target     → Unplug when done
6. At YOUR workstation   → Double-click Write-Protect.bat (OFF, click Yes on UAC prompt)
7. At YOUR workstation   → Double-click Forensic-Mode.bat (OFF)
8. Updater launches      → Checks for updates as normal
```

**Note:** You must disable Write Protection (step 6) before disabling Forensic Mode (step 7), because the updater needs write access to function.

### Logging

All write protection toggles are logged to `write-protect-logs/write-protect.log` on the USB drive. Each entry records the timestamp, computer name, username, disk number, disk name, and the action taken. When turning protection ON, the log is written before the drive becomes read-only.

---

## How It Works

### Architecture

```
D:\DFIR-Updater\
├── Launch-Updater.bat           # Double-click launcher (entry point)
├── DFIR-Updater-GUI.ps1         # Main WPF GUI application
├── Setup-AutoLaunch.ps1         # Task Scheduler registration
├── Portable-Setup.ps1           # First-run wizard for new machines
├── Bootstrap-DFIR-Drive.ps1     # Clone toolkit to a new USB drive
├── Init-GitRepo.ps1             # Push framework to GitHub
├── Forensic-Mode.bat            # Toggle Forensic Mode on/off
├── Forensic-Cleanup.ps1         # Remove updater artifacts from target
├── Write-Protect.bat            # Toggle disk write protection (requires admin)
├── Write-Protect.ps1            # Write protection logic (Set-Disk readonly)
├── Create-Shortcuts.ps1            # Generate .lnk shortcuts for all tools
├── tools-config.json            # Tool definitions and update sources
├── scan-manifest.json           # Auto-discovery tracking (auto-generated)
├── cleanup-reports/             # Forensic cleanup reports (auto-generated)
├── write-protect-logs/          # Write protection toggle logs (auto-generated)
├── FORENSIC_MODE                # Lockfile — present when Forensic Mode is ON
├── .gitignore                   # Git ignore rules
├── README.md                    # This file
├── README.txt                   # Plain-text quick reference
└── modules/
    ├── Update-Checker.ps1       # GitHub API, version comparison, downloads
    ├── Auto-Discovery.ps1       # New tool detection and identification
    └── Tool-Launcher.ps1        # Drive scanning for the Tool Launcher window
```

### Script Descriptions

| Script | Purpose | Admin Required? |
|---|---|---|
| `Launch-Updater.bat` | Entry point. Checks for Forensic Mode lockfile, offers to set up auto-launch if not registered, then launches the GUI via PowerShell with `-ExecutionPolicy Bypass`. | No |
| `DFIR-Updater-GUI.ps1` | Main application. Builds the WPF window, loads tool config, runs update checks in background threads (runspaces), handles downloads and installations. | No |
| `Setup-AutoLaunch.ps1` | Creates/removes/checks the Windows Task Scheduler task. Accepts `-Check` to query status and `-Remove` to unregister the task. | No (user-level task) |
| `Portable-Setup.ps1` | 5-step first-run wizard: registers scheduled task, verifies volume label, validates config, tests internet connectivity, and checks file integrity. | No |
| `Bootstrap-DFIR-Drive.ps1` | Sets up a new USB drive from scratch. Creates folder structure, downloads all GitHub-sourced tools, logs web-sourced tools for manual download, optionally sets volume label and registers auto-launch. Accepts `-DriveLetter` (required), `-SkipDownloads`, `-ToolsOnly`, and `-GitHubToken`. | No |
| `Init-GitRepo.ps1` | Initializes a git repository and pushes the framework to GitHub using the `gh` CLI. Accepts `-RepoName` (default "DFIR-Updater"), `-Visibility` (default "private"), and `-SkipPush`. | No |
| `Forensic-Mode.bat` | Toggles the `FORENSIC_MODE` lockfile on/off at the drive root. | No |
| `Forensic-Cleanup.ps1` | Scans a target computer for updater artifacts and securely deletes them (zero-overwrite). Accepts `-ReportOnly`, `-WhatIf`, `-Confirm`, and `-Verbose`. | Partial (prefetch cleanup needs admin) |
| `Write-Protect.bat` | Entry point for write protection. Handles UAC elevation and calls `Write-Protect.ps1`. | Yes |
| `Write-Protect.ps1` | Toggles the disk readonly attribute. Accepts `-DriveLetter` and `-Status`. Uses `Set-Disk` with `diskpart` fallback. | Yes |
| `Create-Shortcuts.ps1` | Creates `.lnk` shortcuts in `D:\Shortcuts\` for all known DFIR tools on the drive. Safe to run multiple times. | No |
| `modules/Update-Checker.ps1` | Backend module. Functions for GitHub API queries, version comparison, web scraping, asset downloads, backup creation, extraction, and rollback. | No |
| `modules/Auto-Discovery.ps1` | Backend module. Scans drive folders for untracked tools, matches against 133+ known DFIR GitHub repositories, extracts version numbers, and generates config entries. | No |
| `modules/Tool-Launcher.ps1` | Backend module. Scans all category folders and PortableApps for launchable executables, extracts icons, and returns a tool inventory for the Tool Launcher window. Read-only, safe for Forensic Mode. | No |

### Update Flow

```
USB Plugged In
     │
     ▼
Task Scheduler fires (Event ID 112 — device setup complete)
     │
     ▼
Wait 10 seconds (drive letter assignment)
     │
     ▼
Check for FORENSIC_MODE lockfile on drive ──► Found? → Exit silently
     │
     ▼ (not found)
Find drive by volume label "DFIR"
(fallback: scan all drives for DFIR-Updater folder)
     │
     ▼
Launch DFIR-Updater-GUI.ps1
     │
     ├──► Load tools-config.json
     │
     ├──► For each GitHub-sourced tool:
     │       Query GitHub API /repos/{owner}/{repo}/releases/latest
     │       → Extract version from release tag using version_pattern regex
     │       → Compare against current_version (numeric segment-by-segment)
     │       → Flag as "Update available" if remote version is newer
     │
     ├──► For each web-sourced tool:
     │       Flag as "Check manually" with clickable link to download_url
     │
     ▼
Display results in GUI (color-coded rows)
     │
     ├──► User selects tools to update (checkboxes)
     │
     ├──► "Update Selected" button:
     │       For each checked tool:
     │         1. Download asset matching github_asset_pattern to %TEMP%\DFIR-Updater\
     │         2. Create backup: copy existing files to <path>.bak_YYYYMMDD_HHmmss
     │         3. Install based on install_type:
     │            • extract_zip  → Extract zip, replace folder contents
     │            • extract_7z   → Extract 7z archive, replace folder contents
     │            • copy_exe     → Copy single executable to target path
     │            • manual       → Skip (display instructions in notes)
     │         4. Update current_version in tools-config.json
     │         5. On failure → Restore from backup automatically
     │
     └──► "Scan for New Tools" button:
             Run Auto-Discovery module
             → Scan category folders (01_Acquisition/, 02_Analysis/, etc.)
             → Compare found items against tools-config.json
             → Match against known DFIR repo database
             → Show results in popup for review and one-click addition
```

### Tool Launcher

The Tool Launcher is an integrated window accessible from the main GUI via the "Tool Launcher" button. It provides a visual, tile-based interface for launching any tool on the drive.

**Features:**

- **Automatic scanning** — Discovers all launchable executables across category folders (`01_Acquisition/`, `02_Analysis/`, etc.) and the `PortableApps/` directory
- **Icon extraction** — Extracts and displays icons from executables. For PortableApps, uses the `appicon_32.png` if available. Falls back to a generic icon for `.bat` files and tools without extractable icons
- **Category tabs** — Filter tools by category (Acquisition, Analysis, Network, Mobile, PortableApps, Utilities, or All)
- **Search** — Live search across all tool names
- **Click to launch** — Single-click any tile to launch the tool. Sets the working directory to the tool's folder
- **Refresh** — Rescan the drive to detect newly added tools without restarting the application
- **Read-only operation** — The launcher only reads the drive; it never writes. Safe to use in Forensic Mode

**How it discovers tools:**

1. **Known tools** — A built-in registry of well-known DFIR tools (FTK Imager, KAPE, hashcat, etc.) with curated display names and correct primary executables
2. **Category folders** — For unknown subdirectories, picks the primary executable by matching the folder name or selecting the largest `.exe`
3. **PortableApps** — Parses `appinfo.ini` from each PortableApps folder to get the display name and correct executable
4. **Deduplication** — Ensures each executable appears only once, even if discovered by multiple methods

### Version Comparison

The updater compares versions by splitting version strings on `.` (dot) and comparing each numeric segment left to right. For example:

- `6.2.6` vs `7.1.2` → `6 < 7` → **update available**
- `3.11.307` vs `3.11.307` → all segments equal → **up to date**
- `1.2` vs `1.2.1` → first two segments equal, remote has extra segment → **update available**

Version strings are extracted from GitHub release tags using the `version_pattern` regex defined for each tool (e.g., `v([\d.]+)` extracts `3.11.307` from the tag `v3.11.307`).

### Update Sources

| Source Type | How It Works | Example Tools |
|---|---|---|
| **GitHub** (`source_type: "github"`) | Queries the GitHub REST API endpoint `/repos/{owner}/{repo}/releases/latest`. Compares the release tag against the locally stored `current_version`. Downloads the release asset whose filename matches the `github_asset_pattern` regex. | hashcat, UniGetUI |
| **Web** (`source_type: "web"`) | Stores the vendor's download page URL in `download_url`. The GUI flags the tool as "Check manually" and provides a clickable link to the download page. No automated version checking is possible for these tools. | FTK Imager, KAPE, Arsenal Image Mounter, ExifTool, NetworkMiner, NirSoft tools |

### Auto-Discovery

When you add new tools to the drive, the auto-discovery module detects them and offers to add them to the update tracker:

1. **Scans** the numbered category folders (`01_Acquisition/`, `02_Analysis/`, `03_Network/`, etc.) up to 2 directory levels deep. The `PortableApps/` folder is excluded (it has its own update system).
2. **Filters** out items already tracked in `tools-config.json` and items within tracked tool directories (to avoid flagging internal files of known tools).
3. **Compares** found executables and tool folders against a built-in database of 133+ known DFIR GitHub repositories (including tools like Volatility, Autopsy, Wireshark, RegRipper, YARA, and many more).
4. **Extracts** version numbers from filenames using common patterns (e.g., `toolname-1.2.3.exe` → version `1.2.3`, `ToolName_v4.0.zip` → version `4.0`).
5. **Generates** pre-filled config entries with the tool name, detected path, matched GitHub repo (if found), extracted version, and suggested `install_type`. You can review and add them with one click in the GUI.

The module maintains a `scan-manifest.json` file to track which items have been seen, ignored, or added, so it doesn't repeatedly prompt you about the same files.

---

## Configuration

### tools-config.json

The configuration file is a JSON document with three sections:

- **`tools`** — An array of tool definitions (the main section)
- **`update_scripts`** — Named shell commands for batch-updating tool families (see below)
- **`version`** / **`last_updated`** — Metadata for tracking config changes

Each tool is defined as a JSON object in the `tools` array:

```json
{
  "name": "hashcat",
  "path": "02_Analysis/hashcat-6.2.6",
  "source_type": "github",
  "github_repo": "hashcat/hashcat",
  "github_asset_pattern": "hashcat-[\\d.]+\\.7z",
  "download_url": null,
  "current_version": "6.2.6",
  "version_pattern": "hashcat-([\\d.]+)",
  "install_type": "extract_7z",
  "notes": "Released as .7z archive on GitHub. Requires OpenCL-compatible GPU drivers."
}
```

| Field | Description |
|---|---|
| `name` | Display name shown in the GUI. |
| `path` | Relative path from the drive root to the tool's folder or executable (e.g., `02_Analysis/hashcat-6.2.6`). |
| `source_type` | `"github"` for tools with GitHub releases (enables automatic version checking) or `"web"` for tools that must be checked manually via a download page. |
| `github_repo` | GitHub `owner/repo` string for API queries (e.g., `"hashcat/hashcat"`). Set to `null` for web-sourced tools. |
| `github_asset_pattern` | A regex pattern to match the correct download file from the GitHub release assets list (e.g., `"hashcat-[\\d.]+\\.7z"` matches `hashcat-7.1.2.7z`). Set to `null` for web-sourced tools. |
| `download_url` | The vendor's download page URL for web-sourced tools (e.g., `"https://www.exterro.com/ftk-imager"`). Shown as a clickable link in the GUI. Set to `null` for GitHub-sourced tools. |
| `current_version` | The version string currently installed on the drive (e.g., `"6.2.6"`). Updated automatically after a successful update. Set to `null` if the version is unknown. |
| `version_pattern` | A regex with a capture group to extract the version number from release tags or filenames (e.g., `"v([\\d.]+)"` extracts `3.11.307` from `v3.11.307`). |
| `install_type` | How to install the downloaded file: `"extract_zip"` (extract zip archive), `"extract_7z"` (extract 7z archive), `"copy_exe"` (copy a single executable), or `"manual"` (display instructions only, no automatic install). |
| `notes` | Free-text notes displayed in the GUI and used for manual instructions. |

### update_scripts

The `update_scripts` section defines named commands for batch-updating tool families that have their own update mechanisms:

```json
"update_scripts": {
  "ez_tools_updater": {
    "description": "Update all Eric Zimmerman tools (Timeline Explorer, etc.)",
    "command": "powershell -ExecutionPolicy Bypass -Command \"Invoke-WebRequest ...\""
  },
  "kape_module_updater": {
    "description": "Update KAPE targets and modules from GitHub",
    "command": "D:\\01_Acquisition\\KAPE\\kape\\kape.exe --update"
  }
}
```

These are reference commands — they are not run automatically by the GUI but can be executed manually when needed.

### Adding a Tool Manually

Add a new entry to the `tools` array in `tools-config.json`:

```json
{
  "name": "YARA",
  "path": "02_Analysis/yara-4.5.0",
  "source_type": "github",
  "github_repo": "VirusTotal/yara",
  "github_asset_pattern": "yara-.*-win64\\.zip",
  "download_url": null,
  "current_version": "4.5.0",
  "version_pattern": "v([\\d.]+)",
  "install_type": "extract_zip",
  "notes": ""
}
```

Or use the **"Scan for New Tools"** button in the GUI to auto-detect and add it.

---

## Auto-Launch Setup

The auto-launch system uses Windows Task Scheduler to detect when a USB device is connected and automatically start the updater.

### How It Works

1. The scheduled task is registered at the **user level** (no admin required) and triggers on Windows **Event ID 112** from the `DeviceSetupManager` provider. This event fires when Windows completes the setup/installation of a newly connected device (including USB drives).
2. When triggered, the task waits **10 seconds** to allow Windows to assign a drive letter.
3. It then searches for a volume with the label **"DFIR"** using `Get-Volume`. If no matching label is found, it falls back to scanning all drive letters for a `DFIR-Updater` folder.
4. Before launching, it checks for the `FORENSIC_MODE` lockfile — if present, the task exits silently.
5. If the drive is found and forensic mode is off, it launches `DFIR-Updater-GUI.ps1`.

### Register (on any machine)

```powershell
# From the DFIR-Updater folder on the drive:
.\Setup-AutoLaunch.ps1
```

### Check Status

```powershell
.\Setup-AutoLaunch.ps1 -Check
```

### Remove

```powershell
.\Setup-AutoLaunch.ps1 -Remove
```

**Note:** The scheduled task is registered per-computer. If you use the drive on multiple machines, each machine needs its own registration (the launcher will prompt you automatically on first use).

---

## Backing Up to GitHub / Cloning to a New Drive

The DFIR-Updater framework can be version-controlled with Git and pushed to GitHub, making it easy to replicate your entire toolkit onto fresh USB drives. Only the updater scripts and configuration are stored in Git — the actual tool binaries are downloaded fresh by the bootstrap script.

### Initial Setup (push to GitHub)

```powershell
# From the DFIR-Updater folder:
.\Init-GitRepo.ps1
```

This will:
1. Initialize a git repo in the `DFIR-Updater` folder
2. Create a GitHub repository using the `gh` CLI (public or private, your choice)
3. Push all scripts and config (tools themselves are NOT stored in git — just the registry)

**Prerequisite:** The [GitHub CLI](https://cli.github.com/) (`gh`) must be installed and authenticated on the machine (`gh auth login`).

### Clone to a New USB Drive

```powershell
# On any machine with git installed:
git clone https://github.com/jameshenning/DFIR-Updater.git X:\DFIR-Updater

# Then bootstrap the full toolkit:
powershell -ExecutionPolicy Bypass -File X:\DFIR-Updater\Bootstrap-DFIR-Drive.ps1 -DriveLetter X
```

The bootstrap script will:
1. Create the folder structure (`01_Acquisition/`, `02_Analysis/`, etc.)
2. Download all GitHub-sourced tools from their latest releases
3. Generate a `manual-downloads.txt` listing web-sourced tools that require manual download
4. Optionally set the volume label to "DFIR"
5. Offer to set up auto-launch on the current machine

### Structure-Only Clone (no downloads)

```powershell
.\Bootstrap-DFIR-Drive.ps1 -DriveLetter X -SkipDownloads
```

Creates the folder structure and copies the updater, but doesn't download tools. Useful when you want to manually populate the drive.

---

## Drive Organization

The updater expects tools organized in numbered category folders on the USB drive root:

```
D:\
├── 01_Acquisition\          Disk/memory imaging & evidence capture
├── 02_Analysis\             Artifact analysis & examination tools
├── 03_Network\              Network forensics & analysis
├── 04_Mobile-Forensics\     Mobile device forensics
├── 05_Case-Files\           Case data, reports, memory captures
├── 06_Training\             Training materials & lab files
├── 07_Documentation\        Manuals, guides, references
├── 08_Utilities\            General utilities & system tools
├── PortableApps\            PortableApps.com platform (self-managed, excluded from scanning)
├── Shortcuts\               .lnk files for installed applications
├── Documents\               Personal documents
├── DFIR-Updater\            This updater system
└── Start.exe                PortableApps launcher
```

The auto-discovery module scans the numbered folders (`01_` through `08_`) for new tools. The `PortableApps/` folder is excluded because it has its own built-in update system.

---

## Requirements

- **Windows 10 or 11** (PowerShell 5.1 and WPF are included by default)
- **Internet connection** for checking GitHub releases and downloading updates
- **No admin privileges required** for the updater, auto-launch, forensic mode, or forensic cleanup
- **Administrator privileges required** only for Write Protection (disk attribute changes) and deleting prefetch files during forensic cleanup
- **No installation** — fully self-contained on the USB drive

---

## Troubleshooting

### "Running scripts is disabled on this system"

Use `Launch-Updater.bat` instead of running the `.ps1` files directly. The batch file sets `-ExecutionPolicy Bypass` for the session only — no permanent system changes are made to the computer.

### Auto-launch doesn't trigger

1. Verify the task exists: `Get-ScheduledTask -TaskName DFIR-Drive-Updater`
2. Check your drive's volume label is set to **DFIR**: right-click the drive in File Explorer → Properties → check the name at the top
3. Re-run `Setup-AutoLaunch.ps1` to recreate the task
4. Check Task Scheduler history: open `taskschd.msc` → Task Scheduler Library → DFIR-Drive-Updater → History tab

### GitHub API rate limit

Unauthenticated GitHub API requests are limited to **60 per hour** (per IP address). If you have many GitHub-sourced tools, you may hit this limit. The updater displays a warning when remaining requests are low. To increase the limit to 5,000/hour, add a GitHub personal access token.

### Drive letter changed

This is expected and handled automatically. Both the auto-launch task and the batch launcher dynamically resolve the drive letter at runtime using the volume label or folder detection — no hardcoded drive letters.

### A tool update failed

The updater creates backups before every update in the format `<toolpath>.bak_YYYYMMDD_HHmmss`. If an update fails at any step (download, extraction, or copy), the updater automatically restores from the backup. You can also manually restore by renaming the backup folder back to the original name.

### Write Protection won't toggle

- Make sure you clicked **Yes** on the UAC prompt — disk attribute changes require administrator privileges
- Some USB controllers or virtual disk configurations may not support the software readonly attribute. In this case, use a USB drive with a physical write-protect switch
- If the drive appears stuck as read-only, try ejecting and reinserting it, then run `Write-Protect.bat` again

---

## Security Notes

- The updater only downloads from URLs defined in `tools-config.json` — it never executes arbitrary code from the internet
- All downloads use HTTPS
- Backups are created before any files are modified, enabling automatic rollback on failure
- The scheduled task runs with **Limited** privileges (no elevation) — it cannot modify system files
- Write Protection logs all toggle actions with computer name, username, and timestamps for audit purposes
- Forensic Cleanup uses secure deletion (zero-overwrite) before removing files to hinder trivial recovery
- `autorun.inf` is included but is ignored by modern Windows for USB drives (security policy since Windows 7)

---

## Credits

Built for DFIR field operations. Tools are property of their respective developers and organizations.
