# PC-Cache-Cleaner (v1.2.1)

Portable Windows 10/11 cache & temp cleaner. Auto-detects GPU/browser/dev/app
caches and junk on any fixed drive and frees space by deleting **only
regenerable cache/temp data**. Shipped as one `CleanPC.exe` on GitHub Releases
(repo: `Ivan-Ryukendo/PC-Cache-Cleaner`).

## Two projects (this repo + separate Pro repo)

- **This repo - Standard, PowerShell (1.2.x):** lightweight script wrapped by
  ps2exe. Bug fixes and small features only. Asset: `CleanPC.exe`.
- **Pro - `Ivan-Ryukendo/PC-Cache-Cleaner-Pro` (separate repo, own releases,
  asset `CleanPC-Pro.exe`):** C# edition (WPF, .NET Framework 4.8, no Visual
  Studio needed) with the larger feature set: large-file and duplicate finders,
  space-over-time tracker, presets, stale project folders, startup manager,
  scheduling. A **free upgrade** for Standard users. It is a different app, not
  an in-place update: the update dialog lists it as its own "Upgrade to Pro
  (free)" channel and shows "Pro edition not released yet" until a stable release
  exists.
- **Kept mergeable:** both share the safety contract, the cleanup target list
  (names, paths, risk levels, report-only rows) and the docs, so the two can be
  merged later. Port target/safety changes to both; UI and engine code are
  language-specific and will not merge directly.
- Rust stays an optional future scanner library only if C# proves too slow.

## Layout

```
src/
  CleanPC-GUI.ps1      WinForms GUI (what the .exe wraps)
  Clean-PC-Cache.ps1   no-UI console version, same engine
  CleanPC.bat          legacy launcher (self-elevates, runs the GUI)
assets/                icon.png, Screenshot.jpg (icon.ico is generated, gitignored)
docs/README.txt        end-user readme
deploy.ps1             icon -> build -> verify -> release (run from repo root; -BuildOnly skips release)
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
- **Update / download / housekeeping** (CORE, user-triggered only): `CleanFetch`
  and `CleanDownloader` (C# background HTTP with timeouts, progress, cancel),
  `Get-UpdateInfo`/`Get-AllUpdateInfo` (GitHub releases/latest for Standard and
  Pro; semantic compare via `[version]`; 404/prerelease = "not released"),
  `Test-DownloadSpace`, `Complete-Download` (size + SHA-256, `.part` then rename),
  old-installer helpers (`Test-SafeInstallerDelete`, marker file in
  `%LOCALAPPDATA%\CleanPC\pending-delete.txt`, `Start-DeferredDelete`).
- **Restore point + report export** (CORE): `New-CleanRestorePoint`,
  `Export-CleanReport` (HTML or CSV).
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

Header: **Check for updates** button (top right) opens a dialog with two
separate rows - Standard and "Upgrade to Pro (free)" - each with release notes
and a Download dialog (same drive as the program, or another drive/folder).
Bottom bar: **Export report** (HTML/CSV), **Create a System Restore point before
cleaning** checkbox (default off), Select safe/none, Clean Selected.

Console flags: `-Auto -DryRun -IncludeRecycleBin -IncludeClaudeVM
-SkipDevCaches -Drives -AllDrives -SecurityCheck -ListProfiles
-IncludeOtherProfiles -CheckUpdate -RestorePoint -ExportReport <path>`.

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
The update checker runs only on a user click (no telemetry, no auto-check), never
runs or replaces a downloaded file, never overwrites without asking, and the only
file it may delete is the one old `CleanPC*.exe` it came from (explicit Keep/Delete
choice; never a folder, never under Windows/Program Files, never the new file).

## Build & ship

Install the `ps2exe` module once, commit and push, then run
`deploy.ps1 -Version vX.Y.Z` from the repo root: it builds a multi-size
`assets/icon.ico` from `icon.png`, builds `CleanPC.exe` (`-requireAdmin
-noConsole -STA`, icon + product/company/version info embedded), verifies the
icon (16/32/48/256) and version info, then creates the GitHub release with the
exe attached (`-BuildOnly` stops after verification). Bump `$script:AppVersion`
in both scripts and the deploy notes first. The exe is gitignored; never commit it.

## Editing notes

- **Cleanup targets** live in `Build-Targets` (CORE) - one place for GUI and console.
- The CORE block must stay byte-identical in both scripts (diff the region before shipping).
- **Logging:** both scripts roll the prior log to `CleanPC-log.old` and write
  `CleanPC-log.txt` next to the exe via `Write-CleanLog` (must never throw).
  Skips log `SKIP <file>: <reason>`; a script-scope `trap` logs crashes.
- **UI:** header is a docked Top panel, drive panel a second Top panel, tabs sit
  in a Fill panel with top padding - preserve that separation and add the Fill
  control first. `Cancel` stops the clean loop between items (never mid-delete).
- Test path changes with `-DryRun` (and `-AllDrives`) before a real run.
