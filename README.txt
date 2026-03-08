==============================================================================
  DFIR Drive Updater
==============================================================================

  Keep your DFIR USB toolkit current. This system downloads, verifies, and
  installs forensic and incident-response tools defined in tools-config.json
  so your field drive is always ready when you need it.

==============================================================================
  Quick Start
==============================================================================

  1. MANUAL RUN (recommended first time)

     Double-click:  Launch-Updater.bat

     This opens the updater GUI, which reads tools-config.json, checks each
     tool's installed version against the latest available release, and lets
     you choose what to update.

  2. AUTOMATIC LAUNCH ON USB INSERT

     Open PowerShell in this folder and run:

         .\Setup-AutoLaunch.ps1

     A scheduled task ("DFIR-Drive-Updater") will be created for the current
     user. Whenever a USB storage device is connected, Windows will detect the
     event and launch the updater automatically if the DFIR drive is present.

     The task identifies the drive by volume label ("DFIR"). If the label does
     not match, it falls back to scanning all drives for the DFIR-Updater
     folder. A 10-second delay is built in so the drive letter has time to be
     assigned.

  3. REMOVE AUTOMATIC LAUNCH

     Open PowerShell in this folder and run:

         .\Setup-AutoLaunch.ps1 -Remove

     This unregisters the scheduled task. No other system changes are made.

==============================================================================
  Adding or Editing Tools
==============================================================================

  All managed tools are defined in:

      tools-config.json

  Each entry specifies:

      Name           Friendly display name for the tool.
      GitHubRepo     Owner/repo on GitHub (e.g., "EricZimmerman/Get-ZimmermanTools").
      AssetPattern   Regex or glob that matches the desired release asset filename.
      InstallPath    Where the tool should be extracted/copied on the DFIR drive,
                     relative to the drive root.
      ExtractType    How to handle the download: "zip", "exe", or "msi".

  Example entry:

      {
          "Name": "KAPE",
          "GitHubRepo": "EricZimmerman/KapeFiles",
          "AssetPattern": "KAPE\\.zip$",
          "InstallPath": "Tools\\KAPE",
          "ExtractType": "zip"
      }

  After editing tools-config.json, run the updater again. New tools will be
  downloaded and existing tools will be checked for updates.

==============================================================================
  File Overview
==============================================================================

  Launch-Updater.bat       Double-click to run the updater manually.
  Setup-AutoLaunch.ps1     Create/remove the auto-launch scheduled task.
  DFIR-Updater-GUI.ps1     Main updater GUI (WPF/WinForms PowerShell script).
  tools-config.json        Tool definitions (what to download and where).
  modules\                 Supporting PowerShell modules used by the updater.
  README.txt               This file.

==============================================================================
  Requirements
==============================================================================

  - Windows 10 or Windows 11
  - PowerShell 5.1 or later (ships with Windows 10/11)
  - Internet connection (to check GitHub releases and download assets)
  - Sufficient free space on the DFIR drive for tool downloads

  No installation or administrative privileges are required. Everything runs
  from the USB drive in the current user's context.

==============================================================================
  Troubleshooting
==============================================================================

  "Script cannot be loaded because running scripts is disabled"
      Use Launch-Updater.bat, which sets -ExecutionPolicy Bypass for the
      session only. No permanent system changes are made.

  Auto-launch does not trigger
      - Confirm the task exists:  Get-ScheduledTask -TaskName DFIR-Drive-Updater
      - Ensure the USB drive's volume label is set to "DFIR".
      - Check Task Scheduler history for errors (taskschd.msc).
      - Re-run Setup-AutoLaunch.ps1 to recreate the task.

  Drive letter changed
      This is expected. The auto-launch task and the batch file both resolve
      the drive letter dynamically, so no reconfiguration is needed.

==============================================================================
