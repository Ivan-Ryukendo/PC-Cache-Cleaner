# PC Cache Cleaner

<p align="center">
  <img src="assets/icon.png" width="130" alt="PC Cache Cleaner icon">
</p>

A portable Windows 10/11 cache & temp cleaner. It auto-detects what your PC has
— NVIDIA / AMD / Intel GPU caches, any installed browser, dev tools, Electron
apps — and frees disk space by deleting **only regenerable cache and temp
data**. Download one file, run it, tick what to clear, done.

> **Safety first:** it never touches your personal files, browser logins,
> history, bookmarks, passwords, installed programs, or saved games. See
> [What it will never touch](#what-it-will-never-touch).

---

## Download & run

1. Go to the [**Releases**](../../releases/latest) page and download
   **`CleanPC.exe`**.
2. Double-click it. Windows asks for administrator permission (needed to clear
   system temp and the Windows Update cache) — click **Yes**.
3. It scans the drives ticked at the top (the Windows drive by default), then shows a checklist with each item's size. Tick what you
   want, press **Clean Selected**, and it reports how much space it freed. You
   can press **Cancel** mid-run to stop after the current item (already-freed
   space is kept; nothing is left half-deleted).

<p align="center">
  <img src="assets/Screenshot.jpg" alt="PC Cache Cleaner screenshot" width="580">
</p>

### "Windows protected your PC" on first run

The app isn't code-signed (a signing certificate costs money), so Windows
SmartScreen shows a blue warning the first time. This is expected for small
open-source tools. To run it:

> Click **More info** → **Run anyway**.

The full source is in this repo, so you can read exactly what it does before
trusting it.

---

## What it cleans

Anything not present on your PC is silently skipped, so the same app works on
any Windows 10/11 machine.

- Temp folders, app crash dumps, Windows Error Reporting, Windows Update and
  Delivery Optimization caches, old servicing logs
- GPU / shader caches: NVIDIA (incl. NVIDIA App installers), AMD, Intel, DirectX
- Browser caches: Chrome, Edge, Brave, Opera, Vivaldi, Firefox (all profiles)
- App / Electron caches: Discord, Spotify, Slack, Teams, VS Code, and more
- Windows thumbnail / icon cache
- Developer caches: pip, uv, npm, yarn, Go, NuGet, scoop, Arduino staging, `~/.cache`
- **Other drives (new in 1.2.0):** tick any fixed local drive (or *All drives*) and
  it also finds root `\Temp` / `\tmp`, other Windows installs' `Windows\Temp`,
  other users' temp folders, `Thumbs.db`, `*.gid`, `__pycache__`,
  `node_modules\.cache`, and (unticked, review first) old `*.tmp` / `~$*`,
  `*.old`, `*.chk`, `found.NNN`, `*.dmp`. Removable, network and optical drives
  are never scanned; junctions are not followed; Program Files, Windows, WinSxS,
  System Volume Information, AppData and game libraries are skipped. The scan
  runs in the background (time-limited per drive) and has a **Stop scan** button.
- **Optional / unticked by default:** Recycle Bin (per drive), Claude Desktop VM
  cache, kernel crash dumps, Playwright browsers, Gradle cache, old Codex release
  folders. Risky items show a warning and ask for confirmation.

### Report-only tab

Things worth knowing about but **never deleted** by the tool: large virtual disks
(`.vhdx` / `.vmdk` / `.vdi` over 1 GB, e.g. Windows Subsystem for Android, WSL,
Application Guard), shadow-copy / System Restore usage, installed Node versions
(fnm) and leftover profile folders - each with a note on how to remove it
properly.

### Other user profiles (opt-in)

A separate, clearly marked tab lists *other* Windows accounts' profiles with
sizes. Nothing is ticked, and deleting one needs you to type the profile name.
The current user, system, Default/Public, Administrator and any logged-on profile
are never listed.

### Security check (read-only)

A tab (and `-SecurityCheck` on the console) lists running programs and startup
entries that look unusual: running from Temp / Downloads / Public / Recycle Bin,
unsigned programs outside Windows and Program Files, system-process names from
the wrong folder, look-alike names, sustained very high CPU, hidden-window
auto-start entries. It shows signed / unsigned and the path, offers **Open file
location**, shows Windows Defender status and recommends a full Defender scan.
It is only a heuristic: results mean *suspicious, review*, not "virus". It never
kills or deletes anything.

## What it will never touch

Personal files. Browser tabs, sessions, cookies, logins, history, bookmarks,
and passwords. Installed programs and their settings. Saved games. Anything
reached through a junction or symlink. Deleting a cache only costs you a
one-time, automatic re-download or rebuild - nothing you care about is lost.

---

## Log file & troubleshooting

Every run writes **`CleanPC-log.txt`** next to the app, recording what was
scanned, what was freed, and anything it had to skip (for example, a file locked
by a running browser). If something behaves unexpectedly or crashes, the log
gets the error details too.

To get help, just **drag `CleanPC-log.txt` into an AI assistant** (or attach it
to an issue here) and ask what went wrong — it's plain text designed to be read.

Tip: close your browsers and chat apps before running for the most thorough
cleanup (open apps lock their own cache files, which are then safely skipped).

---

## For advanced users

The repo ships the raw PowerShell so you can read, audit, or script it:

- **`src/CleanPC-GUI.ps1`** — the graphical version (what the `.exe` wraps).
- **`src/Clean-PC-Cache.ps1`** — a no-UI console version for scripting/automation:

  ```powershell
  .\Clean-PC-Cache.ps1 -DryRun                 # report only, delete nothing
  .\Clean-PC-Cache.ps1 -Auto                   # no prompts, safe defaults
  .\Clean-PC-Cache.ps1 -Auto -IncludeRecycleBin -IncludeClaudeVM
  .\Clean-PC-Cache.ps1 -SkipDevCaches          # leave package caches alone
  .\Clean-PC-Cache.ps1 -DryRun -Drives C,D     # also scan drive D:
  .\Clean-PC-Cache.ps1 -DryRun -AllDrives      # every fixed local drive
  .\Clean-PC-Cache.ps1 -SecurityCheck          # read-only suspicious-process report
  .\Clean-PC-Cache.ps1 -ListProfiles           # list other user profiles (read-only)
  ```

### Building the EXE yourself

```powershell
Install-Module ps2exe -Scope CurrentUser
Invoke-PS2EXE .\src\CleanPC-GUI.ps1 .\CleanPC.exe -requireAdmin -noConsole -title "PC Cache Cleaner"
```

---

## License

[MIT](LICENSE) — free to use, modify, and share.
