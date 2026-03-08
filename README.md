# DFIR Drive Updater

A portable, self-contained update manager for DFIR (Digital Forensics & Incident Response) USB toolkits. Plug in your drive, and it automatically checks for updates to your forensic tools — then lets you pick which ones to update with a single click.

---

## Features

- **Automatic update checking** — Queries GitHub releases and known download sources for newer versions of your tools
- **WPF GUI** — Dark-themed, professional interface with color-coded status, checkboxes for selective updates, and a live log panel
- **Auto-discovery** — Scans your drive for newly added tools and offers to add them to the update tracker with pre-filled configuration
- **Auto-launch on plug-in** — Registers a Windows Task Scheduler event that triggers when any USB device is connected, then finds your DFIR drive by volume label
- **Fully portable** — Runs from the USB drive on any Windows 10/11 machine with no installation required
- **Backup & rollback** — Creates timestamped backups before every update and rolls back automatically on failure
- **Dynamic drive detection** — Works regardless of which drive letter Windows assigns

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

## Forensic Mode

Forensic Mode blocks ONLY the updater system (auto-launch, update checks, downloads) while keeping all DFIR tools fully functional. Use it to prevent the updater from writing artifacts to a target or evidence computer.

### Toggling Forensic Mode

- **Double-click `Forensic-Mode.bat`** to toggle ON/OFF. The script will confirm the current state.
- **Or manually** create or delete a `FORENSIC_MODE` file at the drive root (e.g., `D:\FORENSIC_MODE`).

Forensic Mode is indicated by the presence of this lockfile. When the file exists, the updater refuses to run.

### What It Blocks vs. What Still Works

| Component | Forensic Mode OFF | Forensic Mode ON |
|---|---|---|
| FTK Imager, KAPE, all DFIR tools | Works | Works |
| Auto-launch on USB insert | Runs | Blocked |
| Update checker / downloads | Runs | Blocked |
| Updater GUI | Runs | Blocked |

### Forensic Cleanup

If you forgot to enable Forensic Mode before plugging into a target, use `Forensic-Cleanup.ps1` to remove updater artifacts:

- **Securely overwrites and deletes** updater temp files and prefetch entries left on the host
- **Generates a cleanup report** saved to the `cleanup-reports/` directory on the USB drive
- Does **NOT** remove Windows USB plug-in artifacts (registry entries, setupapi logs) — those require separate handling

**Usage:**

```powershell
# Full cleanup with report
.\Forensic-Cleanup.ps1

# Report only — show what would be cleaned without deleting anything
.\Forensic-Cleanup.ps1 -ReportOnly
```

### Best Practice Workflow

The `FORENSIC_MODE` lockfile lives **on the USB drive itself**, not on the computer. Once created, it travels with the drive and stays active no matter where you plug in — until you toggle it off.

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
├── tools-config.json            # Tool definitions and update sources
├── scan-manifest.json           # Auto-discovery tracking (auto-generated)
├── cleanup-reports/             # Forensic cleanup reports (auto-generated)
├── FORENSIC_MODE                # Lockfile — present when Forensic Mode is ON
├── .gitignore                   # Git ignore rules
├── README.md                    # This file
├── README.txt                   # Plain-text quick reference
└── modules/
    ├── Update-Checker.ps1       # GitHub API, version comparison, downloads
    └── Auto-Discovery.ps1       # New tool detection and identification
```

### Update Flow

```
USB Plugged In
     │
     ▼
Task Scheduler fires (Event ID 112)
     │
     ▼
Find drive by volume label "DFIR"
     │
     ▼
Launch DFIR-Updater-GUI.ps1
     │
     ├──► Load tools-config.json
     │
     ├──► For each GitHub-sourced tool:
     │       Query GitHub API → Compare versions → Flag if update available
     │
     ├──► For each web-sourced tool:
     │       Flag as "Check manually" with link to download page
     │
     ▼
Display results in GUI
     │
     ├──► User selects tools to update (checkboxes)
     │
     ├──► "Update Selected" button:
     │       Download → Backup existing → Extract/Copy → Verify
     │       (Rollback on failure)
     │
     └──► "Scan for New Tools" button:
             Scan drive → Compare against config → Show new items
             → User selects which to add → Auto-generate config entries
```

### Update Sources

| Source Type | How It Works | Example Tools |
|---|---|---|
| **GitHub** | Queries `/repos/{owner}/{repo}/releases/latest` via the GitHub API. Compares the release tag against the locally stored version. Downloads matching assets by regex pattern. | Arsenal Image Mounter, ExifTool, hashcat, UniGetUI |
| **Web** | Stores the vendor download page URL. Flags the tool as "check manually" with a clickable link. | FTK Imager, KAPE, NetworkMiner, NirSoft tools |

### Auto-Discovery

When you add new tools to the drive, the auto-discovery module:

1. **Scans** organized folders (`01_Acquisition/`, `02_Analysis/`, etc.) up to 2 levels deep
2. **Compares** found executables and tool folders against `tools-config.json`
3. **Identifies** tools by matching names against a built-in database of 40+ known DFIR GitHub repos
4. **Extracts** version numbers from filenames (e.g., `toolname-1.2.3.exe` → version `1.2.3`)
5. **Generates** pre-filled config entries that you can review and add with one click

---

## Configuration

### tools-config.json

Each tool is defined as a JSON object:

```json
{
  "name": "Arsenal Image Mounter",
  "path": "01_Acquisition/Arsenal-Image-Mounter-v3.11.307",
  "source_type": "github",
  "github_repo": "ArsenalRecon/Arsenal-Image-Mounter",
  "github_asset_pattern": "Arsenal\\.Image\\.Mounter-v[\\d.]+\\.zip",
  "download_url": null,
  "current_version": "3.11.307",
  "version_pattern": "v([\\d.]+)",
  "install_type": "extract_zip",
  "notes": "Extract zip and replace folder contents."
}
```

| Field | Description |
|---|---|
| `name` | Display name shown in the GUI |
| `path` | Relative path from drive root to the tool |
| `source_type` | `"github"` (API check) or `"web"` (manual check) |
| `github_repo` | GitHub `owner/repo` string for API queries |
| `github_asset_pattern` | Regex to match the correct release asset filename |
| `download_url` | Direct download page URL (for web-sourced tools) |
| `current_version` | Currently installed version string |
| `version_pattern` | Regex to extract version from filenames |
| `install_type` | `"extract_zip"`, `"copy_exe"`, `"extract_7z"`, or `"manual"` |
| `notes` | Free-text notes shown in the GUI |

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

### Register (on any machine)

```powershell
# From the DFIR-Updater folder on the drive:
.\Setup-AutoLaunch.ps1
```

This creates a **user-level** scheduled task (no admin required) that:
- Triggers on Windows Event ID 112 (`DeviceSetupManager` — device installation complete)
- Waits 10 seconds for drive letter assignment
- Searches for a volume labeled **"DFIR"**
- Falls back to scanning all drives for the `DFIR-Updater` folder
- Launches the GUI if found

### Check Status

```powershell
.\Setup-AutoLaunch.ps1 -Check
```

### Remove

```powershell
.\Setup-AutoLaunch.ps1 -Remove
```

---

## Backing Up to GitHub / Cloning to a New Drive

The DFIR-Updater framework can be version-controlled with Git and pushed to GitHub, making it easy to replicate your entire toolkit onto fresh USB drives.

### Initial Setup (push to GitHub)

```powershell
# From the DFIR-Updater folder:
.\Init-GitRepo.ps1
```

This will:
1. Initialize a git repo in the `DFIR-Updater` folder
2. Create a GitHub repository (public or private, your choice)
3. Push all scripts and config (tools themselves are NOT stored in git — just the registry)

### Clone to a New USB Drive

```powershell
# On any machine with git installed:
git clone https://github.com/YOUR_USERNAME/DFIR-Updater.git X:\DFIR-Updater

# Then bootstrap the full toolkit:
powershell -ExecutionPolicy Bypass -File X:\DFIR-Updater\Bootstrap-DFIR-Drive.ps1 -DriveLetter X
```

The bootstrap script will:
1. Create the folder structure (`01_Acquisition/`, `02_Analysis/`, etc.)
2. Download all GitHub-sourced tools from their latest releases
3. Log which web-sourced tools require manual download
4. Optionally set the volume label to "DFIR"
5. Offer to set up auto-launch on the current machine

### Structure-Only Clone (no downloads)

```powershell
.\Bootstrap-DFIR-Drive.ps1 -DriveLetter X -SkipDownloads
```

Creates the folder structure and copies the updater, but doesn't download tools. Useful when you want to manually populate the drive.

---

## Drive Organization

The updater expects tools organized in numbered category folders:

```
D:\
├── 01_Acquisition\          Disk/memory imaging & evidence capture
├── 02_Analysis\             Artifact analysis & examination tools
├── 03_Network\              Network forensics & analysis
├── 04_Mobile-Forensics\     Mobile device forensics (Cellebrite, etc.)
├── 05_Case-Files\           Case data, reports, memory captures
├── 06_Training\             Training materials & lab files
├── 07_Documentation\        Manuals, guides, references
├── 08_Utilities\            General utilities & system tools
├── PortableApps\            PortableApps.com platform (self-managed)
├── Shortcuts\               .lnk files for installed applications
├── Documents\               Personal documents
├── DFIR-Updater\            This updater system
└── Start.exe                PortableApps launcher
```

---

## Requirements

- **Windows 10 or 11** (PowerShell 5.1 is included)
- **Internet connection** for checking GitHub releases and downloading updates
- **No admin privileges required** — everything runs in user context
- **No installation** — fully self-contained on the USB drive

---

## Troubleshooting

### "Running scripts is disabled on this system"

Use `Launch-Updater.bat` instead of running the `.ps1` files directly. The batch file sets `-ExecutionPolicy Bypass` for the session only — no permanent system changes.

### Auto-launch doesn't trigger

1. Verify the task exists: `Get-ScheduledTask -TaskName DFIR-Drive-Updater`
2. Check your drive's volume label is set to **DFIR**: `Get-Volume`
3. Re-run `Setup-AutoLaunch.ps1` to recreate the task
4. Check Task Scheduler history: `taskschd.msc` → Task Scheduler Library → DFIR-Drive-Updater

### GitHub API rate limit

Unauthenticated requests are limited to 60/hour. If you have many GitHub-sourced tools, you may hit this limit. The updater warns when the limit is low. You can add a GitHub personal access token to increase the limit to 5,000/hour.

### Drive letter changed

This is expected and handled automatically. Both the auto-launch task and the batch launcher dynamically resolve the drive letter at runtime.

### A tool update failed

The updater creates backups before every update (`toolname.bak_YYYYMMDD_HHmmss`). If an update fails, it automatically rolls back. You can also manually restore from the backup folder.

---

## Security Notes

- The updater only downloads from URLs defined in `tools-config.json` — it never executes arbitrary code
- All downloads use HTTPS
- Backups are created before any files are modified
- The scheduled task runs with **Limited** privileges (no elevation)
- `autorun.inf` is included but is ignored by modern Windows for USB drives (security policy since Windows 7)

---

## Credits

Built for DFIR field operations. Tools are property of their respective developers and organizations.
