<#

# Version 2.3.0

.SYNOPSIS
    Builds the GUI.vhdx and CORE.vhdx parent images that New-HyperVSandbox.ps1 requires,
    and (by default) injects the latest Windows Server 2025 cumulative update so that
    every host and SDN VM in the lab inherits the patches.

.DESCRIPTION
    Every virtual machine in the SDN Sandbox is a Hyper-V differencing child (or a direct
    copy) of GUI.vhdx / CORE.vhdx. Patching these two parent images is therefore the single
    place that updates every host VM (SDNMGMT, SDNHOST1/2, DC, ToR router, Admin Center) and
    every SDN infrastructure VM (Network Controller, MUX, Gateways).

    With no parameters the script is fully automatic:
      1. Downloads the Windows Server 2025 Evaluation ISO from the Microsoft Evaluation Center.
      2. Downloads the latest cumulative update (combined SSU+LCU) from the Microsoft Update Catalog.
      3. Builds BOTH GUI.vhdx (Datacenter Desktop Experience) and CORE.vhdx (Datacenter Core)
         at the paths defined in SDNSandbox-Config.psd1, with the update slipstreamed in.

.EXAMPLE
    .\New-SDNVHDfromISO.ps1
    Fully automatic. Downloads ISO + latest CU and builds both parent VHDXs.

.EXAMPLE
    .\New-SDNVHDfromISO.ps1 -IsoPath 'D:\iso\server2025.iso' -VHDType CORE
    Builds only CORE.vhdx from a local ISO (still injects the latest CU).

.EXAMPLE
    .\New-SDNVHDfromISO.ps1 -UpdatesPath '.\MSU Updates' -DownloadUpdates:$false
    Builds both images and injects only the .msu files you provide (no catalog download).

.EXAMPLE
    .\New-SDNVHDfromISO.ps1 -Parallel
    Builds GUI.vhdx and CORE.vhdx concurrently to cut wall-clock time on hosts with spare
    CPU/disk. Shows periodic heartbeat updates instead of the per-image live progress bar.

.NOTES
    * Run from an elevated Windows PowerShell console on the Hyper-V host.
    * The parent images are produced from a generalized WIM and must remain generalized and
      unbooted; the children specialize on first boot via the unattend.xml that
      New-HyperVSandbox.ps1 injects.
#>

[CmdletBinding()]
param(

    # Path to SDNSandbox-Config.psd1. Output VHDX paths (guiVHDXPath/coreVHDXPath) are read from it.
    [Parameter(Mandatory = $false)]
    [String] $ConfigurationDataFile = '.\SDNSandbox-Config.psd1',

    # Which parent image(s) to build.
    [Parameter(Mandatory = $false)]
    [ValidateSet('GUI', 'CORE', 'Both')]
    [String] $VHDType = 'Both',

    # Windows Server edition to extract.
    [Parameter(Mandatory = $false)]
    [ValidateSet('Datacenter', 'Standard')]
    [String] $Edition = 'Datacenter',

    # Use an existing ISO instead of downloading one.
    [Parameter(Mandatory = $false)]
    [String] $IsoPath,

    # Source for the automatic ISO download (default = WS2025 Evaluation, en-us).
    [Parameter(Mandatory = $false)]
    [String] $IsoUrl = 'https://go.microsoft.com/fwlink/?linkid=2345730&clcid=0x409&culture=en-us&country=us',

    # Auto-download the ISO when -IsoPath is not supplied.
    [Parameter(Mandatory = $false)]
    [Bool] $DownloadISO = $true,

    # Auto-download the latest cumulative update from the Microsoft Update Catalog.
    [Parameter(Mandatory = $false)]
    [Bool] $DownloadUpdates = $true,

    # Folder of local *.msu files to additionally inject.
    [Parameter(Mandatory = $false)]
    [String] $UpdatesPath,

    # Virtual size of each parent VHDX (dynamic).
    [Parameter(Mandatory = $false)]
    [UInt64] $VHDSize = 100GB,

    # Working folder for the downloaded ISO, updates and DISM scratch (cached/reused across
    # runs). Defaults to <launch drive>\SDNVHDBuild so nothing large lands on C:.
    [Parameter(Mandatory = $false)]
    [String] $WorkPath = '',

    # Build GUI.vhdx and CORE.vhdx concurrently (only when both are selected). Uses otherwise
    # idle CPU/disk to cut wall-clock time; trades the live DISM progress bar for periodic
    # heartbeat updates. Default is the deterministic sequential build with the live bar.
    [Parameter(Mandatory = $false)]
    [Switch] $Parallel
)

$ErrorActionPreference = "Stop"
$VerbosePreference = "Continue"
$ProgressPreference = "SilentlyContinue"

# Ensure TLS 1.2 for PowerShell Gallery / Update Catalog / ISO downloads on older hosts.
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}

#region helpers

function Test-IsAdmin {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object System.Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-KBNumberFromName {
    param([string]$Name)
    if ($Name -match 'kb(\d{6,})') { return "KB$($Matches[1])" }
    return $null
}

function Get-LaunchDriveRoot {
    # The drive the script was launched from (e.g. 'E:'), so build artifacts and the final
    # images stay off C: by default. Falls back to the current location, then the system drive.
    $root = $null
    if ($PSScriptRoot) { try { $root = Split-Path $PSScriptRoot -Qualifier } catch {} }
    if ([string]::IsNullOrWhiteSpace($root)) {
        try { $root = (Get-Location).Drive.Name + ':' } catch {}
    }
    if ([string]::IsNullOrWhiteSpace($root)) { $root = $env:SystemDrive }
    return $root
}

function ConvertTo-DriveRootedPath {
    # Re-base a rooted local path onto a different drive, preserving folders and filename.
    # Relative or UNC paths are returned unchanged. Pure string work so it never needs the
    # target drive to exist.
    param([string]$Path, [string]$DriveRoot)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
    if ($Path -notmatch '^[A-Za-z]:') { return $Path }   # relative or UNC: leave as-is
    return ($DriveRoot + (Split-Path $Path -NoQualifier))
}

function Set-Psd1StringValue {
    # Surgically update a "Key = "value"" entry in a .psd1, preserving comments/formatting.
    # Returns $true if the file was changed.
    param([string]$Psd1Path, [string]$Key, [string]$Value)
    $content = Get-Content -LiteralPath $Psd1Path -Raw
    $pattern = "(?m)^(?<pre>\s*$([regex]::Escape($Key))\s*=\s*`")(?<val>[^`"]*)(?<post>`")"
    if ($content -notmatch $pattern) { return $false }
    $new = [regex]::Replace($content, $pattern, { param($m) $m.Groups['pre'].Value + $Value + $m.Groups['post'].Value })
    if ($new -eq $content) { return $false }
    [System.IO.File]::WriteAllText($Psd1Path, $new)
    return $true
}

function Get-RemoteFileLength {
    param([string]$Url)
    try {
        $req = [System.Net.HttpWebRequest]::Create($Url)
        $req.Method = "HEAD"
        $req.AllowAutoRedirect = $true
        $resp = $req.GetResponse()
        $len = $resp.ContentLength
        $resp.Close()
        return [int64]$len
    }
    catch { return -1 }
}

function Format-FileSize {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    elseif ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    elseif ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    else { return ('{0} B' -f [int]$Bytes) }
}

function Format-Elapsed {
    param([TimeSpan]$Span)
    return ('{0:hh\:mm\:ss}' -f $Span)
}

$script:PhaseNum = 0
$script:PhaseTotal = 0
function Write-Phase {
    # Prints a clear, numbered phase banner with a timestamp so the user always knows
    # which stage is running and that long waits are expected.
    param([string]$Title, [string]$Note)
    $script:PhaseNum++
    $stamp = (Get-Date).ToString('HH:mm:ss')
    $head = if ($script:PhaseTotal -gt 0) { "[$($script:PhaseNum)/$($script:PhaseTotal)]" } else { "[$($script:PhaseNum)]" }
    Write-Host ''
    Write-Host ("==== {0} {1}  ({2}) ====" -f $head, $Title, $stamp) -ForegroundColor Cyan
    if ($Note) { Write-Host ("     {0}" -f $Note) -ForegroundColor DarkGray }
}

$script:ProgressGlyphs = $null
function Get-ProgressGlyphs {
    # Prefer solid block glyphs for a polished bar; fall back to ASCII if the console
    # cannot be switched to UTF-8 output.
    if ($null -ne $script:ProgressGlyphs) { return $script:ProgressGlyphs }
    $glyphs = @{ Full = '#'; Empty = '-' }
    try {
        if (-not [Console]::IsOutputRedirected) {
            [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
            $glyphs = @{ Full = ([char]0x2588); Empty = ([char]0x2591) }
        }
    }
    catch {}
    $script:ProgressGlyphs = $glyphs
    return $glyphs
}

$script:LastProgressLen = 0
function Write-DownloadProgress {
    <#
        Renders a single, in-place progress line:
          Activity  [#############-------------]  52%   3.95 / 7.59 GB   88.4 MB/s   ETA 00:00:38
        On non-interactive (redirected) hosts it falls back to Write-Progress.
    #>
    param(
        [string]$Activity,
        [int64]$Current,
        [int64]$Total,
        [double]$BytesPerSecond,
        [switch]$Completed
    )

    if ([Console]::IsOutputRedirected) {
        if ($Completed) { Write-Progress -Activity $Activity -Completed }
        elseif ($Total -gt 0) {
            Write-Progress -Activity $Activity -Status ('{0} / {1}' -f (Format-FileSize $Current), (Format-FileSize $Total)) `
                -PercentComplete ([int](100 * $Current / $Total))
        }
        return
    }

    $g = Get-ProgressGlyphs
    $barWidth = 30
    $frac = if ($Total -gt 0) { [math]::Min(1.0, $Current / [double]$Total) } else { 0 }
    $fill = [int][math]::Round($barWidth * $frac)
    $bar = (([string]$g.Full) * $fill) + (([string]$g.Empty) * ($barWidth - $fill))
    $pct = [int]([math]::Round($frac * 100))

    $sizePart = if ($Total -gt 0) { '{0} / {1}' -f (Format-FileSize $Current), (Format-FileSize $Total) }
    else { Format-FileSize $Current }
    $speedPart = if ($BytesPerSecond -gt 0) { '{0}/s' -f (Format-FileSize $BytesPerSecond) } else { '' }
    $etaPart = ''
    if ($BytesPerSecond -gt 0 -and $Total -gt $Current) {
        $eta = [TimeSpan]::FromSeconds(($Total - $Current) / $BytesPerSecond)
        $etaPart = 'ETA {0:hh\:mm\:ss}' -f $eta
    }

    $line = '  {0}  [{1}] {2,3}%  {3}   {4}   {5}' -f $Activity, $bar, $pct, $sizePart, $speedPart, $etaPart
    $pad = [math]::Max(0, $script:LastProgressLen - $line.Length)
    [Console]::Write("`r" + $line + (' ' * $pad))
    $script:LastProgressLen = $line.Length
    if ($Completed) {
        [Console]::Write("`n")
        $script:LastProgressLen = 0
    }
}

function Invoke-StreamDownload {
    # Streams a URL to disk with a live progress bar. Used as the BITS fallback.
    param(
        [string]$Url,
        [string]$Destination,
        [string]$Activity = 'Downloading',
        [int64]$ExpectedLength = -1
    )
    $resp = $null; $in = $null; $out = $null
    try {
        $req = [System.Net.HttpWebRequest]::Create($Url)
        $req.AllowAutoRedirect = $true
        $req.UserAgent = 'SDNSandbox-VHDBuilder'
        $resp = $req.GetResponse()
        $total = [int64]$resp.ContentLength
        if ($total -le 0) { $total = $ExpectedLength }
        $in = $resp.GetResponseStream()
        $out = [System.IO.File]::Create($Destination)
        $buffer = New-Object byte[] (4MB)
        $read = 0L
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $lastBytes = 0L; $lastTick = 0.0; $speed = 0.0; $lastDraw = 0.0
        while (($n = $in.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $out.Write($buffer, 0, $n)
            $read += $n
            $now = $sw.Elapsed.TotalSeconds
            if (($now - $lastTick) -ge 0.5) {
                $inst = ($read - $lastBytes) / ($now - $lastTick)
                $speed = if ($speed -le 0) { $inst } else { (0.7 * $speed) + (0.3 * $inst) }
                $lastBytes = $read; $lastTick = $now
            }
            if (($now - $lastDraw) -ge 0.25) {
                Write-DownloadProgress -Activity $Activity -Current $read -Total $total -BytesPerSecond $speed
                $lastDraw = $now
            }
        }
        $out.Flush()
        $finalTotal = if ($total -gt 0) { $total } else { $read }
        Write-DownloadProgress -Activity $Activity -Current $read -Total $finalTotal -BytesPerSecond $speed -Completed
    }
    finally {
        if ($out) { $out.Dispose() }
        if ($in) { $in.Dispose() }
        if ($resp) { $resp.Close() }
    }
}

function Save-Url {
    <#
        Robust file download with a live progress bar: BITS (async, resumable) first,
        then a direct streaming fallback. Throws on failure or incomplete size.
        Callers are responsible for removing partial files on a thrown error.
    #>
    param(
        [string]$Url,
        [string]$Destination,
        [string]$Activity,
        [int64]$ExpectedLength = 0
    )

    if ($ExpectedLength -le 0) { $ExpectedLength = Get-RemoteFileLength -Url $Url }
    $downloaded = $false
    try {
        Import-Module BitsTransfer -Verbose:$false -ErrorAction Stop
        $job = $null
        try {
            $job = Start-BitsTransfer -Source $Url -Destination $Destination -Asynchronous -Description $Activity -ErrorAction Stop
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $lastBytes = 0L; $lastTick = 0.0; $speed = 0.0; $finalTotal = $ExpectedLength
            while ($job.JobState -eq 'Connecting' -or $job.JobState -eq 'Transferring' -or $job.JobState -eq 'Queued') {
                Start-Sleep -Milliseconds 500
                $cur = [int64]$job.BytesTransferred
                # BITS reports BytesTotal as UInt64.MaxValue (18446744073709551615) until the
                # size is known (Connecting/Queued). Treat that - and 0 - as "unknown" and use
                # the HEAD-probed length, rather than overflowing the Int64 cast (which would
                # abort BITS on the first poll and force the slower streaming fallback).
                $totRaw = $job.BytesTotal
                $tot = if ($totRaw -eq [uint64]::MaxValue -or $totRaw -eq 0) { $ExpectedLength } else { [int64]$totRaw }
                $finalTotal = $tot
                $now = $sw.Elapsed.TotalSeconds
                if (($now - $lastTick) -ge 0.5) {
                    $inst = ($cur - $lastBytes) / [math]::Max($now - $lastTick, 0.001)
                    $speed = if ($speed -le 0) { $inst } else { (0.7 * $speed) + (0.3 * $inst) }
                    $lastBytes = $cur; $lastTick = $now
                }
                Write-DownloadProgress -Activity $Activity -Current $cur -Total $tot -BytesPerSecond $speed
            }
            if ($job.JobState -eq 'Transferred') {
                $finalBytes = [int64]$job.BytesTransferred
                Complete-BitsTransfer -BitsJob $job
                Write-DownloadProgress -Activity $Activity -Current $finalBytes -Total $finalTotal -BytesPerSecond $speed -Completed
                $downloaded = $true
            }
            else {
                $state = $job.JobState
                Remove-BitsTransfer -BitsJob $job -ErrorAction SilentlyContinue
                throw "BITS transfer ended unexpectedly in state '$state'."
            }
        }
        catch {
            if ($job) { Remove-BitsTransfer -BitsJob $job -ErrorAction SilentlyContinue }
            throw
        }
    }
    catch {
        Write-Verbose "BITS unavailable or failed ($($_.Exception.Message)). Falling back to a direct streaming download."
    }

    if (!$downloaded) {
        Invoke-StreamDownload -Url $Url -Destination $Destination -Activity $Activity -ExpectedLength $ExpectedLength
    }

    if (!(Test-Path $Destination)) { throw "Download failed; file not found at $Destination." }
    if ($ExpectedLength -gt 0 -and (Get-Item $Destination).Length -ne $ExpectedLength) {
        throw "Download appears incomplete (expected $ExpectedLength bytes, got $((Get-Item $Destination).Length))."
    }
}

function Get-EvalISO {
    param(
        [string]$Url,
        [string]$DestFolder
    )

    if (!(Test-Path $DestFolder)) { New-Item -Path $DestFolder -ItemType Directory -Force | Out-Null }
    $dest = Join-Path $DestFolder 'WS2025_EVAL_x64FRE_en-us.iso'

    $remoteLen = Get-RemoteFileLength -Url $Url

    if (Test-Path $dest) {
        $localLen = (Get-Item $dest).Length
        if ($remoteLen -gt 0 -and $localLen -eq $remoteLen) {
            Write-Verbose "Reusing cached ISO at $dest ($([math]::Round($localLen / 1GB, 2)) GB)."
            return $dest
        }
        Write-Verbose "Cached ISO is incomplete or stale. Re-downloading."
        Remove-Item $dest -Force -ErrorAction SilentlyContinue
    }

    Write-Host "Downloading the Windows Server 2025 Evaluation ISO (~7.6 GB) to $dest" -ForegroundColor Cyan
    Write-Host "This can take a while depending on your connection; live progress is shown below." -ForegroundColor DarkGray

    try {
        Save-Url -Url $Url -Destination $dest -Activity 'WS2025 Eval ISO' -ExpectedLength $remoteLen
    }
    catch {
        # Don't leave a partial multi-GB ISO behind on a failed download.
        if (Test-Path $dest) { Remove-Item $dest -Force -ErrorAction SilentlyContinue }
        throw
    }

    Write-Verbose "ISO downloaded to $dest."
    return $dest
}

function Find-CatalogUpdate {
    <#
        Queries the Microsoft Update Catalog directly (no third-party module) and returns
        the newest matching update as a PSCustomObject { Guid; Title; KB; Build }, or $null.
        The catalog occasionally serves an error page, so the search is retried.
    #>
    param(
        [string]$Search,
        [int]$Attempts = 4
    )

    $enc = [uri]::EscapeDataString($Search)
    $url = "https://www.catalog.update.microsoft.com/Search.aspx?q=$enc"
    $content = $null
    for ($a = 1; $a -le $Attempts; $a++) {
        try {
            if ($a -gt 1) {
                $wait = 6 * ($a - 1)
                Write-Host "  Update Catalog was busy; retry $a of $Attempts in ${wait}s..." -ForegroundColor DarkGray
                Start-Sleep -Seconds $wait
            }
            $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 40 -ErrorAction Stop
            $content = $resp.Content
            if ($content -match 'The website has encountered a problem' -or $content -match 'catalog\.microsoft\.com site has encountered an error') {
                throw "The catalog returned an error page."
            }
            break
        }
        catch {
            Write-Verbose "Catalog query attempt $a failed: $($_.Exception.Message)"
            $content = $null
            if ($a -eq $Attempts) { throw }
        }
    }
    if (!$content) { return $null }

    # Each result is a <tr id="GUID_Rn"> ... </tr> whose title is in an <a id='GUID_link'>...</a>.
    $rows = [regex]::Matches($content, '(?s)<tr[^>]*id="([0-9a-fA-F\-]{36})_R\d+".*?</tr>')
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($m in $rows) {
        $block = $m.Value
        $guid = $m.Groups[1].Value
        $tm = [regex]::Match($block, "(?s)_link'[^>]*>(.*?)</a>")
        if (!$tm.Success) { continue }
        $title = ($tm.Groups[1].Value -replace '\s+', ' ').Trim()
        $kb = $null
        if ($title -match 'KB(\d+)') { $kb = "KB$($Matches[1])" }
        $build = 0L
        if ($title -match '\(\d+\.(\d+)\)') { $build = [int64]$Matches[1] }   # OS revision, e.g. 26100.(32860)
        $items.Add([pscustomobject]@{ Guid = $guid; Title = $title; KB = $kb; Build = $build })
    }

    return $items | Where-Object {
        $_.Title -match 'Cumulative Update' -and
        $_.Title -match '24H2' -and
        $_.Title -match 'x64' -and
        $_.Title -notmatch 'Preview' -and
        $_.Title -notmatch 'Dynamic' -and
        $_.Title -notmatch '\.NET' -and
        $_.Title -notmatch 'Setup'
    } | Sort-Object Build -Descending | Select-Object -First 1
}

function Get-CatalogDownloadUrls {
    <#
        Resolves the actual .msu download URL(s) for a catalog update GUID via
        DownloadDialog.aspx. For Server 2025 this typically returns the target cumulative
        update *and* any checkpoint cumulative update bundled with it.
    #>
    param([string]$Guid)

    $payload = "[{`"size`":0,`"languages`":`"`",`"uidInfo`":`"$Guid`",`"updateID`":`"$Guid`"}]"
    $body = 'updateIDs=' + [uri]::EscapeDataString($payload)
    $resp = Invoke-WebRequest -Uri 'https://www.catalog.update.microsoft.com/DownloadDialog.aspx' `
        -Method Post -Body $body -ContentType 'application/x-www-form-urlencoded' `
        -UseBasicParsing -TimeoutSec 40 -ErrorAction Stop
    $urls = [regex]::Matches($resp.Content, "(https?://[^'`"]+\.msu)") |
        ForEach-Object { $_.Value } | Select-Object -Unique
    return @($urls)
}

function Get-LatestServerCU {
    <#
        Best-effort acquisition of the latest Windows Server 2025 (24H2) cumulative update,
        querying the Microsoft Update Catalog directly (no third-party module). Downloads
        the target CU AND any checkpoint CU the catalog bundles with it (required for 24H2)
        into $DestFolder so DISM can auto-discover the checkpoint during offline injection.
        Returns @{ KB; TargetFile; Files } or $null. Never throws.
    #>
    param([string]$DestFolder)

    try {
        if (!(Test-Path $DestFolder)) { New-Item -Path $DestFolder -ItemType Directory -Force | Out-Null }

        Write-Verbose "Querying the Microsoft Update Catalog for the latest Server 2025 (24H2) cumulative update..."
        $update = Find-CatalogUpdate -Search 'Cumulative Update Microsoft server operating system version 24H2 x64'
        if (!$update) {
            Write-Warning "Could not identify a suitable cumulative update from the catalog. Continuing without an auto-downloaded CU."
            return $null
        }
        Write-Host "  Latest cumulative update: $($update.Title)" -ForegroundColor DarkGray
        $kbId = $update.KB

        $urls = Get-CatalogDownloadUrls -Guid $update.Guid
        if (!$urls -or $urls.Count -eq 0) {
            Write-Warning "Could not resolve a download URL for $kbId. Continuing without an auto-downloaded CU."
            return $null
        }

        $files = New-Object System.Collections.Generic.List[string]
        foreach ($u in $urls) {
            $fname = [System.IO.Path]::GetFileName(($u -split '\?')[0])
            $dest = Join-Path $DestFolder $fname
            $remoteLen = Get-RemoteFileLength -Url $u

            if ((Test-Path $dest) -and $remoteLen -gt 0 -and (Get-Item $dest).Length -eq $remoteLen) {
                Write-Verbose "Reusing cached update $fname."
                $files.Add($dest)
                continue
            }
            if (Test-Path $dest) { Remove-Item $dest -Force -ErrorAction SilentlyContinue }

            Write-Host "  Downloading $fname ($(Format-FileSize $remoteLen))..." -ForegroundColor Cyan
            try {
                Save-Url -Url $u -Destination $dest -Activity $fname -ExpectedLength $remoteLen
            }
            catch {
                if (Test-Path $dest) { Remove-Item $dest -Force -ErrorAction SilentlyContinue }
                throw
            }
            $files.Add($dest)
        }

        if ($files.Count -eq 0) {
            Write-Warning "Update download produced no .msu file. Continuing without an auto-downloaded CU."
            return $null
        }

        # The target LCU file carries the selected KB in its name; any others are checkpoints.
        $target = $null
        if ($kbId) { $target = $files | Where-Object { [System.IO.Path]::GetFileName($_) -match $kbId } | Select-Object -First 1 }
        if (!$target) { $target = $files | Sort-Object { (Get-Item $_).Length } -Descending | Select-Object -First 1 }

        if ($files.Count -gt 1) {
            Write-Host "  Catalog bundled $($files.Count) packages (target CU + checkpoint prerequisite); all saved for DISM." -ForegroundColor DarkGray
        }
        Write-Verbose "Cumulative update ready: $kbId ($($files.Count) file(s) in $DestFolder)."
        return @{ KB = $kbId; TargetFile = $target; Files = @($files); Build = $update.Build }
    }
    catch {
        Write-Warning "Failed to obtain the latest cumulative update from the catalog: $($_.Exception.Message)"
        Write-Warning "The build will continue WITHOUT an auto-downloaded update. Re-run later, or download the latest Server 2025 cumulative update (use the catalog's Download button so any checkpoint is included) and pass the folder with -UpdatesPath."
        return $null
    }
}

function Resolve-UpdatePackages {
    <#
        Returns an ordered array of .msu paths to inject:
        SSU-like first, then the LCU, then any other local updates.
    #>
    param(
        [string]$AutoCU,
        [string]$UpdatesPath
    )

    $all = New-Object System.Collections.Generic.List[string]

    if ($UpdatesPath -and (Test-Path $UpdatesPath)) {
        Get-ChildItem -Path $UpdatesPath -Filter '*.msu' -ErrorAction SilentlyContinue |
            ForEach-Object { $all.Add($_.FullName) }
    }
    if ($AutoCU -and (Test-Path $AutoCU)) { $all.Add($AutoCU) }

    if ($all.Count -eq 0) { return @() }

    $unique = $all | Select-Object -Unique
    $ssu = $unique | Where-Object { $_ -match 'ssu' -or $_ -match 'servicing.?stack' }
    $lcu = $unique | Where-Object { ($_ -match 'kb') -and ($_ -notin $ssu) }
    $other = $unique | Where-Object { ($_ -notin $ssu) -and ($_ -notin $lcu) }

    return @($ssu) + @($lcu) + @($other) | Where-Object { $_ }
}

function Get-SourceImageInfo {
    <#
        Mounts the ISO, locates install.wim/install.esd, and returns image metadata
        (Index, InstallationType, EditionId, ImageName) for selection.
        Returns: @{ WimPath; IsEsd; Images; DriveLetter }
    #>
    param([string]$IsoPath)

    $before = (Get-Volume).DriveLetter
    Mount-DiskImage -ImagePath $IsoPath | Out-Null
    Start-Sleep -Seconds 2
    $drive = (Get-DiskImage -ImagePath $IsoPath | Get-Volume).DriveLetter
    if (!$drive) {
        # Fallback: diff the volume list
        $after = (Get-Volume).DriveLetter
        $drive = (Compare-Object $before $after | Where-Object { $_.SideIndicator -eq '=>' }).InputObject | Select-Object -First 1
    }
    if (!$drive) { throw "Unable to determine the mounted ISO drive letter." }

    try {
        $wim = Join-Path "${drive}:" 'sources\install.wim'
        $esd = Join-Path "${drive}:" 'sources\install.esd'
        $isEsd = $false
        if (Test-Path $wim) { $src = $wim }
        elseif (Test-Path $esd) { $src = $esd; $isEsd = $true }
        else { throw "Neither sources\install.wim nor sources\install.esd was found on the ISO." }

        $images = @()
        foreach ($img in (Get-WindowsImage -ImagePath $src)) {
            $detail = Get-WindowsImage -ImagePath $src -Index $img.ImageIndex
            $images += [pscustomobject]@{
                Index            = $img.ImageIndex
                ImageName        = $detail.ImageName
                InstallationType = $detail.InstallationType
                EditionId        = $detail.EditionId
            }
        }
    }
    catch {
        # Don't leave the ISO mounted if enumeration fails.
        Dismount-DiskImage -ImagePath $IsoPath -ErrorAction SilentlyContinue | Out-Null
        throw
    }

    return [pscustomobject]@{
        WimPath     = $src
        IsEsd       = $isEsd
        Images      = $images
        DriveLetter = $drive
    }
}

function Select-ImageIndex {
    param(
        [object[]]$Images,
        [string]$Type,      # GUI or CORE
        [string]$Edition    # Datacenter or Standard
    )

    # GUI => full "Server" (Desktop Experience); CORE => "Server Core".
    $wantType = if ($Type -eq 'GUI') { 'Server' } else { 'Server Core' }

    $match = $Images | Where-Object {
        $_.InstallationType -eq $wantType -and
        $_.EditionId -like "*$Edition*"
    } | Select-Object -First 1

    if (!$match) {
        # Fall back to display-name matching for media with non-standard metadata.
        if ($Type -eq 'GUI') {
            $match = $Images | Where-Object { $_.ImageName -like "*$Edition*" -and $_.ImageName -like '*Desktop Experience*' } | Select-Object -First 1
        }
        else {
            $match = $Images | Where-Object { $_.ImageName -like "*$Edition*" -and $_.ImageName -notlike '*Desktop Experience*' } | Select-Object -First 1
        }
    }

    return $match
}

function Wait-PartitionDriveLetter {
    <#
        Returns a partition's assigned drive letter, polling briefly because the Storage
        stack can take a moment to surface the letter after New-Partition/Format-Volume.
    #>
    param(
        [int]$DiskNumber,
        [int]$PartitionNumber,
        [int]$TimeoutSeconds = 30
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $letter = (Get-Partition -DiskNumber $DiskNumber -PartitionNumber $PartitionNumber -ErrorAction SilentlyContinue).DriveLetter
        if ($letter) { return $letter }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    return $null
}

function Convert-ToParentVHDX {
    <#
        Builds a bootable UEFI/GPT parent VHDX natively, with no third-party module:
          create VHDX -> GPT partitions (ESP + MSR + Windows) -> apply image (.wim/.esd)
          -> inject updates offline -> bcdboot.
        Doing this with native DISM + Storage cmdlets is reliable on Windows Server 2025,
        unlike WindowsImageTools' Convert-Wim2VHD which fails at bcdboot (0xC0E90002).
    #>
    param(
        [string]$SourcePath,   # install.wim or install.esd (DISM applies either directly)
        [bool]$IsEsd,          # retained for call-site compatibility; not needed natively
        [int]$Index,
        [string]$OutPath,
        [uint64]$SizeBytes,
        [string[]]$Packages,
        [string]$ScratchDir
    )

    # Keep DISM's scratch off C: too (it otherwise defaults to %TEMP%).
    $scratchArg = @{}
    if ($ScratchDir) {
        if (!(Test-Path $ScratchDir)) { New-Item -Path $ScratchDir -ItemType Directory -Force | Out-Null }
        $scratchArg['ScratchDirectory'] = $ScratchDir
    }
    # Use a per-build DISM log (under the scratch dir) so concurrent parallel builds don't
    # interleave into the single host log and so failure diagnostics read the right tail.
    $dismLogPath = if ($ScratchDir) { Join-Path $ScratchDir 'dism.log' } else { Join-Path $env:SystemRoot 'Logs\DISM\dism.log' }

    $dir = Split-Path $OutPath -Parent
    if ($dir -and !(Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
    # Dismount first in case a previous interrupted run left this VHDX attached (otherwise
    # the file is locked and cannot be removed/recreated).
    if (Test-Path $OutPath) {
        Dismount-VHD -Path $OutPath -ErrorAction SilentlyContinue
        Remove-Item $OutPath -Force
    }

    $name = Split-Path $OutPath -Leaf
    $disk = $null
    $success = $false

    # Surface DISM's native percentage progress bars during the long image apply/inject;
    # the script otherwise suppresses progress globally.
    $prevProgress = $ProgressPreference
    $ProgressPreference = 'Continue'
    $prevEA = $ErrorActionPreference
    $ErrorActionPreference = 'Stop'
    try {
        # 1. Create and mount the (dynamic) VHDX, then lay down a clean GPT.
        Write-Host "  Creating $name ($([math]::Round($SizeBytes / 1GB)) GB, dynamic, GPT/UEFI)..." -ForegroundColor DarkGray
        New-VHD -Path $OutPath -SizeBytes $SizeBytes -Dynamic | Out-Null
        $disk = Mount-VHD -Path $OutPath -Passthru | Get-Disk
        Initialize-Disk -Number $disk.Number -PartitionStyle GPT -Confirm:$false | Out-Null
        # Remove any auto-created partition so we fully control the layout.
        Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue |
            Remove-Partition -Confirm:$false -ErrorAction SilentlyContinue

        # 2. EFI System Partition. Create it as a basic partition first so Format-Volume
        #    accepts FAT32 and a drive letter; it is re-tagged as ESP after bcdboot.
        $sysPart = New-Partition -DiskNumber $disk.Number -Size 260MB -AssignDriveLetter
        Format-Volume -Partition $sysPart -FileSystem FAT32 -NewFileSystemLabel 'System' -Confirm:$false | Out-Null
        $sysLetter = Wait-PartitionDriveLetter -DiskNumber $disk.Number -PartitionNumber $sysPart.PartitionNumber

        # 3. Microsoft Reserved Partition (MSR).
        New-Partition -DiskNumber $disk.Number -Size 16MB -GptType '{e3c9e316-0b5c-4db8-817d-f92df00215ae}' | Out-Null

        # 4. Windows (OS) partition - the rest of the disk.
        $winPart = New-Partition -DiskNumber $disk.Number -UseMaximumSize -AssignDriveLetter
        Format-Volume -Partition $winPart -FileSystem NTFS -NewFileSystemLabel 'Windows' -Confirm:$false | Out-Null
        $winLetter = Wait-PartitionDriveLetter -DiskNumber $disk.Number -PartitionNumber $winPart.PartitionNumber

        if (!$sysLetter -or !$winLetter) { throw "Failed to assign drive letters to the new VHDX partitions." }
        $sysRoot = "${sysLetter}:"
        $winRoot = "${winLetter}:"

        # 5. Apply the Windows image (Expand-WindowsImage handles install.wim and install.esd).
        Write-Host "  Applying image index $Index to $winRoot (typically 10-25 minutes - it is not hung)..." -ForegroundColor DarkGray
        $swApply = [System.Diagnostics.Stopwatch]::StartNew()
        Expand-WindowsImage -ImagePath $SourcePath -Index $Index -ApplyPath "$winRoot\" @scratchArg -ErrorAction Stop | Out-Null
        $swApply.Stop()
        Write-Host "  Image applied in $(Format-Elapsed $swApply.Elapsed)." -ForegroundColor DarkGray

        # 6. Inject updates offline (SSU-first ordering is supplied by the caller), per
        #    MS guidance "Add updates to a Windows image" / "Update Windows installation media".
        #    For Windows Server 2025 (24H2) the latest CU can have a *checkpoint* CU
        #    prerequisite; DISM auto-discovers and installs checkpoints found in the same
        #    folder as the target package (so keep the CU + its checkpoints together).
        #    Injection is best-effort: a failure leaves a bootable but unpatched image
        #    rather than aborting the whole build.
        $patchOk = $true
        if ($Packages -and $Packages.Count -gt 0) {
            $i = 0
            foreach ($pkg in $Packages) {
                $i++
                Write-Host "  Injecting update $i/$($Packages.Count): $([System.IO.Path]::GetFileName($pkg))" -ForegroundColor DarkGray
                Write-Host "    This can take several minutes; DISM's progress bar is shown below." -ForegroundColor DarkGray
                try {
                    # Prefer dism.exe over Add-WindowsPackage so the operator sees DISM's live
                    # percentage progress bar (the cmdlet shows no progress for cumulative
                    # updates and looks hung). DISM still auto-discovers any checkpoint CU that
                    # sits in the same folder as the target package. Output flows straight to the
                    # console so the \r-animated bar renders; success/failure comes from the exit
                    # code rather than captured text.
                    $dismExe = Join-Path $env:SystemRoot 'System32\dism.exe'
                    if (Test-Path $dismExe) {
                        $dismScratch = if ($ScratchDir) { @("/ScratchDir:$ScratchDir", "/LogPath:$dismLogPath") } else { @() }
                        & $dismExe /Image:"$winRoot\" /Add-Package /PackagePath:"$pkg" @dismScratch
                        if ($LASTEXITCODE -ne 0) {
                            $hr = '0x{0:X8}' -f $LASTEXITCODE
                            throw "dism /Add-Package failed (exit code $LASTEXITCODE / $hr)."
                        }
                    }
                    else {
                        Add-WindowsPackage -Path "$winRoot\" -PackagePath $pkg @scratchArg -ErrorAction Stop | Out-Null
                    }
                }
                catch {
                    $patchOk = $false
                    $injErr = $_.Exception.Message
                    Write-Warning "  Failed to inject $([System.IO.Path]::GetFileName($pkg)): $injErr"
                    # dism.exe surfaces only a code; pull the DISM log tail to detect the
                    # checkpoint/prerequisite case so we can give the operator actionable guidance.
                    $dismLog = $dismLogPath
                    $logTail = ''
                    if (Test-Path $dismLog) {
                        $logTail = (Get-Content $dismLog -Tail 40 -ErrorAction SilentlyContinue) -join "`n"
                    }
                    if ("$injErr`n$logTail" -match '0x800f0823|0x800f081e|checkpoint|prerequisite') {
                        Write-Warning "  This Server 2025 cumulative update likely needs a CHECKPOINT update installed first. Use the catalog's Download button (it bundles the checkpoint), put all the .msu files in one folder, and pass that folder with -UpdatesPath."
                    }
                }
            }
            if ($patchOk) {
                Write-Host "  All updates injected." -ForegroundColor DarkGray
            } else {
                Write-Warning "  One or more updates were not injected; this image may be unpatched. See guidance above."
            }
        }

        # 6a. Remove superseded component payloads so the parent image - and therefore every VM
        #     cloned from it - is substantially smaller. /ResetBase makes the injected cumulative
        #     update permanent, which is exactly what we want for a disposable lab parent. This is
        #     best-effort: a failure here leaves a larger but fully valid, bootable image. Reclaiming
        #     the freed space happens after dismount via Optimize-VHD (step 9).
        if ($patchOk) {
            try {
                Write-Host "  Cleaning up superseded components (/ResetBase) to shrink the image (a few minutes)..." -ForegroundColor DarkGray
                $cleanExe = Join-Path $env:SystemRoot 'System32\dism.exe'
                if (Test-Path $cleanExe) {
                    $cleanScratch = if ($ScratchDir) { @("/ScratchDir:$ScratchDir", "/LogPath:$dismLogPath") } else { @() }
                    & $cleanExe /Image:"$winRoot\" /Cleanup-Image /StartComponentCleanup /ResetBase @cleanScratch
                    if ($LASTEXITCODE -ne 0) { throw "dism /StartComponentCleanup /ResetBase failed (exit code $LASTEXITCODE)." }
                }
                else {
                    Repair-WindowsImage -Path "$winRoot\" -StartComponentCleanup -ResetBase @scratchArg -ErrorAction Stop | Out-Null
                }
                # Mark the now-free blocks (TRIM) so the later Optimize-VHD compaction can reclaim them.
                Optimize-Volume -DriveLetter $winLetter -ReTrim -ErrorAction SilentlyContinue
            }
            catch {
                Write-Warning "  Component cleanup/ResetBase skipped: $($_.Exception.Message). The image will be larger but valid."
            }
        }
        else {
            Write-Verbose "Skipping /ResetBase because updates were not fully injected."
        }

        # 6b. Suppress the OOBE privacy / "send diagnostic data to Microsoft" experience in the
        #     parent image itself. EVERY VM in the lab derives from this image - not just the three
        #     first-tier VMs, but every nested VM SDNMGMT later stands up (AD, Top-of-Rack, WAC,
        #     Network Controller, SLB/MUX, gateways, tenant and web-server VMs). Setting it here once
        #     covers them all and avoids first-boot OOBE pauses that would otherwise stall each
        #     provisioning script. These are the documented Group Policy values, written via reg.exe
        #     so no .NET hive handles remain to block the dismount. The mount key includes the PID so
        #     concurrent GUI/CORE builds do not collide on the machine-global HKLM namespace.
        $swHive = "$winRoot\Windows\System32\config\SOFTWARE"
        if (Test-Path -LiteralPath $swHive) {
            $offKey = "SDNVHD_OFF_$PID"
            $loadOut = reg load "HKLM\$offKey" "$swHive" 2>&1
            if ($LASTEXITCODE -eq 0) {
                try {
                    # "Don't launch privacy settings experience on user logon".
                    $null = reg add "HKLM\$offKey\Policies\Microsoft\Windows\OOBE" /v DisablePrivacyExperience /t REG_DWORD /d 1 /f 2>&1
                    # Pre-set diagnostic data to Required so nothing prompts for it.
                    $null = reg add "HKLM\$offKey\Policies\Microsoft\Windows\DataCollection" /v AllowTelemetry /t REG_DWORD /d 1 /f 2>&1
                    Write-Host "  Disabled the OOBE privacy/diagnostic-data experience in the image." -ForegroundColor DarkGray
                }
                finally {
                    [gc]::Collect()
                    for ($u = 0; $u -lt 5; $u++) {
                        Start-Sleep -Milliseconds 400
                        reg unload "HKLM\$offKey" *>$null
                        if ($LASTEXITCODE -eq 0) { break }
                    }
                }
            }
            else {
                Write-Warning "  Could not load the offline SOFTWARE hive to disable the OOBE privacy experience: $loadOut"
            }
        }

        # 7. Make the VHDX bootable. Use the HOST's bcdboot to service the offline image
        #    (more reliable than the image's own copy), falling back to the image if absent.
        $bcdboot = Join-Path $env:SystemRoot 'System32\bcdboot.exe'
        if (!(Test-Path $bcdboot)) { $bcdboot = Join-Path "$winRoot\" 'Windows\System32\bcdboot.exe' }
        if (!(Test-Path $bcdboot)) { $bcdboot = 'bcdboot.exe' }
        Write-Host "  Writing UEFI boot files (bcdboot)..." -ForegroundColor DarkGray
        $bcdOut = & $bcdboot "$winRoot\Windows" /s $sysRoot /f UEFI 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "bcdboot failed (exit code $LASTEXITCODE): $($bcdOut -join ' ')"
        }

        # 8. Tag the system partition as an EFI System Partition so VM firmware finds it.
        Set-Partition -DiskNumber $disk.Number -PartitionNumber $sysPart.PartitionNumber `
            -GptType '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' -ErrorAction SilentlyContinue

        Write-Host "  $name is bootable and ready." -ForegroundColor DarkGray
        $success = $true
    }
    finally {
        $ProgressPreference = $prevProgress
        $ErrorActionPreference = $prevEA
        if ($disk) { Dismount-VHD -Path $OutPath -ErrorAction SilentlyContinue }

        # 9. On success, compact the dynamic VHDX to reclaim the space freed by /ResetBase. Full mode
        #    needs the disk mounted read-only; this is best-effort so a compaction hiccup never fails
        #    an otherwise-good build. Smaller parents make every downstream copy in New-HyperVSandbox.ps1
        #    (host, SDNMGMT base, and each nested VM) faster.
        if ($success -and (Test-Path $OutPath)) {
            try {
                $beforeGB = (Get-Item $OutPath).Length / 1GB
                Write-Host "  Compacting $name to reclaim freed space (Optimize-VHD, a few minutes)..." -ForegroundColor DarkGray
                Mount-VHD -Path $OutPath -ReadOnly -Passthru | Out-Null
                try { Optimize-VHD -Path $OutPath -Mode Full -ErrorAction Stop }
                finally { Dismount-VHD -Path $OutPath -ErrorAction SilentlyContinue }
                $afterGB = (Get-Item $OutPath).Length / 1GB
                Write-Host ("  Compacted {0}: {1:N1} GB -> {2:N1} GB." -f $name, $beforeGB, $afterGB) -ForegroundColor DarkGray
            }
            catch {
                Write-Warning "  Could not compact $OutPath (left as-is): $($_.Exception.Message)"
                Dismount-VHD -Path $OutPath -ErrorAction SilentlyContinue
            }
        }
        # On failure, remove the partial/non-bootable VHDX so we don't leave tens of GB
        # of bloat behind. The disk must be dismounted (above) before the file can be deleted.
        if (-not $success -and (Test-Path $OutPath)) {
            for ($r = 0; $r -lt 5; $r++) {
                try { Remove-Item $OutPath -Force -ErrorAction Stop; break }
                catch { Start-Sleep -Milliseconds 500 }
            }
            if (Test-Path $OutPath) {
                Write-Warning "Could not delete the incomplete '$OutPath'. Remove it manually before re-running."
            }
            else {
                Write-Verbose "Removed the incomplete '$OutPath' after a failed build."
            }
        }
    }
}

function Test-VHDXPatched {
    <#
        Mounts the finished VHDX, confirms the Windows volume is present, and (when an
        expected KB is supplied) confirms the package is installed. Returns $true/$false.
    #>
    param(
        [string]$VHDPath,
        [string]$ExpectedKB,
        [int64]$ExpectedBuild = 0
    )

    $mounted = $false
    try {
        $disk = Mount-VHD -Path $VHDPath -Passthru | Get-Disk
        $mounted = $true
        Start-Sleep -Seconds 2

        $winDrive = $null
        foreach ($p in (Get-Partition -DiskNumber $disk.Number)) {
            if ($p.DriveLetter -and (Test-Path "$($p.DriveLetter):\Windows\System32\ntoskrnl.exe")) {
                $winDrive = $p.DriveLetter
                break
            }
        }

        if (!$winDrive) {
            Write-Warning "Verification: could not locate the Windows volume inside $VHDPath."
            return $false
        }

        if ($ExpectedKB -or $ExpectedBuild -gt 0) {
            $pkgs = @(Get-WindowsPackage -Path "${winDrive}:\" -ErrorAction SilentlyContinue)

            # The most reliable signal is the OS build revision: a cumulative update's package
            # identity embeds the target revision (e.g. Package_for_RollupFix~...~~26100.32860.x),
            # NOT its KB number. Match on the expected revision first, then fall back to detecting
            # any installed cumulative rollup, and finally the KB string (rarely present).
            $hitBuild = if ($ExpectedBuild -gt 0) {
                $pkgs | Where-Object { $_.PackageName -match "\.$ExpectedBuild\." -or $_.PackageName -match "~$ExpectedBuild\." }
            }
            $rollup = $pkgs | Where-Object { $_.PackageName -match 'RollupFix' -and "$($_.PackageState)" -match 'Installed' }
            $kbNum = if ($ExpectedKB) { $ExpectedKB.TrimStart('K', 'B') } else { $null }
            $hitKb = if ($kbNum) { $pkgs | Where-Object { $_.PackageName -match $kbNum } }

            $label = if ($ExpectedKB) { $ExpectedKB } else { "build 26100.$ExpectedBuild" }
            if ($hitBuild -or $hitKb) {
                Write-Verbose "Verification: $label is present in $([System.IO.Path]::GetFileName($VHDPath))."
                return $true
            }
            elseif ($rollup) {
                Write-Verbose "Verification: a cumulative update rollup is installed in $([System.IO.Path]::GetFileName($VHDPath)) (target $label not matched exactly, but the image is patched)."
                return $true
            }
            else {
                Write-Warning "Verification: no cumulative update was found in $([System.IO.Path]::GetFileName($VHDPath)). The image was built but may be unpatched."
                return $false
            }
        }

        return $true
    }
    catch {
        Write-Warning "Verification failed for ${VHDPath}: $($_.Exception.Message)"
        return $false
    }
    finally {
        if ($mounted) { Dismount-VHD -Path $VHDPath -ErrorAction SilentlyContinue }
    }
}

function Test-CommandSet {
    # Returns the subset of cmdlet names that are NOT available on this host.
    param([string[]]$Names)
    $missing = @()
    foreach ($n in $Names) {
        if (-not (Get-Command $n -ErrorAction SilentlyContinue)) { $missing += $n }
    }
    return , $missing
}

function Get-FreeSpaceGB {
    # Free space (GB) for the drive that hosts $Path. $Path need not exist yet.
    param([string]$Path)
    try {
        $root = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($Path))
        if (-not $root) { return $null }
        $di = New-Object System.IO.DriveInfo($root)
        if (-not $di.IsReady) { return $null }
        return [math]::Round($di.AvailableFreeSpace / 1GB, 1)
    }
    catch { return $null }
}

function Invoke-Preflight {
    <#
        Validates the host and inputs and fails fast with actionable guidance BEFORE
        anything is downloaded or installed. Hard problems throw a consolidated error;
        soft problems are surfaced as warnings and allow the build to proceed.
    #>
    param(
        [bool]$BuildGUI,
        [bool]$BuildCORE,
        [bool]$DownloadISO,
        [bool]$DownloadUpdates,
        [string]$IsoPath,
        [string]$GuiOut,
        [string]$CoreOut,
        [string]$WorkPath,
        [bool]$Parallel
    )

    Write-Verbose "Running pre-flight checks..."
    $fail = New-Object System.Collections.Generic.List[string]
    $warn = New-Object System.Collections.Generic.List[string]

    # 1. Administrator.
    if (-not (Test-IsAdmin)) {
        $fail.Add("Not elevated. Close this window and re-launch PowerShell with 'Run as administrator'.")
    }

    # 2. 64-bit OS / process (image servicing requires 64-bit).
    if (-not [Environment]::Is64BitOperatingSystem) {
        $fail.Add("A 64-bit operating system is required to service Windows Server 2025 images.")
    }
    if (-not [Environment]::Is64BitProcess) {
        $warn.Add("This is a 32-bit PowerShell process; launch the 64-bit PowerShell to avoid DISM file-system redirection problems.")
    }

    # 3. DISM servicing cmdlets (the 'Dism' module powers update injection and image export).
    $missingDism = Test-CommandSet @('Get-WindowsImage', 'Add-WindowsPackage', 'Export-WindowsImage', 'Get-WindowsPackage')
    if ($missingDism.Count -gt 0) {
        $fail.Add("DISM servicing cmdlets are unavailable ($($missingDism -join ', ')). Run on a full Windows OS, or install the Windows ADK / 'Dism' PowerShell module.")
    }

    # 4. Hyper-V VHD cmdlets (New-VHD / Mount-VHD are used to create the parent VHDX).
    $missingHv = Test-CommandSet @('New-VHD', 'Mount-VHD', 'Dismount-VHD')
    if ($missingHv.Count -gt 0) {
        $fail.Add("Hyper-V PowerShell cmdlets are unavailable ($($missingHv -join ', ')). On Windows Server: 'Install-WindowsFeature Hyper-V-PowerShell'. On Windows client: 'Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-Management-PowerShell'.")
    }

    # 5. Storage cmdlets for mounting the ISO and the finished VHDX.
    $missingStor = Test-CommandSet @('Mount-DiskImage', 'Dismount-DiskImage', 'Get-Volume')
    if ($missingStor.Count -gt 0) {
        $fail.Add("Storage cmdlets are unavailable ($($missingStor -join ', ')).")
    }

    # 6. ISO inputs.
    if ($IsoPath -and -not (Test-Path $IsoPath)) {
        $fail.Add("The ISO specified by -IsoPath was not found: $IsoPath")
    }
    if (-not $IsoPath -and -not $DownloadISO) {
        $fail.Add("No -IsoPath supplied and -DownloadISO is `$false. Provide an ISO or allow the download.")
    }

    # 7. Disk space. Estimate ~35 GB committed per patched dynamic parent image, plus the
    #    ISO cache (~9 GB), a temporary WIM export (~6 GB), and the CU download (~3 GB).
    #    Requirements are grouped by drive so co-located outputs are summed.
    $perImageGB = 35
    $reqs = @()
    if ($BuildGUI) { $reqs += @{ Path = $GuiOut; GB = $perImageGB } }
    if ($BuildCORE) { $reqs += @{ Path = $CoreOut; GB = $perImageGB } }
    $workNeed = 6
    if ($DownloadISO -or $IsoPath) { $workNeed += 9 }
    if ($DownloadUpdates) { $workNeed += 3 }
    # Parallel mode services both images at once with two separate DISM scratch dirs, so
    # budget extra working space for the concurrent component-store expansion.
    if ($Parallel -and $BuildGUI -and $BuildCORE) { $workNeed += 8 }
    $reqs += @{ Path = $WorkPath; GB = $workNeed }

    $byRoot = @{}
    foreach ($r in $reqs) {
        $root = $null
        try { $root = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($r.Path)) } catch {}
        if (-not $root) { continue }
        if ($byRoot.ContainsKey($root)) { $byRoot[$root] += $r.GB } else { $byRoot[$root] = $r.GB }
    }
    foreach ($root in $byRoot.Keys) {
        $req = $byRoot[$root]
        $free = Get-FreeSpaceGB -Path $root
        if ($null -eq $free) {
            $warn.Add("Could not determine free space on '$root' (UNC path or drive not ready). Ensure at least ~$req GB is free there.")
        }
        elseif ($free -lt $req) {
            $fail.Add("Insufficient free space on '$root': $free GB free, ~$req GB required.")
        }
        else {
            Write-Verbose "Disk space OK on ${root}: $free GB free (need ~$req GB)."
        }
    }

    # 8. Network is needed when downloading the ISO and/or querying the Update Catalog.
    $needNet = $DownloadISO -or $DownloadUpdates

    # 9. Internet reachability (soft) when a download/install is implied.
    if ($needNet) {
        $online = $false
        try {
            $null = Invoke-WebRequest -Uri 'https://www.microsoft.com' -UseBasicParsing -TimeoutSec 15 -Method Head
            $online = $true
        }
        catch { $online = $false }
        if (-not $online) {
            $warn.Add("Could not reach the internet. ISO / update / module downloads may fail. For an offline build, pre-install the modules and pass -IsoPath and -UpdatesPath with -DownloadISO:`$false -DownloadUpdates:`$false.")
        }
    }

    # 10. Evaluation-media licensing reminder (informational).
    if ($DownloadISO -and -not $IsoPath) {
        $warn.Add("The auto-downloaded ISO is the Evaluation edition (expires ~180 days; reports an *Eval EditionId). Supply -IsoPath with retail media for a licensed or long-lived lab.")
    }

    foreach ($w in $warn) { Write-Warning $w }

    if ($fail.Count -gt 0) {
        $msg = "Pre-flight checks failed:`n" + (($fail | ForEach-Object { "  - $_" }) -join "`n")
        throw $msg
    }
    Write-Verbose "Pre-flight checks passed."
}

function Get-BuildSpec {
    # Resolve everything needed to build one parent image (index, output path, dedicated
    # scratch dir) so the sequential and parallel code paths share identical inputs.
    param(
        [object[]]$Images,
        [string]$Type,        # GUI or CORE
        [string]$Edition,
        [string]$OutPath,
        [string]$WorkPath
    )
    $idx = Select-ImageIndex -Images $Images -Type $Type -Edition $Edition
    if (!$idx) {
        $desc = if ($Type -eq 'GUI') { 'Desktop Experience (GUI)' } else { 'Server Core (CORE)' }
        throw "Could not find a '$Edition' $desc image in the ISO."
    }
    return @{
        Type             = $Type
        Label            = if ($Type -eq 'GUI') { 'GUI.vhdx' } else { 'CORE.vhdx' }
        Index            = $idx.Index
        EditionId        = $idx.EditionId
        InstallationType = $idx.InstallationType
        OutPath          = $OutPath
        ScratchDir       = [System.IO.Path]::Combine($WorkPath, "Scratch-$Type")
    }
}

function Invoke-ParallelBuild {
    <#
        Builds two parent VHDXs concurrently in separate elevated PowerShell background jobs
        (Start-Job). Each job runs only the native converter against the parent-mounted ISO,
        writing to its own VHDX with a dedicated scratch dir. The converter and its helper
        dependencies are marshaled into each job as text (Start-Job has no $using: support).
        Returns one result object per spec: @{ Spec; Success }.
    #>
    param(
        [hashtable[]]$Specs,
        [string]$SourcePath,
        [bool]$IsEsd,
        [uint64]$SizeBytes,
        [string[]]$Packages
    )

    # Marshal the converter + the helper functions it calls into each job.
    $fnNames = @('Format-Elapsed', 'Wait-PartitionDriveLetter', 'Convert-ToParentVHDX')
    $fnText = ($fnNames | ForEach-Object { "function $_ {`n$((Get-Command $_).Definition)`n}" }) -join "`n`n"

    # File paths can never contain '|', so it is a safe delimiter. (Passing the array via
    # -ArgumentList would be flattened/unrolled by Start-Job and mis-bind the trailing args.)
    $packagesJoined = if ($Packages) { ($Packages -join '|') } else { '' }

    $jobSb = {
        param($FnText, $SourcePath, $IsEsd, $Index, $OutPath, $SizeBytes, $ScratchDir, $PackagesJoined)
        $ErrorActionPreference = 'Stop'
        $ProgressPreference = 'SilentlyContinue'
        Import-Module Dism, Storage, Hyper-V -ErrorAction SilentlyContinue
        . ([scriptblock]::Create($FnText))
        $pkgs = if ([string]::IsNullOrEmpty($PackagesJoined)) { @() } else { $PackagesJoined -split '\|' }
        Convert-ToParentVHDX -SourcePath $SourcePath -IsEsd $IsEsd -Index $Index `
            -OutPath $OutPath -SizeBytes $SizeBytes -Packages $pkgs -ScratchDir $ScratchDir
    }

    $entries = @()
    foreach ($s in $Specs) {
        Write-Host "  Starting $($s.Label) build (index $($s.Index) [$($s.EditionId) / $($s.InstallationType)])..." -ForegroundColor DarkGray
        $job = Start-Job -Name $s.Label -ScriptBlock $jobSb -ArgumentList `
            $fnText, $SourcePath, $IsEsd, $s.Index, $s.OutPath, $SizeBytes, $s.ScratchDir, $packagesJoined
        $entries += [pscustomobject]@{ Spec = $s; Job = $job }
    }
    # Track the live jobs so the main finally can stop them if the run is interrupted.
    $script:BuildJobs = @($entries | ForEach-Object { $_.Job })

    Write-Host "  Both builds are running concurrently - no live progress bar is shown in parallel mode." -ForegroundColor DarkGray
    Write-Host "  Heartbeat updates print every 30s (each image typically takes 15-40 minutes)..." -ForegroundColor DarkGray

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($entries | Where-Object { $_.Job.State -eq 'Running' }) {
        Start-Sleep -Seconds 30
        $status = ($entries | ForEach-Object { "$($_.Spec.Label): $($_.Job.State)" }) -join '  |  '
        Write-Host "  [$(Format-Elapsed $sw.Elapsed)] $status" -ForegroundColor DarkGray
    }
    $sw.Stop()

    $results = @()
    foreach ($entry in $entries) {
        $ok = $false
        try {
            # Surface the job's warnings to the parent; drop its (replayed) Write-Host noise.
            Receive-Job -Job $entry.Job -ErrorAction Stop 6>$null | Out-Null
            $ok = ($entry.Job.State -eq 'Completed')
        }
        catch {
            Write-Warning "  $($entry.Spec.Label) build failed: $($_.Exception.Message)"
            $ok = $false
        }
        Remove-Job -Job $entry.Job -Force -ErrorAction SilentlyContinue
        $results += [pscustomobject]@{ Spec = $entry.Spec; Success = $ok }
    }
    $script:BuildJobs = @()
    return $results
}

#endregion helpers

#region main

# Keep all build artifacts on the drive the script was launched from (off C: by default).
$launchRoot = Get-LaunchDriveRoot
if (-not $PSBoundParameters.ContainsKey('WorkPath') -or [string]::IsNullOrWhiteSpace($WorkPath)) {
    $WorkPath = Join-Path $launchRoot 'SDNVHDBuild'
}
Write-Verbose "Launch drive: $launchRoot   Work/temp folder: $WorkPath"

# Resolve output paths from the configuration file, re-based onto the launch drive so the
# final images land in <launchDrive>\SDNVHDs and the deployment (New-HyperVSandbox.ps1, which
# reads the same config) finds them in the same place.
$guiOut = $null
$coreOut = $null
if (Test-Path $ConfigurationDataFile) {
    $cfgResolved = (Resolve-Path $ConfigurationDataFile).Path
    $SDNConfig = Import-PowerShellDataFile -Path $cfgResolved
    $guiOut = ConvertTo-DriveRootedPath -Path $SDNConfig.guiVHDXPath -DriveRoot $launchRoot
    $coreOut = ConvertTo-DriveRootedPath -Path $SDNConfig.coreVHDXPath -DriveRoot $launchRoot

    # Persist the re-based paths so the build output and the deployment stay in sync.
    $changed = $false
    if ($guiOut -and $guiOut -ne $SDNConfig.guiVHDXPath) {
        if (Set-Psd1StringValue -Psd1Path $cfgResolved -Key 'guiVHDXPath' -Value $guiOut) { $changed = $true }
    }
    if ($coreOut -and $coreOut -ne $SDNConfig.coreVHDXPath) {
        if (Set-Psd1StringValue -Psd1Path $cfgResolved -Key 'coreVHDXPath' -Value $coreOut) { $changed = $true }
    }
    if ($changed) {
        Write-Host "  Updated $cfgResolved to keep the parent images on the launch drive:" -ForegroundColor Cyan
        Write-Host "    guiVHDXPath  = $guiOut" -ForegroundColor DarkGray
        Write-Host "    coreVHDXPath = $coreOut" -ForegroundColor DarkGray
    }
    Write-Verbose "Output paths: GUI='$guiOut' CORE='$coreOut'"
}
else {
    Write-Warning "Configuration file '$ConfigurationDataFile' not found. Defaulting output to $launchRoot\SDNVHDs."
    $guiOut = Join-Path $launchRoot 'SDNVHDs\GUI.vhdx'
    $coreOut = Join-Path $launchRoot 'SDNVHDs\CORE.vhdx'
}

# Decide what to build.
$buildGUI = ($VHDType -eq 'GUI' -or $VHDType -eq 'Both')
$buildCORE = ($VHDType -eq 'CORE' -or $VHDType -eq 'Both')

# Pre-flight: validate the host and inputs and fail fast with actionable guidance
# BEFORE anything is downloaded or installed.
Invoke-Preflight -BuildGUI $buildGUI -BuildCORE $buildCORE -DownloadISO $DownloadISO `
    -DownloadUpdates $DownloadUpdates -IsoPath $IsoPath -GuiOut $guiOut -CoreOut $coreOut `
    -WorkPath $WorkPath -Parallel $Parallel.IsPresent

# Parallel only applies when both images are being built; otherwise fall back to sequential.
$useParallel = $Parallel.IsPresent -and $buildGUI -and $buildCORE
if ($Parallel.IsPresent -and -not $useParallel) {
    Write-Warning "-Parallel has no effect when only one image is selected; building sequentially."
}

# Start the overall timer and compute how many phases we will report.
$swOverall = [System.Diagnostics.Stopwatch]::StartNew()
$script:PhaseNum = 0
$script:PhaseTotal = 2  # media + read catalog
if ($DownloadUpdates -or $UpdatesPath) { $script:PhaseTotal++ }
if ($useParallel) {
    $script:PhaseTotal++            # one combined parallel build phase
}
else {
    if ($buildGUI) { $script:PhaseTotal++ }
    if ($buildCORE) { $script:PhaseTotal++ }
}

# Ensure the imaging modules are present is no longer required: image apply, update
# injection and VHDX creation all use native DISM, Storage and Hyper-V cmdlets that
# were verified by the pre-flight check.

# Acquire the ISO.
$isoMountedByScript = $false
$srcInfo = $null
$script:BuildJobs = @()
try {
    Write-Phase -Title 'Preparing the installation media (ISO)'
    if ($IsoPath) {
        if (!(Test-Path $IsoPath)) { throw "The ISO specified by -IsoPath was not found: $IsoPath" }
        $isoToUse = (Resolve-Path $IsoPath).Path
        Write-Host "  Using supplied ISO: $isoToUse" -ForegroundColor DarkGray
    }
    elseif ($DownloadISO) {
        $isoToUse = Get-EvalISO -Url $IsoUrl -DestFolder $WorkPath
    }
    else {
        throw "No -IsoPath supplied and -DownloadISO is `$false. Provide an ISO or allow the download."
    }

    # Acquire updates (best-effort).
    $cuInfo = $null
    if ($DownloadUpdates -or $UpdatesPath) {
        Write-Phase -Title 'Acquiring the latest Windows updates'
    }
    if ($DownloadUpdates) {
        $cuInfo = Get-LatestServerCU -DestFolder (Join-Path $WorkPath 'Updates')
    }
    $autoCU = if ($cuInfo) { $cuInfo.TargetFile } else { $null }
    $packages = Resolve-UpdatePackages -AutoCU $autoCU -UpdatesPath $UpdatesPath
    $expectedKB = if ($cuInfo) { $cuInfo.KB } else { $null }
    $expectedBuild = if ($cuInfo) { $cuInfo.Build } else { $null }

    if ($packages.Count -gt 0) {
        Write-Host "  $($packages.Count) update package(s) will be injected:" -ForegroundColor DarkGray
        $packages | ForEach-Object { Write-Host "    $([System.IO.Path]::GetFileName($_))" -ForegroundColor DarkGray }
        if ($cuInfo -and $cuInfo.Files.Count -gt 1) {
            Write-Host "  (plus a checkpoint prerequisite that DISM will install automatically from the same folder)" -ForegroundColor DarkGray
        }
    }
    else {
        Write-Warning "No update packages will be injected. The resulting images will not be patched."
    }

    # Enumerate the images in the ISO.
    Write-Phase -Title 'Reading the image catalog from the ISO'
    Write-Host "  Mounting the ISO and listing the available editions..." -ForegroundColor DarkGray
    $srcInfo = Get-SourceImageInfo -IsoPath $isoToUse
    $isoMountedByScript = $true
    $srcInfo.Images | Format-Table Index, InstallationType, EditionId, ImageName -AutoSize | Out-String | Write-Verbose

    # Resolve build inputs for the requested image(s) (shared by both code paths).
    $buildSpecs = @()
    if ($buildGUI) { $buildSpecs += Get-BuildSpec -Images $srcInfo.Images -Type 'GUI' -Edition $Edition -OutPath $guiOut -WorkPath $WorkPath }
    if ($buildCORE) { $buildSpecs += Get-BuildSpec -Images $srcInfo.Images -Type 'CORE' -Edition $Edition -OutPath $coreOut -WorkPath $WorkPath }

    if ($useParallel) {
        # Build both images concurrently in background jobs, then verify each in the parent.
        Write-Phase -Title 'Building GUI.vhdx and CORE.vhdx in parallel' -Note 'Both run concurrently to use idle CPU/disk; expect roughly 15-40 minutes total.'
        $results = Invoke-ParallelBuild -Specs $buildSpecs -SourcePath $srcInfo.WimPath `
            -IsEsd $srcInfo.IsEsd -SizeBytes $VHDSize -Packages $packages
        foreach ($r in $results) {
            if ($r.Success -and (Test-Path $r.Spec.OutPath)) {
                Write-Host "  Verifying $($r.Spec.Label) was patched..." -ForegroundColor DarkGray
                if (Test-VHDXPatched -VHDPath $r.Spec.OutPath -ExpectedKB $expectedKB -ExpectedBuild $expectedBuild) {
                    Write-Host "  $($r.Spec.Label) complete: $($r.Spec.OutPath)" -ForegroundColor Green
                }
                else {
                    Write-Warning "  $($r.Spec.Label) was built but could not be verified as patched: $($r.Spec.OutPath)"
                }
            }
            else {
                Write-Warning "  $($r.Spec.Label) was NOT built successfully (see the messages above)."
            }
        }
    }
    else {
        # Sequential build: one image at a time, with the live DISM progress bar.
        foreach ($spec in $buildSpecs) {
            Write-Phase -Title "Building $($spec.Label) ($($spec.EditionId) / $($spec.InstallationType))" -Note 'One of the longest steps - expect roughly 15-40 minutes.'
            Write-Host "  Selected image index $($spec.Index) [$($spec.EditionId) / $($spec.InstallationType)]" -ForegroundColor DarkGray
            Convert-ToParentVHDX -SourcePath $srcInfo.WimPath -IsEsd $srcInfo.IsEsd -Index $spec.Index `
                -OutPath $spec.OutPath -SizeBytes $VHDSize -Packages $packages -ScratchDir $spec.ScratchDir
            Write-Host "  Verifying the update was applied..." -ForegroundColor DarkGray
            [void](Test-VHDXPatched -VHDPath $spec.OutPath -ExpectedKB $expectedKB -ExpectedBuild $expectedBuild)
            Write-Host "  $($spec.Label) complete: $($spec.OutPath)" -ForegroundColor Green
        }
    }
}
finally {
    # If the run was interrupted while parallel build jobs are still going, stop them before
    # we dismount the ISO they are reading from.
    if ($script:BuildJobs -and ($script:BuildJobs | Where-Object { $_.State -eq 'Running' })) {
        Write-Warning "Stopping in-progress build jobs before cleanup..."
        $script:BuildJobs | Stop-Job -ErrorAction SilentlyContinue
        $script:BuildJobs | Wait-Job -Timeout 60 | Out-Null
        $script:BuildJobs | Remove-Job -Force -ErrorAction SilentlyContinue
    }
    if ($isoMountedByScript -and $isoToUse) {
        Write-Verbose "Dismounting ISO."
        Dismount-DiskImage -ImagePath $isoToUse -ErrorAction SilentlyContinue | Out-Null
    }
}

$swOverall.Stop()
Write-Host "`nFinished building parent VHDX image(s) in $(Format-Elapsed $swOverall.Elapsed)." -ForegroundColor Green
if ($buildGUI) { Write-Host "  GUI : $guiOut" -ForegroundColor Green }
if ($buildCORE) { Write-Host "  CORE: $coreOut" -ForegroundColor Green }

$ErrorActionPreference = "Continue"
$VerbosePreference = "SilentlyContinue"
$ProgressPreference = "Continue"

#endregion main
