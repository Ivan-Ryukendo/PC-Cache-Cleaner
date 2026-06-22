# PC-Cache-Cleaner

A portable Windows 10/11 cache & temp cleaner. Auto-detects what a PC has
(NVIDIA / AMD / Intel GPU caches, any installed browser, dev tools, Claude
Desktop) and frees disk space by deleting **only regenerable cache/temp data**.
Designed to be copied to any Windows PC and run by double-clicking.

## Project layout

```
E:\PC-Cache-Cleaner\
├─ CleanPC.bat          # Entry point. Double-clicked by the user.
│                       #   - Self-elevates to Administrator (UAC prompt)
│                       #   - Launches the GUI (CleanPC-GUI.ps1)
│                       #   - Has a commented line to run the console version instead
├─ CleanPC-GUI.ps1      # The graphical version (default experience):
│                       #   scan -> checklist with sizes -> "Clean Selected"
├─ Clean-PC-Cache.ps1   # The no-UI console version: same cleanup, runs straight
│                       #   through. Supports flags for scripting/automation.
├─ README.txt           # Plain-English usage guide for end users / friends.
└─ CLAUDE.md            # This file (context for future edits).
```

## How it works

1. **CleanPC.bat** checks for admin rights; if missing, it relaunches itself
   elevated so it can also clear system locations (Windows\Temp, Windows Update
   cache). It then starts the GUI.
2. **Scan phase** walks known cache locations plus a generic sweep of AppData
   for folders with well-known cache names, measuring each folder's size.
3. **Choose phase** (GUI only) lists every found item with its size, category,
   and a checkbox. Safe items are pre-checked; heavy/optional items
   (Claude VM cache, Recycle Bin) start unchecked. Nothing is deleted yet.
4. **Clean phase** deletes the *contents* of the chosen cache folders (the
   folders themselves are kept). Files locked by running apps are skipped, then
   it reports total space freed and the new C: free space.

## What it cleans (auto-skipped if absent)

- Temp folders, app crash dumps, Windows Error Reporting
- GPU / shader caches: NVIDIA, AMD, Intel, DirectX
- Browser caches: Chrome, Edge, Brave, Opera, Vivaldi, Firefox (all profiles)
- App / Electron caches: Discord, Spotify, Slack, Teams, VS Code, etc.
- Windows thumbnail / icon cache
- Developer package caches: pip, uv, npm, yarn, Go, NuGet, `~/.cache`
- Optional: Recycle Bin, Claude Desktop local-agent VM cache

## What it NEVER touches (safety contract)

Personal files; browser tabs / sessions / cookies / logins / history /
bookmarks / passwords; installed programs and their settings; saved games.
Any change to the codebase must preserve this contract.

## Console version flags (Clean-PC-Cache.ps1)

- `-Auto` — run with no prompts (safe defaults)
- `-DryRun` — report what would be freed, delete nothing
- `-IncludeRecycleBin` / `-IncludeClaudeVM` — opt into the heavy extras
- `-SkipDevCaches` — leave package caches alone

## Where to start when changing things

- **Add or remove a cache location:** edit the `Build-Targets` function in
  `CleanPC-GUI.ps1` (GUI) and the matching section in `Clean-PC-Cache.ps1`
  (console). Keep both in sync. Each target has a name, category, one or more
  paths, a kind (Contents / Thumbnail / RecycleBin), a default-checked flag,
  and an optional note.
- **Change which app names show in the list:** edit the `Friendly-App` helper
  in `CleanPC-GUI.ps1` (it maps a cache path to a readable app name).
- **Adjust the generic app-cache sweep:** edit the cache folder-name list and
  the `-Depth` used in the AppData recursion (in both scripts).
- **Change scan speed / sizing:** `Get-FolderSizeFast` uses a single-pass .NET
  enumerator. Avoid measuring a folder twice — that was the original slowness.
- **Change the UI layout / buttons:** the WinForms window is built at the
  bottom of `CleanPC-GUI.ps1` (splash form, ListView, buttons, the
  `Clean Selected` click handler). **Dock z-order gotcha:** docked controls
  must be added to `$form.Controls` with `Top`/`Bottom` panels FIRST and the
  `Fill` ListView LAST, or the header overlaps the first row. The `Cancel`
  button (`$btnCancel`) is hidden until cleaning starts and shares the `Close`
  button's slot; it sets `$script:cancelRequested`, which the clean loop checks
  between items (stops cleanly, never mid-delete).
- **Build the shareable EXE:** `Invoke-PS2EXE .\CleanPC-GUI.ps1 .\CleanPC.exe
  -requireAdmin -noConsole -title "PC Cache Cleaner"` (needs `Install-Module
  ps2exe`). `-requireAdmin` bakes in the UAC prompt, so the exe replaces
  `CleanPC.bat` for end users. The exe is distributed via GitHub Releases, not
  committed (see `.gitignore`).
- **Make the launcher use the console version by default:** swap the active
  and commented `powershell` lines near the end of `CleanPC.bat`.

## Conventions & gotchas

- Two PowerShell files intentionally duplicate the cleanup list (one for GUI,
  one for console). Edits should update both.
- Deletion empties folder *contents* and skips locked files; it should never
  delete a folder a program expects to exist.
- The Claude Desktop VM cache (large) is locked while Claude Desktop runs —
  it can only be fully freed after closing the app. Keep it default-unchecked.
- Always test new cache paths with `-DryRun` (console) before a real run.
- The whole folder is portable: keep `CleanPC.bat` and both `.ps1` files
  together when copying to another PC.
- Both scripts write `CleanPC-log.txt` next to the exe/script (rolling the
  prior run to `CleanPC-log.old`) via the `Write-CleanLog` helper. The empty
  `catch {}` blocks at each `Remove-Item` now log `SKIP <file>: <reason>` so
  locked-file skips are visible; a script-scope `trap` logs crashes. The
  logging helper must never throw — keep its own `try/catch`. Update both
  scripts' logging in lockstep, same as the cleanup list.
