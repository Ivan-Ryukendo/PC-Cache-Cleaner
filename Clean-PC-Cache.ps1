<#
================================================================================
  Clean-PC-Cache.ps1  -  Generalized Windows 10/11 cache & temp cleaner
================================================================================
  Safely deletes regenerable CACHE and TEMP data only. It NEVER touches:
    - Documents, downloads, or any personal files
    - Browser tabs, sessions, cookies, logins, history, bookmarks, passwords
    - Installed programs or their settings
    - Saved game data

  Auto-detects what the PC has. Anything not present is silently skipped, so
  the same script works on any Windows 10/11 machine (NVIDIA / AMD / Intel).

  USAGE
    Double-click  CleanPC.bat   (recommended - it self-elevates for system temp)
  or from PowerShell:
    .\Clean-PC-Cache.ps1                 # interactive, prompts for risky extras
    .\Clean-PC-Cache.ps1 -Auto           # no prompts, safe defaults only
    .\Clean-PC-Cache.ps1 -Auto -IncludeRecycleBin -IncludeClaudeVM
    .\Clean-PC-Cache.ps1 -DryRun         # show what WOULD be freed, delete nothing

  PARAMETERS
    -Auto              Run without any prompts (uses defaults + any -Include flags)
    -IncludeRecycleBin Also empty the Recycle Bin
    -IncludeClaudeVM   Also delete the Claude Desktop local-agent VM bundle (large)
    -SkipDevCaches     Skip pip/uv/npm/yarn/NuGet/Go package caches
    -DryRun            Report only, delete nothing
================================================================================
#>
[CmdletBinding()]
param(
    [switch]$Auto,
    [switch]$IncludeRecycleBin,
    [switch]$IncludeClaudeVM,
    [switch]$SkipDevCaches,
    [switch]$DryRun
)

$ErrorActionPreference = 'SilentlyContinue'
$script:TotalFreed = [int64]0
$script:Rows = @()

# --- logging setup (next to the exe/script) ---
$script:LogDir = if ($PSScriptRoot) { $PSScriptRoot } else { [System.AppDomain]::CurrentDomain.BaseDirectory }
if (-not $script:LogDir) { $script:LogDir = (Get-Location).Path }
$script:LogPath = Join-Path $script:LogDir 'CleanPC-log.txt'
try {
    if (Test-Path -LiteralPath $script:LogPath) {
        Copy-Item -LiteralPath $script:LogPath -Destination (Join-Path $script:LogDir 'CleanPC-log.old') -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $script:LogPath -Force -ErrorAction SilentlyContinue
    }
} catch {}
function Write-CleanLog([string]$msg){
    try { Add-Content -LiteralPath $script:LogPath -Value ("{0}  {1}" -f (Get-Date -Format s), $msg) } catch {}
}

function Format-Size([int64]$b) {
    if ($b -ge 1GB) { return ('{0:N2} GB' -f ($b / 1GB)) }
    if ($b -ge 1MB) { return ('{0:N1} MB' -f ($b / 1MB)) }
    if ($b -ge 1KB) { return ('{0:N0} KB' -f ($b / 1KB)) }
    return "$b B"
}

function Get-FolderSize([string]$path) {
    try {
        return [int64]((Get-ChildItem -LiteralPath $path -Recurse -File -Force -ErrorAction SilentlyContinue |
            Measure-Object -Property Length -Sum).Sum)
    } catch { return [int64]0 }
}

function Is-Admin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        return ([Security.Principal.WindowsPrincipal]$id).IsInRole(
            [Security.Principal.WindowsBuiltinRole]::Administrator)
    } catch { return $false }
}

# Empties the CONTENTS of a folder (keeps the folder itself). Locked files are skipped.
function Clear-Contents {
    param([string]$Path, [string]$Label)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $before = Get-FolderSize $Path
    if ($before -le 0) { return }
    if (-not $DryRun) {
        Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue | ForEach-Object {
            $f = $_.FullName
            try { Remove-Item -LiteralPath $f -Recurse -Force -ErrorAction Stop } catch { Write-CleanLog "SKIP ${f}: $($_.Exception.Message)" }
        }
    }
    $after  = if ($DryRun) { 0 } else { Get-FolderSize $Path }
    $freed  = $before - $after
    if ($freed -lt 0) { $freed = 0 }
    if ($freed -gt 0 -or $DryRun) {
        $script:TotalFreed += $freed
        $shown = if ($DryRun) { $before } else { $freed }
        $script:Rows += [PSCustomObject]@{ Freed = $shown; Item = $Label }
        Write-CleanLog ("FREED {0}  {1}" -f (Format-Size $shown), $Label)
        Write-Host ("   {0,10}  {1}" -f (Format-Size $shown), $Label) -ForegroundColor Gray
    }
}

function Section([string]$t) { Write-Host "`n== $t ==" -ForegroundColor Cyan }

Clear-Host
Write-Host "================================================================" -ForegroundColor White
Write-Host "  Windows Cache & Temp Cleaner" -ForegroundColor White
Write-Host "  Mode: $(if($DryRun){'DRY RUN (nothing deleted)'}elseif($Auto){'Auto'}else{'Interactive'})   Admin: $(Is-Admin)" -ForegroundColor White
Write-Host "================================================================" -ForegroundColor White

trap {
    Write-CleanLog "CRASH: $($_.Exception.Message)"
    Write-CleanLog "STACK: $($_.ScriptStackTrace)"
    Write-Host "An error occurred. Details written to $script:LogPath" -ForegroundColor Red
    continue
}

$cFreeStart = (Get-PSDrive C -ErrorAction SilentlyContinue).Free
$L = $env:LOCALAPPDATA; $R = $env:APPDATA; $U = $env:USERPROFILE; $PD = $env:ProgramData
$admin = Is-Admin
Write-CleanLog ("=== Run start === admin=$admin os=$([System.Environment]::OSVersion.Version) host=$([System.Environment]::MachineName) dryrun=$DryRun")

# ---------------------------------------------------------------- Temp / system
Section "Temporary files"
Clear-Contents "$env:TEMP"                                   "User Temp"
Clear-Contents "$L\Temp"                                     "User Temp (LocalAppData)"
Clear-Contents "$L\CrashDumps"                               "Application crash dumps"
Clear-Contents "$L\Microsoft\Windows\WER"                    "Windows Error Reporting (user)"
Clear-Contents "$L\Microsoft\Windows\INetCache"             "Internet Explorer/WinINet cache"
if ($admin) {
    Clear-Contents "C:\Windows\Temp"                         "Windows Temp (system)"
    Clear-Contents "$PD\Microsoft\Windows\WER"               "Windows Error Reporting (system)"
    # Windows Update download cache
    if (Test-Path "C:\Windows\SoftwareDistribution\Download") {
        Stop-Service wuauserv -Force -ErrorAction SilentlyContinue
        Clear-Contents "C:\Windows\SoftwareDistribution\Download" "Windows Update download cache"
        Start-Service wuauserv -ErrorAction SilentlyContinue
    }
} else {
    Write-Host "   (run as Administrator to also clean Windows\Temp & Windows Update cache)" -ForegroundColor DarkYellow
}

# ----------------------------------------------------------------- GPU caches
Section "GPU / shader caches (NVIDIA / AMD / Intel)"
Clear-Contents "$L\NVIDIA\DXCache"                           "NVIDIA DirectX shader cache"
Clear-Contents "$L\NVIDIA\GLCache"                           "NVIDIA OpenGL shader cache"
Clear-Contents "$PD\NVIDIA Corporation\NV_Cache"            "NVIDIA driver cache"
Clear-Contents "$L\AMD\DxCache"                              "AMD DirectX shader cache"
Clear-Contents "$L\AMD\GLCache"                              "AMD OpenGL shader cache"
Clear-Contents "$L\AMD\VkCache"                              "AMD Vulkan shader cache"
Clear-Contents "$L\Intel\ShaderCache"                       "Intel shader cache"
Clear-Contents "$L\D3DSCache"                                "DirectX shader cache (D3DSCache)"

# ----------------------------------------------------- Browser & app (Chromium/Electron)
# Generic sweep: any folder under AppData with a well-known CACHE name.
# Catches Chrome/Edge/Brave/Opera/Vivaldi + Discord/Spotify/Slack/Teams/VS Code/etc.
Section "Browser & application caches"
$cacheNames = @('Cache','Cache_Data','Code Cache','GPUCache','CachedData',
                'DawnGraphiteCache','DawnWebGPUCache','DawnCache','GrShaderCache','ShaderCache')
foreach ($root in @($L, $R)) {
    if (-not (Test-Path -LiteralPath $root)) { continue }
    Get-ChildItem -LiteralPath $root -Directory -Recurse -Depth 5 -Force -ErrorAction SilentlyContinue |
        Where-Object { $cacheNames -contains $_.Name } |
        ForEach-Object {
            # skip the Claude VM bundle area; handled separately
            if ($_.FullName -like '*\vm_bundles\*') { return }
            $sz = Get-FolderSize $_.FullName
            if ($sz -gt 5MB) {
                $rel = $_.FullName.Replace($L,'%LOCALAPPDATA%').Replace($R,'%APPDATA%')
                Clear-Contents $_.FullName $rel
            }
        }
}
# Firefox uses cache2
Get-ChildItem -LiteralPath "$L\Mozilla\Firefox\Profiles" -Directory -ErrorAction SilentlyContinue | ForEach-Object {
    Clear-Contents (Join-Path $_.FullName 'cache2') "Firefox cache ($($_.Name))"
}

# ---------------------------------------------------------------- Thumbnail cache
Section "Windows thumbnail / icon cache"
$thumbDir = "$L\Microsoft\Windows\Explorer"
if (Test-Path $thumbDir) {
    $tb = (Get-ChildItem -LiteralPath $thumbDir -Filter 'thumbcache_*.db' -Force -EA SilentlyContinue |
           Measure-Object Length -Sum).Sum
    $ib = (Get-ChildItem -LiteralPath $thumbDir -Filter 'iconcache_*.db' -Force -EA SilentlyContinue |
           Measure-Object Length -Sum).Sum
    $tot = [int64]$tb + [int64]$ib
    if ($tot -gt 0) {
        if (-not $DryRun) {
            Get-ChildItem -LiteralPath $thumbDir -Include 'thumbcache_*.db','iconcache_*.db' -Force -EA SilentlyContinue |
                ForEach-Object { $f = $_.FullName; try { Remove-Item -LiteralPath $f -Force -EA Stop } catch { Write-CleanLog "SKIP ${f}: $($_.Exception.Message)" } }
        }
        $script:TotalFreed += $tot
        $script:Rows += [PSCustomObject]@{ Freed = $tot; Item = 'Thumbnail/icon cache' }
        Write-Host ("   {0,10}  {1}" -f (Format-Size $tot), 'Thumbnail/icon cache (rebuilds automatically)') -ForegroundColor Gray
    }
}

# ----------------------------------------------------------- Dev / package caches
if (-not $SkipDevCaches) {
    Section "Developer package caches (re-downloaded on next use)"
    Clear-Contents "$L\pip\Cache"          "pip cache (Python)"
    Clear-Contents "$L\pip\cache"          "pip cache (Python)"
    Clear-Contents "$L\uv\cache"           "uv cache (Python)"
    Clear-Contents "$L\npm-cache"          "npm cache (Node)"
    Clear-Contents "$R\npm-cache"          "npm cache (Node)"
    Clear-Contents "$L\Yarn\Cache"         "Yarn cache (Node)"
    Clear-Contents "$L\go-build"           "Go build cache"
    Clear-Contents "$L\NuGet\v3-cache"     "NuGet http cache (.NET)"
    Clear-Contents "$U\.cache"             "User .cache (tool caches)"
}

# --------------------------------------------------------- Claude Desktop VM (opt)
$claudeVM = "$R\Claude\vm_bundles"
if (Test-Path $claudeVM) {
    $doClaude = $IncludeClaudeVM
    if (-not $Auto -and -not $IncludeClaudeVM) {
        $sz = Format-Size (Get-FolderSize $claudeVM)
        $ans = Read-Host "`nClaude Desktop local-agent VM cache found ($sz). Delete it? Close Claude Desktop first. (y/N)"
        $doClaude = ($ans -match '^(y|yes)$')
    }
    if ($doClaude) {
        Section "Claude Desktop VM bundle"
        if (Get-Process -Name 'claude' -ErrorAction SilentlyContinue) {
            Write-Host "   NOTE: Claude Desktop appears to be running - locked files will be skipped." -ForegroundColor DarkYellow
            Write-Host "   Close Claude Desktop and re-run for full cleanup." -ForegroundColor DarkYellow
        }
        Clear-Contents $claudeVM "Claude Desktop local-agent VM cache"
    }
}

# ------------------------------------------------------------------ Recycle Bin
$doBin = $IncludeRecycleBin
if (-not $Auto -and -not $IncludeRecycleBin) {
    $ans = Read-Host "`nEmpty the Recycle Bin? (y/N)"
    $doBin = ($ans -match '^(y|yes)$')
}
if ($doBin -and -not $DryRun) {
    Section "Recycle Bin"
    try {
        $rbBefore = ((New-Object -ComObject Shell.Application).Namespace(0xA).Items() |
                     ForEach-Object { $_.Size } | Measure-Object -Sum).Sum
    } catch { $rbBefore = 0 }
    Clear-RecycleBin -Force -ErrorAction SilentlyContinue
    if ($rbBefore -gt 0) {
        $script:TotalFreed += $rbBefore
        Write-Host ("   {0,10}  {1}" -f (Format-Size $rbBefore), 'Recycle Bin emptied') -ForegroundColor Gray
    }
}

# ----------------------------------------------------------------------- Summary
Write-Host "`n================================================================" -ForegroundColor White
if ($DryRun) {
    Write-Host ("  DRY RUN - would free about: {0}" -f (Format-Size $script:TotalFreed)) -ForegroundColor Yellow
} else {
    Write-Host ("  TOTAL FREED: {0}" -f (Format-Size $script:TotalFreed)) -ForegroundColor Green
}
$cFreeEnd = (Get-PSDrive C -ErrorAction SilentlyContinue).Free
if ($null -ne $cFreeStart -and $null -ne $cFreeEnd) {
    Write-Host ("  C: free  {0}  ->  {1}" -f (Format-Size $cFreeStart), (Format-Size $cFreeEnd)) -ForegroundColor Green
}
Write-Host "================================================================" -ForegroundColor White
Write-Host "Tip: close browsers & chat apps before running for maximum cleanup." -ForegroundColor DarkGray
Write-CleanLog ("=== TOTAL FREED {0} ===" -f (Format-Size $script:TotalFreed))
