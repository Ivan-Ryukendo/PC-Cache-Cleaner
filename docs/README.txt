================================================================
  Windows Cache & Temp Cleaner
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
    - (Optional) Recycle Bin
    - (Optional) Claude Desktop local-agent VM cache, if present

IT NEVER DELETES
    - Your documents, photos, downloads, or any personal files
    - Browser tabs, sessions, logins, cookies, history, bookmarks, passwords
    - Installed programs or their settings
    - Saved game data

HOW TO USE
  Easiest:  double-click  CleanPC.bat
            (say YES to the admin prompt so it can clean system temp too).
            It will ask before emptying the Recycle Bin or the Claude VM cache.

  Tip:      Close your browsers and chat apps first for the biggest cleanup
            (files in use are safely skipped, just freeing a little less).

  Advanced (PowerShell):
    .\Clean-PC-Cache.ps1 -DryRun                 (preview only, deletes nothing)
    .\Clean-PC-Cache.ps1 -Auto                   (no questions, safe defaults)
    .\Clean-PC-Cache.ps1 -Auto -IncludeRecycleBin -IncludeClaudeVM
    .\Clean-PC-Cache.ps1 -SkipDevCaches          (leave package caches alone)

SHARING WITH FRIENDS
  Copy the whole "PC-Cache-Cleaner" folder (both CleanPC.bat and
  Clean-PC-Cache.ps1) to any Windows 10/11 PC and double-click CleanPC.bat.
  Anything their PC doesn't have is simply skipped.

NOTE
  After cleaning, the first launch of each app / game may be slightly slower
  for a moment while its cache rebuilds. This is normal.
================================================================
