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

# --- 1. Convert icon.png -> icon.ico (proper Vista ICO: ICONDIR + embedded PNG) ---
Write-Host "Converting icon.png to icon.ico..." -ForegroundColor Cyan
Add-Type -AssemblyName System.Drawing
$srcImg = [System.Drawing.Image]::FromFile((Resolve-Path '.\assets\icon.png').Path)
$bmp    = New-Object System.Drawing.Bitmap(256, 256)
$g      = [System.Drawing.Graphics]::FromImage($bmp)
$g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$g.DrawImage($srcImg, 0, 0, 256, 256)
$g.Dispose(); $srcImg.Dispose()
$pngStream = New-Object System.IO.MemoryStream
$bmp.Save($pngStream, [System.Drawing.Imaging.ImageFormat]::Png)
$pngBytes = $pngStream.ToArray()
$pngStream.Close(); $bmp.Dispose()
$icoPath = '.\assets\icon.ico'
$w = [System.IO.BinaryWriter]::new([System.IO.File]::Create($icoPath))
$w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]1)   # ICONDIR header
$w.Write([byte]0); $w.Write([byte]0); $w.Write([byte]0); $w.Write([byte]0)  # 256x256, no palette
$w.Write([uint16]1); $w.Write([uint16]32)                       # 1 plane, 32bpp
$w.Write([uint32]$pngBytes.Length); $w.Write([uint32]22)        # data size, offset=22
$w.Write($pngBytes); $w.Close()

# --- 2. Build the exe ---
Write-Host "Building CleanPC.exe..." -ForegroundColor Cyan
if (-not (Get-Command Invoke-PS2EXE -ErrorAction SilentlyContinue)) {
    Write-Host "ps2exe not found. Installing..." -ForegroundColor Yellow
    Install-Module ps2exe -Scope CurrentUser -Force
}
Invoke-PS2EXE .\src\CleanPC-GUI.ps1 .\CleanPC.exe `
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
