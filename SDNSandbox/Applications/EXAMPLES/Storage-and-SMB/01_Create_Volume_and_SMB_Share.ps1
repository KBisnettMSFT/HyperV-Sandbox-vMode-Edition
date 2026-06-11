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

# 3. Find the Cluster Shared Volume created for this volume, then create the SMB share on the CSV
#    owner node (that is where the C:\ClusterStorage path physically exists). New-Volume creates a
#    "Cluster Virtual Disk (<FriendlyName>)" resource, so match the CSV by the volume name.
$csv = Get-ClusterSharedVolume -Cluster $ClusterName |
    Where-Object { $_.Name -like "*$VolumeName*" } | Select-Object -First 1
if (-not $csv) {
    throw "Could not find a Cluster Shared Volume for '$VolumeName' on $ClusterName. Check 'Get-ClusterSharedVolume -Cluster $ClusterName'."
}
$csvPath   = $csv.SharedVolumeInfo.FriendlyVolumeName   # e.g. C:\ClusterStorage\Volume2
$ownerNode = $csv.OwnerNode.Name
$sharePath = Join-Path $csvPath $ShareName

# Create the folder and the SMB share on the CSV owner node (run remotely so the path resolves there).
Invoke-Command -ComputerName $ownerNode -ArgumentList $sharePath, $ShareName -ScriptBlock {
    param($Path, $Name)
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    if (-not (Get-SmbShare -Name $Name -ErrorAction SilentlyContinue)) {
        New-SmbShare -Name $Name -Path $Path -FullAccess 'contoso\Administrator' | Out-Null
        Write-Host "Created SMB share \\$env:COMPUTERNAME\$Name -> $Path" -ForegroundColor Green
    }
    else {
        Write-Host "SMB share '$Name' already exists on $env:COMPUTERNAME - skipping." -ForegroundColor Yellow
    }
}

Write-Host "`nInspect with:" -ForegroundColor Cyan
Write-Host "  Get-SmbShare -CimSession $ownerNode ; Get-Volume -CimSession $ClusterName"
