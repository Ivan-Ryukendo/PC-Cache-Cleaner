<#
  deploy.ps1  -  Build CleanPC.exe and publish a GitHub release.

  Commit and push your changes first, then run:
    .\deploy.ps1 -Version v1.1.0

  Prerequisites:
    Install-Module ps2exe -Scope CurrentUser   # once
    gh auth login                              # once (GitHub CLI)
#>
param(
    [Parameter(Mandatory)][string]$Version
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- 1. Convert icon.png -> icon.ico (ps2exe needs .ico) ---
Write-Host "Converting icon.png to icon.ico..." -ForegroundColor Cyan
Add-Type -AssemblyName System.Drawing
$png   = [System.Drawing.Bitmap]::new((Resolve-Path '.\icon.png').Path)
$hicon = $png.GetHicon()
$ico   = [System.Drawing.Icon]::FromHandle($hicon)
$icoPath = '.\icon.ico'
$fs    = [System.IO.FileStream]::new($icoPath, [System.IO.FileMode]::Create)
$ico.Save($fs)
$fs.Close(); $ico.Dispose(); $png.Dispose()

# --- 2. Build the exe ---
Write-Host "Building CleanPC.exe..." -ForegroundColor Cyan
if (-not (Get-Command Invoke-PS2EXE -ErrorAction SilentlyContinue)) {
    Write-Host "ps2exe not found. Installing..." -ForegroundColor Yellow
    Install-Module ps2exe -Scope CurrentUser -Force
}
Invoke-PS2EXE .\CleanPC-GUI.ps1 .\CleanPC.exe `
    -requireAdmin -noConsole `
    -title "PC Cache Cleaner" `
    -iconFile $icoPath `
    -version ($Version.TrimStart('v') + '.0')

if (-not (Test-Path '.\CleanPC.exe')) { throw "Build failed: CleanPC.exe not found." }
Write-Host "Build OK." -ForegroundColor Green

# --- 3. Create the GitHub release ---
Write-Host "Creating GitHub release $Version..." -ForegroundColor Cyan
$tag   = $Version
$title = "PC Cache Cleaner $Version"
$notes = @"
## What's new in $Version

- **App icon** -- the broom icon now appears on the EXE file, title bar, taskbar button, and system tray while the app is running
- **System tray** -- the icon is visible in the notification area for the full duration of a cleaning session
- **Button fix** -- Select All, Select None, Clean Selected, and Close buttons no longer have clipped borders
- **README** -- icon and screenshot added so visitors can see the app before downloading

### How to upgrade
Download ``CleanPC.exe`` from the assets below and replace your old copy. No installer needed.

### Safety reminder
This app only deletes regenerable cache and temp data. It never touches personal files, browser logins, history, passwords, installed programs, or saved games.
"@

gh release create $tag .\CleanPC.exe --title $title --notes $notes

Write-Host "Done! Release $Version is live." -ForegroundColor Green
