<#
  deploy.ps1  -  Build CleanPC.exe (icon + version info embedded), verify it, publish a GitHub release.

  Commit and push your changes first, then run (from the repo root):
    .\deploy.ps1 -Version v1.2.1               # build + verify + GitHub release
    .\deploy.ps1 -Version v1.2.1 -BuildOnly    # build + verify only, no release

  Prerequisites:
    Install-Module ps2exe -Scope CurrentUser   # once (installed automatically if missing)
    gh auth login                              # once (GitHub CLI), only for the release step
#>
param(
    [Parameter(Mandatory)][string]$Version,
    [switch]$BuildOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ver4 = ($Version.TrimStart('v') + '.0')

# --- 1. assets\icon.png -> assets\icon.ico (multi-size: 16..256, each entry PNG-compressed) ---
Write-Host "Converting icon.png to a multi-size icon.ico..." -ForegroundColor Cyan
Add-Type -AssemblyName System.Drawing
$srcImg = [System.Drawing.Image]::FromFile((Resolve-Path '.\assets\icon.png').Path)
$sizes  = 16, 24, 32, 48, 64, 128, 256
$pngs   = @()
foreach ($sz in $sizes) {
    $bmp = New-Object System.Drawing.Bitmap($sz, $sz, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    $g.PixelOffsetMode   = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.Clear([System.Drawing.Color]::Transparent)
    $g.DrawImage($srcImg, 0, 0, $sz, $sz)
    $g.Dispose()
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $pngs += ,($ms.ToArray())
    $ms.Close(); $bmp.Dispose()
}
$srcImg.Dispose()
$icoPath = Join-Path (Get-Location).Path 'assets\icon.ico'
$w = [System.IO.BinaryWriter]::new([System.IO.File]::Create($icoPath))
$w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$sizes.Count)      # ICONDIR
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {                                       # ICONDIRENTRY x N
    $d = if ($sizes[$i] -ge 256) { 0 } else { $sizes[$i] }
    $w.Write([byte]$d); $w.Write([byte]$d); $w.Write([byte]0); $w.Write([byte]0)
    $w.Write([uint16]1); $w.Write([uint16]32)
    $w.Write([uint32]$pngs[$i].Length); $w.Write([uint32]$offset)
    $offset += $pngs[$i].Length
}
foreach ($p in $pngs) { $w.Write($p) }
$w.Close()
Write-Host ("  icon.ico: {0} sizes ({1}), {2} bytes" -f $sizes.Count, ($sizes -join ','), (Get-Item $icoPath).Length)

# --- 2. Build the exe (admin manifest, no console, STA for dialogs, icon + version info) ---
Write-Host "Building CleanPC.exe..." -ForegroundColor Cyan
if (-not (Get-Command Invoke-PS2EXE -ErrorAction SilentlyContinue)) {
    Write-Host "ps2exe not found. Installing..." -ForegroundColor Yellow
    Install-Module ps2exe -Scope CurrentUser -Force
}
if (Test-Path '.\CleanPC.exe') { Remove-Item '.\CleanPC.exe' -Force }
Invoke-PS2EXE .\src\CleanPC-GUI.ps1 .\CleanPC.exe `
    -requireAdmin -noConsole -STA `
    -iconFile $icoPath `
    -title "PC Cache Cleaner" `
    -description "PC Cache Cleaner - removes regenerable cache and temp files" `
    -product "PC Cache Cleaner" `
    -company "Ivan-Ryukendo" `
    -copyright "MIT License - github.com/Ivan-Ryukendo/PC-Cache-Cleaner" `
    -version $ver4

if (-not (Test-Path '.\CleanPC.exe')) { throw "Build failed: CleanPC.exe not found." }

# --- 3. Verify: embedded icon (several sizes) + version info ---
Write-Host "Verifying embedded icon and version info..." -ForegroundColor Cyan
$exe = (Resolve-Path '.\CleanPC.exe').Path
Add-Type -Namespace Win32 -Name IconProbe -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern uint PrivateExtractIcons(string file, int index, int cx, int cy, System.IntPtr[] icons, uint[] ids, uint n, uint flags);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool DestroyIcon(System.IntPtr h);
'@
$assoc = [System.Drawing.Icon]::ExtractAssociatedIcon($exe)
if (-not $assoc) { throw "Verification failed: exe has no icon." }
Write-Host ("  ExtractAssociatedIcon OK ({0}x{1})" -f $assoc.Width, $assoc.Height)
foreach ($sz in 16, 32, 48, 256) {
    $h = New-Object 'System.IntPtr[]' 1; $id = New-Object 'uint32[]' 1
    $n = [Win32.IconProbe]::PrivateExtractIcons($exe, 0, $sz, $sz, $h, $id, 1, 0)
    if ($n -lt 1 -or $h[0] -eq [System.IntPtr]::Zero) { throw "Verification failed: no ${sz}x${sz} icon in the exe." }
    [void][Win32.IconProbe]::DestroyIcon($h[0])
    Write-Host ("  {0}x{0} icon present" -f $sz)
}
$vi = (Get-Item $exe).VersionInfo
Write-Host ("  Version info: product='{0}' file version={1} company='{2}' title='{3}'" -f $vi.ProductName, $vi.FileVersion, $vi.CompanyName, $vi.FileDescription)
if ($vi.FileVersion -ne $ver4 -or $vi.ProductName -ne 'PC Cache Cleaner') { throw "Verification failed: unexpected version info." }
Write-Host "Build OK." -ForegroundColor Green
if ($BuildOnly) { return }

# --- 4. Create the GitHub release ---
Write-Host "Creating GitHub release $Version..." -ForegroundColor Cyan
$tag   = $Version
$title = "PC Cache Cleaner $Version"
$notes = @"
## What's new in $Version

- **Check for updates** -- a button that asks GitHub for newer releases. It only runs when you click it (no automatic checks, no telemetry). Downloads go to the same folder as the program or any fixed drive/folder you pick, with a progress bar, Cancel, size and SHA-256 verification; files are never run or replaced automatically. Afterwards you are asked whether to keep or delete the old installer (only that one exe, never a folder).
- **Pro channel** -- the same dialog shows "Upgrade to Pro (free)" once the separate Pro edition is released. A fuller-featured **Pro** edition is coming as its own project (Ivan-Ryukendo/PC-Cache-Cleaner-Pro).
- **System Restore point** -- optional checkbox (off by default) to create a restore point before cleaning; handles Windows' one-per-24h limit and a disabled System Restore gracefully.
- **Export report** -- save the scan (items, sizes, ticked state, risk, paths, report-only rows and security findings) as a self-contained HTML or CSV file, before cleaning.
- **Icon and version info embedded** in the exe (multi-size icon, product/company/version).
- Console script: new ``-CheckUpdate``, ``-RestorePoint`` and ``-ExportReport <path>`` switches.

Also included from v1.2.0:
- **Multi-drive scanning** -- tick any fixed local drive (or All drives) to also find temp folders, Thumbs.db, ``*.gid``, __pycache__ and node_modules cache folders; risky patterns (``*.tmp``, ``*.old``, ``*.dmp``, ``*.chk``, found.NNN) are listed unticked. Removable/network/optical drives are never scanned and junctions are never followed.
- **More junk found** -- Windows Update and Delivery Optimization caches, WER and crash dumps, old CBS logs, NVIDIA App installers, Arduino staging, scoop, Teams caches; Playwright, Gradle and old Codex releases are listed unticked.
- **Report-only tab** -- big virtual disks (WSA, WSL, Application Guard), shadow copies and installed Node versions with removal instructions; the tool never deletes these.
- **Other user profiles** -- optional, separate, unticked; each deletion needs the profile name typed.
- **Security check** -- read-only list of suspicious processes and startup entries plus Defender status. Heuristic only ("suspicious, review"); never kills or deletes anything.
- **Responsive scan** -- scanning runs on background threads with a Stop scan button.

### How to upgrade
Download ``CleanPC.exe`` from the assets below and replace your old copy (or use **Check for updates** inside v1.2.1+). No installer needed.

### Safety reminder
This app only deletes regenerable cache and temp data. It never touches personal files, browser logins, history, passwords, installed programs, or saved games.
"@

# notes go through a UTF-8 file: embedded quotes in --notes break native argument passing on Windows PowerShell 5.1
$notesFile = Join-Path ([System.IO.Path]::GetTempPath()) "cleanpc-notes-$tag.md"
[System.IO.File]::WriteAllText($notesFile, $notes, (New-Object System.Text.UTF8Encoding($false)))
try { gh release create $tag .\CleanPC.exe --title $title --notes-file $notesFile }
finally { Remove-Item $notesFile -Force -ErrorAction SilentlyContinue }
if ($LASTEXITCODE -ne 0) { throw "gh release create failed (exit $LASTEXITCODE)." }

Write-Host "Done! Release $Version is live." -ForegroundColor Green
