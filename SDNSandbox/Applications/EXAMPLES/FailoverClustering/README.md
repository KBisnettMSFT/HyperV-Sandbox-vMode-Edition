# Failover Clustering — Hyper-V Sandbox · vMode Edition

The lab builds a **two-node Storage Spaces Direct (S2D) failover cluster** named **`SDNCLUSTER`**
on `SDNHOST1` and `SDNHOST2`. Use it to learn Failover Clustering and S2D hands-on, on disposable
infrastructure.

## What the lab already gives you
- Cluster: **SDNCLUSTER** (nodes: `SDNHOST1`, `SDNHOST2`)
- Storage Spaces Direct enabled, with Cluster Shared Volumes under `C:\ClusterStorage`
- Desktop shortcut on the AdminCenter VM: **Failover Cluster Manager**

## Prerequisites
- Run from a domain-joined lab VM (the **AdminCenter** VM or the **Console**) as `contoso\Administrator`.
- FailoverClusters RSAT module: `Install-WindowsFeature RSAT-Clustering-PowerShell`.

## Starter exercise
- [`01_Inspect_SDNCLUSTER.ps1`](01_Inspect_SDNCLUSTER.ps1) — read-only health and inventory of the cluster, nodes, networks, Cluster Shared Volumes, and the S2D pool. Safe to run.

## Ideas to explore next
- Drain and resume a node (`Suspend-ClusterNode` / `Resume-ClusterNode`) and watch roles move
- Create or resize CSV volumes (see the **Storage & SMB** track)
- Cluster-Aware Updating (CAU)
- Quorum and witness configuration
