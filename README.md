# DFIR Drive Updater

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![PowerShell 5.1+](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?logo=powershell&logoColor=white)](https://docs.microsoft.com/en-us/powershell/)
[![Platform: Windows](https://img.shields.io/badge/Platform-Windows%2010%2F11-0078D6?logo=windows&logoColor=white)](https://www.microsoft.com/windows)
[![GitHub Release](https://img.shields.io/github/v/release/jameshenning/DFIR-Updater?label=Release)](https://github.com/jameshenning/DFIR-Updater/releases/latest)

A portable, self-contained update manager for DFIR (Digital Forensics & Incident Response) USB toolkits. Plug in your drive, and it automatically checks for updates to your forensic tools -- then lets you pick which ones to update with a single click. No installation required.

<!-- Screenshots
     Add screenshots of the main GUI, Tool Launcher, and Forensic Mode badge below.
     Recommended sizes: 800-1000px wide, PNG format.

     Example:
     ![Main GUI](docs/screenshots/main-gui.png)
     ![Tool Launcher](docs/screenshots/tool-launcher.png)
-->

---

## Table of Contents

- [Features](#features)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
  - [From Release (Recommended)](#from-release-recommended)
  - [From Source](#from-source)
  - [Clone to a New USB Drive](#clone-to-a-new-usb-drive)
- [Usage](#usage)
  - [First Time Setup](#first-time-setup)
  - [Subsequent Use](#subsequent-use)
  - [The GUI](#the-gui)
  - [Tool Launcher](#tool-launcher)
  - [Forensic Mode](#forensic-mode)
  - [Write Protection](#write-protection)
  - [Forensic Cleanup](#forensic-cleanup)
- [Project Structure](#project-structure)
- [Building from Source](#building-from-source)
- [Configuration](#configuration)
  - [tools-config.json](#tools-configjson)
  - [Adding a Tool Manually](#adding-a-tool-manually)
- [Contributing](#contributing)
- [License](#license)
- [Acknowledgments](#acknowledgments)

---

## Features

**Automatic Update Management**

- Queries GitHub releases for 49+ tracked DFIR tools and compares versions automatically
- Selective updates via checkboxes -- choose exactly which tools to update
- Backup and rollback on every update; automatic restore on failure
- Supports multiple install types: zip extraction, 7z extraction, single-exe copy, and manual instructions

**Professional WPF GUI**

- Dark-themed interface with color-coded status rows (green = current, yellow = update available, gray = manual check)
- Real-time progress bar and scrolling log panel
- Right-click context menu for per-tool actions (open download page, set custom version)

**Auto-Discovery**

- Scans the drive for newly added tools not yet tracked in configuration
- Matches against a built-in database of 133+ known DFIR GitHub repositories
- One-click addition with pre-filled configuration entries

**Tool Launcher**

- Visual tile-based interface for browsing and launching any tool on the drive
- Automatic icon extraction, category filtering, and live search
- Read-only operation -- safe to use in Forensic Mode

**Portability and Automation**

- Fully portable on any Windows 10/11 machine with no installation
- Auto-launch via Windows Task Scheduler on USB plug-in (Event ID 112)
- Dynamic drive detection by volume label -- works regardless of assigned drive letter

**Forensic Integrity**

- Forensic Mode blocks all updater activity via a lockfile while keeping DFIR tools fully functional
- Write Protection sets a disk-level readonly attribute to prevent any program from writing to the drive
- Forensic Cleanup securely removes updater artifacts from a target computer (zero-overwrite deletion)
- All write protection toggles are logged with timestamps, computer name, and username for audit trails

---

## Prerequisites

| Requirement | Details |
|---|---|
| **Operating System** | Windows 10 or Windows 11 |
| **PowerShell** | 5.1+ (included with Windows by default) |
| **WPF / .NET Framework** | 4.5+ (included with Windows by default) |
| **Internet Connection** | Required for checking GitHub releases and downloading updates |
| **Administrator Privileges** | Not required for general use. Only needed for Write Protection (disk attribute changes) and prefetch cleanup |

No software installation is needed. The entire application runs from the USB drive.

---

## Installation

### From Release (Recommended)

1. Download `DFIR-Updater-Portable.zip` from the [latest release](https://github.com/jameshenning/DFIR-Updater/releases/latest).
2. Extract the `DFIR-Updater` folder to the root of your DFIR USB drive (e.g., `D:\DFIR-Updater\`).
3. Ensure your drive has the standard category folder structure (see [Project Structure](#project-structure)).
4. Double-click `DFIR-Updater.exe` to launch.

### From Source

1. Clone the repository to your DFIR USB drive:

   ```
   git clone https://github.com/jameshenning/DFIR-Updater.git D:\DFIR-Updater
   ```

2. Double-click `Launch-Updater.bat` or run the PowerShell script directly:

   ```powershell
   powershell -ExecutionPolicy Bypass -File D:\DFIR-Updater\DFIR-Updater-GUI.ps1
   ```

### Clone to a New USB Drive

The bootstrap script creates the full folder structure and downloads all GitHub-sourced tools from their latest releases:

```powershell
git clone https://github.com/jameshenning/DFIR-Updater.git X:\DFIR-Updater
powershell -ExecutionPolicy Bypass -File X:\DFIR-Updater\Bootstrap-DFIR-Drive.ps1 -DriveLetter X
```

Use `-SkipDownloads` to create the folder structure without downloading tool binaries.

---

## Usage

### First Time Setup

1. Plug in your DFIR USB drive.
2. Open `DFIR-Updater\Launch-Updater.bat` (double-click).
3. The launcher will ask if you want to set up auto-launch -- say **Y**.
4. The GUI will open and begin checking for updates.

On a new computer, run `Portable-Setup.ps1` for a guided first-run wizard that verifies connectivity, drive label, and file integrity.

### Subsequent Use

- **Automatic**: Plug in the drive. The updater launches itself after a 10-second delay via Task Scheduler.
- **Manual**: Double-click `Launch-Updater.bat` at any time.

### The GUI

The main window contains the following elements:

- **Tool List** -- A data grid where each row shows a tool's name, current version, latest version, status, and source type. Rows are color-coded: green (up to date), yellow (update available), gray (manual check required).
- **Check for Updates** -- Queries all GitHub-sourced tools for their latest release. Web-sourced tools are flagged with a clickable link to their download page.
- **Update Selected** -- Downloads and installs updates for checked tools. Each update is backed up before installation and rolled back automatically on failure.
- **Scan for New Tools** -- Runs auto-discovery to detect untracked tools on the drive and add them to the configuration.
- **Tool Launcher** -- Opens the tile-based tool browser.
- **Forensic Mode Badge** -- Displays current forensic mode state. Click to toggle.
- **Progress Bar and Log Panel** -- Real-time feedback during operations.

### Tool Launcher

The Tool Launcher provides a visual, tile-based interface for browsing and launching any tool on the drive. It automatically discovers executables across all category folders and the `PortableApps/` directory, extracts icons, and organizes tools by category with search and filtering. The launcher is read-only and safe for use in Forensic Mode.

### Forensic Mode

Forensic Mode blocks the updater system (auto-launch, update checks, downloads) while keeping all DFIR tools fully functional. It uses a lockfile named `FORENSIC_MODE` at the drive root.

- Toggle with `Forensic-Mode.bat` (double-click) or via the GUI badge.
- The lockfile travels with the drive and stays active on every computer until explicitly removed.

**Recommended workflow for target examinations:**

1. At your workstation: enable Forensic Mode.
2. At the target computer: plug in the drive and use your tools. The updater will not run.
3. Back at your workstation: disable Forensic Mode. The updater resumes normal operation.

### Write Protection

Write Protection sets a disk-level readonly attribute using `Set-Disk -IsReadOnly` (with `diskpart` fallback). When enabled, the OS refuses all write operations to the drive.

- Toggle with `Write-Protect.bat` (requires administrator via UAC prompt).
- Check status only: `.\Write-Protect.ps1 -Status`

> **Note:** This is a software-level protection and is not equivalent to a hardware write blocker for court-admissible evidence handling. For maximum forensic soundness, use a USB drive with a physical write-protect switch or a dedicated hardware write blocker.

### Forensic Cleanup

If the updater ran on a target computer before Forensic Mode was enabled, use `Forensic-Cleanup.ps1` to remove artifacts:

```powershell
.\Forensic-Cleanup.ps1              # Full cleanup with report
.\Forensic-Cleanup.ps1 -ReportOnly  # Report only, no deletions
.\Forensic-Cleanup.ps1 -WhatIf      # Preview what would be deleted
```

The script scans for temp files, prefetch entries, recent file shortcuts, and event log entries. Found files are securely deleted with zero-overwrite before removal.

---

## Project Structure

```
D:\
├── 01_Acquisition\              Disk/memory imaging & evidence capture
├── 02_Analysis\                 Artifact analysis & examination tools
├── 03_Network\                  Network forensics & analysis
├── 04_Mobile-Forensics\         Mobile device forensics
├── 05_Case-Files\               Case data, reports, memory captures
├── 06_Training\                 Training materials & lab files
├── 07_Documentation\            Manuals, guides, references
├── 08_Utilities\                General utilities & system tools
├── PortableApps\                PortableApps platform (self-managed)
├── Shortcuts\                   Generated .lnk files for tools
└── DFIR-Updater\
    ├── Launch-Updater.bat           Entry point (double-click launcher)
    ├── DFIR-Updater-GUI.ps1         Main WPF GUI application
    ├── tools-config.json            Tool definitions and update sources
    ├── Setup-AutoLaunch.ps1         Task Scheduler registration
    ├── Portable-Setup.ps1           First-run wizard for new machines
    ├── Bootstrap-DFIR-Drive.ps1     Clone toolkit to a new USB drive
    ├── Build-Exe.ps1                Compile to standalone .exe
    ├── Init-GitRepo.ps1             Push framework to GitHub
    ├── Forensic-Mode.bat            Toggle Forensic Mode
    ├── Forensic-Cleanup.ps1         Remove updater artifacts from target
    ├── Write-Protect.bat            Toggle disk write protection
    ├── Write-Protect.ps1            Write protection logic
    ├── Create-Shortcuts.ps1         Generate .lnk shortcuts for tools
    ├── scan-manifest.json           Auto-discovery tracking (generated)
    └── modules\
        ├── Update-Checker.ps1       GitHub API, version comparison, downloads
        ├── Auto-Discovery.ps1       New tool detection and identification
        ├── Tool-Launcher.ps1        Drive scanning for Tool Launcher
        └── Package-Manager.ps1      Package manager integration
```

---

## Building from Source

The `Build-Exe.ps1` script compiles the application into a standalone `.exe` using [PS2EXE](https://github.com/MScholtes/PS2EXE). The build process:

1. Merges all module files into a single script (inlining dot-sourced dependencies).
2. Compiles the merged script to a Windows executable with PS2EXE.
3. Copies supporting files (`tools-config.json`, modules).
4. Packages everything into a distributable `DFIR-Updater-Portable.zip`.

**Steps:**

```powershell
# Install the PS2EXE module (one-time)
Install-Module ps2exe -Scope CurrentUser

# Run the build
.\Build-Exe.ps1

# Output is placed in the dist\ directory:
#   dist\DFIR-Updater.exe
#   dist\DFIR-Updater-Portable.zip
```

Use `-SkipZip` to compile the `.exe` without creating the zip archive. Use `-OutputDir` to specify a custom output directory.

---

## Configuration

### tools-config.json

The configuration file is a JSON document with the following structure:

- **`tools`** -- An array of tool definitions (the main section).
- **`update_scripts`** -- Named shell commands for batch-updating tool families with their own update mechanisms.
- **`version`** / **`last_updated`** -- Metadata for tracking configuration changes.

Each tool entry uses this schema:

| Field | Description |
|---|---|
| `name` | Display name shown in the GUI. |
| `path` | Relative path from the drive root to the tool's folder or executable. |
| `source_type` | `"github"` for automated version checking via the GitHub API, or `"web"` for manual checks via a download page URL. |
| `github_repo` | GitHub `owner/repo` string (e.g., `"hashcat/hashcat"`). `null` for web-sourced tools. |
| `github_asset_pattern` | Regex to match the correct download file from GitHub release assets. `null` for web-sourced tools. |
| `download_url` | Vendor download page URL for web-sourced tools. `null` for GitHub-sourced tools. |
| `current_version` | Version string currently installed on the drive. Updated automatically after a successful update. |
| `version_pattern` | Regex with a capture group to extract version numbers from release tags or filenames. |
| `install_type` | Installation method: `"extract_zip"`, `"extract_7z"`, `"copy_exe"`, or `"manual"`. |
| `notes` | Free-text notes displayed in the GUI. |

**Example entry:**

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
  "notes": "Released as .7z archive on GitHub."
}
```

### Adding a Tool Manually

Add a new JSON object to the `tools` array in `tools-config.json`, or use the **Scan for New Tools** button in the GUI for automatic detection and one-click addition.

---

## Contributing

Contributions are welcome. To get started:

1. Fork the repository.
2. Create a feature branch (`git checkout -b feature/your-feature`).
3. Make your changes and test them on a DFIR USB drive.
4. Submit a pull request with a clear description of the changes.

Please ensure that any new tool entries added to `tools-config.json` include all required fields and valid regex patterns.

---

## License

This project is distributed under the MIT License. See [LICENSE](LICENSE) for details.

---

## Acknowledgments

- Built for DFIR field operations by [jameshenning](https://github.com/jameshenning).
- All forensic tools referenced in this project are the property of their respective developers and organizations.
- GUI built with Windows Presentation Foundation (WPF).
- Standalone `.exe` compilation powered by [PS2EXE](https://github.com/MScholtes/PS2EXE).
- Auto-discovery database covers 133+ known DFIR repositories from the open-source forensics community.
