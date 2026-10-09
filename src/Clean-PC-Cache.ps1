<#
================================================================================
  Clean-PC-Cache.ps1  -  Generalized Windows 10/11 cache & temp cleaner  (v1.2.0)
================================================================================
  Safely deletes regenerable CACHE and TEMP data only. It NEVER touches:
    - Documents, downloads, or any personal files
    - Browser tabs, sessions, cookies, logins, history, bookmarks, passwords
    - Installed programs or their settings
    - Saved game data
  Junctions/symlinks are never followed. Locked files are skipped, not forced.

  Auto-detects what the PC has. Anything not present is silently skipped, so
  the same script works on any Windows 10/11 machine (NVIDIA / AMD / Intel).
  Uses the same scan engine as CleanPC-GUI.ps1 (the CORE region is identical).

  USAGE
    Double-click  CleanPC.bat   (recommended - it self-elevates for system temp)
  or from PowerShell:
    .\Clean-PC-Cache.ps1                 # interactive: asks y/N for each risky item
    .\Clean-PC-Cache.ps1 -Auto           # no prompts, safe (ticked) defaults only
    .\Clean-PC-Cache.ps1 -DryRun         # show what WOULD be freed, delete nothing
    .\Clean-PC-Cache.ps1 -DryRun -Drives C,D       # also scan drive D:
    .\Clean-PC-Cache.ps1 -DryRun -AllDrives        # every fixed local drive
    .\Clean-PC-Cache.ps1 -SecurityCheck            # read-only suspicious process report
    .\Clean-PC-Cache.ps1 -ListProfiles             # list other user profiles (read-only)

  PARAMETERS
    -Auto                 Run without any prompts (uses defaults + any -Include flags)
    -IncludeRecycleBin    Also empty the Recycle Bin of each selected drive
    -IncludeClaudeVM      Also delete the Claude Desktop local-agent VM bundle (large)
    -SkipDevCaches        Skip pip/uv/npm/yarn/NuGet/Go/scoop/Gradle... caches
    -DryRun               Report only, delete nothing
    -Drives C,D           Fixed local drives to scan (default: the Windows drive)
    -AllDrives            Scan every fixed local drive (removable/network/optical excluded)
    -SecurityCheck        Read-only list of suspicious processes/startup entries; deletes nothing
    -ListProfiles         List OTHER user profiles with sizes (read-only)
    -IncludeOtherProfiles Offer to delete other user profiles; each needs the profile name
                          typed to confirm. Ignored with -Auto or -DryRun.
================================================================================
#>
[CmdletBinding()]
param(
    [switch]$Auto,
    [switch]$IncludeRecycleBin,
    [switch]$IncludeClaudeVM,
    [switch]$SkipDevCaches,
    [switch]$DryRun,
    [string[]]$Drives,
    [switch]$AllDrives,
    [switch]$SecurityCheck,
    [switch]$ListProfiles,
    [switch]$IncludeOtherProfiles
)

$ErrorActionPreference = 'SilentlyContinue'
$script:AppVersion = '1.2.0'
$script:ScanCancel = $false

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
#endregion CORE

# ================================================================ console
function Section([string]$t) { Write-Host "`n== $t ==" -ForegroundColor Cyan }
$script:lastProg = [DateTime]::MinValue
$conProg = { param($m) if(((Get-Date)-$script:lastProg).TotalMilliseconds -gt 400){ $script:lastProg=Get-Date; Write-Progress -Activity 'Scanning' -Status $m } }

trap {
    Write-CleanLog "CRASH: $($_.Exception.Message)"
    Write-CleanLog "AT: line $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())"
    Write-CleanLog "STACK: $($_.ScriptStackTrace)"
    Write-Host "An error occurred. Details written to $script:LogPath" -ForegroundColor Red
    continue
}

try { Clear-Host } catch {}
Write-Host "================================================================" -ForegroundColor White
Write-Host "  Windows Cache & Temp Cleaner v$script:AppVersion" -ForegroundColor White
$mode = if($SecurityCheck){'SECURITY CHECK (read-only)'}elseif($ListProfiles){'LIST PROFILES (read-only)'}elseif($DryRun){'DRY RUN (nothing deleted)'}elseif($Auto){'Auto'}else{'Interactive'}
Write-Host "  Mode: $mode   Admin: $(Is-Admin)" -ForegroundColor White
Write-Host "================================================================" -ForegroundColor White
Write-CleanLog ("=== Run start (console v$script:AppVersion) === admin=$(Is-Admin) os=$([System.Environment]::OSVersion.Version) host=$([System.Environment]::MachineName) dryrun=$DryRun mode=$mode")

# ---------------------------------------------------------------- security check (read-only)
if($SecurityCheck){
    Section "Security check (heuristic, read-only - nothing is killed or deleted)"
    $rep = Get-SecurityReport $conProg
    Write-Progress -Activity 'Scanning' -Completed
    foreach($x in $rep.Items){
        $col = switch($x.Severity){ 'High' {'Red'} 'Medium' {'Yellow'} default {'Gray'} }
        Write-Host ("[{0}] {1}: {2} (pid {3})" -f $x.Severity,$x.Type,$x.Name,$x.PID) -ForegroundColor $col
        Write-Host ("      suspicious, review: {0}" -f $x.Reasons) -ForegroundColor DarkGray
        Write-Host ("      signature: {0} {1}   path: {2}" -f $x.Signature,$(if($x.Signer){"($($x.Signer))"}else{''}),$x.Path) -ForegroundColor DarkGray
        Write-CleanLog ("SECURITY {0} {1} {2} pid={3} sig={4} path={5} :: {6}" -f $x.Severity,$x.Type,$x.Name,$x.PID,$x.Signature,$x.Path,$x.Reasons)
    }
    Write-Host ("`nChecked {0} processes and {1} startup entries; {2} flagged; {3} validly signed AppData startup entries not listed." -f $rep.Stats.Processes,$rep.Stats.StartupEntries,$rep.Items.Count,$rep.Stats.SignedAppDataStartup)
    $d=$rep.Defender
    if($d.Available){ Write-Host ("Defender: real-time={0} service={1} definitions={2} day(s) old, last full scan: {3}" -f $d.Realtime,$d.AMService,$d.SigAgeDays,$(if($d.LastFullScan){$d.LastFullScan}else{'unknown'})) }
    foreach($a in $d.Advice){ Write-Host "  * $a" -ForegroundColor Yellow }
    Write-Host "Results are heuristics, not proof of malware." -ForegroundColor DarkGray
    return
}

# ---------------------------------------------------------------- drives
$driveList = @(Resolve-Drives $Drives -All:$AllDrives)
if($driveList.Count -eq 0){ $driveList = @(Resolve-Drives @($env:SystemDrive)) }
Write-Host ("  Drives: {0}" -f ($driveList -join ', ')) -ForegroundColor White
foreach($fd in @(Get-FixedDrives)){ Write-CleanLog ("DRIVE {0} {1} size={2} free={3} selected={4}" -f $fd.Letter,$fd.Label,(Format-Size $fd.Size),(Format-Size $fd.Free),($driveList -contains $fd.Letter)) }
$freeStart=@{}; foreach($d in $driveList){ $freeStart[$d]=(New-Object System.IO.DriveInfo $d).AvailableFreeSpace }

if($ListProfiles){
    Section "Other user profiles (read-only list)"
    $pl = @(Get-OtherProfiles $driveList $conProg)
    Write-Progress -Activity 'Scanning' -Completed
    if($pl.Count -eq 0){ Write-Host "   none (current, system, loaded, Default/Public and Administrator profiles are never listed)" -ForegroundColor Gray }
    foreach($p in $pl){ Write-Host ("   {0,10}  {1}   last used {2}" -f (Format-Size $p.Size),$p.Path,$p.LastUse) -ForegroundColor Gray; Write-CleanLog "PROFILE listed $($p.Path) $(Format-Size $p.Size)" }
    return
}

# ---------------------------------------------------------------- scan
Section "Scanning"
$res = Build-Targets $driveList $conProg
Write-Progress -Activity 'Scanning' -Completed
$targets = @($res.Targets)
if($SkipDevCaches){ $targets = @($targets | Where-Object { $_.Category -ne 'Dev' }) }
Write-Host ("   Drive scan visited {0} folders." -f $res.Info.DirsVisited) -ForegroundColor DarkGray
if($res.Info.WalkTimedOut){ Write-Host "   (drive scan hit its time limit; some folders were not searched)" -ForegroundColor DarkYellow }
if(-not (Is-Admin)){ Write-Host "   (run as Administrator to also see Windows\Temp, Windows Update cache, other users' temp, shadow copies)" -ForegroundColor DarkYellow }

# ---------------------------------------------------------------- choose
$sel = New-Object System.Collections.Generic.List[object]
foreach($t in ($targets | Sort-Object Category,@{e='Size';Descending=$true})){
    $on = [bool]$t.Checked
    if($IncludeRecycleBin -and $t.Kind -eq 'RecycleBin'){ $on=$true }
    if($IncludeClaudeVM -and $t.Name -like 'Claude*'){ $on=$true }
    if(-not $on -and -not $Auto -and -not $DryRun){
        $ans = Read-Host ("`n{0} ({1}) is NOT selected by default. {2}`n   Delete it? (y/N)" -f $t.Name,(Format-Size $t.Size),$t.Note)
        $on = ($ans -match '^(y|yes)$')
    }
    Write-Host ("   [{0}] {1,10}  {2}{3}" -f $(if($on){'x'}else{' '}),(Format-Size $t.Size),$t.Name,$(if($t.Note){"   - $($t.Note)"}else{''})) -ForegroundColor $(if($on){'Gray'}else{'DarkGray'})
    Write-CleanLog ("FOUND {0,12}  {1}  [{2}] selected={3}" -f (Format-Size $t.Size),$t.Name,$t.Category,$on)
    if($on){ $sel.Add($t) }
}
if(@($res.Report).Count -gt 0){
    Section "Report only (never deleted by this tool)"
    foreach($r in ($res.Report | Sort-Object Size -Descending)){
        Write-Host ("   {0,10}  {1}" -f (Format-Size $r.Size),$r.Name) -ForegroundColor Gray
        Write-Host ("               {0}" -f $r.Note) -ForegroundColor DarkGray
        Write-CleanLog ("REPORT {0,12}  {1}  {2}" -f (Format-Size $r.Size),$r.Name,(@($r.Paths) -join ' | '))
    }
}

# ---------------------------------------------------------------- clean
$totalSel = [int64]0; foreach($t in $sel){ $totalSel += [int64]$t.Size }
$freed = [int64]0
if($DryRun){
    Write-Host "`n   DRY RUN - nothing was deleted." -ForegroundColor Yellow
} else {
    Section "Cleaning"
    if(($sel | Where-Object { $_.Name -like 'Claude*' }) -and (Get-Process -Name 'claude' -ErrorAction SilentlyContinue)){
        Write-Host "   NOTE: Claude Desktop appears to be running - locked files will be skipped." -ForegroundColor DarkYellow
    }
    foreach($t in $sel){
        $before=[int64]$t.Size
        Write-CleanLog ("CLEAN {0}  [{1}]" -f $t.Name,($t.Paths -join ' | '))
        $df=[int64](Invoke-Clean $t); if($df -gt $before){ $df=$before }
        $freed += $df
        Write-CleanLog ("FREED {0}  {1}" -f (Format-Size $df),$t.Name)
        Write-Host ("   {0,10}  {1}" -f (Format-Size $df),$t.Name) -ForegroundColor Gray
    }
}

# ---------------------------------------------------------------- other profiles (explicit opt-in only)
if($IncludeOtherProfiles){
    if($Auto -or $DryRun){
        Write-Host "`n-IncludeOtherProfiles is ignored with -Auto/-DryRun: profile deletion always needs a typed confirmation." -ForegroundColor DarkYellow
    } else {
        Section "Other user profiles (DANGER: permanent)"
        foreach($p in @(Get-OtherProfiles $driveList $conProg)){
            Write-Host ("   {0}  {1}  ({2})" -f $p.Name,$p.Path,(Format-Size $p.Size)) -ForegroundColor Yellow
            $typed = Read-Host "   Type the profile name '$($p.Name)' to DELETE it permanently, or press Enter to keep it"
            if($typed.Trim() -ieq $p.Name){
                if(Remove-OtherProfile $p){ Write-Host "   deleted." -ForegroundColor Green } else { Write-Host "   could not delete (see log)." -ForegroundColor Red }
            } else { Write-Host "   kept." -ForegroundColor Gray; Write-CleanLog "PROFILE kept: $($p.Path)" }
        }
        Write-Progress -Activity 'Scanning' -Completed
    }
}

# ---------------------------------------------------------------- summary
Write-Host "`n================================================================" -ForegroundColor White
if($DryRun){
    Write-Host ("  DRY RUN - would free about: {0}  ({1} items selected)" -f (Format-Size $totalSel),$sel.Count) -ForegroundColor Yellow
} else {
    Write-Host ("  TOTAL FREED: {0}" -f (Format-Size $freed)) -ForegroundColor Green
}
foreach($d in $driveList){
    $now=(New-Object System.IO.DriveInfo $d).AvailableFreeSpace
    Write-Host ("  {0} free  {1}  ->  {2}" -f $d,(Format-Size $freeStart[$d]),(Format-Size $now)) -ForegroundColor Green
}
Write-Host "================================================================" -ForegroundColor White
Write-Host "Tip: close browsers & chat apps before running for maximum cleanup." -ForegroundColor DarkGray
Write-CleanLog ("=== TOTAL {0} {1} ===" -f $(if($DryRun){'WOULD FREE'}else{'FREED'}),$(if($DryRun){Format-Size $totalSel}else{Format-Size $freed}))
