================================================================
  Windows Cache & Temp Cleaner  v1.2.1
================================================================

WHAT IT DOES
  Frees disk space by deleting only regenerable CACHE and TEMP data.
  It auto-detects what your PC has, so the SAME files work on any
  Windows 10 / 11 computer (NVIDIA, AMD, or Intel graphics).

  Cleans:
    - Temp folders + application crash dumps
    - GPU / shader caches (NVIDIA, AMD, Intel)
    - Browser caches (Chrome, Edge, Brave, Opera, Vivaldi, Firefox)
    - App caches (Discord, Spotify, Slack, Teams, VS Code, Electron apps...)
    - Windows thumbnail / icon cache
    - Developer package caches (pip, uv, npm, yarn, NuGet, Go)
    - Windows Update / Delivery Optimization caches, old servicing logs
    - Other fixed drives (tick them in the GUI, or use -Drives / -AllDrives):
      root Temp/tmp, other users' temp, Thumbs.db, *.gid, __pycache__,
      node_modules\.cache. Risky patterns (*.tmp, *.old, *.chk, found.NNN,
      *.dmp) are listed UNTICKED so you can review them first.
    - (Optional, unticked) Recycle Bin, Claude Desktop VM cache, kernel crash
      dumps, Playwright browsers, Gradle cache, old Codex release folders

  REPORT ONLY (never deleted by the tool): large virtual disks (.vhdx/.vmdk/.vdi
  over 1 GB), shadow copies / System Restore usage, installed Node versions.
  Each comes with a note on how to remove it properly.

  OTHER USER PROFILES (optional, separate tab, nothing ticked): lists other
  Windows accounts' profiles. Deleting one needs you to type its name. Never the
  current user, system, Default/Public, Administrator or a logged-on profile.

  SECURITY CHECK (read-only tab, or -SecurityCheck): lists suspicious-looking
  running programs and startup entries (Temp/Downloads paths, unsigned, wrong
  folder for system names, hidden auto-start, very high CPU) plus Windows
  Defender status. These are heuristics: "suspicious, review", NOT proof of a
  virus. Nothing is killed or deleted. Run a Defender full scan if worried.

CHECK FOR UPDATES (button, top right; only when you click it): asks GitHub for a
  newer version of this program and for the free "Pro" edition (a separate,
  fuller app in its own project; "not released yet" until it exists). You can
  download to this program's folder or any fixed drive/folder; the file is
  verified (size, and SHA-256 when available) and never run or replaced for you.
  Afterwards you choose to Keep or Delete the old installer (only that one exe).
  Nothing is sent automatically; no telemetry.

SYSTEM RESTORE POINT (checkbox, off by default): creates one before cleaning.
  Windows allows one per 24 hours; if it cannot be made you are asked whether to
  clean anyway.

EXPORT REPORT (button): saves the scan (items, sizes, ticked state, risk, paths,
  report-only rows, security findings if run) as an HTML page or CSV file.

IT NEVER DELETES
    - Your documents, photos, downloads, or any personal files
    - Browser tabs, sessions, logins, cookies, history, bookmarks, passwords
    - Installed programs or their settings
    - Saved game data
    - Anything reached through a junction/symlink (links are never followed)

HOW TO USE
  Easiest:  double-click  CleanPC.bat
            (say YES to the admin prompt so it can clean system temp too).
            In the window, tick the drives to scan, review the list, then press
            Clean Selected. Risky items start unticked.

  Tip:      Close your browsers and chat apps first for the biggest cleanup
            (files in use are safely skipped, just freeing a little less).

  Advanced (PowerShell):
    .\Clean-PC-Cache.ps1 -DryRun                 (preview only, deletes nothing)
    .\Clean-PC-Cache.ps1 -Auto                   (no questions, safe defaults)
    .\Clean-PC-Cache.ps1 -Auto -IncludeRecycleBin -IncludeClaudeVM
    .\Clean-PC-Cache.ps1 -SkipDevCaches          (leave package caches alone)
    .\Clean-PC-Cache.ps1 -DryRun -Drives C,D     (also scan drive D:)
    .\Clean-PC-Cache.ps1 -DryRun -AllDrives      (every fixed local drive)
    .\Clean-PC-Cache.ps1 -SecurityCheck          (read-only suspicious-process report)
    .\Clean-PC-Cache.ps1 -ListProfiles           (list other user profiles, read-only)
    .\Clean-PC-Cache.ps1 -CheckUpdate            (look for a newer version / Pro)
    .\Clean-PC-Cache.ps1 -DryRun -ExportReport C:\temp\scan.html   (or .csv)
    .\Clean-PC-Cache.ps1 -RestorePoint           (restore point first; needs admin)

SHARING WITH FRIENDS
  Copy the whole "PC-Cache-Cleaner" folder (both CleanPC.bat and
  Clean-PC-Cache.ps1) to any Windows 10/11 PC and double-click CleanPC.bat.
  Anything their PC doesn't have is simply skipped.

NOTE
  After cleaning, the first launch of each app / game may be slightly slower
  for a moment while its cache rebuilds. This is normal.
================================================================
