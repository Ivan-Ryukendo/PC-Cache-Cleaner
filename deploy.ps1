<#
  deploy.ps1  -  Build CleanPC.exe and publish a GitHub release.

  Usage:
    .\deploy.ps1 -Version v1.1.0 -Notes "What changed in this release"

  Prerequisites:
    Install-Module ps2exe -Scope CurrentUser   # once
    gh auth login                              # once (GitHub CLI)
#>
param(
    [Parameter(Mandatory)][string]$Version,
    [string]$Notes = ''
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

# --- 3. Commit and push ---
Write-Host "Committing..." -ForegroundColor Cyan
git add -A
git commit -m "Release $Version"
git push

# --- 4. Create the GitHub release ---
Write-Host "Creating GitHub release $Version..." -ForegroundColor Cyan
if (-not $Notes) { $Notes = "Bug fixes and icon update." }
gh release create $Version .\CleanPC.exe `
    --title "PC Cache Cleaner $Version" `
    --notes $Notes

Write-Host "Done! Release $Version is live." -ForegroundColor Green
