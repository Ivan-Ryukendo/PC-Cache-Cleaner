<#
================================================================================
  CleanPC-GUI.ps1  -  Windows 10/11 cache cleaner with a click-to-confirm UI
================================================================================
  Scans the PC for regenerable CACHE / TEMP data, then shows a checklist where
  YOU pick exactly what to delete (each row shows its size). Nothing is removed
  until you press "Clean Selected".

  NEVER touches: personal files, browser tabs/sessions/logins/history/bookmarks,
  installed programs, or saved games.

  Auto-detects what the PC has (NVIDIA / AMD / Intel, any browser, dev tools),
  so the same file works on any Windows 10/11 machine.
================================================================================
#>
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$ErrorActionPreference = 'SilentlyContinue'

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

# ---------------------------------------------------------------- helpers
function Format-Size([int64]$b){
    if($b -ge 1GB){ return ('{0:N2} GB' -f ($b/1GB)) }
    if($b -ge 1MB){ return ('{0:N1} MB' -f ($b/1MB)) }
    if($b -ge 1KB){ return ('{0:N0} KB' -f ($b/1KB)) }
    return "$b B"
}
# Fast directory size via .NET enumerator (FileInfo.Length needs no extra I/O)
function Get-FolderSizeFast([string]$p){
    if(-not [System.IO.Directory]::Exists($p)){ return [int64]0 }
    $sum=[int64]0
    try{
        $di = New-Object System.IO.DirectoryInfo $p
        foreach($f in $di.EnumerateFiles('*',[System.IO.SearchOption]::AllDirectories)){
            try{ $sum += $f.Length }catch{}
        }
    }catch{}
    return $sum
}
function Is-Admin{
    try{ return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator) }catch{ return $false }
}
function Friendly-App([string]$full,[string]$L,[string]$R){
    $rel=$full
    if($full.StartsWith($L,'OrdinalIgnoreCase')){ $rel=$full.Substring($L.Length).TrimStart('\') }
    elseif($full.StartsWith($R,'OrdinalIgnoreCase')){ $rel=$full.Substring($R.Length).TrimStart('\') }
    $p0=($rel -split '\\')[0]
    switch -Regex ($rel){
        'Google\\Chrome'        { return 'Google Chrome (cache)' }
        'BraveSoftware'         { return 'Brave Browser (cache)' }
        'Microsoft\\Edge'       { return 'Microsoft Edge (cache)' }
        'Vivaldi'               { return 'Vivaldi (cache)' }
        'Opera Software'        { return 'Opera (cache)' }
        'Mozilla'               { return 'Firefox (cache)' }
        default                 { return "$p0 (cache)" }
    }
}

# ---------------------------------------------------------------- scan model
# Builds the list of cleanup targets. Each target:
#   Name, Category, Size(int64), Paths(string[]), Kind(Contents/Thumbnail/RecycleBin), Checked(bool), Note
function Build-Targets([scriptblock]$Progress){
    $L=$env:LOCALAPPDATA; $R=$env:APPDATA; $U=$env:USERPROFILE; $PD=$env:ProgramData
    $admin = Is-Admin
    $T = New-Object System.Collections.Generic.List[object]
    function Add-T($name,$cat,$paths,$kind,$checked,$note){
        & $Progress "Scanning: $name"
        if($kind -eq 'RecycleBin'){
            try{ $sz=((New-Object -ComObject Shell.Application).Namespace(0xA).Items()|ForEach-Object{$_.Size}|Measure-Object -Sum).Sum }catch{ $sz=0 }
        } else {
            $sz=[int64]0; foreach($p in $paths){ if($kind -eq 'Thumbnail'){ $sz += (Get-ChildItem -LiteralPath $p -Force -EA SilentlyContinue|Where-Object{$_.Name -match '^(thumb|icon)cache_.*\.db$'}|Measure-Object Length -Sum).Sum } else { $sz += Get-FolderSizeFast $p } }
        }
        if($sz -le 0){ return }
        $T.Add([PSCustomObject]@{ Name=$name; Category=$cat; Size=[int64]$sz; Paths=$paths; Kind=$kind; Checked=$checked; Note=$note })
    }

    # --- Temp / system ---
    Add-T 'User Temp files'              'Temp'  @("$env:TEMP","$L\Temp")                 'Contents' $true ''
    Add-T 'Application crash dumps'      'Temp'  @("$L\CrashDumps")                        'Contents' $true ''
    Add-T 'Windows Error Reporting'     'Temp'  @("$L\Microsoft\Windows\WER")             'Contents' $true ''
    if($admin){
        Add-T 'Windows Temp (system)'    'Temp'  @("C:\Windows\Temp")                      'Contents' $true 'admin'
        Add-T 'Windows Update cache'     'Temp'  @("C:\Windows\SoftwareDistribution\Download") 'Contents' $true 'admin'
    }

    # --- GPU / shader ---
    Add-T 'NVIDIA shader cache'          'GPU'   @("$L\NVIDIA\DXCache","$L\NVIDIA\GLCache","$PD\NVIDIA Corporation\NV_Cache") 'Contents' $true ''
    Add-T 'AMD shader cache'             'GPU'   @("$L\AMD\DxCache","$L\AMD\GLCache","$L\AMD\VkCache") 'Contents' $true ''
    Add-T 'Intel shader cache'           'GPU'   @("$L\Intel\ShaderCache")                 'Contents' $true ''
    Add-T 'DirectX shader cache'         'GPU'   @("$L\D3DSCache")                          'Contents' $true ''

    # --- Browser & app caches (generic, grouped by app) ---
    $names=@('Cache','Cache_Data','Code Cache','GPUCache','CachedData','DawnGraphiteCache','DawnWebGPUCache','DawnCache','GrShaderCache','ShaderCache')
    $groups=@{}
    foreach($root in @($L,$R)){
        if(-not (Test-Path -LiteralPath $root)){ continue }
        & $Progress "Scanning apps in $(Split-Path $root -Leaf)..."
        Get-ChildItem -LiteralPath $root -Directory -Recurse -Depth 5 -Force -EA SilentlyContinue |
            Where-Object { $names -contains $_.Name -and $_.FullName -notlike '*\vm_bundles\*' } |
            ForEach-Object {
                $key = Friendly-App $_.FullName $L $R
                if(-not $groups.ContainsKey($key)){ $groups[$key]=New-Object System.Collections.Generic.List[string] }
                $groups[$key].Add($_.FullName)
            }
    }
    # Firefox cache2
    Get-ChildItem -LiteralPath "$L\Mozilla\Firefox\Profiles" -Directory -EA SilentlyContinue | ForEach-Object {
        $c=Join-Path $_.FullName 'cache2'; if(Test-Path $c){ if(-not $groups.ContainsKey('Firefox (cache)')){$groups['Firefox (cache)']=New-Object System.Collections.Generic.List[string]}; $groups['Firefox (cache)'].Add($c) }
    }
    foreach($k in $groups.Keys){ Add-T $k 'Browser/App' ($groups[$k].ToArray()) 'Contents' $true '' }

    # --- Thumbnails ---
    Add-T 'Thumbnail / icon cache'       'Windows' @("$L\Microsoft\Windows\Explorer")      'Thumbnail' $true ''

    # --- Dev / package caches ---
    Add-T 'pip cache (Python)'           'Dev'   @("$L\pip\Cache","$L\pip\cache")           'Contents' $true ''
    Add-T 'uv cache (Python)'            'Dev'   @("$L\uv\cache")                           'Contents' $true ''
    Add-T 'npm cache (Node)'             'Dev'   @("$L\npm-cache","$R\npm-cache")           'Contents' $true ''
    Add-T 'Yarn cache (Node)'            'Dev'   @("$L\Yarn\Cache")                          'Contents' $true ''
    Add-T 'Go build cache'               'Dev'   @("$L\go-build")                           'Contents' $true ''
    Add-T 'NuGet http cache (.NET)'      'Dev'   @("$L\NuGet\v3-cache")                      'Contents' $true ''
    Add-T 'User .cache (tool caches)'    'Dev'   @("$U\.cache")                             'Contents' $true ''

    # --- Optional / heavy (default UNchecked) ---
    Add-T 'Claude Desktop VM cache'      'Optional' @("$R\Claude\vm_bundles")              'Contents' $false 'Close Claude Desktop first to free it fully'
    Add-T 'Recycle Bin'                  'Optional' @('')                                   'RecycleBin' $false ''

    return $T
}

# ---------------------------------------------------------------- deletion
function Invoke-Clean($target){
    switch($target.Kind){
        'RecycleBin' { Clear-RecycleBin -Force -EA SilentlyContinue; return }
        'Thumbnail'  {
            foreach($p in $target.Paths){
                Get-ChildItem -LiteralPath $p -Force -EA SilentlyContinue |
                    Where-Object { $_.Name -match '^(thumb|icon)cache_.*\.db$' } |
                    ForEach-Object { $f=$_.FullName; try{ Remove-Item -LiteralPath $f -Force -EA Stop }catch{ Write-CleanLog "SKIP ${f}: $($_.Exception.Message)" } }
            }
            return
        }
        default {
            foreach($p in $target.Paths){
                if(-not (Test-Path -LiteralPath $p)){ continue }
                Get-ChildItem -LiteralPath $p -Force -EA SilentlyContinue | ForEach-Object {
                    $f=$_.FullName
                    try{ Remove-Item -LiteralPath $f -Recurse -Force -EA Stop }catch{ Write-CleanLog "SKIP ${f}: $($_.Exception.Message)" }
                }
            }
        }
    }
}

# ---------------------------------------------------------------- splash + scan
trap {
    Write-CleanLog "CRASH: $($_.Exception.Message)"
    Write-CleanLog "STACK: $($_.ScriptStackTrace)"
    try { [System.Windows.Forms.MessageBox]::Show("An error occurred. Details written to:`n$script:LogPath","Clean PC error",'OK','Error') | Out-Null } catch {}
    continue
}
Write-CleanLog ("=== Run start (GUI) === admin=$(Is-Admin) os=$([System.Environment]::OSVersion.Version) host=$([System.Environment]::MachineName)")
$splash = New-Object System.Windows.Forms.Form
$splash.Text='Scanning'; $splash.FormBorderStyle='FixedDialog'; $splash.StartPosition='CenterScreen'
$splash.Width=420; $splash.Height=120; $splash.ControlBox=$false; $splash.TopMost=$true
$lblS=New-Object System.Windows.Forms.Label; $lblS.AutoSize=$false; $lblS.Dock='Fill'
$lblS.TextAlign='MiddleCenter'; $lblS.Text="Scanning your PC for cache files..."; $lblS.Font=New-Object System.Drawing.Font('Segoe UI',10)
$splash.Controls.Add($lblS); $splash.Show(); $splash.Refresh()
$progress = { param($m) $lblS.Text=$m; $lblS.Refresh(); [System.Windows.Forms.Application]::DoEvents() }

$targets = Build-Targets $progress
$splash.Close(); $splash.Dispose()

if(($targets|Measure-Object).Count -eq 0){
    [System.Windows.Forms.MessageBox]::Show("Nothing to clean - no cache found. Your PC is already tidy!","Clean PC",'OK','Information')|Out-Null
    return
}

# ---------------------------------------------------------------- main window
$form=New-Object System.Windows.Forms.Form
$form.Text='Clean PC - choose what to delete'
$form.StartPosition='CenterScreen'; $form.Width=720; $form.Height=620; $form.MinimumSize=New-Object System.Drawing.Size(640,520)

# Build all controls, then add them in dock z-order: Fill control MUST be added
# LAST so docked Top/Bottom controls reserve their space first and nothing overlaps.
$header=New-Object System.Windows.Forms.Label
$header.Text="Tick the items you want to delete, then press 'Clean Selected'. Only safe cache/temp data is listed."
$header.Dock='Top'; $header.Height=40; $header.Padding=New-Object System.Windows.Forms.Padding(10,10,10,0)
$header.Font=New-Object System.Drawing.Font('Segoe UI',9)

$lv=New-Object System.Windows.Forms.ListView
$lv.View='Details'; $lv.CheckBoxes=$true; $lv.FullRowSelect=$true; $lv.GridLines=$true
$lv.Dock='Fill'; $lv.Font=New-Object System.Drawing.Font('Segoe UI',9)
$lv.Columns.Add('Item',300)|Out-Null
$lv.Columns.Add('Size',90)|Out-Null
$lv.Columns.Add('Category',110)|Out-Null
$lv.Columns.Add('Note',170)|Out-Null

foreach($t in ($targets | Sort-Object @{e='Category'},@{e='Size';Descending=$true})){
    $it=New-Object System.Windows.Forms.ListViewItem($t.Name)
    $it.SubItems.Add((Format-Size $t.Size))|Out-Null
    $it.SubItems.Add($t.Category)|Out-Null
    $it.SubItems.Add($t.Note)|Out-Null
    $it.Checked=$t.Checked
    $it.Tag=$t
    $lv.Items.Add($it)|Out-Null
}

$panel=New-Object System.Windows.Forms.Panel; $panel.Dock='Bottom'; $panel.Height=90

# Dock z-order: add Bottom + Top first, Fill (ListView) LAST so it fills the gap.
$form.Controls.Add($panel)
$form.Controls.Add($header)
$form.Controls.Add($lv)

$lblTotal=New-Object System.Windows.Forms.Label
$lblTotal.AutoSize=$false; $lblTotal.Dock='Top'; $lblTotal.Height=28
$lblTotal.TextAlign='MiddleLeft'; $lblTotal.Padding=New-Object System.Windows.Forms.Padding(12,0,0,0)
$lblTotal.Font=New-Object System.Drawing.Font('Segoe UI',10,[System.Drawing.FontStyle]::Bold)
$panel.Controls.Add($lblTotal)

$status=New-Object System.Windows.Forms.Label
$status.AutoSize=$false; $status.Dock='Top'; $status.Height=20; $status.Padding=New-Object System.Windows.Forms.Padding(12,0,0,0)
$status.ForeColor=[System.Drawing.Color]::DimGray
$panel.Controls.Add($status)

function Update-Total{
    $sum=[int64]0
    foreach($i in $lv.Items){ if($i.Checked){ $sum += [int64]$i.Tag.Size } }
    $lblTotal.Text = "Selected: " + (Format-Size $sum)
}
$lv.Add_ItemChecked({ Update-Total })

$btnAll=New-Object System.Windows.Forms.Button; $btnAll.Text='Select all'; $btnAll.Width=90; $btnAll.Height=30; $btnAll.Left=12; $btnAll.Top=46
$btnAll.Add_Click({ foreach($i in $lv.Items){$i.Checked=$true} })
$btnNone=New-Object System.Windows.Forms.Button; $btnNone.Text='Select none'; $btnNone.Width=90; $btnNone.Height=30; $btnNone.Left=110; $btnNone.Top=46
$btnNone.Add_Click({ foreach($i in $lv.Items){$i.Checked=$false} })
$btnClean=New-Object System.Windows.Forms.Button; $btnClean.Text='Clean Selected'; $btnClean.Width=140; $btnClean.Height=34; $btnClean.Top=44
$btnClean.Font=New-Object System.Drawing.Font('Segoe UI',9,[System.Drawing.FontStyle]::Bold)
$btnClose=New-Object System.Windows.Forms.Button; $btnClose.Text='Close'; $btnClose.Width=90; $btnClose.Height=34; $btnClose.Top=44
$btnClose.Add_Click({ $form.Close() })
# Cancel: only visible while cleaning; sets a flag the loop checks between items.
$script:cancelRequested=$false
$btnCancel=New-Object System.Windows.Forms.Button; $btnCancel.Text='Cancel'; $btnCancel.Width=90; $btnCancel.Height=34; $btnCancel.Top=44; $btnCancel.Visible=$false
$btnCancel.Add_Click({ $script:cancelRequested=$true; $btnCancel.Enabled=$false; $status.Text='Cancelling after current item...' })
$panel.Controls.AddRange(@($btnAll,$btnNone,$btnClean,$btnClose,$btnCancel))
$panel.Add_Resize({ $btnClose.Left=$panel.Width-104; $btnCancel.Left=$panel.Width-104; $btnClean.Left=$panel.Width-252 })
$btnClose.Left=$form.Width-120; $btnCancel.Left=$form.Width-120; $btnClean.Left=$form.Width-268

$btnClean.Add_Click({
    $chosen=@(); foreach($i in $lv.Items){ if($i.Checked){ $chosen += $i } }
    if($chosen.Count -eq 0){ [System.Windows.Forms.MessageBox]::Show("Nothing selected.","Clean PC",'OK','Information')|Out-Null; return }
    $cv = $chosen | Where-Object { $_.Tag.Name -like 'Claude*' }
    if($cv -and (Get-Process -Name 'claude' -EA SilentlyContinue)){
        $r=[System.Windows.Forms.MessageBox]::Show("Claude Desktop is running, so its VM cache can't be fully freed. Close Claude Desktop first for that item.`n`nContinue with the rest now?","Claude Desktop is open",'OKCancel','Warning')
        if($r -eq 'Cancel'){ return }
    }
    $btnClean.Enabled=$false; $btnAll.Enabled=$false; $btnNone.Enabled=$false
    $script:cancelRequested=$false; $btnCancel.Enabled=$true; $btnCancel.Visible=$true; $btnClose.Visible=$false
    $freed=[int64]0; $n=0; $cancelled=$false
    foreach($i in $chosen){
        if($script:cancelRequested){ $cancelled=$true; Write-CleanLog "=== CANCELLED by user ==="; break }
        $n++; $status.Text="Cleaning ($n/$($chosen.Count)): $($i.Tag.Name)"; $status.Refresh(); [System.Windows.Forms.Application]::DoEvents()
        $before=[int64]$i.Tag.Size
        Invoke-Clean $i.Tag
        $after=[int64]0
        if($i.Tag.Kind -ne 'RecycleBin'){ foreach($p in $i.Tag.Paths){ if($p){ $after += Get-FolderSizeFast $p } } }
        $df=$before-$after; if($df -lt 0){$df=0}; $freed+=$df
        Write-CleanLog ("FREED {0}  {1}" -f (Format-Size $df), $i.Tag.Name)
        $i.SubItems[1].Text = (Format-Size $after)
        $i.Checked=$false
    }
    $btnCancel.Visible=$false; $btnClose.Visible=$true
    $status.Text= if($cancelled){"Cancelled."}else{"Done."}
    Write-CleanLog ("=== TOTAL FREED {0} ===" -f (Format-Size $freed))
    $cFree=(Get-PSDrive C -EA SilentlyContinue).Free
    $msg = if($cancelled){"Cancelled. Freed about {0} before stopping.`nC: free space is now {1}."}else{"Freed about {0}.`nC: free space is now {1}."}
    [System.Windows.Forms.MessageBox]::Show(($msg -f (Format-Size $freed),(Format-Size $cFree)),"Cleanup complete",'OK','Information')|Out-Null
    $btnClean.Enabled=$true; $btnAll.Enabled=$true; $btnNone.Enabled=$true
    Update-Total
})

Update-Total
[void]$form.ShowDialog()
