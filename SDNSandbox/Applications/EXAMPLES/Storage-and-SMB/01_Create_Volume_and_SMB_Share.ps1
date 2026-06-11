<#
.SYNOPSIS
    Storage & SMB starter exercise for the Hyper-V Sandbox - vMode Edition. Creates a new ReFS
    Cluster Shared Volume on the lab's S2D cluster (SDNCLUSTER) and exposes it as an SMB share.

.DESCRIPTION
    Finds the Storage Spaces Direct pool, creates a ReFS CSV volume (idempotent), then creates an
    SMB share on it. For production-grade continuously-available shares, host the share on a
    Scale-Out File Server role - this starter keeps it simple.

.NOTES
    Run from a domain-joined lab VM (the AdminCenter VM or the Console) as contoso\Administrator.
    Requires the FailoverClusters + Storage modules. This MODIFIES the cluster (creates a volume).
    Tune -SizeGB to fit the free pool space the script reports.

.EXAMPLE
    .\01_Create_Volume_and_SMB_Share.ps1
.EXAMPLE
    .\01_Create_Volume_and_SMB_Share.ps1 -VolumeName Demo01 -SizeGB 20 -ShareName Demo01
#>
[CmdletBinding()]
param(
    [string] $ClusterName = 'SDNCLUSTER',
    [string] $VolumeName  = 'SandboxVol01',
    [uint64] $SizeGB      = 10,
    [string] $ShareName   = 'SandboxShare'
)

Import-Module FailoverClusters -ErrorAction Stop
Import-Module Storage -ErrorAction Stop

# 1. Find the Storage Spaces Direct pool on the cluster.
$pool = Get-StoragePool -CimSession $ClusterName -IsPrimordial $false -ErrorAction Stop |
    Where-Object { $_.FriendlyName -like 'S2D*' } | Select-Object -First 1
if (-not $pool) { throw "No Storage Spaces Direct pool found on $ClusterName." }
$freeGB = [math]::Round(($pool.Size - $pool.AllocatedSize) / 1GB)
Write-Host "Using pool '$($pool.FriendlyName)' - approx ${freeGB} GB free." -ForegroundColor Cyan

# 2. Create the ReFS Cluster Shared Volume (skip if it already exists).
if (-not (Get-Volume -CimSession $ClusterName -FriendlyName $VolumeName -ErrorAction SilentlyContinue)) {
    New-Volume -CimSession $ClusterName -StoragePoolFriendlyName $pool.FriendlyName `
        -FriendlyName $VolumeName -FileSystem CSVFS_ReFS -Size ($SizeGB * 1GB) | Out-Null
    Write-Host "Created CSV volume '$VolumeName' (${SizeGB} GB)." -ForegroundColor Green
}
else {
    Write-Host "Volume '$VolumeName' already exists - skipping creation." -ForegroundColor Yellow
}

# 3. Create a folder on the CSV and share it over SMB.
$csvPath = Join-Path 'C:\ClusterStorage' $VolumeName
if (-not (Test-Path -LiteralPath $csvPath)) {
    # New-Volume names the CSV mount point after the volume; fall back to the newest CSV if needed.
    $csv = Get-ClusterSharedVolume -Cluster $ClusterName | Sort-Object Name | Select-Object -Last 1
    $csvPath = $csv.SharedVolumeInfo.FriendlyVolumeName
}
$sharePath = Join-Path $csvPath $ShareName
New-Item -ItemType Directory -Path $sharePath -Force | Out-Null

if (-not (Get-SmbShare -Name $ShareName -CimSession $ClusterName -ErrorAction SilentlyContinue)) {
    New-SmbShare -Name $ShareName -Path $sharePath -FullAccess 'contoso\Administrator' -CimSession $ClusterName | Out-Null
    Write-Host "Created SMB share \\$ClusterName\$ShareName -> $sharePath" -ForegroundColor Green
}
else {
    Write-Host "SMB share '$ShareName' already exists - skipping." -ForegroundColor Yellow
}

Write-Host "`nInspect with:" -ForegroundColor Cyan
Write-Host "  Get-SmbShare -CimSession $ClusterName ; Get-Volume -CimSession $ClusterName"
