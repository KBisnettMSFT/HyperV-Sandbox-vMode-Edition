# Storage & SMB — Hyper-V Sandbox · vMode Edition

The lab's `SDNCLUSTER` uses **Storage Spaces Direct (S2D)** with **Cluster Shared Volumes (CSV)**
and **SMB** as its storage fabric (the hosts also carry dedicated Storage VLANs). Use this track
to practice creating volumes and SMB shares on disposable cluster storage.

## What the lab already gives you
- An S2D storage pool on `SDNCLUSTER`, with ReFS CSV volumes under `C:\ClusterStorage`
- Dedicated storage networks (StorageA / StorageB VLANs) on the hosts

## Prerequisites
- Run from a domain-joined lab VM (the **AdminCenter** VM or the **Console**) as `contoso\Administrator`.
- FailoverClusters + Storage RSAT modules.

## Starter exercise
- [`01_Create_Volume_and_SMB_Share.ps1`](01_Create_Volume_and_SMB_Share.ps1) — creates a new ReFS CSV volume on the S2D pool and shares it over SMB. **This modifies the cluster** — tune `-SizeGB` to the free pool space reported by the script.

## Ideas to explore next
- Continuously-available SMB via a **Scale-Out File Server (SOFS)** role
- Storage QoS policies
- ReFS vs NTFS; mirror vs parity resiliency
- SMB Multichannel / RDMA (where the fabric supports it)
