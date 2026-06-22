# PC-Cache-Cleaner

Portable Windows 10/11 cache & temp cleaner. Auto-detects GPU/browser/dev/app
caches and frees space by deleting **only regenerable cache/temp data**. Shipped
as one `CleanPC.exe` on GitHub Releases (repo: `Ivan-Ryukendo/PC-Cache-Cleaner`).

## Files

- `CleanPC-GUI.ps1` — GUI (scan → checklist with sizes → Clean Selected). This
  is what the `.exe` wraps and the default experience.
- `Clean-PC-Cache.ps1` — no-UI console version; same cleanup. Flags: `-Auto`,
  `-DryRun`, `-IncludeRecycleBin`, `-IncludeClaudeVM`, `-SkipDevCaches`.
- `CleanPC.bat` — legacy launcher (self-elevates, runs the GUI). The `-requireAdmin`
  exe makes this optional for end users; kept for source runs.
- `README.md` (GitHub) / `README.txt` (end users). `DESIGN-exe-and-logging.md` —
  design/decision log (gitignored, local only).

## Safety contract (never break)

Deletes cache/temp **contents** only, keeping the folders. NEVER touches
personal files, browser sessions/cookies/logins/history/bookmarks/passwords,
installed programs/settings, or saved games. Locked files are skipped, not
forced. **Nothing in the list may be hidden from the user before deletion** —
every item must be visible and tickable.

## Build & ship

```powershell
Install-Module ps2exe -Scope CurrentUser   # once
Invoke-PS2EXE .\CleanPC-GUI.ps1 .\CleanPC.exe -requireAdmin -noConsole -title "PC Cache Cleaner"
gh release create vX.Y.Z .\CleanPC.exe --title "..." --notes "..."
```

The exe and `CleanPC-log*.txt` are gitignored — never commit them; the exe goes
to a Release, logs stay local.

## Editing notes

- **Cleanup targets** live in `Build-Targets` (GUI) and the matching section in
  the console script — keep both in sync, including logging.
- **Logging:** both scripts roll the prior log to `CleanPC-log.old` and write
  `CleanPC-log.txt` next to the exe via `Write-CleanLog` (must never throw).
  Skips log `SKIP <file>: <reason>`; a script-scope `trap` logs crashes.
- **UI (WinForms, bottom of GUI script):** the header is in its own docked Top
  panel and the ListView in a Fill panel with top padding, so the header can't
  cover the first row — preserve that separation. `Cancel` button stops the
  clean loop between items (never mid-delete).
- Test path changes with `-DryRun` before a real run.
