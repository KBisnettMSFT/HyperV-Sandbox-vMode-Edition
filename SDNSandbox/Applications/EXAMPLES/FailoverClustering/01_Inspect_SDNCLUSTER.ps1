<#
.SYNOPSIS
    Failover Clustering starter exercise for the Hyper-V Sandbox - vMode Edition.
    Read-only inventory and health check of the lab's two-node Storage Spaces Direct cluster.

.DESCRIPTION
    Prints the cluster, its nodes, networks, Cluster Shared Volumes, the S2D pool, and core
    resources. Makes NO changes - a safe first look before you start experimenting.

.NOTES
    Run from a domain-joined lab VM (the AdminCenter VM or the Console) as contoso\Administrator.
    Requires the FailoverClusters module (Install-WindowsFeature RSAT-Clustering-PowerShell).

.EXAMPLE
    .\01_Inspect_SDNCLUSTER.ps1
#>
[CmdletBinding()]
param(
    [string] $ClusterName = 'SDNCLUSTER'
)

Import-Module FailoverClusters -ErrorAction Stop

Write-Host '== Cluster ==' -ForegroundColor Cyan
Get-Cluster -Name $ClusterName | Format-List Name, Domain, SharedVolumesRoot

Write-Host '== Nodes ==' -ForegroundColor Cyan
Get-ClusterNode -Cluster $ClusterName | Format-Table Name, State, DynamicWeight -AutoSize

Write-Host '== Networks ==' -ForegroundColor Cyan
Get-ClusterNetwork -Cluster $ClusterName | Format-Table Name, Role, Address, State -AutoSize

Write-Host '== Cluster Shared Volumes ==' -ForegroundColor Cyan
Get-ClusterSharedVolume -Cluster $ClusterName | Format-Table Name, State, OwnerNode -AutoSize

Write-Host '== Storage Spaces Direct pool ==' -ForegroundColor Cyan
Get-StoragePool -CimSession $ClusterName -IsPrimordial $false -ErrorAction SilentlyContinue |
    Format-Table FriendlyName, HealthStatus,
        @{ N = 'Size(GB)';  E = { [math]::Round($_.Size / 1GB) } },
        @{ N = 'Alloc(GB)'; E = { [math]::Round($_.AllocatedSize / 1GB) } } -AutoSize

Write-Host '== Cluster core resources ==' -ForegroundColor Cyan
Get-ClusterResource -Cluster $ClusterName | Format-Table Name, State, OwnerGroup -AutoSize
