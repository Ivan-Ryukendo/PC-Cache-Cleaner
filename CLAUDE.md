# PC-Cache-Cleaner (v1.2.0)

Portable Windows 10/11 cache & temp cleaner. Auto-detects GPU/browser/dev/app
caches and junk on any fixed drive and frees space by deleting **only
regenerable cache/temp data**. Shipped as one `CleanPC.exe` on GitHub Releases
(repo: `Ivan-Ryukendo/PC-Cache-Cleaner`).

## Two projects (this repo + planned fork)

- **This repo - PowerShell edition (1.2.x):** lightweight script wrapped by ps2exe.
  Gets bug fixes and small features only.
- **Fork - C# edition (1.3.0+, not created yet):** separate repo (working name
  `PC-Cache-Cleaner-Pro`), C# WPF targeting .NET Framework 4.8 (ships with
  Windows, tiny exe, built with the .NET SDK, no Visual Studio). Carries the
  larger feature set: large-file and duplicate finders, space-over-time tracker,
  presets, stale project folders, startup manager, scheduling, update check,
  restore point before cleaning, report export. Single purpose: a Windows cleaner.
- **Kept mergeable:** the safety contract, the cleanup target list (names, paths,
  risk levels) and the docs are shared between both. Port them to the fork first;
  UI and engine code are language-specific and will not merge directly.
- Rust stays an optional future scanner library only if C# proves too slow.

## Layout

```
src/
  CleanPC-GUI.ps1      WinForms GUI (what the .exe wraps)
  Clean-PC-Cache.ps1   no-UI console version, same engine
  CleanPC.bat          legacy launcher (self-elevates, runs the GUI)
assets/                icon.png, Screenshot.jpg (icon.ico is generated)
docs/README.txt        end-user readme
deploy.ps1             build + release script (run from repo root)
README.md              GitHub readme
LICENSE
```

Gitignored/local only: `CleanPC.exe`, `CleanPC-log*.txt`, `DESIGN-exe-and-logging.md`.

## Architecture

Both scripts contain an identical `#region CORE` block (the exe wraps a single
script, so it is duplicated on purpose; edit one, copy to the other):

- **C# helper** (`Add-Type`): `CleanGuard` (deny-list enforced at delete time),
  `CleanOps` (reparse-safe size/delete), `CleanWorker` (background threads for
  sizing, junk walk per drive, AppData cache sweep).
- **PowerShell engine**: `Get-FixedDrives`/`Resolve-Drives`, `Build-Targets`
  (the single list of cleanup targets + report-only rows), `Invoke-Clean`,
  `Get-OtherProfiles`/`Remove-OtherProfile`, `Get-SecurityReport`.
- GUI and console only differ in the UI shell around the core.

Target kinds: Contents (empty a folder, keep it), Files (explicit file list),
RemoveDirs (old versioned folders only), RecycleBin, Report (never deletable).

## Tabs (GUI)

Drive checkboxes (fixed local drives + All drives, system drive default) sit
above the tabs; Rescan re-runs the scan, Stop scan keeps what was found.

- **Cleanup** - tickable checklist with sizes; risky items start unticked and
  need an extra confirmation; double-click a row to list every path.
- **Report only** - big virtual disks, shadow copies, installed Node versions,
  unregistered profile folders. Information and removal instructions only.
- **Other user profiles (opt-in)** - unticked; each deletion needs the profile
  name typed; uses Win32_UserProfile removal.
- **Security check** - read-only suspicious process/startup report, Defender
  status, "Open file location" button. Never kills or deletes.

Console flags: `-Auto -DryRun -IncludeRecycleBin -IncludeClaudeVM
-SkipDevCaches -Drives -AllDrives -SecurityCheck -ListProfiles
-IncludeOtherProfiles`.

## Safety contract (never break)

Deletes cache/temp **contents** only, keeping the folders. NEVER touches
personal files, browser sessions/cookies/logins/history/bookmarks/passwords,
installed programs/settings, or saved games. Locked files are skipped, not
forced. **Nothing in the list may be hidden from the user before deletion** -
every item must be visible and tickable. Junctions/symlinks are never followed.
Walk skips Program Files, Windows, WinSxS, Installer, System Volume Information,
AppData, game libraries. Risky patterns (*.tmp, *.old, *.dmp, *.chk, found.NNN,
kernel dumps, Playwright, Gradle, old Codex releases) are unticked. Virtual
disks, shadow copies and fnm Node versions are report-only. Profile deletion is
explicit opt-in with typed confirmation, never the current/system/loaded profile.
Security check is read-only: report "suspicious, review", never claim detection.

## Build & ship

Install the `ps2exe` module once, then run `deploy.ps1 -Version vX.Y.Z` from the
repo root: it converts the icon, builds `CleanPC.exe` with `-requireAdmin
-noConsole` and creates the GitHub release (exe attached). Commit and push first.
Bump the version in both script headers (`$script:AppVersion`) and deploy notes.

## Editing notes

- **Cleanup targets** live in `Build-Targets` (CORE) - one place for GUI and console.
- **Logging:** both scripts roll the prior log to `CleanPC-log.old` and write
  `CleanPC-log.txt` next to the exe via `Write-CleanLog` (must never throw).
  Skips log `SKIP <file>: <reason>`; a script-scope `trap` logs crashes.
- **UI:** header is a docked Top panel, drive panel a second Top panel, tabs sit
  in a Fill panel with top padding - preserve that separation and add the Fill
  control first. `Cancel` stops the clean loop between items (never mid-delete).
- Test path changes with `-DryRun` (and `-AllDrives`) before a real run.
