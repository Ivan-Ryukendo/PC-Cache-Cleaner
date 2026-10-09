<#
================================================================================
  CleanPC-GUI.ps1  -  Windows 10/11 cache cleaner with a click-to-confirm UI   (v1.2.1)
================================================================================
  Scans the selected drives for regenerable CACHE / TEMP data, then shows a
  checklist where YOU pick exactly what to delete (each row shows its size).
  Nothing is removed until you press "Clean Selected".

  Extras: Check for updates (click only) | Export report (HTML/CSV) | restore point option

  Tabs:  Cleanup | Report only (never deleted) | Other user profiles (opt-in)
         | Security check (read-only report)

  NEVER touches: personal files, browser tabs/sessions/logins/history/bookmarks,
  installed programs, or saved games. Risky items are listed UNTICKED with a
  warning. Junctions/symlinks are never followed.
================================================================================
#>
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$ErrorActionPreference = 'SilentlyContinue'
$script:AppVersion = '1.2.1'

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
$script:ScanCancel = $false

#region CORE ---------------------------------------------------------------
# Shared engine. This block is IDENTICAL in CleanPC-GUI.ps1 and Clean-PC-Cache.ps1
# (the .exe wraps a single script, so it is duplicated on purpose). Keep both in sync.
# Needs from the host script: $script:LogPath and Write-CleanLog.

# C# helper: fast reparse-point-safe sizing / walking / deleting, runs on background threads.
if (-not ('CleanOps' -as [type])) {
Add-Type -ReferencedAssemblies 'System.Core' -Language CSharp -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Text.RegularExpressions;
using System.Threading;

public class CleanFinding {
    public string Kind; public string Root; public string FullPath; public long Size; public bool IsDir; public DateTime Modified;
}

// Last line of defence: refuses to delete anything that is not an obvious cache/temp location.
public static class CleanGuard {
    static readonly HashSet<string> BlockedSegs = new HashSet<string>(new string[] {
        "program files", "program files (x86)", "system volume information", "winsxs", "$recycle.bin",
        "windowsapps", "$winreagent", "recovery", "config.msi", "msocache", "boot", "efi",
        "system32", "syswow64", "installer", "saved games", "my games", ".ssh", ".gnupg", ".aws" });
    static readonly HashSet<string> PersonalLeaf = new HashSet<string>(new string[] {
        "documents", "desktop", "pictures", "downloads", "videos", "music", "onedrive", "appdata", "local",
        "roaming", "locallow", "users", "default", "public", "favorites", "contacts", "links", "searches",
        "3d objects", "windows", "programdata", "user data" });
    static readonly string[] WindowsAllowed = new string[] {
        "windows\\temp", "windows\\softwaredistribution\\download", "windows\\logs\\cbs", "windows\\minidump",
        "windows\\livekernelreports", "windows\\memory.dmp",
        "windows\\serviceprofiles\\networkservice\\appdata\\local\\microsoft\\windows\\deliveryoptimization\\cache" };

    public static bool Check(string path, bool isRoot, out string why) {
        why = "";
        string n;
        try { n = Path.GetFullPath(path).TrimEnd('\\'); } catch (Exception) { why = "bad path"; return false; }
        if (n.Length < 4 || n[1] != ':') { why = "not a local drive path"; return false; }
        string rest = n.Substring(3);
        string lower = rest.ToLowerInvariant();
        string[] segs = lower.Split('\\');
        foreach (string s in segs) { if (BlockedSegs.Contains(s)) { why = "protected folder '" + s + "'"; return false; } }
        if (segs[0] == "windows") {
            bool ok = false;
            foreach (string a in WindowsAllowed) { if (lower == a || lower.StartsWith(a + "\\")) ok = true; }
            if (!ok) { why = "inside Windows folder and not an allow-listed cache"; return false; }
        }
        if (isRoot) {
            string leaf = segs[segs.Length - 1];
            if (PersonalLeaf.Contains(leaf) && !(segs[0] == "windows")) { why = "personal/profile folder '" + leaf + "'"; return false; }
            if (segs.Length == 1 && !(leaf == "temp" || leaf == "tmp" || leaf.StartsWith("found."))) { why = "top-level folder not recognised as temp"; return false; }
            if (segs.Length == 2 && segs[0] == "users") { why = "user profile root"; return false; }
        }
        return true;
    }
}

public static class CleanOps {
    public static bool IsReparse(FileSystemInfo fi) { return (fi.Attributes & FileAttributes.ReparsePoint) != 0; }

    // Size of a folder tree; never follows junctions/symlinks.
    public static long DirSize(string path, CleanWorker w) {
        long sum = 0;
        try {
            if (File.Exists(path)) { return new FileInfo(path).Length; }
            if (!Directory.Exists(path)) return 0;
            if (IsReparse(new DirectoryInfo(path))) return 0;
            Stack<string> st = new Stack<string>();
            st.Push(path);
            while (st.Count > 0) {
                if (w != null && w.Cancel) break;
                string d = st.Pop();
                if (w != null) w.Current = d;
                try {
                    DirectoryInfo di = new DirectoryInfo(d);
                    foreach (FileSystemInfo fi in di.EnumerateFileSystemInfos()) {
                        try {
                            if (IsReparse(fi)) continue;
                            if ((fi.Attributes & FileAttributes.Directory) != 0) st.Push(fi.FullName);
                            else sum += ((FileInfo)fi).Length;
                        } catch (Exception) { }
                    }
                } catch (Exception) { }
            }
        } catch (Exception) { }
        return sum;
    }

    // Deletes the CONTENTS of a folder, keeps the folder. Locked/denied entries are skipped and logged.
    public static long DeleteContents(string root, List<string> skips) {
        string why;
        if (!CleanGuard.Check(root, true, out why)) { skips.Add("BLOCKED " + root + ": " + why); return 0; }
        long freed = 0;
        try {
            DirectoryInfo di = new DirectoryInfo(root);
            if (!di.Exists) return 0;
            if (IsReparse(di)) { skips.Add("SKIP " + root + ": reparse point (not followed)"); return 0; }
            foreach (FileSystemInfo k in di.GetFileSystemInfos()) { freed += DeleteEntry(k, skips); }
        } catch (Exception e) { skips.Add("SKIP " + root + ": " + e.Message); }
        return freed;
    }

    // Deletes one whole folder tree (used for old versioned release folders only).
    public static long DeleteTree(string path, List<string> skips) {
        string why;
        if (!CleanGuard.Check(path, true, out why)) { skips.Add("BLOCKED " + path + ": " + why); return 0; }
        long freed = DeleteContents(path, skips);
        try {
            DirectoryInfo di = new DirectoryInfo(path);
            if (di.Exists && !IsReparse(di)) di.Delete(false);
        } catch (Exception e) { skips.Add("SKIP " + path + ": " + e.Message); }
        return freed;
    }

    public static long DeleteFiles(string[] paths, List<string> skips) {
        long freed = 0;
        foreach (string p in paths) {
            string why;
            if (!CleanGuard.Check(p, false, out why)) { skips.Add("BLOCKED " + p + ": " + why); continue; }
            try {
                FileInfo fi = new FileInfo(p);
                if (!fi.Exists) continue;
                if (IsReparse(fi)) { skips.Add("SKIP " + p + ": reparse point"); continue; }
                long len = fi.Length;
                if ((fi.Attributes & FileAttributes.ReadOnly) != 0) fi.Attributes = FileAttributes.Normal;
                fi.Delete();
                freed += len;
            } catch (Exception e) { skips.Add("SKIP " + p + ": " + e.Message); }
        }
        return freed;
    }

    static long DeleteEntry(FileSystemInfo fi, List<string> skips) {
        long freed = 0;
        try {
            if (IsReparse(fi)) {   // remove the link itself, never follow it
                if ((fi.Attributes & FileAttributes.Directory) != 0) ((DirectoryInfo)fi).Delete(false); else fi.Delete();
                return 0;
            }
            if ((fi.Attributes & FileAttributes.Directory) != 0) {
                DirectoryInfo di = (DirectoryInfo)fi;
                int before = skips.Count;
                foreach (FileSystemInfo k in di.GetFileSystemInfos()) { freed += DeleteEntry(k, skips); }
                try { di.Delete(false); } catch (Exception e) { if (skips.Count == before) skips.Add("SKIP " + fi.FullName + ": " + e.Message); }
            } else {
                FileInfo f = (FileInfo)fi;
                long len = f.Length;
                if ((f.Attributes & FileAttributes.ReadOnly) != 0) f.Attributes = FileAttributes.Normal;
                f.Delete();
                freed += len;
            }
        } catch (Exception e) { skips.Add("SKIP " + fi.FullName + ": " + e.Message); }
        return freed;
    }
}

public class CleanFrame { public string P; public int D; public CleanFrame(string p, int d) { P = p; D = d; } }

// Background worker: sizing, junk-file walk and named-folder sweep. The UI/console just polls Done/Current.
public class CleanWorker {
    public volatile bool Cancel;
    public volatile bool Done;
    public volatile bool TimedOut;
    public volatile string Current = "";
    public int DirsVisited;
    public long[] Sizes;
    public List<CleanFinding> Findings = new List<CleanFinding>();
    public List<string> NamedHits = new List<string>();
    Thread th;

    static readonly HashSet<string> WalkSkip = new HashSet<string>(new string[] {
        "windows", "program files", "program files (x86)", "programdata", "system volume information", "$recycle.bin",
        "recovery", "boot", "efi", "perflogs", "winsxs", "installer", "$winreagent", "config.msi", "msocache", "appdata",
        "$windows.~bt", "$windows.~ws", "windowsapps", ".git", "site-packages", ".venv", "venv", "$sysreset",
        "documents and settings", "steamapps", "steamlibrary", "epic games", "gog galaxy", "riot games", "xboxgames",
        "saved games", "my games", "onedrive" });
    static readonly HashSet<string> SweepSkip = new HashSet<string>(new string[] {
        "node_modules", "site-packages", ".git", "temp", "vm_bundles" });
    static readonly Regex FoundRx = new Regex(@"^found\.\d{3}$", RegexOptions.IgnoreCase);
    public long BigDiskBytes = 1073741824L;

    void Launch(ThreadStart body) {
        Done = false;
        th = new Thread(delegate() { try { body(); } catch (Exception) { } Done = true; });
        th.IsBackground = true;
        th.Start();
    }

    public void StartSizing(List<string[]> groups) {
        Sizes = new long[groups.Count];
        Launch(delegate() {
            for (int i = 0; i < groups.Count; i++) {
                long s = 0;
                foreach (string p in groups[i]) { Current = p; s += CleanOps.DirSize(p, null); }
                Sizes[i] = s;
            }
        });
    }

    public void StartWalk(string[] roots, int maxDepth, int secondsPerRoot, int minAgeDays) {
        Launch(delegate() {
            foreach (string r in roots) {
                if (Cancel) break;
                WalkRoot(r, maxDepth, DateTime.UtcNow.AddSeconds(secondsPerRoot), minAgeDays);
            }
        });
    }

    public void StartSweep(string[] roots, string[] names, int maxDepth) {
        HashSet<string> nm = new HashSet<string>();
        foreach (string n in names) nm.Add(n.ToLowerInvariant());
        Launch(delegate() {
            foreach (string r in roots) { if (Cancel) break; SweepRoot(r, nm, maxDepth); }
        });
    }

    void AddFinding(string kind, string root, FileSystemInfo fi, bool isDir, long size) {
        if (Findings.Count > 30000) return;
        CleanFinding f = new CleanFinding();
        f.Kind = kind; f.Root = root; f.FullPath = fi.FullName; f.IsDir = isDir; f.Size = size; f.Modified = fi.LastWriteTimeUtc;
        Findings.Add(f);
    }

    static bool IsDiskExt(string ext) { return ext == ".vhdx" || ext == ".vhd" || ext == ".vmdk" || ext == ".vdi"; }

    void WalkRoot(string root, int maxDepth, DateTime deadline, int minAgeDays) {
        Stack<CleanFrame> st = new Stack<CleanFrame>();
        st.Push(new CleanFrame(root, 0));
        DateTime ageCut = DateTime.UtcNow.AddDays(-minAgeDays);
        DateTime oldCut = DateTime.UtcNow.AddDays(-30);
        while (st.Count > 0) {
            if (Cancel) return;
            if (DateTime.UtcNow > deadline) { TimedOut = true; return; }
            CleanFrame f = st.Pop();
            Current = f.P; DirsVisited++;
            IEnumerable<FileSystemInfo> en;
            try { en = new DirectoryInfo(f.P).EnumerateFileSystemInfos(); } catch (Exception) { continue; }
            try {
                foreach (FileSystemInfo fi in en) {
                    try {
                        if (CleanOps.IsReparse(fi)) continue;
                        string name = fi.Name; string ln = name.ToLowerInvariant();
                        if ((fi.Attributes & FileAttributes.Directory) != 0) {
                            if (WalkSkip.Contains(ln)) continue;
                            if (ln == "__pycache__") { AddFinding("PyCache", root, fi, true, CleanOps.DirSize(fi.FullName, null)); continue; }
                            if (ln == ".pytest_cache" || ln == ".mypy_cache" || ln == ".ruff_cache") { AddFinding("ToolCache", root, fi, true, CleanOps.DirSize(fi.FullName, null)); continue; }
                            if (ln == "node_modules") {
                                string nc = Path.Combine(fi.FullName, ".cache");
                                DirectoryInfo nd = new DirectoryInfo(nc);
                                if (nd.Exists && !CleanOps.IsReparse(nd)) AddFinding("NodeCache", root, nd, true, CleanOps.DirSize(nc, null));
                                continue;
                            }
                            if (f.D == 0 && FoundRx.IsMatch(name)) { AddFinding("ChkFolder", root, fi, true, CleanOps.DirSize(fi.FullName, null)); continue; }
                            if (f.D + 1 <= maxDepth) st.Push(new CleanFrame(fi.FullName, f.D + 1));
                        } else {
                            FileInfo file = (FileInfo)fi;
                            string ext = file.Extension.ToLowerInvariant();
                            DateTime wt = file.LastWriteTimeUtc;
                            if (ln == "thumbs.db") AddFinding("Thumbs", root, fi, false, file.Length);
                            else if (ext == ".gid") AddFinding("Gid", root, fi, false, file.Length);
                            else if (ext == ".tmp" || ext == ".temp" || ln.StartsWith("~$")) { if (wt < ageCut) AddFinding("TmpFiles", root, fi, false, file.Length); }
                            else if (ext == ".chk") { if (wt < oldCut) AddFinding("ChkFile", root, fi, false, file.Length); }
                            else if (ext == ".old") { if (wt < oldCut) AddFinding("OldFiles", root, fi, false, file.Length); }
                            else if (ext == ".dmp") { if (wt < ageCut) AddFinding("DumpFiles", root, fi, false, file.Length); }
                            else if (IsDiskExt(ext) && file.Length >= BigDiskBytes) AddFinding("BigDisk", root, fi, false, file.Length);
                        }
                    } catch (Exception) { }
                }
            } catch (Exception) { }
        }
    }

    void SweepRoot(string root, HashSet<string> names, int maxDepth) {
        Stack<CleanFrame> st = new Stack<CleanFrame>();
        st.Push(new CleanFrame(root, 0));
        while (st.Count > 0) {
            if (Cancel) return;
            CleanFrame f = st.Pop();
            Current = f.P; DirsVisited++;
            IEnumerable<FileSystemInfo> en;
            try { en = new DirectoryInfo(f.P).EnumerateFileSystemInfos(); } catch (Exception) { continue; }
            try {
                foreach (FileSystemInfo fi in en) {
                    try {
                        if (CleanOps.IsReparse(fi)) continue;
                        string ln = fi.Name.ToLowerInvariant();
                        if ((fi.Attributes & FileAttributes.Directory) != 0) {
                            if (names.Contains(ln)) { NamedHits.Add(fi.FullName); continue; }
                            if (SweepSkip.Contains(ln)) continue;
                            if (f.D + 1 <= maxDepth) st.Push(new CleanFrame(fi.FullName, f.D + 1));
                        } else {
                            FileInfo file = (FileInfo)fi;
                            if (IsDiskExt(file.Extension.ToLowerInvariant()) && file.Length >= BigDiskBytes) AddFinding("BigDisk", root, fi, false, file.Length);
                        }
                    } catch (Exception) { }
                }
            } catch (Exception) { }
        }
    }
}
'@
}

# ---------------------------------------------------------------- helpers
function Format-Size([int64]$b){
    if($b -ge 1TB){ return ('{0:N2} TB' -f ($b/1TB)) }
    if($b -ge 1GB){ return ('{0:N2} GB' -f ($b/1GB)) }
    if($b -ge 1MB){ return ('{0:N1} MB' -f ($b/1MB)) }
    if($b -ge 1KB){ return ('{0:N0} KB' -f ($b/1KB)) }
    return "$b B"
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
        '^Packages\\([^\\]+)'   { return "$($Matches[1]) (cache)" }
        default                 { return "$p0 (cache)" }
    }
}

# Fixed local disks only (DriveType 3): removable, network and optical drives are excluded.
function Get-FixedDrives{
    $r=@()
    try{
        foreach($d in @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -EA Stop)){
            if($d.Size -ge 1GB -and $d.VolumeName -ne 'System Reserved'){ $r += [PSCustomObject]@{ Letter=$d.DeviceID.ToUpper(); Label=[string]$d.VolumeName; Size=[int64]$d.Size; Free=[int64]$d.FreeSpace } }
        }
    }catch{
        foreach($d in [System.IO.DriveInfo]::GetDrives()){ if($d.DriveType -eq 'Fixed' -and $d.IsReady){ $r += [PSCustomObject]@{ Letter=($d.Name.Substring(0,2)).ToUpper(); Label=$d.VolumeLabel; Size=$d.TotalSize; Free=$d.AvailableFreeSpace } } }
    }
    return $r
}
# Accepts 'c', 'C:', 'C:\' ... and keeps only real fixed drives.
function Resolve-Drives([string[]]$want,[switch]$All){
    $fixed=@(Get-FixedDrives)
    if($All){ return @($fixed | ForEach-Object { $_.Letter }) }
    $out=@()
    foreach($w in @($want)){
        if(-not $w){ continue }
        $l=($w.Trim().Substring(0,1)).ToUpper()+':'
        if(($fixed | Where-Object { $_.Letter -eq $l }) -and ($out -notcontains $l)){ $out += $l }
    }
    return @($out)
}

# Waits for a background worker while keeping the host responsive. $Progress may pump UI events.
function Wait-Worker($w,[scriptblock]$Progress,[string]$label){
    while(-not $w.Done){
        if($script:ScanCancel){ $w.Cancel=$true }
        $cur=[string]$w.Current
        if($cur.Length -gt 70){ $cur=$cur.Substring(0,30)+'...'+$cur.Substring($cur.Length-37) }
        & $Progress ("{0} {1}" -f $label,$cur)
        Start-Sleep -Milliseconds 100
    }
}

function Get-VdiskHowTo([string]$p){
    if($p -match 'WindowsSubsystemForAndroid'){ return 'Windows Subsystem for Android (discontinued): Settings > Apps > Installed apps > Windows Subsystem for Android > Uninstall (removes its userdata disks).' }
    if($p -match '\\Containers\\'){ return 'Windows Defender Application Guard / Sandbox container image: turn the feature off in "Turn Windows features on or off" (or Disable-WindowsOptionalFeature -Online -FeatureName Windows-Defender-ApplicationGuard in admin PowerShell).' }
    if($p -match 'ext4\.vhdx$'){ return 'WSL/Docker disk: run "wsl --list --verbose"; "wsl --unregister <distro>" DELETES that distro and its files; or shrink it instead with "wsl --manage <distro> --set-sparse true". Docker Desktop: Troubleshoot > Clean / Purge data.' }
    if($p -match '\.(vmdk|vdi)$'){ return 'Virtual machine disk: remove the VM in VirtualBox/VMware and choose to delete its files. Do not delete it by hand if the VM is still needed.' }
    return 'Virtual disk: remove it only through the app/feature that owns it (Hyper-V Manager, Settings > Apps) after confirming it is unused.'
}

# ---------------------------------------------------------------- scan model
# Returns @{ Targets = deletable rows ; Report = informational rows (never deletable) }.
# Row fields: Name, Category, Size, Paths, Kind (Contents|Files|RemoveDirs|RecycleBin|Report),
#             Checked, Note, Drive, Service
function Build-Targets([string[]]$Drives,[scriptblock]$Progress){
    if(-not $Progress){ $Progress = { param($m) } }
    $Drives=@($Drives)
    $L=$env:LOCALAPPDATA; $R=$env:APPDATA; $U=$env:USERPROFILE; $PD=$env:ProgramData
    $sys=$env:SystemDrive.ToUpper(); $WIN=$env:SystemRoot
    $doSys=($Drives -contains $sys)
    $admin = Is-Admin
    $S = New-Object System.Collections.Generic.List[object]
    $Rep = New-Object System.Collections.Generic.List[object]
    $explicit = New-Object System.Collections.Generic.List[string]

    function Add-S($name,$cat,$paths,$kind,$checked,$note,$drive,$service){
        $ex=@(); foreach($p in @($paths)){ if($p -and ($ex -notcontains $p) -and (Test-Path -LiteralPath $p)){ $ex += $p; $explicit.Add($p.TrimEnd('\')) } }
        if($ex.Count -eq 0){ return }
        $S.Add([PSCustomObject]@{ Name=$name; Category=$cat; Size=[int64]-1; Paths=$ex; Kind=$kind; Checked=$checked; Note=$note; Drive=$drive; Service=$service })
    }
    function Add-Pre($name,$cat,$paths,$kind,$checked,$note,$drive,[int64]$size){
        if($size -le 0 -or @($paths).Count -eq 0){ return }
        $S.Add([PSCustomObject]@{ Name=$name; Category=$cat; Size=$size; Paths=@($paths); Kind=$kind; Checked=$checked; Note=$note; Drive=$drive; Service=$null })
    }
    function Add-Rep($name,$paths,$note,[int64]$size){
        $Rep.Add([PSCustomObject]@{ Name=$name; Category='Report'; Size=$size; Paths=@($paths); Kind='Report'; Checked=$false; Note=$note; Drive=''; Service=$null })
    }

    # 1) start the background junk walk over the selected drives right away
    $walkers=@(); $wSweep=$null
    if($Drives.Count -gt 0){
        & $Progress 'Starting drive scan...'
        foreach($dv in $Drives){   # one background thread per drive, all in parallel
            $ww = New-Object CleanWorker
            $ww.StartWalk([string[]]@($dv + '\'), 8, 90, 7)
            $walkers += $ww
        }
    }
    # 2) sweep the user's AppData for browser/app caches (and big virtual disks) in the background
    if($doSys){
        $wSweep = New-Object CleanWorker
        $roots=@($L,$R,"$PD\Microsoft\Windows\Containers") | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
        $wSweep.StartSweep([string[]]@($roots), [string[]]@('Cache','Cache_Data','Code Cache','GPUCache','CachedData','DawnGraphiteCache','DawnWebGPUCache','DawnCache','GrShaderCache','ShaderCache'), 6)
    }

    # 3) explicit, known locations (cheap existence checks only; sizes are measured later in the background)
    if($doSys){
        Add-S 'User Temp files'              'Temp'  @("$env:TEMP","$L\Temp")                         'Contents' $true  '' $sys
        Add-S 'Application crash dumps'      'Temp'  @("$L\CrashDumps")                                'Contents' $true  '' $sys
        Add-S 'Windows Error Reporting (user)' 'Temp' @("$L\Microsoft\Windows\WER")                    'Contents' $true  '' $sys
        Add-S 'Internet/WinINet cache'       'Temp'  @("$L\Microsoft\Windows\INetCache")               'Contents' $true  '' $sys
        if($admin){
            Add-S 'Windows Temp (system)'    'Temp'  @("$WIN\Temp")                                    'Contents' $true  'admin' $sys
            Add-S 'Windows Update download cache' 'Windows' @("$WIN\SoftwareDistribution\Download")    'Contents' $true  'admin; update service is paused briefly' $sys 'wuauserv'
            Add-S 'Delivery Optimization cache' 'Windows' @("$WIN\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache") 'Contents' $true 'admin; re-downloaded if needed' $sys
            Add-S 'Windows Error Reporting (system)' 'Temp' @("$PD\Microsoft\Windows\WER\ReportArchive","$PD\Microsoft\Windows\WER\ReportQueue","$PD\Microsoft\Windows\WER\Temp") 'Contents' $true 'admin' $sys
            Add-S 'Kernel crash dumps (Minidump, LiveKernelReports)' 'Windows' @("$WIN\Minidump","$WIN\LiveKernelReports") 'Contents' $false 'RISKY: blue-screen diagnostics - keep if you are troubleshooting crashes' $sys
            if(Test-Path -LiteralPath "$WIN\MEMORY.DMP"){ $mf=Get-Item -LiteralPath "$WIN\MEMORY.DMP" -Force -EA SilentlyContinue; if($mf){ Add-Pre 'Full memory dump (MEMORY.DMP)' 'Windows' @("$WIN\MEMORY.DMP") 'Files' $false 'RISKY: blue-screen diagnostics - keep if you are troubleshooting crashes' $sys ([int64]$mf.Length) } }
            $cbs=@(Get-ChildItem -LiteralPath "$WIN\Logs\CBS" -File -Force -EA SilentlyContinue | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-14) -and $_.Extension -match '^\.(log|cab)$' })
            if($cbs.Count -gt 0){ Add-Pre 'Old Windows servicing logs (Logs\CBS, 14+ days)' 'Windows' @($cbs | ForEach-Object { $_.FullName }) 'Files' $true 'admin; only files older than 14 days' $sys ([int64]($cbs | Measure-Object Length -Sum).Sum) }
        }
        Add-S 'NVIDIA shader cache'          'GPU'   @("$L\NVIDIA\DXCache","$L\NVIDIA\GLCache","$PD\NVIDIA Corporation\NV_Cache") 'Contents' $true '' $sys
        Add-S 'NVIDIA App update installers (ota-artifacts)' 'GPU' @("$PD\NVIDIA Corporation\NVIDIA App\UpdateFramework\ota-artifacts") 'Contents' $true 'downloaded installers; re-downloaded on next update' $sys
        Add-S 'AMD shader cache'             'GPU'   @("$L\AMD\DxCache","$L\AMD\GLCache","$L\AMD\VkCache") 'Contents' $true '' $sys
        Add-S 'Intel shader cache'           'GPU'   @("$L\Intel\ShaderCache")                         'Contents' $true  '' $sys
        Add-S 'DirectX shader cache'         'GPU'   @("$L\D3DSCache")                                  'Contents' $true  '' $sys
        # Teams (new) keeps its WebView cache deeper than the generic sweep reaches
        $tp=@(); foreach($pk in @(Get-ChildItem -LiteralPath "$L\Packages" -Directory -Filter 'MSTeams*' -EA SilentlyContinue)){ foreach($cn in 'Cache','Code Cache','GPUCache'){ foreach($c in @(Get-ChildItem -LiteralPath "$($pk.FullName)\LocalCache\Microsoft\MSTeams\EBWebView" -Directory -Recurse -Depth 2 -Filter $cn -EA SilentlyContinue)){ $tp += $c.FullName } } }
        if($tp.Count -gt 0){ Add-S 'Microsoft Teams (cache)' 'Browser/App' $tp 'Contents' $true 'cache folders only' $sys }
        # Firefox cache2
        $ff=@(); foreach($pf in @(Get-ChildItem -LiteralPath "$L\Mozilla\Firefox\Profiles" -Directory -EA SilentlyContinue)){ $c=Join-Path $pf.FullName 'cache2'; if(Test-Path -LiteralPath $c){ $ff += $c } }
        if($ff.Count -gt 0){ Add-S 'Firefox (cache)' 'Browser/App' $ff 'Contents' $true '' $sys }
        # Thumbnail / icon cache
        $th=@(Get-ChildItem -LiteralPath "$L\Microsoft\Windows\Explorer" -File -Force -EA SilentlyContinue | Where-Object { $_.Name -match '^(thumb|icon)cache_.*\.db$' })
        if($th.Count -gt 0){ Add-Pre 'Thumbnail / icon cache' 'Windows' @($th | ForEach-Object { $_.FullName }) 'Files' $true 'rebuilds automatically' $sys ([int64]($th | Measure-Object Length -Sum).Sum) }
        # Dev / package caches
        $uvc=@("$L\uv\cache"); if($env:UV_CACHE_DIR){ $uvc += $env:UV_CACHE_DIR }
        Add-S 'pip cache (Python)'           'Dev'   @("$L\pip\Cache","$L\pip\cache")                  'Contents' $true  '' $sys
        Add-S 'uv cache (Python)'            'Dev'   $uvc                                               'Contents' $true  '' $sys
        Add-S 'npm cache (Node)'             'Dev'   @("$L\npm-cache","$R\npm-cache")                  'Contents' $true  '' $sys
        Add-S 'Yarn cache (Node)'            'Dev'   @("$L\Yarn\Cache")                                 'Contents' $true  '' $sys
        Add-S 'Go build cache'               'Dev'   @("$L\go-build")                                   'Contents' $true  '' $sys
        Add-S 'NuGet http cache (.NET)'      'Dev'   @("$L\NuGet\v3-cache")                             'Contents' $true  '' $sys
        $sc=@("$U\scoop\cache"); if($env:SCOOP){ $sc += "$($env:SCOOP)\cache" }
        Add-S 'Scoop download cache'         'Dev'   $sc                                                'Contents' $true  'installer downloads; re-downloaded if needed' $sys
        Add-S 'Arduino staging (downloads)'  'Dev'   @("$L\Arduino15\staging")                          'Contents' $true  'downloaded packages; re-downloaded if needed' $sys
        Add-S 'User .cache (tool caches)'    'Dev'   @("$U\.cache")                                     'Contents' $true  '' $sys
        Add-S 'Gradle dependency cache'      'Dev'   @("$U\.gradle\caches")                             'Contents' $false 'large re-download on next build' $sys
        Add-S 'Playwright browsers'          'Dev'   @("$L\ms-playwright")                              'Contents' $false 'RISKY: tests need these; re-download is several hundred MB' $sys
        # Codex: old versioned release folders. Keeps the newest, the highest version AND whatever 'current' points to.
        foreach($rel in @(Get-ChildItem -LiteralPath "$U\.codex\packages" -Directory -EA SilentlyContinue | ForEach-Object { Join-Path $_.FullName 'releases' } | Where-Object { Test-Path -LiteralPath $_ })){
            $vers=@(Get-ChildItem -LiteralPath $rel -Directory -EA SilentlyContinue | Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) })
            if($vers.Count -lt 2){ continue }
            $keep=@{}
            $keep[($vers | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName]=1
            $hv=$vers | Sort-Object { try{ [version](($_.Name -split '-')[0]) }catch{ [version]'0.0' } } -Descending | Select-Object -First 1
            $keep[$hv.FullName]=1
            try{ $cur=Get-Item -LiteralPath (Join-Path (Split-Path $rel -Parent) 'current') -Force -EA Stop; foreach($tg in @($cur.Target)){ if($tg){ $keep[(Join-Path $rel (Split-Path $tg -Leaf))]=1 } } }catch{}
            $old=@($vers | Where-Object { -not $keep.ContainsKey($_.FullName) } | ForEach-Object { $_.FullName })
            if($old.Count -gt 0){
                $pkg=Split-Path (Split-Path $rel -Parent) -Leaf
                Add-S "Codex old releases ($pkg)" 'Dev' $old 'RemoveDirs' $false ("RISKY: removes whole old version folders; keeps: " + (($keep.Keys | ForEach-Object { Split-Path $_ -Leaf }) -join ', ')) $sys
            }
        }
        # Optional / heavy
        Add-S 'Claude Desktop VM cache'      'Optional' @("$R\Claude\vm_bundles")                       'Contents' $false 'Close Claude Desktop first to free it fully' $sys
        # fnm node versions: LIST ONLY, never deleted by this tool
        $nvSeen=@{}
        foreach($nv in @("$R\fnm\node-versions", $(if($env:FNM_DIR){ "$($env:FNM_DIR)\node-versions" }))){
            if(-not $nv -or $nvSeen.ContainsKey($nv.ToLower())){ continue }; $nvSeen[$nv.ToLower()]=1
            if($nv -and (Test-Path -LiteralPath $nv)){
                foreach($v in @(Get-ChildItem -LiteralPath $nv -Directory -EA SilentlyContinue | Where-Object { $_.Name -notlike '.*' })){
                    $S.Add([PSCustomObject]@{ Name="Node.js $($v.Name) (fnm)"; Category='Report'; Size=[int64]-1; Paths=@($v.FullName); Kind='Report'; Checked=$false; Note="Installed Node version - report only. If unused, remove with: fnm uninstall $($v.Name)"; Drive=$sys; Service=$null })
                }
            }
        }
    }

    foreach($d in $Drives){
        Add-S "Recycle Bin [$d]" 'Optional' @($d + '\$Recycle.Bin') 'RecycleBin' $false 'Permanently empties the Recycle Bin of this drive' $d
        Add-S "Root \Temp folder [$d]" 'Drive junk' @("$d\Temp") 'Contents' $false 'Check what is in it first' $d
        Add-S "Root \tmp folder [$d]"  'Drive junk' @("$d\tmp")  'Contents' $false 'Check what is in it first' $d
        if($d -ne $sys -and (Test-Path -LiteralPath "$d\Windows\System32")){
            Add-S "Windows Temp of other install [$d]" 'Drive junk' @("$d\Windows\Temp") 'Contents' $true 'another Windows installation on this drive' $d
        }
        if(Test-Path -LiteralPath "$d\Users"){
            foreach($ud in @(Get-ChildItem -LiteralPath "$d\Users" -Directory -Force -EA SilentlyContinue | Where-Object { $_.Name -notin @('Public','Default','Default User','All Users') -and -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) })){
                if($ud.FullName.TrimEnd('\') -ieq $U.TrimEnd('\')){ continue }
                Add-S "Temp of user '$($ud.Name)' [$d]" 'Other users' @("$($ud.FullName)\AppData\Local\Temp") 'Contents' $true 'another profile; locked files are skipped' $d
            }
        }
    }

    # 4) collect the AppData sweep and group it by application
    if($wSweep){
        Wait-Worker $wSweep $Progress 'Looking for app caches:'
        $groups=@{}
        foreach($hit in $wSweep.NamedHits){
            $h=$hit.TrimEnd('\')
            $dup=$false; foreach($e in $explicit){ if($h -ieq $e -or $h.StartsWith($e+'\',[StringComparison]::OrdinalIgnoreCase)){ $dup=$true; break } }
            if($dup){ continue }
            $key = Friendly-App $hit $L $R
            if(-not $groups.ContainsKey($key)){ $groups[$key]=New-Object System.Collections.Generic.List[string] }
            $groups[$key].Add($hit)
        }
        foreach($k in $groups.Keys){ Add-S $k 'Browser/App' ($groups[$k].ToArray()) 'Contents' $true '' $sys }
    }

    # 5) measure everything in the background
    $sizeIdx=@(); $groupsL = New-Object 'System.Collections.Generic.List[string[]]'
    for($i=0;$i -lt $S.Count;$i++){ if($S[$i].Size -lt 0){ $sizeIdx += $i; $groupsL.Add([string[]]@($S[$i].Paths)) } }
    if($groupsL.Count -gt 0){
        $wSize = New-Object CleanWorker
        $wSize.StartSizing($groupsL)
        Wait-Worker $wSize $Progress 'Measuring:'
        for($j=0;$j -lt $sizeIdx.Count;$j++){ $S[$sizeIdx[$j]].Size = [int64]$wSize.Sizes[$j] }
    }

    # 6) junk-file findings from the drive walk and the AppData sweep
    while(@($walkers | Where-Object { -not $_.Done }).Count -gt 0){
        if($script:ScanCancel){ foreach($ww in $walkers){ $ww.Cancel=$true } }
        $act=@($walkers | Where-Object { -not $_.Done })
        $cur=[string]$act[0].Current; if($cur.Length -gt 70){ $cur=$cur.Substring(0,30)+'...'+$cur.Substring($cur.Length-37) }
        & $Progress ("Scanning drives ({0} running): {1}" -f $act.Count,$cur)
        Start-Sleep -Milliseconds 100
    }
    $finds = New-Object System.Collections.Generic.List[object]
    foreach($ww in $walkers){ foreach($f in $ww.Findings){ $finds.Add($f) } }
    if($wSweep){ foreach($f in $wSweep.Findings){ $finds.Add($f) } }
    $defs = @{
        PyCache   = @('Python __pycache__ folders',            'Contents', $true,  'compiled Python bytecode; regenerated automatically')
        ToolCache = @('Python tool caches (.pytest/.mypy/.ruff)','Contents', $true,  'regenerated automatically')
        NodeCache = @('node_modules\.cache folders',           'Contents', $true,  'build-tool caches; regenerated')
        Thumbs    = @('Thumbs.db files',                       'Files',    $true,  'old Explorer thumbnail files')
        Gid       = @('*.gid files (old Help cache)',          'Files',    $true,  'obsolete Windows Help cache files')
        TmpFiles  = @('Old *.tmp / *.temp / ~$* files',        'Files',    $false, 'RISKY: 7+ days old, but apps may still use some - review the list (double-click)')
        ChkFile   = @('*.chk files (CHKDSK fragments)',        'Files',    $false, 'RISKY: may be fragments of recoverable files; 30+ days old')
        ChkFolder = @('found.NNN folders (CHKDSK)',            'Contents', $false, 'RISKY: may hold recoverable file fragments - check first')
        OldFiles  = @('*.old files (30+ days)',                'Files',    $false, 'RISKY: can be backups made by installers or you - review the list')
        DumpFiles = @('*.dmp crash dumps (7+ days)',           'Files',    $false, 'RISKY: you may want them for debugging - review the list')
    }
    $seenDisk=@{}
    foreach($grp in ($finds | Group-Object Kind, Root)){
        $kind=$grp.Group[0].Kind; $root=$grp.Group[0].Root.Substring(0,2).ToUpper()
        $items=@($grp.Group)
        if($kind -ne 'BigDisk'){
            $items=@($items | Where-Object { $fp=$_.FullPath.TrimEnd('\'); $dupe=$false; foreach($e in $explicit){ if($fp -ieq $e -or $fp.StartsWith($e+'\',[StringComparison]::OrdinalIgnoreCase)){ $dupe=$true; break } }; -not $dupe })
            if($items.Count -eq 0){ continue }
        }
        $paths=@($items | ForEach-Object { $_.FullPath } | Select-Object -Unique)
        $size=[int64]($items | Measure-Object Size -Sum).Sum
        if($kind -eq 'BigDisk'){
            foreach($g in $items){
                if($seenDisk.ContainsKey($g.FullPath)){ continue }; $seenDisk[$g.FullPath]=1
                Add-Rep ("Virtual disk: " + (Split-Path $g.FullPath -Leaf)) @($g.FullPath) ("REPORT ONLY - this tool never deletes it. " + (Get-VdiskHowTo $g.FullPath)) ([int64]$g.Size)
            }
            continue
        }
        if(-not $defs.ContainsKey($kind)){ continue }
        # drop paths already covered by an explicit row
        $dd=$defs[$kind]
        Add-Pre ("{0} [{1}]" -f $dd[0],$root) 'Drive junk' $paths $dd[1] $dd[2] $dd[3] $root $size
    }

    # 7) split into deletable vs report-only
    $targets = New-Object System.Collections.Generic.List[object]
    foreach($t in $S){
        if($t.Kind -eq 'Report'){ if($t.Size -ge 0){ $Rep.Add($t) }; continue }
        if($t.Size -gt 0){ $targets.Add($t) }
    }
    # shadow copies / System Restore usage (information only)
    if($admin){
        & $Progress 'Reading shadow copy storage...'
        try{
            $vs = & vssadmin.exe list shadowstorage 2>$null
            $cur=$null
            foreach($line in @($vs)){
                if($line -match 'For volume:\s*\((\w:)\)'){ $cur=$Matches[1].ToUpper() }
                elseif($cur -and ($line -match 'Used') -and ($line -match ':\s*([\d\.,]+)\s*(KB|MB|GB|TB)\b')){
                    $num=[double](($Matches[1] -replace ',','.')); $mult=@{KB=1KB;MB=1MB;GB=1GB;TB=1TB}[$Matches[2]]
                    if($Drives -contains $cur){ Add-Rep "Shadow copies / System Restore ($cur)" @() 'REPORT ONLY - manage in System Properties > System Protection > Configure (Delete removes ALL restore points), or "vssadmin delete shadows /for=C: /oldest".' ([int64]($num*$mult)) }
                    $cur=$null
                }
            }
        }catch{}
    }
    # unregistered profile folders (report only)
    foreach($d in $Drives){
        $reg=@(Get-CimInstance Win32_UserProfile -EA SilentlyContinue | Where-Object { $_.LocalPath } | ForEach-Object { $_.LocalPath.TrimEnd('\').ToLower() })
        foreach($ud in @(Get-ChildItem -LiteralPath "$d\Users" -Directory -Force -EA SilentlyContinue | Where-Object { $_.Name -notin @('Public','Default','Default User','All Users') -and -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) })){
            if($reg -notcontains $ud.FullName.TrimEnd('\').ToLower()){
                Add-Rep "Unregistered profile folder [$d]: $($ud.Name)" @($ud.FullName) 'REPORT ONLY - a Users folder with no Windows profile (left over from a removed account). Review it in Explorer and delete it yourself if you are sure.' 0
            }
        }
    }
    $needSz=@($Rep | Where-Object { $_.Name -like 'Unregistered profile*' -and $_.Size -le 0 })
    if($needSz.Count -gt 0){
        $gl = New-Object 'System.Collections.Generic.List[string[]]'; foreach($n in $needSz){ $gl.Add([string[]]@($n.Paths)) }
        $wr = New-Object CleanWorker; $wr.StartSizing($gl); Wait-Worker $wr $Progress 'Measuring:'
        for($j=0;$j -lt $needSz.Count;$j++){ $needSz[$j].Size=[int64]$wr.Sizes[$j] }
    }
    $info = [PSCustomObject]@{ WalkTimedOut = [bool](@($walkers | Where-Object { $_.TimedOut }).Count -gt 0); WalkCancelled = [bool]$script:ScanCancel; DirsVisited = [int](($walkers | Measure-Object DirsVisited -Sum).Sum) }
    return @{ Targets=$targets.ToArray(); Report=$Rep.ToArray(); Info=$info }
}

# ---------------------------------------------------------------- deletion
# Returns bytes freed. Reparse points are never followed; locked files are skipped and logged.
function Invoke-Clean($t){
    $skips = New-Object 'System.Collections.Generic.List[string]'
    $freed=[int64]0; $stopped=$false
    try{
        if($t.Kind -eq 'Report'){ Write-CleanLog "REFUSED report-only item: $($t.Name)"; return [int64]0 }
        if($t.Service){
            $svc = Get-Service -Name $t.Service -EA SilentlyContinue
            if($svc -and $svc.Status -eq 'Running'){ Stop-Service -Name $t.Service -Force -EA SilentlyContinue; $stopped=$true }
        }
        switch($t.Kind){
            'RecycleBin' {
                try{ Clear-RecycleBin -DriveLetter $t.Drive.Substring(0,1) -Force -EA Stop; $freed=[int64]$t.Size }catch{ Write-CleanLog "SKIP Recycle Bin $($t.Drive): $($_.Exception.Message)" }
            }
            'Files'      { $freed = [CleanOps]::DeleteFiles([string[]]@($t.Paths), $skips) }
            'RemoveDirs' { foreach($p in $t.Paths){ $freed += [CleanOps]::DeleteTree($p, $skips) } }
            default      { foreach($p in $t.Paths){ $freed += [CleanOps]::DeleteContents($p, $skips) } }
        }
    } finally {
        if($stopped){ Start-Service -Name $t.Service -EA SilentlyContinue }
    }
    foreach($s in $skips){ Write-CleanLog $s }
    return [int64]$freed
}

# ---------------------------------------------------------------- other user profiles (opt-in, never auto-selected)
# Lists ONLY registered profiles that are: not the current user, not loaded/logged on, not special/system,
# not Default/Public/built-in Administrator. Deleted (after typed confirmation) via Win32_UserProfile.
function Test-ProfileRemovable($p){
    try{
        if(-not $p -or -not $p.LocalPath){ return $false }
        if($p.Special -or $p.Loaded){ return $false }
        $me=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        if($p.SID -eq $me){ return $false }
        if($p.SID -notmatch '^S-1-5-21-'){ return $false }          # only real local/domain accounts
        if($p.SID -match '-500$'){ return $false }                  # built-in Administrator
        $lp=$p.LocalPath.TrimEnd('\')
        if($lp -ieq $env:USERPROFILE.TrimEnd('\')){ return $false }
        if($lp -like "$env:SystemRoot\*"){ return $false }
        $leaf=Split-Path $lp -Leaf
        if($leaf -in @('Default','Default User','Public','All Users','systemprofile','LocalService','NetworkService')){ return $false }
        return $true
    }catch{ return $false }
}
function Get-OtherProfiles([string[]]$Drives,[scriptblock]$Progress){
    if(-not $Progress){ $Progress = { param($m) } }
    $res=@()
    foreach($p in @(Get-CimInstance Win32_UserProfile -EA SilentlyContinue)){
        if(-not (Test-ProfileRemovable $p)){ continue }
        $drv=$p.LocalPath.Substring(0,2).ToUpper()
        if(@($Drives) -notcontains $drv){ continue }
        $res += [PSCustomObject]@{ Sid=$p.SID; Name=(Split-Path $p.LocalPath -Leaf); Path=$p.LocalPath; Drive=$drv; Size=[int64]-1; LastUse=$p.LastUseTime }
    }
    if($res.Count -gt 0){
        $gl = New-Object 'System.Collections.Generic.List[string[]]'; foreach($r in $res){ $gl.Add([string[]]@($r.Path)) }
        $w = New-Object CleanWorker; $w.StartSizing($gl); Wait-Worker $w $Progress 'Measuring profiles:'
        for($i=0;$i -lt $res.Count;$i++){ $res[$i].Size=[int64]$w.Sizes[$i] }
    }
    return $res
}
# Deletes one profile with the proper Windows API (removes folder AND registry entry). Re-validates first.
function Remove-OtherProfile($prof){
    try{
        $p = Get-CimInstance Win32_UserProfile -Filter ("SID='{0}'" -f $prof.Sid) -EA Stop
        if(-not (Test-ProfileRemovable $p)){ Write-CleanLog "REFUSED profile (not removable now): $($prof.Path)"; return $false }
        Write-CleanLog "DELETE PROFILE (user confirmed by typing name): $($p.LocalPath) sid=$($p.SID)"
        Remove-CimInstance -InputObject $p -EA Stop
        Write-CleanLog "PROFILE DELETED: $($prof.Path)"
        return $true
    }catch{ Write-CleanLog "PROFILE DELETE FAILED $($prof.Path): $($_.Exception.Message)"; return $false }
}

# ---------------------------------------------------------------- security check (READ-ONLY)
# Heuristics only. Never kills, deletes or modifies anything. Output means "suspicious, review".
function Get-EditDistance([string]$a,[string]$b){
    $n=$a.Length; $m=$b.Length
    if($n -eq 0){ return $m }; if($m -eq 0){ return $n }
    $d = New-Object 'int[,]' ($n+1),($m+1)
    for($i=0;$i -le $n;$i++){ $d[$i,0]=$i }; for($j=0;$j -le $m;$j++){ $d[0,$j]=$j }
    for($i=1;$i -le $n;$i++){ for($j=1;$j -le $m;$j++){
        $c= if($a[$i-1] -eq $b[$j-1]){0}else{1}
        $im=$i-1; $jm=$j-1
        $x1=$d[$im,$j]+1; $x2=$d[$i,$jm]+1; $x3=$d[$im,$jm]+$c
        $d[$i,$j]=[Math]::Min([Math]::Min($x1,$x2),$x3)
    } }
    return $d[$n,$m]
}
function Get-RiskyLocation([string]$s){
    if(-not $s){ return $null }
    if($s -match '(?i)\\AppData\\Local\\Temp\\|\\Windows\\Temp\\|\\Temp\\'){ return 'runs from a Temp folder' }
    if($s -match '(?i)\\Downloads\\'){ return 'runs from Downloads' }
    if($s -match '(?i)\\Users\\Public\\'){ return 'runs from Users\Public' }
    if($s -match '(?i)\$Recycle\.Bin'){ return 'runs from the Recycle Bin' }
    return $null
}
function Get-CmdExePath([string]$cmd){
    if([string]::IsNullOrWhiteSpace($cmd)){ return $null }
    $c=[Environment]::ExpandEnvironmentVariables($cmd.Trim())
    if($c.StartsWith('"')){ $e=$c.IndexOf('"',1); if($e -gt 1){ return $c.Substring(1,$e-1) } }
    $m=[regex]::Match($c,'^(.*?\.(exe|bat|cmd|com|ps1|vbs|vbe|js|jse|wsf|scr|lnk|dll|msi|cpl))(\s|$)','IgnoreCase')
    if($m.Success){ return $m.Groups[1].Value }
    return ($c -split '\s+')[0]
}
$script:SigCache=@{}
function Sleep-Pump([int]$ms,[scriptblock]$Progress,[string]$msg){
    $end=(Get-Date).AddMilliseconds($ms)
    while((Get-Date) -lt $end){ & $Progress $msg; Start-Sleep -Milliseconds 100 }
}
function Get-SigInfo([string]$path){
    if(-not $path){ return [PSCustomObject]@{ Status='Unknown'; Signer='' } }
    $k=$path.ToLower()
    if($script:SigCache.ContainsKey($k)){ return $script:SigCache[$k] }
    $r=[PSCustomObject]@{ Status='Unknown'; Signer='' }
    try{
        if(Test-Path -LiteralPath $path -PathType Leaf){
            $s=Get-AuthenticodeSignature -LiteralPath $path -EA Stop
            $signer=''; if($s.SignerCertificate){ $signer=($s.SignerCertificate.Subject -split ',')[0] -replace '^CN=','' }
            $r=[PSCustomObject]@{ Status=[string]$s.Status; Signer=$signer }
        } else { $r=[PSCustomObject]@{ Status='FileNotFound'; Signer='' } }
    }catch{}
    $script:SigCache[$k]=$r
    return $r
}
function Get-DefenderInfo{
    $o=[PSCustomObject]@{ Available=$false; Realtime=$null; AMService=$null; SigAgeDays=$null; LastFullScan=$null; LastQuickScan=$null; Advice=@() }
    try{
        $m=Get-MpComputerStatus -EA Stop
        $o.Available=$true; $o.Realtime=$m.RealTimeProtectionEnabled; $o.AMService=$m.AMServiceEnabled
        if($m.AntivirusSignatureLastUpdated){ $o.SigAgeDays=[int]((Get-Date)-$m.AntivirusSignatureLastUpdated).TotalDays }
        $o.LastFullScan=$m.FullScanEndTime; $o.LastQuickScan=$m.QuickScanEndTime
        if(-not $m.RealTimeProtectionEnabled){ $o.Advice += 'Real-time protection is OFF (unless another antivirus is active) - consider turning it on.' }
        if($o.SigAgeDays -ne $null -and $o.SigAgeDays -gt 3){ $o.Advice += "Virus definitions are $($o.SigAgeDays) days old - update them in Windows Security." }
    }catch{ $o.Advice += 'Windows Defender status is unavailable (a third-party antivirus may be managing protection).' }
    $o.Advice += 'Recommended: run a Defender FULL scan (Windows Security > Virus & threat protection > Scan options > Full scan, or admin PowerShell: Start-MpScan -ScanType FullScan). This tool does not run it for you.'
    return $o
}
# Returns @{ Items = flagged rows ; Defender = info ; Stats = counts }. $Progress may pump UI events.
function Get-SecurityReport([scriptblock]$Progress){
    if(-not $Progress){ $Progress = { param($m) } }
    $items = New-Object System.Collections.Generic.List[object]
    $win=$env:SystemRoot; $pf=$env:ProgramFiles; $pf86=${env:ProgramFiles(x86)}
    $isTrusted = { param($p) ($p -like "$win\*") -or ($p -like "$pf\*") -or ($pf86 -and ($p -like "$pf86\*")) -or ($p -like '*\WindowsApps\*') }
    $sysNames = @{ 'svchost.exe'="$win\System32"; 'lsass.exe'="$win\System32"; 'csrss.exe'="$win\System32"; 'smss.exe'="$win\System32"; 'services.exe'="$win\System32";
                   'winlogon.exe'="$win\System32"; 'wininit.exe'="$win\System32"; 'taskhostw.exe'="$win\System32"; 'spoolsv.exe'="$win\System32";
                   'dwm.exe'="$win\System32"; 'conhost.exe'="$win\System32"; 'sihost.exe'="$win\System32"; 'explorer.exe'="$win" }
    $startup = New-Object System.Collections.Generic.List[object]   # all startup entries (for cross-reference)

    # ---- startup entries
    & $Progress 'Reading startup entries...'
    $runKeys=@('HKCU:\Software\Microsoft\Windows\CurrentVersion\Run','HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce','HKLM:\Software\Microsoft\Windows\CurrentVersion\Run','HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce','HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run')
    foreach($k in $runKeys){
        $key=Get-Item -LiteralPath $k -EA SilentlyContinue
        if(-not $key){ continue }
        foreach($vn in $key.GetValueNames()){
            if(-not $vn){ continue }
            $cmd=[string]$key.GetValue($vn)
            $startup.Add([PSCustomObject]@{ Source=($k -replace '^HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion','HKCU' -replace '^HKLM:\\Software\\','HKLM '); Name=$vn; Command=$cmd; Exe=(Get-CmdExePath $cmd) })
        }
    }
    foreach($sf in @("$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup","$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Startup")){
        foreach($f in @(Get-ChildItem -LiteralPath $sf -File -Force -EA SilentlyContinue | Where-Object { $_.Name -ne 'desktop.ini' })){
            $exe=$f.FullName
            if($f.Extension -eq '.lnk'){ try{ $exe=(New-Object -ComObject WScript.Shell).CreateShortcut($f.FullName).TargetPath }catch{} }
            $startup.Add([PSCustomObject]@{ Source='Startup folder'; Name=$f.Name; Command=$f.FullName; Exe=$exe })
        }
    }
    & $Progress 'Reading scheduled tasks...'
    try{
        foreach($t in @(Get-ScheduledTask -EA Stop | Where-Object { $_.TaskPath -notlike '\Microsoft\*' -and $_.State -ne 'Disabled' })){
            foreach($a in @($t.Actions)){
                if(-not $a.Execute){ continue }
                $cmd=($a.Execute + ' ' + $a.Arguments).Trim()
                $startup.Add([PSCustomObject]@{ Source='Scheduled task'; Name=($t.TaskPath + $t.TaskName); Command=$cmd; Exe=(Get-CmdExePath $a.Execute) })
            }
        }
    }catch{}

    # ---- startup entry findings
    $signedAppData=0
    $i=0
    foreach($s in $startup){
        $i++; & $Progress ("Checking startup entry $i/$($startup.Count)...")
        $reasons=@(); $sev='Low'
        $loc = Get-RiskyLocation $s.Command; if(-not $loc){ $loc = Get-RiskyLocation $s.Exe }
        $sig = $null
        if($loc){ $reasons += "startup entry that $loc"; $sev='High' }
        elseif(($s.Command -match '(?i)\\AppData\\') -or ($s.Exe -match '(?i)\\AppData\\')){
            $sig = Get-SigInfo $s.Exe
            if($sig.Status -ne 'Valid'){ $reasons += "startup entry in AppData with signature '$($sig.Status)'"; $sev='Medium' } else { $signedAppData++ }
        }
        if($reasons.Count -gt 0){
            if(-not $sig){ $sig = Get-SigInfo $s.Exe }
            $items.Add([PSCustomObject]@{ Type='Startup'; Severity=$sev; Name="$($s.Name)  [$($s.Source)]"; PID=''; Path=[string]$s.Exe; Signature=$sig.Status; Signer=$sig.Signer; Reasons=($reasons -join '; ') })
        }
    }
    $startupPaths=@{}; foreach($s in $startup){ if($s.Exe){ $startupPaths[$s.Exe.ToLower()]=1 } }

    # ---- running processes
    & $Progress 'Listing processes...'
    $procs=@(Get-CimInstance Win32_Process -EA SilentlyContinue)
    $winH=@{}; foreach($gp in @(Get-Process -EA SilentlyContinue)){ try{ $winH[[int]$gp.Id]=[int64]$gp.MainWindowHandle }catch{} }
    # CPU: two 2.5 s samples, flag only if high in BOTH (sustained)
    & $Progress 'Sampling CPU (5 s)...'
    $cores=[Environment]::ProcessorCount
    $cpu0=@{}; foreach($gp in @(Get-Process -EA SilentlyContinue)){ try{ $cpu0[[int]$gp.Id]=$gp.TotalProcessorTime.TotalSeconds }catch{} }
    $t0=Get-Date; Sleep-Pump 2500 $Progress 'Sampling CPU (5 s)...'
    $cpu1=@{}; foreach($gp in @(Get-Process -EA SilentlyContinue)){ try{ $cpu1[[int]$gp.Id]=$gp.TotalProcessorTime.TotalSeconds }catch{} }
    $t1=Get-Date; Sleep-Pump 2500 $Progress 'Sampling CPU (5 s)...'
    $cpu2=@{}; foreach($gp in @(Get-Process -EA SilentlyContinue)){ try{ $cpu2[[int]$gp.Id]=$gp.TotalProcessorTime.TotalSeconds }catch{} }
    $t2=Get-Date
    $e1=($t1-$t0).TotalSeconds; $e2=($t2-$t1).TotalSeconds
    $n=0
    foreach($p in $procs){
        $n++; if($n % 15 -eq 0){ & $Progress ("Checking process $n/$($procs.Count)...") }
        $ppid=[int]$p.ProcessId
        if($ppid -le 4){ continue }
        $path=[string]$p.ExecutablePath
        if(-not $path){ continue }   # protected/system process with no readable path
        $name=[string]$p.Name; $lname=$name.ToLower()
        $reasons=@(); $sev='Low'
        $loc=Get-RiskyLocation $path
        if($loc){ $reasons += $loc; $sev='High' }
        if($sysNames.ContainsKey($lname)){
            $expected=$sysNames[$lname]
            $dir=Split-Path $path -Parent
            $ok = ($dir -ieq $expected) -or ($lname -ne 'explorer.exe' -and $dir -ieq "$win\SysWOW64")
            if(-not $ok){ $reasons += "has the system name '$name' but runs from '$dir' (expected $expected)"; $sev='High' }
        } else {
            $base=[IO.Path]::GetFileNameWithoutExtension($lname)
            foreach($sn in $sysNames.Keys){
                $sb=[IO.Path]::GetFileNameWithoutExtension($sn)
                if($sb.Length -ge 5 -and $base.Length -ge 4 -and [Math]::Abs($base.Length-$sb.Length) -le 1 -and (Get-EditDistance $base $sb) -le $(if($sb.Length -ge 7){2}else{1})){
                    $reasons += "name looks like the system process '$sn'"; if($sev -ne 'High'){ $sev='Medium' }; break
                }
            }
        }
        $trusted = & $isTrusted $path
        $sig=$null
        if(-not $trusted){
            $sig=Get-SigInfo $path
            if($sig.Status -ne 'Valid'){ $reasons += "signature: $($sig.Status) (outside Windows/Program Files)"; if($sev -eq 'Low'){ $sev='Medium' } }
        }
        if(-not $trusted -and $startupPaths.ContainsKey($path.ToLower()) -and $winH.ContainsKey($ppid) -and $winH[$ppid] -eq 0){
            $reasons += 'no visible window and registered to start automatically (possible hidden persistence)'; if($sev -eq 'Low' -and $sig -and $sig.Status -ne 'Valid'){ $sev='Medium' }
        }
        if($cpu0.ContainsKey($ppid) -and $cpu1.ContainsKey($ppid) -and $cpu2.ContainsKey($ppid) -and $e1 -gt 0 -and $e2 -gt 0){
            $u1=(($cpu1[$ppid]-$cpu0[$ppid])/$e1/$cores)*100; $u2=(($cpu2[$ppid]-$cpu1[$ppid])/$e2/$cores)*100
            if($u1 -ge 50 -and $u2 -ge 50){ $reasons += ("very high CPU: ~{0:N0}% of the whole CPU over 5 s" -f (($u1+$u2)/2)) }
        }
        if($reasons.Count -gt 0){
            if(-not $sig){ $sig=Get-SigInfo $path }
            $items.Add([PSCustomObject]@{ Type='Process'; Severity=$sev; Name=$name; PID=$ppid; Path=$path; Signature=$sig.Status; Signer=$sig.Signer; Reasons=($reasons -join '; ') })
        }
    }
    $order=@{High=0;Medium=1;Low=2}
    $sorted=@($items | Sort-Object @{e={$order[$_.Severity]}},Type,Name)
    return @{ Items=$sorted; Defender=(Get-DefenderInfo); Stats=[PSCustomObject]@{ Processes=$procs.Count; StartupEntries=$startup.Count; SignedAppDataStartup=$signedAppData } }
}

# ---------------------------------------------------------------- network helpers (update checker + downloader)
# Used ONLY when the user asks (button / -CheckUpdate). No telemetry, no automatic calls.
if (-not ('CleanFetch' -as [type])) {
Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.IO;
using System.Net;
using System.Text;
using System.Threading;

// Small GET on a background thread (short timeouts) so the UI never freezes.
public class CleanFetch {
    public volatile bool Done;
    public int Status;
    public string Body = "";
    public string Error = "";
    public void Start(string url, string ua, int timeoutMs) {
        Done = false;
        Thread t = new Thread(delegate() {
            try {
                HttpWebRequest rq = (HttpWebRequest)WebRequest.Create(url);
                rq.UserAgent = ua; rq.Accept = "application/vnd.github+json";
                rq.Timeout = timeoutMs; rq.ReadWriteTimeout = timeoutMs;
                using (HttpWebResponse rs = (HttpWebResponse)rq.GetResponse()) {
                    Status = (int)rs.StatusCode;
                    using (StreamReader sr = new StreamReader(rs.GetResponseStream(), Encoding.UTF8)) { Body = sr.ReadToEnd(); }
                }
            } catch (WebException we) {
                HttpWebResponse r = we.Response as HttpWebResponse;
                if (r != null) { Status = (int)r.StatusCode; r.Close(); }
                Error = we.Message;
            } catch (Exception e) { Error = e.Message; }
            Done = true;
        });
        t.IsBackground = true; t.Start();
    }
}

// File download on a background thread with progress + cancel. Writes to 'dest' (caller passes a .part name).
public class CleanDownloader {
    public volatile bool Cancel;
    public volatile bool Done;
    public volatile bool Ok;
    public long Total;
    public long BytesDone;
    public string Error = "";
    public void Start(string url, string ua, string dest, int timeoutMs) {
        Done = false; Ok = false; BytesDone = 0; Total = 0; Error = "";
        Thread t = new Thread(delegate() {
            FileStream fs = null;
            try {
                HttpWebRequest rq = (HttpWebRequest)WebRequest.Create(url);
                rq.UserAgent = ua; rq.Accept = "application/octet-stream";
                rq.Timeout = timeoutMs; rq.ReadWriteTimeout = timeoutMs; rq.AllowAutoRedirect = true;
                using (HttpWebResponse rs = (HttpWebResponse)rq.GetResponse()) {
                    Total = rs.ContentLength;
                    using (Stream s = rs.GetResponseStream()) {
                        fs = new FileStream(dest, FileMode.Create, FileAccess.Write, FileShare.None);
                        byte[] buf = new byte[81920]; int n;
                        while ((n = s.Read(buf, 0, buf.Length)) > 0) {
                            if (Cancel) { Error = "cancelled"; break; }
                            fs.Write(buf, 0, n); BytesDone += n;
                        }
                    }
                }
                fs.Close(); fs = null;
                Ok = (!Cancel && Error.Length == 0);
            } catch (Exception e) { Error = e.Message; }
            finally { if (fs != null) { try { fs.Close(); } catch (Exception) { } } }
            Done = true;
        });
        t.IsBackground = true; t.Start();
    }
}
'@
}

# ---------------------------------------------------------------- update checker
$script:RepoStd  = 'Ivan-Ryukendo/PC-Cache-Cleaner'
$script:RepoPro  = 'Ivan-Ryukendo/PC-Cache-Cleaner-Pro'
$script:ApiBase  = 'https://api.github.com/repos/'
$script:MarkerPath = Join-Path $env:LOCALAPPDATA 'CleanPC\pending-delete.txt'

function Enable-Tls12 { try { [Net.ServicePointManager]::SecurityProtocol = ([Net.ServicePointManager]::SecurityProtocol -bor 3072) } catch {} }

# GET + parse JSON. Never throws. Returns Ok/Status/Data/Message. $Pump (optional) keeps a UI alive while waiting.
function Invoke-GitHubJson([string]$url,[scriptblock]$Pump,[int]$TimeoutMs=8000){
    $r=[PSCustomObject]@{ Ok=$false; Status=0; Data=$null; Message='' }
    try{
        Enable-Tls12
        $f=New-Object CleanFetch
        $f.Start($url,"CleanPC/$script:AppVersion",$TimeoutMs)
        $sw=[Diagnostics.Stopwatch]::StartNew()
        while(-not $f.Done){
            if($Pump){ & $Pump }
            Start-Sleep -Milliseconds 50
            if($sw.ElapsedMilliseconds -gt ($TimeoutMs*2+2000)){ break }
        }
        if(-not $f.Done){ $r.Message='The request timed out.' }
        else{
            $r.Status=[int]$f.Status
            if($r.Status -eq 200){ try{ $r.Data=($f.Body | ConvertFrom-Json); $r.Ok=$true }catch{ $r.Message='GitHub sent an unexpected reply.' } }
            elseif($r.Status -eq 404){ $r.Message='Not found (404).' }
            elseif($r.Status -eq 403 -or $r.Status -eq 429){ $r.Message='GitHub is limiting requests right now. Please try again later.' }
            elseif($r.Status -gt 0){ $r.Message="GitHub answered with HTTP $($r.Status)." }
            else{ $r.Message="Could not reach GitHub. Check your internet connection. ($($f.Error))" }
        }
    }catch{ $r.Message='The update check failed: ' + $_.Exception.Message }
    Write-CleanLog ("UPDATE GET {0} -> ok={1} status={2} {3}" -f $url,$r.Ok,$r.Status,$r.Message)
    return $r
}

# '1.2' / 'v1.2.1' / 'PC Cache Cleaner v1.2.1-beta' -> [version] 1.2.1 (3+ parts), or $null
function ConvertTo-AppVersion([string]$s){
    if(-not $s){ return $null }
    $m=[regex]::Match($s,'(\d+)\.(\d+)(?:\.(\d+))?(?:\.(\d+))?')
    if(-not $m.Success){ return $null }
    $p=@($m.Groups[1].Value,$m.Groups[2].Value,$(if($m.Groups[3].Success){$m.Groups[3].Value}else{'0'}))
    if($m.Groups[4].Success){ $p += $m.Groups[4].Value }
    try{ return [version]($p -join '.') }catch{ return $null }
}

# State: Newer | UpToDate | Available (Pro) | NotReleased | Error.  Never throws.
function Get-UpdateInfo([string]$Channel,[string]$Repo,[string]$AssetName,[string]$CurrentVersion,[scriptblock]$Pump,[string]$ApiUrl){
    $o=[PSCustomObject]@{ Channel=$Channel; State='Error'; Message=''; Tag=''; Version=$null; Notes=''; PageUrl=''; AssetName=$AssetName; AssetUrl=''; AssetSize=[int64]0; AssetSha256=''; Current=$CurrentVersion }
    try{
        if(-not $ApiUrl){ $ApiUrl = "$($script:ApiBase)$Repo/releases/latest" }
        $r=Invoke-GitHubJson $ApiUrl $Pump
        if($r.Status -eq 404){ $o.State='NotReleased'; $o.Message='No release has been published yet.'; return $o }
        if(-not $r.Ok){ $o.Message=$r.Message; return $o }
        $d=$r.Data
        if($d.draft -or $d.prerelease){ $o.State='NotReleased'; $o.Message='Only a pre-release exists so far.'; return $o }
        $o.Tag=[string]$d.tag_name; $o.PageUrl=[string]$d.html_url
        $o.Version=ConvertTo-AppVersion $o.Tag
        if(-not $o.Version){ $o.Message="Could not read the version number from the release tag '$($o.Tag)'."; return $o }
        $n=[string]$d.body; if($n.Length -gt 700){ $n=$n.Substring(0,700).TrimEnd()+' ...' }
        $o.Notes=($n -replace "`r","").Trim()
        foreach($a in @($d.assets)){
            if($a.name -ieq $AssetName){
                $o.AssetUrl=[string]$a.browser_download_url; $o.AssetSize=[int64]$a.size
                if($a.digest -and ([string]$a.digest) -match '^sha256:([0-9a-fA-F]{64})$'){ $o.AssetSha256=$Matches[1].ToLower() }
            }
        }
        if($Channel -eq 'Pro'){
            if(-not $o.AssetUrl){ $o.State='NotReleased'; $o.Message="The Pro release has no $AssetName file attached yet."; return $o }
            $o.State='Available'; return $o
        }
        $cur=ConvertTo-AppVersion $CurrentVersion
        if($cur -and $o.Version -gt $cur){ $o.State='Newer'; if(-not $o.AssetUrl){ $o.Message="The release has no $AssetName file attached; open the release page instead." } }
        else{ $o.State='UpToDate' }
    }catch{ $o.State='Error'; $o.Message='The update check failed: ' + $_.Exception.Message }
    return $o
}
function Get-AllUpdateInfo([scriptblock]$Pump){
    Write-CleanLog "UPDATE CHECK requested by user (current v$script:AppVersion)"
    $std=Get-UpdateInfo 'Standard' $script:RepoStd 'CleanPC.exe' $script:AppVersion $Pump
    $pro=Get-UpdateInfo 'Pro' $script:RepoPro 'CleanPC-Pro.exe' '' $Pump
    Write-CleanLog ("UPDATE RESULT standard={0} ({1}) pro={2} ({3})" -f $std.State,$std.Tag,$pro.State,$pro.Tag)
    return @{ Standard=$std; Pro=$pro }
}

# ---------------------------------------------------------------- download + installer housekeeping
function Get-SelfPath{
    try{ $p=[Diagnostics.Process]::GetCurrentProcess().MainModule.FileName; if($p -and ([IO.Path]::GetFileName($p) -notmatch '^(powershell|pwsh|powershell_ise)\.exe$')){ return $p } }catch{}
    if($PSCommandPath){ return $PSCommandPath }
    return $null
}
function Get-AppFolder{
    $s=Get-SelfPath; if($s){ return (Split-Path -Parent $s) }
    return $script:LogDir
}
# Free-space check: needs asset size + margin (50 MB or 10%, whichever is larger).
function Test-DownloadSpace([string]$folder,[int64]$assetSize){
    $res=[PSCustomObject]@{ Ok=$false; Free=[int64]0; Need=[int64]0; Message='' }
    try{
        $margin=[int64][Math]::Max([double]50MB,[Math]::Ceiling([double]$assetSize*0.1))
        $res.Need=$assetSize+$margin
        $root=[IO.Path]::GetPathRoot([IO.Path]::GetFullPath($folder))
        if($root.StartsWith('\\')){ $res.Message='Network (UNC) folders cannot be checked for free space; choose a local drive.'; return $res }
        $di=New-Object IO.DriveInfo $root
        if($di.DriveType -ne 'Fixed'){ $res.Message="Drive $root is not a fixed local drive."; return $res }
        $res.Free=[int64]$di.AvailableFreeSpace
        if($res.Free -ge $res.Need){ $res.Ok=$true } else { $res.Message="Not enough free space on $root : $(Format-Size $res.Free) free, $(Format-Size $res.Need) needed." }
    }catch{ $res.Message='Could not check free space: ' + $_.Exception.Message }
    return $res
}
# Only github.com/Ivan-Ryukendo/... https links may be downloaded.
function Test-AllowedDownloadUrl([string]$u){ return [bool]($u -match '^https://github\.com/Ivan-Ryukendo/[A-Za-z0-9._-]+/releases/download/') }
# Finishes a download: size check, optional SHA-256 check, then moves .part -> final name.
function Complete-Download([string]$part,[string]$final,[int64]$expectedSize,[string]$sha256,[bool]$overwrite){
    $r=[PSCustomObject]@{ Ok=$false; Message='' }
    try{
        $len=(Get-Item -LiteralPath $part -Force -EA Stop).Length
        if($expectedSize -gt 0 -and $len -ne $expectedSize){ $r.Message="Size mismatch: got $len bytes, expected $expectedSize. The partial file was deleted."; Remove-Item -LiteralPath $part -Force -EA SilentlyContinue; return $r }
        if($sha256){
            $h=(Get-FileHash -LiteralPath $part -Algorithm SHA256 -EA Stop).Hash.ToLower()
            if($h -ne $sha256.ToLower()){ $r.Message='SHA-256 checksum mismatch. The partial file was deleted.'; Remove-Item -LiteralPath $part -Force -EA SilentlyContinue; return $r }
        }
        if((Test-Path -LiteralPath $final) -and -not $overwrite){ $r.Message='The target file already exists.'; return $r }
        Move-Item -LiteralPath $part -Destination $final -Force -EA Stop
        $r.Ok=$true; $r.Message="Saved to $final"
    }catch{ $r.Message='Could not finish the download: ' + $_.Exception.Message }
    Write-CleanLog ("DOWNLOAD finish ok={0} {1} :: {2}" -f $r.Ok,$final,$r.Message)
    return $r
}

# The ONLY delete this program does outside caches: the one old installer .exe it came from.
function Test-SafeInstallerDelete([string]$path,[string]$newFile,[string]$running,[switch]$RequireOurName){
    $r=[PSCustomObject]@{ Ok=$false; Why='' }
    try{
        if([string]::IsNullOrWhiteSpace($path)){ $r.Why='no path'; return $r }
        if($path -match '[\*\?<>|"]'){ $r.Why='wildcard or invalid characters'; return $r }
        $full=[IO.Path]::GetFullPath($path)
        if($full.Length -lt 8 -or [IO.Path]::GetPathRoot($full) -eq $full){ $r.Why='not a file path'; return $r }
        if([IO.Path]::GetExtension($full) -ine '.exe'){ $r.Why='not an .exe file'; return $r }
        if(-not (Test-Path -LiteralPath $full -PathType Leaf)){ $r.Why='file does not exist (or is a folder)'; return $r }
        $fi=Get-Item -LiteralPath $full -Force
        if($fi.PSIsContainer -or ($fi.Attributes -band [IO.FileAttributes]::ReparsePoint)){ $r.Why='folder or link'; return $r }
        if($newFile -and ($full -ieq [IO.Path]::GetFullPath($newFile))){ $r.Why='this is the NEW file'; return $r }
        if($running -and ($full -ieq [IO.Path]::GetFullPath($running))){ $r.Why='this is the program that is running right now'; return $r }
        foreach($bad in @($env:SystemRoot,$env:ProgramFiles,${env:ProgramFiles(x86)},$env:ProgramW6432)){
            if($bad -and $full.StartsWith($bad.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){ $r.Why="inside $bad"; return $r }
        }
        if($RequireOurName -and ([IO.Path]::GetFileName($full) -notmatch '^CleanPC.*\.exe$')){ $r.Why='file name is not CleanPC*.exe'; return $r }
        $r.Ok=$true
    }catch{ $r.Why=$_.Exception.Message }
    return $r
}
function Write-PendingDelete([string]$oldPath,[string]$oldVersion,[string]$newFile){
    try{
        $dir=Split-Path -Parent $script:MarkerPath
        if(-not (Test-Path -LiteralPath $dir)){ New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Set-Content -LiteralPath $script:MarkerPath -Encoding UTF8 -Value @("old=$oldPath","oldversion=$oldVersion","new=$newFile","utc=$((Get-Date).ToUniversalTime().ToString('s'))")
        Write-CleanLog "MARKER written: delete old installer $oldPath (v$oldVersion) after upgrade to $newFile"
        return $true
    }catch{ Write-CleanLog "MARKER write failed: $($_.Exception.Message)"; return $false }
}
function Clear-PendingDelete{ try{ Remove-Item -LiteralPath $script:MarkerPath -Force -EA SilentlyContinue }catch{} }
# New-version startup: returns {Old;OldVersion;New} when the user should be asked once, else $null.
function Get-PendingDelete{
    try{
        if(-not (Test-Path -LiteralPath $script:MarkerPath -PathType Leaf)){ return $null }
        $m=@{}; foreach($l in @(Get-Content -LiteralPath $script:MarkerPath -EA Stop)){ if($l -match '^([a-z]+)=(.*)$'){ $m[$Matches[1]]=$Matches[2] } }
        if(-not $m['old'] -or -not (Test-Path -LiteralPath $m['old'] -PathType Leaf)){ Clear-PendingDelete; return $null }   # already gone
        $self=Get-SelfPath
        if(-not $self -or -not $m['new'] -or ($self -ine $m['new'])){ return $null }                                      # not the new version (yet)
        $ov=ConvertTo-AppVersion $m['oldversion']; $cv=ConvertTo-AppVersion $script:AppVersion
        $isPro = ([IO.Path]::GetFileName($self) -match 'Pro')
        if($ov -and $cv -and -not $isPro -and $ov -ge $cv){ Clear-PendingDelete; return $null }
        $chk=Test-SafeInstallerDelete $m['old'] $self $self -RequireOurName
        if(-not $chk.Ok){ Write-CleanLog "MARKER ignored ($($chk.Why)): $($m['old'])"; Clear-PendingDelete; return $null }
        return [PSCustomObject]@{ Old=$m['old']; OldVersion=$m['oldversion']; New=$self }
    }catch{ return $null }
}
function Remove-OldInstaller([string]$oldPath,[string]$newFile,[string]$running,[switch]$RequireOurName){
    $chk=Test-SafeInstallerDelete $oldPath $newFile $running -RequireOurName:$RequireOurName
    if(-not $chk.Ok){ Write-CleanLog "OLD INSTALLER delete REFUSED ($($chk.Why)): $oldPath"; return $false }
    try{
        Remove-Item -LiteralPath $oldPath -Force -EA Stop
        Write-CleanLog "OLD INSTALLER deleted (user chose Delete): $oldPath"
        return $true
    }catch{ Write-CleanLog "OLD INSTALLER delete failed $oldPath : $($_.Exception.Message)"; return $false }
}
# A running exe cannot delete itself: start a tiny hidden cmd that retries deleting that ONE file until
# this program has exited (up to ~10 minutes). Same safety checks as above.
function Start-DeferredDelete([string]$oldPath,[string]$newFile){
    $chk=Test-SafeInstallerDelete $oldPath $newFile $null
    if(-not $chk.Ok){ Write-CleanLog "DEFERRED delete REFUSED ($($chk.Why)): $oldPath"; return $false }
    if($oldPath -match '[%&^!]'){ Write-CleanLog "DEFERRED delete REFUSED (special characters in path): $oldPath"; return $false }
    try{
        $cl = 'for /l %i in (1,1,600) do @if exist "{0}" (del /f /q "{0}" >nul 2>&1 & ping -n 2 127.0.0.1 >nul)' -f $oldPath
        Start-Process -FilePath "$env:SystemRoot\System32\cmd.exe" -ArgumentList @('/d','/c',$cl) -WindowStyle Hidden
        Write-CleanLog "DEFERRED delete scheduled (runs after this program exits): $oldPath"
        return $true
    }catch{ Write-CleanLog "DEFERRED delete failed to start: $($_.Exception.Message)"; return $false }
}

# ---------------------------------------------------------------- restore point
function Test-RestoreDisabled{
    try{
        $pol=Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\SystemRestore' -EA SilentlyContinue
        if($pol -and $pol.DisableSR -eq 1){ return $true }
        $vs=@(& vssadmin.exe list shadowstorage 2>$null)
        if($vs.Count -gt 0 -and ($vs -join "`n") -match 'For volume'){ return (($vs -join "`n") -notmatch ("\(" + [regex]::Escape($env:SystemDrive) + "\)")) }
    }catch{}
    return $false
}
function Get-LastRestoreSeq{ try{ $m=(Get-ComputerRestorePoint -EA Stop | Measure-Object SequenceNumber -Maximum).Maximum; if($m){ return [int]$m } }catch{}; return 0 }
# Status: Created | Skipped24h | Disabled | NotAdmin | Failed.  Never throws; Windows allows 1 per 24 h by default.
function New-CleanRestorePoint{
    $r=[PSCustomObject]@{ Status='Failed'; Message='' }
    try{
        if(-not (Is-Admin)){ $r.Status='NotAdmin'; $r.Message='Creating a restore point needs Administrator rights.'; return $r }
        if(Test-RestoreDisabled){ $r.Status='Disabled'; $r.Message='System Restore appears to be turned off for the Windows drive.'; return $r }
        $before=Get-LastRestoreSeq
        $wv=$null
        Checkpoint-Computer -Description "PC Cache Cleaner $script:AppVersion" -RestorePointType MODIFY_SETTINGS -ErrorAction Stop -WarningVariable wv -WarningAction SilentlyContinue
        $after=Get-LastRestoreSeq
        $w=(@($wv) | ForEach-Object { [string]$_ }) -join ' '
        if($after -gt $before){ $r.Status='Created'; $r.Message='Restore point created.' }
        elseif($w -match '1440|already been created|within the past'){ $r.Status='Skipped24h'; $r.Message='Windows allows one restore point per 24 hours and one was already created recently; the existing one still protects you.' }
        elseif($w -match 'disabled|turned off'){ $r.Status='Disabled'; $r.Message='System Restore is turned off.' }
        else{ $r.Status='Failed'; $r.Message=$(if($w){$w}else{'Windows did not create a restore point.'}) }
    }catch{
        $msg=$_.Exception.Message
        if($msg -match 'disabled|turned off'){ $r.Status='Disabled'; $r.Message='System Restore is turned off.' }
        elseif($msg -match '1440|already been created|within the past'){ $r.Status='Skipped24h'; $r.Message='Windows allows one restore point per 24 hours and one was already created recently.' }
        else{ $r.Status='Failed'; $r.Message=$msg }
    }
    Write-CleanLog ("RESTORE POINT status={0} {1}" -f $r.Status,$r.Message)
    return $r
}

# ---------------------------------------------------------------- report export (HTML / CSV)
# $Cleanup rows need: Name Category Size Paths Note Ticked.  $Report rows: Name Size Paths Note.  $Security: result of Get-SecurityReport or $null.
function Get-RiskLabel($note){ if([string]$note -like 'RISKY*'){ return 'Risky' } else { return 'Normal' } }
function ConvertTo-CsvCell([string]$s){
    if($s -match '^[=+\-@\t]'){ $s = "'" + $s }          # neutralise spreadsheet formulas
    return '"' + ($s -replace '"','""') + '"'
}
function Export-CleanReport([string]$Path,[string]$Format,$Cleanup,$Report,$Security,[string[]]$Drives){
    $res=[PSCustomObject]@{ Ok=$false; Message='' }
    try{
        if(-not $Format){ $Format = $(if([IO.Path]::GetExtension($Path) -ieq '.csv'){'csv'}else{'html'}) }
        $Cleanup=@($Cleanup); $Report=@($Report)
        $gen=Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $tick=[int64]0; foreach($c in $Cleanup){ if($c.Ticked){ $tick += [int64]$c.Size } }
        if($Format -eq 'csv'){
            $sb=New-Object System.Text.StringBuilder
            [void]$sb.AppendLine('Section,Name,Category,SizeBytes,Size,Ticked,Risk,Note,Paths')
            foreach($c in $Cleanup){ [void]$sb.AppendLine((@('Cleanup',$c.Name,$c.Category,[string][int64]$c.Size,(Format-Size $c.Size),$(if($c.Ticked){'yes'}else{'no'}),(Get-RiskLabel $c.Note),$c.Note,(@($c.Paths) -join ' | ')) | ForEach-Object { ConvertTo-CsvCell ([string]$_) }) -join ',') }
            foreach($c in $Report){ [void]$sb.AppendLine((@('Report only',$c.Name,'Report',[string][int64]$c.Size,(Format-Size $c.Size),'no','Report only',$c.Note,(@($c.Paths) -join ' | ')) | ForEach-Object { ConvertTo-CsvCell ([string]$_) }) -join ',') }
            if($Security){ foreach($x in @($Security.Items)){ [void]$sb.AppendLine((@('Security',$x.Name,$x.Type,'','','no',$x.Severity,$x.Reasons,$x.Path) | ForEach-Object { ConvertTo-CsvCell ([string]$_) }) -join ',') } }
            [IO.File]::WriteAllText($Path,$sb.ToString(),(New-Object System.Text.UTF8Encoding($true)))
        } else {
            $e={ param($s) [System.Net.WebUtility]::HtmlEncode([string]$s) }
            $h=New-Object System.Text.StringBuilder
            [void]$h.AppendLine('<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><title>PC Cache Cleaner report</title>')
            [void]$h.AppendLine('<style>body{font:14px Segoe UI,Arial,sans-serif;margin:24px;color:#222}h1{font-size:20px}h2{font-size:16px;margin-top:28px}table{border-collapse:collapse;width:100%}th,td{border:1px solid #ccc;padding:5px 8px;text-align:left;vertical-align:top}th{background:#f0f0f0}td.n{text-align:right;white-space:nowrap}.risk{color:#a00;font-weight:600}.paths{font:12px Consolas,monospace;color:#444;word-break:break-all}.meta{color:#555}</style></head><body>')
            [void]$h.AppendLine("<h1>PC Cache Cleaner report</h1><p class=""meta"">Generated $(& $e $gen) by v$(& $e $script:AppVersion). Drives: $(& $e ($Drives -join ', ')). Ticked total: <b>$(& $e (Format-Size $tick))</b>. Nothing in this report has been deleted by exporting it.</p>")
            [void]$h.AppendLine('<h2>Cleanup items</h2><table><tr><th>Ticked</th><th>Item</th><th>Category</th><th>Size</th><th>Risk</th><th>Note</th><th>Paths</th></tr>')
            foreach($c in $Cleanup){ [void]$h.AppendLine("<tr><td>$(if($c.Ticked){'yes'}else{'no'})</td><td>$(& $e $c.Name)</td><td>$(& $e $c.Category)</td><td class=""n"">$(& $e (Format-Size $c.Size))</td><td class=""$(if((Get-RiskLabel $c.Note) -eq 'Risky'){'risk'})"">$(Get-RiskLabel $c.Note)</td><td>$(& $e $c.Note)</td><td class=""paths"">$(& $e (@($c.Paths) -join ' | '))</td></tr>") }
            [void]$h.AppendLine('</table>')
            if($Report.Count -gt 0){
                [void]$h.AppendLine('<h2>Report only (this tool never deletes these)</h2><table><tr><th>Item</th><th>Size</th><th>How to deal with it</th><th>Location</th></tr>')
                foreach($c in $Report){ [void]$h.AppendLine("<tr><td>$(& $e $c.Name)</td><td class=""n"">$(& $e (Format-Size $c.Size))</td><td>$(& $e $c.Note)</td><td class=""paths"">$(& $e (@($c.Paths) -join ' | '))</td></tr>") }
                [void]$h.AppendLine('</table>')
            }
            if($Security){
                [void]$h.AppendLine("<h2>Security check (heuristic: suspicious, review - not confirmed malware)</h2><p class=""meta"">$(@($Security.Items).Count) item(s) flagged.</p><table><tr><th>Level</th><th>Type</th><th>Name</th><th>Why</th><th>Path</th></tr>")
                foreach($x in @($Security.Items)){ [void]$h.AppendLine("<tr><td>$(& $e $x.Severity)</td><td>$(& $e $x.Type)</td><td>$(& $e $x.Name)</td><td>$(& $e $x.Reasons)</td><td class=""paths"">$(& $e $x.Path)</td></tr>") }
                [void]$h.AppendLine('</table>')
            }
            [void]$h.AppendLine('</body></html>')
            [IO.File]::WriteAllText($Path,$h.ToString(),(New-Object System.Text.UTF8Encoding($false)))
        }
        $res.Ok=$true; $res.Message="Report saved to $Path"
    }catch{ $res.Message='Could not save the report: ' + $_.Exception.Message }
    Write-CleanLog ("REPORT EXPORT ok={0} {1} :: {2}" -f $res.Ok,$Path,$res.Message)
    return $res
}
#endregion CORE

# ================================================================ GUI
trap {
    Write-CleanLog "CRASH: $($_.Exception.Message)"
    Write-CleanLog "AT: line $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())"
    Write-CleanLog "STACK: $($_.ScriptStackTrace)"
    try { [System.Windows.Forms.MessageBox]::Show("An error occurred. Details written to:`n$script:LogPath","Clean PC error",'OK','Error') | Out-Null } catch {}
    continue
}
Write-CleanLog ("=== Run start (GUI v$script:AppVersion) === admin=$(Is-Admin) os=$([System.Environment]::OSVersion.Version) host=$([System.Environment]::MachineName)")
$script:appIcon = $null
try { $script:appIcon = [System.Drawing.Icon]::ExtractAssociatedIcon([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) } catch {}

$script:Scanning=$false; $script:closeAfterScan=$false; $script:cancelRequested=$false
$fontUI = New-Object System.Drawing.Font('Segoe UI',9)
$fontBold = New-Object System.Drawing.Font('Segoe UI',9,[System.Drawing.FontStyle]::Bold)

$form=New-Object System.Windows.Forms.Form
$form.Text="Clean PC v$script:AppVersion - choose what to delete"
$form.StartPosition='CenterScreen'; $form.Width=940; $form.Height=720; $form.MinimumSize=New-Object System.Drawing.Size(780,600)
if ($script:appIcon) { $form.Icon = $script:appIcon }

# Header lives in its own docked Top panel so it can never overlap the list.
$headerPanel=New-Object System.Windows.Forms.Panel; $headerPanel.Dock='Top'; $headerPanel.Height=44
$header=New-Object System.Windows.Forms.Label
$header.Text="Tick the items you want to delete, then press 'Clean Selected'. Only cache/temp data is listed; risky items start unticked."
$header.Dock='Fill'; $header.TextAlign='MiddleLeft'; $header.Padding=New-Object System.Windows.Forms.Padding(10,0,10,0)
$header.Font=$fontUI
$headerPanel.Controls.Add($header)
$btnUpdate=New-Object System.Windows.Forms.Button; $btnUpdate.Text='Check for updates'; $btnUpdate.Dock='Right'; $btnUpdate.Width=140; $btnUpdate.Font=$fontUI
$headerPanel.Controls.Add($btnUpdate)

# Drive selection (one box per fixed local drive + All drives)
$drivePanel=New-Object System.Windows.Forms.Panel; $drivePanel.Dock='Top'; $drivePanel.Height=62
$driveFlow=New-Object System.Windows.Forms.FlowLayoutPanel; $driveFlow.Dock='Fill'; $driveFlow.WrapContents=$true; $driveFlow.Padding=New-Object System.Windows.Forms.Padding(8,4,8,0)
$lblDrives=New-Object System.Windows.Forms.Label; $lblDrives.Text='Drives to scan:'; $lblDrives.AutoSize=$true; $lblDrives.Font=$fontBold; $lblDrives.Margin=New-Object System.Windows.Forms.Padding(4,6,8,0)
$driveFlow.Controls.Add($lblDrives)
$script:driveBoxes=@(); $script:updatingBoxes=$false
$sysDrive=$env:SystemDrive.ToUpper()
$cbAll=New-Object System.Windows.Forms.CheckBox; $cbAll.Text='All drives'; $cbAll.AutoSize=$true; $cbAll.Font=$fontBold; $cbAll.Margin=New-Object System.Windows.Forms.Padding(4,3,14,0)
foreach($d in @(Get-FixedDrives)){
    $cb=New-Object System.Windows.Forms.CheckBox; $cb.AutoSize=$true; $cb.Tag=$d.Letter; $cb.Margin=New-Object System.Windows.Forms.Padding(4,3,12,0)
    $nm= if($d.Label){ " $($d.Label)" }else{ '' }
    $cb.Text = "{0}{1}  ({2} free of {3})" -f $d.Letter,$nm,(Format-Size $d.Free),(Format-Size $d.Size)
    $cb.Checked = ($d.Letter -eq $sysDrive)
    $cb.Add_CheckedChanged({ if(-not $script:updatingBoxes){ $script:updatingBoxes=$true; $cbAll.Checked = (@($script:driveBoxes | Where-Object { -not $_.Checked }).Count -eq 0); $script:updatingBoxes=$false } })
    $script:driveBoxes += $cb
}
$cbAll.Add_CheckedChanged({ if(-not $script:updatingBoxes){ $script:updatingBoxes=$true; foreach($b in $script:driveBoxes){ $b.Checked=$cbAll.Checked }; $script:updatingBoxes=$false } })
$driveFlow.Controls.Add($cbAll)
foreach($b in $script:driveBoxes){ $driveFlow.Controls.Add($b) }
$btnRescan=New-Object System.Windows.Forms.Button; $btnRescan.Text='Rescan'; $btnRescan.Width=80; $btnRescan.Height=26
$btnStop=New-Object System.Windows.Forms.Button; $btnStop.Text='Stop scan'; $btnStop.Width=80; $btnStop.Height=26; $btnStop.Visible=$false
$driveFlow.Controls.Add($btnRescan); $driveFlow.Controls.Add($btnStop)
$drivePanel.Controls.Add($driveFlow)

# Tabs live in a Fill panel with top padding -> guaranteed gap below the header.
$lvHost=New-Object System.Windows.Forms.Panel; $lvHost.Dock='Fill'; $lvHost.Padding=New-Object System.Windows.Forms.Padding(0,4,0,0)
$tabs=New-Object System.Windows.Forms.TabControl; $tabs.Dock='Fill'; $tabs.Font=$fontUI
$tpClean=New-Object System.Windows.Forms.TabPage 'Cleanup'
$tpRep=New-Object System.Windows.Forms.TabPage 'Report only'
$tpProf=New-Object System.Windows.Forms.TabPage 'Other user profiles (opt-in)'
$tpSec=New-Object System.Windows.Forms.TabPage 'Security check'
$tabs.TabPages.AddRange(@($tpClean,$tpRep,$tpProf,$tpSec))

function New-LV([bool]$checks){
    $x=New-Object System.Windows.Forms.ListView
    $x.View='Details'; $x.CheckBoxes=$checks; $x.FullRowSelect=$true; $x.GridLines=$true; $x.Dock='Fill'; $x.Font=$fontUI; $x.ShowItemToolTips=$true
    return $x
}
# --- Cleanup tab
$lv=New-LV $true
$lv.Columns.Add('Item',310)|Out-Null; $lv.Columns.Add('Size',85)|Out-Null; $lv.Columns.Add('Category',90)|Out-Null; $lv.Columns.Add('Items',55)|Out-Null; $lv.Columns.Add('Note (double-click a row to see every file/folder)',330)|Out-Null
$tpClean.Controls.Add($lv)
# --- Report tab
$lvR=New-LV $false
$lvR.Columns.Add('Item',280)|Out-Null; $lvR.Columns.Add('Size',85)|Out-Null; $lvR.Columns.Add('Location',280)|Out-Null; $lvR.Columns.Add('How to deal with it (this tool will NOT delete these)',520)|Out-Null
$lblRep=New-Object System.Windows.Forms.Label; $lblRep.Dock='Top'; $lblRep.Height=34; $lblRep.Padding=New-Object System.Windows.Forms.Padding(8,6,8,0)
$lblRep.Text='Information only. Large virtual disks, shadow copies / System Restore and installed Node versions cannot be deleted from here.'
$tpRep.Controls.Add($lvR); $tpRep.Controls.Add($lblRep)
# --- Profiles tab
$lvP=New-LV $true
$lvP.Columns.Add('Profile',200)|Out-Null; $lvP.Columns.Add('Size',90)|Out-Null; $lvP.Columns.Add('Last used',140)|Out-Null; $lvP.Columns.Add('Location',420)|Out-Null
$lblProf=New-Object System.Windows.Forms.Label; $lblProf.Dock='Top'; $lblProf.Height=78; $lblProf.Padding=New-Object System.Windows.Forms.Padding(8,6,8,0); $lblProf.ForeColor=[System.Drawing.Color]::DarkRed
$lblProf.Text="DANGER ZONE - optional. Lists OTHER Windows user accounts' profiles (never the one you are logged in as, never system/Default/Public/Administrator, never a loaded profile). Deleting a profile permanently removes that user's documents, desktop, pictures and settings. Untick = untouched (default). You must type the profile name to confirm."
$pnlProf=New-Object System.Windows.Forms.Panel; $pnlProf.Dock='Bottom'; $pnlProf.Height=44
$btnDelProf=New-Object System.Windows.Forms.Button; $btnDelProf.Text='Delete ticked profile(s)...'; $btnDelProf.Width=190; $btnDelProf.Height=30; $btnDelProf.Left=8; $btnDelProf.Top=6
$pnlProf.Controls.Add($btnDelProf)
$tpProf.Controls.Add($lvP); $tpProf.Controls.Add($lblProf); $tpProf.Controls.Add($pnlProf)
# --- Security tab
$lvS=New-LV $false
$lvS.Columns.Add('Level',60)|Out-Null; $lvS.Columns.Add('Type',65)|Out-Null; $lvS.Columns.Add('Name',190)|Out-Null; $lvS.Columns.Add('PID',50)|Out-Null; $lvS.Columns.Add('Signature',90)|Out-Null; $lvS.Columns.Add('Why it is flagged (suspicious, review)',360)|Out-Null; $lvS.Columns.Add('Path',380)|Out-Null
$pnlSecTop=New-Object System.Windows.Forms.Panel; $pnlSecTop.Dock='Top'; $pnlSecTop.Height=74
$lblSec=New-Object System.Windows.Forms.Label; $lblSec.Left=8; $lblSec.Top=4; $lblSec.Width=880; $lblSec.Height=36; $lblSec.Anchor='Top,Left,Right'
$lblSec.Text='READ-ONLY heuristic check. Results are "suspicious, review" - NOT confirmed malware. This tool never kills or deletes anything here. Many unsigned developer tools and games will appear.'
$btnSec=New-Object System.Windows.Forms.Button; $btnSec.Text='Run security check'; $btnSec.Left=8; $btnSec.Top=40; $btnSec.Width=150; $btnSec.Height=28
$btnOpenLoc=New-Object System.Windows.Forms.Button; $btnOpenLoc.Text='Open file location'; $btnOpenLoc.Left=166; $btnOpenLoc.Top=40; $btnOpenLoc.Width=150; $btnOpenLoc.Height=28
$lblSecStatus=New-Object System.Windows.Forms.Label; $lblSecStatus.Left=326; $lblSecStatus.Top=45; $lblSecStatus.Width=560; $lblSecStatus.ForeColor=[System.Drawing.Color]::DimGray
$pnlSecTop.Controls.AddRange(@($lblSec,$btnSec,$btnOpenLoc,$lblSecStatus))
$txtDef=New-Object System.Windows.Forms.TextBox; $txtDef.Multiline=$true; $txtDef.ReadOnly=$true; $txtDef.Dock='Bottom'; $txtDef.Height=96; $txtDef.ScrollBars='Vertical'; $txtDef.Font=$fontUI
$txtDef.Text='Run the security check to see Windows Defender status and a scan recommendation.'
$tpSec.Controls.Add($lvS); $tpSec.Controls.Add($pnlSecTop); $tpSec.Controls.Add($txtDef)

$lvHost.Controls.Add($tabs)

$panel=New-Object System.Windows.Forms.Panel; $panel.Dock='Bottom'; $panel.Height=128

# WinForms dock resolves by z-order: the Fill control must be added FIRST
# (lowest z-order), then the Top/Bottom panels, so Fill takes the leftover space.
$form.Controls.Add($lvHost)
$form.Controls.Add($drivePanel)
$form.Controls.Add($headerPanel)
$form.Controls.Add($panel)

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

$btnAll=New-Object System.Windows.Forms.Button; $btnAll.Text='Select safe'; $btnAll.Width=90; $btnAll.Height=34; $btnAll.Left=12; $btnAll.Top=82
$btnAll.Add_Click({ foreach($i in $lv.Items){ $i.Checked=[bool]$i.Tag.Checked } })
$btnNone=New-Object System.Windows.Forms.Button; $btnNone.Text='Select none'; $btnNone.Width=90; $btnNone.Height=34; $btnNone.Left=110; $btnNone.Top=82
$btnNone.Add_Click({ foreach($i in $lv.Items){$i.Checked=$false} })
$btnClean=New-Object System.Windows.Forms.Button; $btnClean.Text='Clean Selected'; $btnClean.Width=140; $btnClean.Height=34; $btnClean.Top=82
$btnClean.Font=$fontBold
$btnClose=New-Object System.Windows.Forms.Button; $btnClose.Text='Close'; $btnClose.Width=90; $btnClose.Height=34; $btnClose.Top=82
$btnClose.Add_Click({ $form.Close() })
# Cancel: only visible while cleaning; sets a flag the loop checks between items (never mid-delete).
$btnCancel=New-Object System.Windows.Forms.Button; $btnCancel.Text='Cancel'; $btnCancel.Width=90; $btnCancel.Height=34; $btnCancel.Top=82; $btnCancel.Visible=$false
$btnCancel.Add_Click({ $script:cancelRequested=$true; $btnCancel.Enabled=$false; $status.Text='Cancelling after current item...' })
$btnExport=New-Object System.Windows.Forms.Button; $btnExport.Text='Export report'; $btnExport.Width=110; $btnExport.Height=34; $btnExport.Left=208; $btnExport.Top=82
$cbRestore=New-Object System.Windows.Forms.CheckBox; $cbRestore.Text='Create a System Restore point before cleaning'; $cbRestore.AutoSize=$true; $cbRestore.Left=12; $cbRestore.Top=54; $cbRestore.Checked=$false; $cbRestore.Font=$fontUI
$panel.Controls.AddRange(@($btnAll,$btnNone,$btnExport,$cbRestore,$btnClean,$btnClose,$btnCancel))
$panel.Add_Resize({ $btnClose.Left=$panel.Width-104; $btnCancel.Left=$panel.Width-104; $btnClean.Left=$panel.Width-252 })
$btnClose.Left=$form.Width-120; $btnCancel.Left=$form.Width-120; $btnClean.Left=$form.Width-268

# ---------------------------------------------------------------- dialogs
function Show-Details($t){
    $f=New-Object System.Windows.Forms.Form; $f.Text="Everything in: $($t.Name)"; $f.StartPosition='CenterParent'; $f.Width=820; $f.Height=520
    $lab=New-Object System.Windows.Forms.Label; $lab.Dock='Top'; $lab.Height=44; $lab.Padding=New-Object System.Windows.Forms.Padding(8,6,8,0)
    $paths=@($t.Paths); $more=''
    if($paths.Count -gt 3000){ $more="`r`n... and $($paths.Count-3000) more"; $paths=$paths[0..2999] }
    $what= if($t.Kind -eq 'Files'){ 'files' }elseif($t.Kind -eq 'RemoveDirs'){ 'folders (removed completely)' }else{ 'folders (only their CONTENTS are deleted)' }
    $lab.Text="$(@($t.Paths).Count) $what - total $(Format-Size $t.Size). Nothing is deleted from this window."
    $tb=New-Object System.Windows.Forms.TextBox; $tb.Multiline=$true; $tb.ReadOnly=$true; $tb.ScrollBars='Both'; $tb.WordWrap=$false; $tb.Dock='Fill'; $tb.Font=New-Object System.Drawing.Font('Consolas',9)
    $tb.Text=(($paths -join "`r`n") + $more)
    $f.Controls.Add($tb); $f.Controls.Add($lab)
    [void]$f.ShowDialog($form); $f.Dispose()
}
# Typed confirmation: OK is only enabled when the exact profile name has been typed.
function Confirm-TypedName([string]$title,[string]$message,[string]$expected){
    $f=New-Object System.Windows.Forms.Form; $f.Text=$title; $f.StartPosition='CenterParent'; $f.Width=560; $f.Height=250; $f.FormBorderStyle='FixedDialog'; $f.MaximizeBox=$false; $f.MinimizeBox=$false
    $l=New-Object System.Windows.Forms.Label; $l.Left=12; $l.Top=10; $l.Width=520; $l.Height=110; $l.Text=$message
    $t=New-Object System.Windows.Forms.TextBox; $t.Left=12; $t.Top=128; $t.Width=520
    $ok=New-Object System.Windows.Forms.Button; $ok.Text='Delete this profile'; $ok.Left=300; $ok.Top=165; $ok.Width=140; $ok.Height=30; $ok.Enabled=$false; $ok.DialogResult='OK'
    $no=New-Object System.Windows.Forms.Button; $no.Text='Cancel'; $no.Left=450; $no.Top=165; $no.Width=82; $no.Height=30; $no.DialogResult='Cancel'
    $t.Add_TextChanged({ $ok.Enabled = ($t.Text.Trim() -ieq $expected) })
    $f.Controls.AddRange(@($l,$t,$ok,$no)); $f.CancelButton=$no
    $r=$f.ShowDialog($form); $f.Dispose()
    return ($r -eq 'OK')
}

# ---------------------------------------------------------------- update checker / download dialogs (only on click)
# Generic Keep/Delete style dialog: returns the text of the clicked button, or $null if closed with X.
function Show-ChoiceDialog([string]$title,[string]$message,[string[]]$buttons){
    $script:choiceResult=$null
    $f=New-Object System.Windows.Forms.Form; $f.Text=$title; $f.StartPosition='CenterParent'; $f.FormBorderStyle='FixedDialog'; $f.MaximizeBox=$false; $f.MinimizeBox=$false; $f.ShowInTaskbar=$false
    $f.ClientSize=New-Object System.Drawing.Size(560,170)
    if($script:appIcon){ $f.Icon=$script:appIcon }
    $l=New-Object System.Windows.Forms.Label; $l.Left=14; $l.Top=12; $l.Width=530; $l.Height=100; $l.Text=$message; $l.Font=$fontUI
    $f.Controls.Add($l)
    $x=546
    for($i=$buttons.Count-1;$i -ge 0;$i--){
        $b=New-Object System.Windows.Forms.Button; $b.Text=$buttons[$i]; $b.Height=30
        $b.Width=[Math]::Max(90,[int]($buttons[$i].Length*7.5+24)); $x-=($b.Width+8); $b.Left=$x; $b.Top=126
        $b.Add_Click({ param($s,$e) $script:choiceResult=$s.Text; $s.FindForm().Close() })
        $f.Controls.Add($b)
    }
    [void]$f.ShowDialog($form); $f.Dispose()
    return $script:choiceResult
}

# After a successful download: ask whether to keep or delete the old installer (the exe this program runs from).
function Invoke-OldInstallerPrompt([string]$newFile){
    $self=Get-SelfPath
    if(-not $self -or [IO.Path]::GetExtension($self) -ine '.exe'){ Write-CleanLog 'OLD INSTALLER prompt skipped: running from a script, not an exe'; return }
    $chk=Test-SafeInstallerDelete $self $newFile $null
    if(-not $chk.Ok){ Write-CleanLog "OLD INSTALLER prompt skipped ($($chk.Why)): $self"; return }
    $c=Show-ChoiceDialog 'Old installer' "Do you want to keep the old installer or delete it?`n`nOld (this program, v$script:AppVersion):`n$self`n`nNew:`n$newFile" @('Keep','Delete')
    if($c -ne 'Delete'){ Write-CleanLog "OLD INSTALLER kept by user: $self"; return }
    Write-PendingDelete $self $script:AppVersion $newFile | Out-Null
    $c2=Show-ChoiceDialog 'Delete old installer' "A running program cannot delete itself. Delete it automatically right after you close this program?`n`nOnly this one file will be deleted:`n$self`n`nIf you choose 'Ask later', you will be asked once more when the new version starts." @('Delete when I close this program','Ask later')
    if($c2 -like 'Delete when*'){
        if(Start-DeferredDelete $self $newFile){ [System.Windows.Forms.MessageBox]::Show("Scheduled. The old file will be deleted as soon as you close this program (a hidden helper retries for up to 10 minutes).","Old installer",'OK','Information')|Out-Null }
        else { [System.Windows.Forms.MessageBox]::Show("Could not schedule the deletion. You will be asked again when the new version starts.","Old installer",'OK','Warning')|Out-Null }
    }
}

# New version, first launch: a marker from the previous version says the user wanted the old exe deleted (or undecided).
function Invoke-StartupInstallerPrompt{
    try{
        $p=Get-PendingDelete
        if(-not $p){ return }
        Write-CleanLog "STARTUP: pending old installer $($p.Old) (v$($p.OldVersion))"
        $c=Show-ChoiceDialog 'Old installer' "Do you want to keep the old installer or delete it?`n`nOld (v$($p.OldVersion)):`n$($p.Old)`n`nOnly this one file would be deleted." @('Keep','Delete')
        if($c -eq 'Delete'){
            if(Remove-OldInstaller $p.Old $p.New $p.New -RequireOurName){ [System.Windows.Forms.MessageBox]::Show("Old installer deleted.","Old installer",'OK','Information')|Out-Null }
            else { [System.Windows.Forms.MessageBox]::Show("Could not delete it (it may still be running). See the log.","Old installer",'OK','Warning')|Out-Null }
        } else { Write-CleanLog "OLD INSTALLER kept by user: $($p.Old)" }
        if($c){ Clear-PendingDelete }
    }catch{ Write-CleanLog "STARTUP installer prompt error: $($_.Exception.Message)" }
}

function Show-DownloadDialog($info){
    $title= if($info.Channel -eq 'Pro'){ 'Upgrade to Pro (free) - download' }else{ 'Download update' }
    $tag=($info.Tag -replace '[^A-Za-z0-9._-]','')
    $fileName="$([IO.Path]::GetFileNameWithoutExtension($info.AssetName))-$tag.exe"
    if(-not (Test-AllowedDownloadUrl $info.AssetUrl)){ [System.Windows.Forms.MessageBox]::Show("The download address is not an official GitHub release link, so it was blocked.","Download",'OK','Warning')|Out-Null; return }
    $script:dlBusy=$false; $script:dlObj=$null; $script:dlFolder2=$null
    $f=New-Object System.Windows.Forms.Form; $f.Text=$title; $f.StartPosition='CenterParent'; $f.FormBorderStyle='FixedDialog'; $f.MaximizeBox=$false; $f.MinimizeBox=$false; $f.ShowInTaskbar=$false
    $f.ClientSize=New-Object System.Drawing.Size(600,360); if($script:appIcon){ $f.Icon=$script:appIcon }
    $lInfo=New-Object System.Windows.Forms.Label; $lInfo.Left=14; $lInfo.Top=10; $lInfo.Width=572; $lInfo.Height=40; $lInfo.Font=$fontBold
    $lInfo.Text="$($info.AssetName) $($info.Tag)  ($(Format-Size $info.AssetSize))`nSaved as: $fileName   - never run or replaced automatically."
    $rb1=New-Object System.Windows.Forms.RadioButton; $rb1.Text='Same drive as this program (folder of the running exe/script)'; $rb1.Left=14; $rb1.Top=58; $rb1.Width=570; $rb1.Checked=$true
    $rb2=New-Object System.Windows.Forms.RadioButton; $rb2.Text='Another drive/folder'; $rb2.Left=14; $rb2.Top=84; $rb2.Width=200
    $btnBr=New-Object System.Windows.Forms.Button; $btnBr.Text='Choose drive/folder...'; $btnBr.Left=220; $btnBr.Top=80; $btnBr.Width=170; $btnBr.Height=26; $btnBr.Enabled=$false
    $dv=@(Get-FixedDrives | ForEach-Object { "$($_.Letter) $(Format-Size $_.Free) free" }) -join '   |   '
    $lDrv=New-Object System.Windows.Forms.Label; $lDrv.Left=34; $lDrv.Top=112; $lDrv.Width=552; $lDrv.Height=34; $lDrv.ForeColor=[System.Drawing.Color]::DimGray; $lDrv.Text="Fixed drives: $dv"
    $lTgt=New-Object System.Windows.Forms.Label; $lTgt.Left=14; $lTgt.Top=152; $lTgt.Width=572; $lTgt.Height=36; $lTgt.Font=$fontUI
    $lSpc=New-Object System.Windows.Forms.Label; $lSpc.Left=14; $lSpc.Top=190; $lSpc.Width=572; $lSpc.Height=34
    $pb=New-Object System.Windows.Forms.ProgressBar; $pb.Left=14; $pb.Top=232; $pb.Width=572; $pb.Height=22; $pb.Minimum=0; $pb.Maximum=1000
    $lPrg=New-Object System.Windows.Forms.Label; $lPrg.Left=14; $lPrg.Top=258; $lPrg.Width=572; $lPrg.Height=40
    $btnGo=New-Object System.Windows.Forms.Button; $btnGo.Text='Download'; $btnGo.Left=300; $btnGo.Top=312; $btnGo.Width=130; $btnGo.Height=32; $btnGo.Font=$fontBold
    $btnNo=New-Object System.Windows.Forms.Button; $btnNo.Text='Cancel'; $btnNo.Left=446; $btnNo.Top=312; $btnNo.Width=140; $btnNo.Height=32
    $f.Controls.AddRange(@($lInfo,$rb1,$rb2,$btnBr,$lDrv,$lTgt,$lSpc,$pb,$lPrg,$btnGo,$btnNo))
    $refresh={
        $folder = if($rb1.Checked){ Get-AppFolder } else { $script:dlFolder2 }
        if(-not $folder){ $lTgt.Text='Target folder: (choose a drive/folder)'; $lSpc.Text=''; $btnGo.Enabled=$false; return }
        $lTgt.Text="Target folder: $folder"
        $sp=Test-DownloadSpace $folder $info.AssetSize
        if($sp.Ok){ $lSpc.ForeColor=[System.Drawing.Color]::DarkGreen; $lSpc.Text="Free space OK: $(Format-Size $sp.Free) free, $(Format-Size $sp.Need) needed (file + margin)." }
        else{ $lSpc.ForeColor=[System.Drawing.Color]::DarkRed; $lSpc.Text=$sp.Message }
        $btnGo.Enabled=$sp.Ok
    }
    $rb1.Add_CheckedChanged({ $btnBr.Enabled=$rb2.Checked; & $refresh })
    $btnBr.Add_Click({
        $fb=New-Object System.Windows.Forms.FolderBrowserDialog; $fb.Description='Choose a folder on a local drive for the download'; $fb.ShowNewFolderButton=$true
        if($script:dlFolder2){ $fb.SelectedPath=$script:dlFolder2 }
        if($fb.ShowDialog($f) -eq 'OK'){ $script:dlFolder2=$fb.SelectedPath }
        & $refresh
    })
    $btnNo.Add_Click({ if($script:dlBusy -and $script:dlObj){ $script:dlObj.Cancel=$true; $btnNo.Enabled=$false; $lPrg.Text='Cancelling...' } else { $f.Close() } })
    $f.Add_FormClosing({ if($script:dlBusy){ $_.Cancel=$true; if($script:dlObj){ $script:dlObj.Cancel=$true }; $lPrg.Text='Cancelling...' } })
    $btnGo.Add_Click({
        $folder = if($rb1.Checked){ Get-AppFolder } else { $script:dlFolder2 }
        if(-not $folder){ return }
        try{ if(-not (Test-Path -LiteralPath $folder)){ New-Item -ItemType Directory -Path $folder -Force -EA Stop | Out-Null } }catch{ [System.Windows.Forms.MessageBox]::Show("Cannot use that folder: $($_.Exception.Message)","Download",'OK','Warning')|Out-Null; return }
        $sp=Test-DownloadSpace $folder $info.AssetSize
        if(-not $sp.Ok){ [System.Windows.Forms.MessageBox]::Show($sp.Message,"Download",'OK','Warning')|Out-Null; return }
        $final=Join-Path $folder $fileName
        $selfp=Get-SelfPath
        $overwrite=$false
        if(Test-Path -LiteralPath $final){
            if($selfp -and ($final -ieq $selfp)){ $final=Join-Path $folder ("{0}-new{1}" -f [IO.Path]::GetFileNameWithoutExtension($fileName),'.exe') }
            if(Test-Path -LiteralPath $final){
                $a=[System.Windows.Forms.MessageBox]::Show("A file named`n$final`nalready exists. Replace it?","File exists",'YesNo','Warning')
                if($a -ne 'Yes'){ return }
                $overwrite=$true
            }
        }
        $part="$final.part"
        $script:dlBusy=$true; $btnGo.Enabled=$false; $rb1.Enabled=$false; $rb2.Enabled=$false; $btnBr.Enabled=$false
        Write-CleanLog "DOWNLOAD start $($info.AssetUrl) -> $final ($(Format-Size $info.AssetSize))"
        $dl=New-Object CleanDownloader; $script:dlObj=$dl
        Enable-Tls12
        $dl.Start($info.AssetUrl,"CleanPC/$script:AppVersion",$part,20000)
        while(-not $dl.Done){
            $tot= if($dl.Total -gt 0){ $dl.Total }else{ $info.AssetSize }
            if($tot -gt 0){ $pb.Value=[int][Math]::Min(1000,[Math]::Floor(1000.0*$dl.BytesDone/$tot)) }
            $lPrg.Text="Downloading... $(Format-Size $dl.BytesDone) of $(Format-Size $tot)"
            [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 60
        }
        $script:dlBusy=$false
        if(-not $dl.Ok){
            Remove-Item -LiteralPath $part -Force -EA SilentlyContinue
            $why= if($dl.Error -eq 'cancelled'){ 'Download cancelled. The partial file was removed.' }else{ "Download failed: $($dl.Error). The partial file was removed." }
            Write-CleanLog "DOWNLOAD failed/cancelled: $($dl.Error)"
            $lPrg.Text=$why; $pb.Value=0; $btnGo.Enabled=$true; $btnNo.Enabled=$true; $rb1.Enabled=$true; $rb2.Enabled=$true; $btnBr.Enabled=$rb2.Checked
            return
        }
        $lPrg.Text='Verifying...'; [System.Windows.Forms.Application]::DoEvents()
        $fin=Complete-Download $part $final $info.AssetSize $info.AssetSha256 $overwrite
        if(-not $fin.Ok){
            [System.Windows.Forms.MessageBox]::Show($fin.Message,"Download",'OK','Warning')|Out-Null
            $lPrg.Text=$fin.Message; $pb.Value=0; $btnGo.Enabled=$true; $btnNo.Enabled=$true; $rb1.Enabled=$true; $rb2.Enabled=$true; $btnBr.Enabled=$rb2.Checked
            return
        }
        $pb.Value=1000
        $chk= if($info.AssetSha256){ 'size and SHA-256 verified' }else{ 'size verified (no checksum published)' }
        $lPrg.Text="Done - $chk."
        $c=Show-ChoiceDialog 'Download complete' "Downloaded and verified ($chk):`n$final`n`nThe file has NOT been run. Start it yourself when you are ready." @('Open folder','Close')
        if($c -eq 'Open folder'){ try{ Start-Process explorer.exe -ArgumentList ('/select,"{0}"' -f $final) }catch{} }
        Invoke-OldInstallerPrompt $final
        $f.Close()
    })
    & $refresh
    [void]$f.ShowDialog($form); $f.Dispose()
}

function Show-UpdateDialog($all){
    $f=New-Object System.Windows.Forms.Form; $f.Text='Check for updates'; $f.StartPosition='CenterParent'; $f.FormBorderStyle='FixedDialog'; $f.MaximizeBox=$false; $f.MinimizeBox=$false; $f.ShowInTaskbar=$false
    $f.ClientSize=New-Object System.Drawing.Size(660,520); if($script:appIcon){ $f.Icon=$script:appIcon }
    $mk={
        param($top,$caption,$info,$isPro)
        $g=New-Object System.Windows.Forms.GroupBox; $g.Text=$caption; $g.Left=12; $g.Top=$top; $g.Width=636; $g.Height=222; $g.Font=$fontBold
        $st=New-Object System.Windows.Forms.Label; $st.Left=12; $st.Top=22; $st.Width=610; $st.Height=44; $st.Font=$fontUI
        $nt=New-Object System.Windows.Forms.TextBox; $nt.Left=12; $nt.Top=70; $nt.Width=610; $nt.Height=104; $nt.Multiline=$true; $nt.ReadOnly=$true; $nt.ScrollBars='Vertical'; $nt.Font=$fontUI
        $bd=New-Object System.Windows.Forms.Button; $bd.Left=12; $bd.Top=182; $bd.Width=170; $bd.Height=30; $bd.Text='Download...'; $bd.Font=$fontUI
        $bp=New-Object System.Windows.Forms.Button; $bp.Left=190; $bp.Top=182; $bp.Width=150; $bp.Height=30; $bp.Text='Open release page'; $bp.Font=$fontUI
        $nt.Visible=$false; $bd.Visible=$false; $bp.Visible=$false
        $note= if($info.Notes){ "Release notes:`r`n" + ($info.Notes -replace "`n","`r`n") }else{ '' }
        switch($info.State){
            'Newer'      { $st.Text="Version $($info.Tag) is available (you have v$script:AppVersion)."; $nt.Text=$note; $nt.Visible=$true; $bd.Visible=($info.AssetUrl -ne ''); $bp.Visible=$true }
            'UpToDate'   { $st.Text="You are up to date. Latest release: $($info.Tag), you have v$script:AppVersion." }
            'Available'  { $st.Text="Pro is a separate, fuller-featured app (free for you). Latest: $($info.Tag). It is downloaded as its own file and does not replace this program."; $nt.Text=$note; $nt.Visible=$true; $bd.Text='Download Pro...'; $bd.Visible=$true; $bp.Visible=$true }
            'NotReleased'{ $st.Text= if($isPro){ 'Pro edition not released yet. Nothing to download for now - check again later.' }else{ $info.Message } }
            default      { $st.Text="Could not check: $($info.Message)" }
        }
        $g.Controls.AddRange(@($st,$nt,$bd,$bp))
        $bd.Add_Click({ Show-DownloadDialog $info }.GetNewClosure())
        $bp.Add_Click({ try{ if($info.PageUrl -match '^https://github\.com/'){ Start-Process $info.PageUrl } }catch{} }.GetNewClosure())
        return $g
    }
    $g1 = & $mk 10  'Standard edition (this program)' $all.Standard $false
    $g2 = & $mk 240 'Upgrade to Pro (free)' $all.Pro $true
    $bc=New-Object System.Windows.Forms.Button; $bc.Text='Close'; $bc.Left=548; $bc.Top=480; $bc.Width=100; $bc.Height=30; $bc.DialogResult='Cancel'
    $lnote=New-Object System.Windows.Forms.Label; $lnote.Left=14; $lnote.Top=474; $lnote.Width=520; $lnote.Height=40; $lnote.ForeColor=[System.Drawing.Color]::DimGray
    $lnote.Text='Checked only because you clicked the button. Nothing is sent except a normal request to api.github.com; nothing is installed or run automatically.'
    $f.Controls.AddRange(@($g1,$g2,$lnote,$bc)); $f.CancelButton=$bc
    [void]$f.ShowDialog($form); $f.Dispose()
}

$btnUpdate.Add_Click({
    $btnUpdate.Enabled=$false; $old=$status.Text
    $status.Text='Checking GitHub for updates (you asked for this)...'
    $all=$null
    try{ $all=Get-AllUpdateInfo { [System.Windows.Forms.Application]::DoEvents() } }catch{ Write-CleanLog "UPDATE CHECK ERROR: $($_.Exception.Message)" }
    $status.Text=$old; $btnUpdate.Enabled=$true
    if(-not $all){ [System.Windows.Forms.MessageBox]::Show("The update check could not be completed. Please try again later.","Check for updates",'OK','Information')|Out-Null; return }
    Show-UpdateDialog $all
})

# ---------------------------------------------------------------- report export
$script:lastSecurity=$null
$btnExport.Add_Click({
    if($lv.Items.Count -eq 0 -and $lvR.Items.Count -eq 0){ [System.Windows.Forms.MessageBox]::Show("Nothing to export yet - wait for the scan to finish.","Export report",'OK','Information')|Out-Null; return }
    $sd=New-Object System.Windows.Forms.SaveFileDialog
    $sd.Title='Export scan report'; $sd.Filter='HTML report (*.html)|*.html|CSV spreadsheet (*.csv)|*.csv'; $sd.DefaultExt='html'; $sd.AddExtension=$true
    $sd.FileName='CleanPC-report-' + (Get-Date -Format 'yyyyMMdd-HHmm'); $sd.OverwritePrompt=$true
    if($sd.ShowDialog($form) -ne 'OK'){ return }
    $fmt= if($sd.FilterIndex -eq 2 -or [IO.Path]::GetExtension($sd.FileName) -ieq '.csv'){ 'csv' }else{ 'html' }
    $cl=@(); foreach($i in $lv.Items){ $t=$i.Tag; $cl += [PSCustomObject]@{ Name=$t.Name; Category=$t.Category; Size=$t.Size; Paths=$t.Paths; Note=$t.Note; Ticked=[bool]$i.Checked } }
    $rp=@(); foreach($i in $lvR.Items){ $rp += $i.Tag }
    $dr=@(); foreach($b in $script:driveBoxes){ if($b.Checked){ $dr += $b.Tag } }
    $r=Export-CleanReport $sd.FileName $fmt $cl $rp $script:lastSecurity $dr
    if($r.Ok){
        $a=[System.Windows.Forms.MessageBox]::Show("$($r.Message)`n`nOpen it now?","Export report",'YesNo','Information')
        if($a -eq 'Yes'){ try{ Start-Process $sd.FileName }catch{} }
    } else { [System.Windows.Forms.MessageBox]::Show($r.Message,"Export report",'OK','Warning')|Out-Null }
})

# ---------------------------------------------------------------- scan
function Start-Scan{
    if($script:Scanning){ return }
    $drives=@(); foreach($b in $script:driveBoxes){ if($b.Checked){ $drives += $b.Tag } }
    if($drives.Count -eq 0){ [System.Windows.Forms.MessageBox]::Show("Tick at least one drive to scan.","Clean PC",'OK','Information')|Out-Null; return }
    $script:Scanning=$true; $script:ScanCancel=$false
    foreach($c in @($btnRescan,$btnClean,$btnAll,$btnNone,$btnDelProf,$btnSec,$btnExport)){ $c.Enabled=$false }
    foreach($b in $script:driveBoxes){ $b.Enabled=$false }; $cbAll.Enabled=$false
    $btnStop.Visible=$true; $btnStop.Enabled=$true; $btnRescan.Visible=$false
    $lv.Items.Clear(); $lvR.Items.Clear(); $lvP.Items.Clear()
    Write-CleanLog ("SCAN start drives=" + ($drives -join ','))
    $prog = { param($m) $status.Text=$m; [System.Windows.Forms.Application]::DoEvents() }
    $res=$null; $profs=@()
    try {
        $res = Build-Targets $drives $prog
        if($res -and -not $script:ScanCancel){ $profs = @(Get-OtherProfiles $drives $prog) }
    } catch { Write-CleanLog "SCAN ERROR: $($_.Exception.Message)" }
    if($res){
        foreach($t in ($res.Targets | Sort-Object @{e='Category'},@{e='Size';Descending=$true})){
            $it=New-Object System.Windows.Forms.ListViewItem($t.Name)
            $it.SubItems.Add((Format-Size $t.Size))|Out-Null
            $it.SubItems.Add($t.Category)|Out-Null
            $it.SubItems.Add([string]@($t.Paths).Count)|Out-Null
            $it.SubItems.Add($t.Note)|Out-Null
            $it.ToolTipText = "$($t.Name)`n$($t.Note)`nDouble-click to list every file/folder."
            if(-not $t.Checked -and $t.Note -like 'RISKY*'){ $it.ForeColor=[System.Drawing.Color]::DarkRed }
            $it.Checked=[bool]$t.Checked
            $it.Tag=$t
            $lv.Items.Add($it)|Out-Null
            Write-CleanLog ("FOUND {0,12}  {1}  [{2}]{3}" -f (Format-Size $t.Size),$t.Name,$t.Category,$(if($t.Checked){''}else{'  (unticked)'}))
        }
        foreach($t in ($res.Report | Sort-Object @{e='Size';Descending=$true})){
            $it=New-Object System.Windows.Forms.ListViewItem($t.Name)
            $it.SubItems.Add((Format-Size $t.Size))|Out-Null
            $it.SubItems.Add((@($t.Paths) -join '; '))|Out-Null
            $it.SubItems.Add($t.Note)|Out-Null
            $it.ToolTipText=$t.Note
            $it.Tag=$t
            $lvR.Items.Add($it)|Out-Null
            Write-CleanLog ("REPORT {0,12}  {1}" -f (Format-Size $t.Size),$t.Name)
        }
        $tpRep.Text = "Report only ($($lvR.Items.Count))"
        $msg = "Scan finished: $($lv.Items.Count) cleanup items, $($res.Info.DirsVisited) folders searched."
        if($res.Info.WalkTimedOut){ $msg += ' Drive scan hit its time limit - some folders were not searched.' }
        if($res.Info.WalkCancelled){ $msg += ' Drive scan was stopped early.' }
        $status.Text=$msg
    } else { $status.Text='Scan failed - see log.' }
    foreach($p in $profs){
        $it=New-Object System.Windows.Forms.ListViewItem($p.Name)
        $it.SubItems.Add((Format-Size $p.Size))|Out-Null
        $it.SubItems.Add($(if($p.LastUse){ ([datetime]$p.LastUse).ToString('yyyy-MM-dd') }else{ '' }))|Out-Null
        $it.SubItems.Add($p.Path)|Out-Null
        $it.Tag=$p; $it.Checked=$false
        $lvP.Items.Add($it)|Out-Null
        Write-CleanLog ("PROFILE listed (unticked) {0}  {1}" -f (Format-Size $p.Size),$p.Path)
    }
    $tpProf.Text = "Other user profiles (opt-in) ($($lvP.Items.Count))"
    $btnStop.Visible=$false; $btnRescan.Visible=$true
    foreach($c in @($btnRescan,$btnClean,$btnAll,$btnNone,$btnDelProf,$btnSec,$btnExport)){ $c.Enabled=$true }
    foreach($b in $script:driveBoxes){ $b.Enabled=$true }; $cbAll.Enabled=$true
    $script:Scanning=$false
    Update-Total
    $lblTotal.Refresh()
}
$btnRescan.Add_Click({ Start-Scan })
$btnStop.Add_Click({ $script:ScanCancel=$true; $btnStop.Enabled=$false; $status.Text='Stopping the drive scan (keeps what was found)...' })
$form.Add_FormClosing({
    if($script:Scanning){ $script:ScanCancel=$true; $script:closeAfterScan=$true; $_.Cancel=$true; $status.Text='Stopping scan, window will close...' }
})
$form.Add_Shown({ Invoke-StartupInstallerPrompt; Start-Scan; if($script:closeAfterScan){ $form.Close() } })

$lv.Add_DoubleClick({ if($lv.SelectedItems.Count -gt 0){ Show-Details $lv.SelectedItems[0].Tag } })
$lvR.Add_DoubleClick({ if($lvR.SelectedItems.Count -gt 0 -and @($lvR.SelectedItems[0].Tag.Paths).Count -gt 0){ Show-Details $lvR.SelectedItems[0].Tag } })

# ---------------------------------------------------------------- clean
$btnClean.Add_Click({
    $chosen=@(); foreach($i in $lv.Items){ if($i.Checked){ $chosen += $i } }
    if($chosen.Count -eq 0){ [System.Windows.Forms.MessageBox]::Show("Nothing selected.","Clean PC",'OK','Information')|Out-Null; return }
    # items that are normally unticked (flagged risky) -> explicit confirmation listing them
    $risky=@($chosen | Where-Object { -not $_.Tag.Checked })
    if($risky.Count -gt 0){
        $names=($risky | ForEach-Object { " - $($_.Tag.Name)  ($(Format-Size $_.Tag.Size))" }) -join "`n"
        $r=[System.Windows.Forms.MessageBox]::Show("You ticked item(s) that are NOT selected by default because they carry some risk:`n`n$names`n`nThey will be deleted permanently (not sent to the Recycle Bin). Continue?","Confirm risky items",'YesNo','Warning')
        if($r -ne 'Yes'){ return }
    }
    $cv = $chosen | Where-Object { $_.Tag.Name -like 'Claude*' }
    if($cv -and (Get-Process -Name 'claude' -EA SilentlyContinue)){
        $r=[System.Windows.Forms.MessageBox]::Show("Claude Desktop is running, so its VM cache can't be fully freed. Close Claude Desktop first for that item.`n`nContinue with the rest now?","Claude Desktop is open",'OKCancel','Warning')
        if($r -eq 'Cancel'){ return }
    }
    if($cbRestore.Checked){
        $status.Text='Creating a System Restore point (this can take a minute)...'; $status.Refresh(); [System.Windows.Forms.Application]::DoEvents()
        $form.Cursor='WaitCursor'; $rp=New-CleanRestorePoint; $form.Cursor='Default'
        if($rp.Status -eq 'Created'){ $status.Text='Restore point created.' }
        elseif($rp.Status -eq 'Skipped24h'){ [System.Windows.Forms.MessageBox]::Show($rp.Message,"Restore point",'OK','Information')|Out-Null }
        else{
            $r=[System.Windows.Forms.MessageBox]::Show("No restore point was created: $($rp.Message)`n`nClean WITHOUT a restore point?","Restore point",'YesNo','Warning')
            if($r -ne 'Yes'){ $status.Text='Cleaning cancelled (no restore point).'; Write-CleanLog 'CLEAN cancelled: restore point not created and user declined'; return }
        }
    }
    $btnClean.Enabled=$false; $btnAll.Enabled=$false; $btnNone.Enabled=$false; $btnRescan.Enabled=$false
    $script:cancelRequested=$false; $btnCancel.Enabled=$true; $btnCancel.Visible=$true; $btnClose.Visible=$false
    $freed=[int64]0; $n=0; $cancelled=$false
    foreach($i in $chosen){
        if($script:cancelRequested){ $cancelled=$true; Write-CleanLog "=== CANCELLED by user ==="; break }
        $n++; $status.Text="Cleaning ($n/$($chosen.Count)): $($i.Tag.Name)"; $status.Refresh(); [System.Windows.Forms.Application]::DoEvents()
        $before=[int64]$i.Tag.Size
        Write-CleanLog ("CLEAN {0}  [{1}]" -f $i.Tag.Name,($i.Tag.Paths -join ' | '))
        $df=[int64](Invoke-Clean $i.Tag)
        if($df -gt $before){ $df=$before }
        $freed+=$df
        Write-CleanLog ("FREED {0}  {1}" -f (Format-Size $df), $i.Tag.Name)
        $i.Tag.Size = $before-$df
        $i.SubItems[1].Text = (Format-Size $i.Tag.Size)
        $i.Checked=$false
    }
    $btnCancel.Visible=$false; $btnClose.Visible=$true
    $status.Text= if($cancelled){"Cancelled."}else{"Done."}
    Write-CleanLog ("=== TOTAL FREED {0} ===" -f (Format-Size $freed))
    $free=@(); foreach($b in $script:driveBoxes){ if($b.Checked){ $dl=$b.Tag; $di=New-Object System.IO.DriveInfo $dl; $free += ("{0} {1}" -f $dl,(Format-Size $di.AvailableFreeSpace)) } }
    $msg = if($cancelled){"Cancelled. Freed about {0} before stopping."}else{"Freed about {0}."}
    [System.Windows.Forms.MessageBox]::Show((($msg -f (Format-Size $freed)) + "`nFree space now: " + ($free -join ',  ')),"Cleanup complete",'OK','Information')|Out-Null
    $btnClean.Enabled=$true; $btnAll.Enabled=$true; $btnNone.Enabled=$true; $btnRescan.Enabled=$true
    Update-Total
})

# ---------------------------------------------------------------- profiles (explicit opt-in)
$btnDelProf.Add_Click({
    $sel=@(); foreach($i in $lvP.Items){ if($i.Checked){ $sel += $i } }
    if($sel.Count -eq 0){ [System.Windows.Forms.MessageBox]::Show("Tick the profile(s) you want to delete first.","Other user profiles",'OK','Information')|Out-Null; return }
    $deleted=0
    foreach($i in $sel){
        $p=$i.Tag
        $m="You are about to PERMANENTLY delete the Windows user profile:`n`n$($p.Path)   ($(Format-Size $p.Size))`n`nThis removes that user's documents, desktop, pictures, downloads and settings. It cannot be undone.`n`nType the profile name  $($p.Name)  below to confirm."
        if(-not (Confirm-TypedName "Delete user profile '$($p.Name)'" $m $p.Name)){ Write-CleanLog "PROFILE delete declined: $($p.Path)"; continue }
        $status.Text="Deleting profile $($p.Name)..."; [System.Windows.Forms.Application]::DoEvents()
        if(Remove-OtherProfile $p){ $deleted++; $lvP.Items.Remove($i) } else { [System.Windows.Forms.MessageBox]::Show("Could not delete profile '$($p.Name)'. It may be in use. Details are in the log.","Other user profiles",'OK','Warning')|Out-Null }
    }
    $status.Text="Profiles deleted: $deleted"
})

# ---------------------------------------------------------------- security check (read-only)
$btnSec.Add_Click({
    $btnSec.Enabled=$false; $btnRescan.Enabled=$false; $btnClean.Enabled=$false; $lvS.Items.Clear()
    Write-CleanLog "SECURITY CHECK start (read-only)"
    $prog = { param($m) $lblSecStatus.Text=$m; [System.Windows.Forms.Application]::DoEvents() }
    $rep=$null
    try { $rep = Get-SecurityReport $prog } catch { Write-CleanLog "SECURITY CHECK ERROR: $($_.Exception.Message)" }
    if($rep){
        $script:lastSecurity=$rep
        foreach($x in $rep.Items){
            $it=New-Object System.Windows.Forms.ListViewItem($x.Severity)
            $it.SubItems.Add($x.Type)|Out-Null; $it.SubItems.Add($x.Name)|Out-Null; $it.SubItems.Add([string]$x.PID)|Out-Null
            $it.SubItems.Add($(if($x.Signer){ "$($x.Signature) ($($x.Signer))" }else{ $x.Signature }))|Out-Null
            $it.SubItems.Add($x.Reasons)|Out-Null; $it.SubItems.Add($x.Path)|Out-Null
            $it.ToolTipText=$x.Reasons; $it.Tag=$x
            if($x.Severity -eq 'High'){ $it.ForeColor=[System.Drawing.Color]::DarkRed } elseif($x.Severity -eq 'Medium'){ $it.ForeColor=[System.Drawing.Color]::DarkOrange }
            $lvS.Items.Add($it)|Out-Null
            Write-CleanLog ("SECURITY {0} {1} {2} pid={3} sig={4} path={5} :: {6}" -f $x.Severity,$x.Type,$x.Name,$x.PID,$x.Signature,$x.Path,$x.Reasons)
        }
        $d=$rep.Defender
        $lines=@("Checked $($rep.Stats.Processes) processes and $($rep.Stats.StartupEntries) startup entries; $($rep.Items.Count) flagged ('suspicious, review'). $($rep.Stats.SignedAppDataStartup) validly signed AppData startup entries were not listed.")
        if($d.Available){ $lines += ("Defender: real-time protection {0}, service {1}, definitions {2} day(s) old, last full scan {3}." -f $d.Realtime,$d.AMService,$d.SigAgeDays,$(if($d.LastFullScan){ $d.LastFullScan.ToString('yyyy-MM-dd') }else{ 'never/unknown' })) }
        $lines += $d.Advice
        $txtDef.Text = ($lines -join "`r`n")
        $lblSecStatus.Text="Done - $($rep.Items.Count) item(s) to review."
    } else { $lblSecStatus.Text='Security check failed - see log.' }
    $btnSec.Enabled=$true; $btnRescan.Enabled=$true; $btnClean.Enabled=$true
})
$btnOpenLoc.Add_Click({
    if($lvS.SelectedItems.Count -eq 0){ return }
    $p=[string]$lvS.SelectedItems[0].Tag.Path
    if($p -and (Test-Path -LiteralPath $p)){ Start-Process explorer.exe -ArgumentList ('/select,"{0}"' -f $p) }
    elseif($p -and (Test-Path -LiteralPath (Split-Path $p -Parent))){ Start-Process explorer.exe -ArgumentList ('"{0}"' -f (Split-Path $p -Parent)) }
})

Update-Total
[void]$form.ShowDialog()
