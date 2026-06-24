# Hyper-V Sandbox — vMode Edition — Guide (updated 2026-06-11)

**Hyper-V Sandbox — vMode Edition** is a set of PowerShell scripts that create a [HyperConverged](https://docs.microsoft.com/en-us/windows-server/hyperconverged/) Windows Server lab using nested Hyper-V virtual machines. It provides operational training and a development/validation environment for modern Windows Server (2025 / vNext) datacenter features — **Active Directory, Failover Clustering, SMB & Storage Spaces Direct, Windows Admin Center (including Virtualization Mode / "vMode"), and Software-Defined Networking (SDN)** — without the time-consuming process of setting up physical servers, switches, and routers. SDN remains a first-class scenario (see the `SDNEXAMPLES` walkthroughs and `SDNExpress` tooling).

>**This is not a production solution!** The Hyper-V Sandbox scripts are tuned for a limited-resource lab. The environment is not fault tolerant, not highly available, and slower than a real deployment. Never use real credentials or production networks.

Also note that the lab is managed by **Windows Admin Center** (not System Center Virtual Machine Manager / SCVMM).

### A note on names

The product is **Hyper-V Sandbox — vMode Edition**, but some internal identifiers keep their historical `SDN` prefix for stability — the VM names (`SDNMGMT`, `SDNHOST1/2`), the `SDN*` config keys, and the `SDNSandbox-Config.psd1` filename. The `SDNEXAMPLES`/`SDNExpress` content keeps "SDN" because that is the correct technical term. 

## History

This project began in 2016 as a fast way to spin up online labs for **Microsoft SDN** (originally via SCVMM). It has since grown into a broader **Hyper-V Sandbox** for learning and validating Windows Server virtualization — Active Directory, Failover Clustering, SMB, Storage, and Windows Admin Center vMode — while keeping SDN at the forefront.


## Quick Start (TLDR)

You probably are not going to read the requirements listed below, so here are the steps to get the Hyper-V Sandbox up and running on a **single host** :

1. Download and unzip this solution to a drive on a x86 System with at least 64gb of RAM, 2025 (or higher) Hyper-V Installed, and , optionally, a External Switch attached to a network that can route to the Internet and provides DHCP.

2. Create the GUI.vhdx and CORE.vhdx parent images. The easiest way is to run ``.\New-SDNVHDfromISO.ps1`` from an elevated PowerShell console with **no parameters** - it will automatically download the Windows Server 2025 Evaluation ISO, download the latest cumulative update, and build **both** GUI.vhdx (Datacenter Desktop Experience) and CORE.vhdx (Datacenter Core) - fully patched - at the paths defined in the configuration file. (See "Building the VHDX files" below for options such as using your own ISO or offline updates.)

3. Edit the .PSD1 configuration file (do not rename it) to set:
    
    * Product Key for 2025 Datacenter (or just use the provide product key which assumes you have a KMS server to activate the image.  
      
    >**Warning!** The Configuration file will be copied to the console drive during install. **The product keys will be in plain text and not deleted or hidden!**     
    
    * The paths to the VHDX files that you just created.
    * Set ``HostVMPath`` where your VHDX files will reside. (*Ensure that there is at least 250gb of free space!*)
    * Optionally, set the name of your external switch that has access to the internet in the ``natExternalVMSwitchName = `` setting and optionally the VLAN for it in the ``natVLANID``. If you don't want Internet access, set ``natConfigure`` to ``$false``.

4. On the Hyper-V Host, open up a PowerShell console (with admin rights) and navigate to the ``SDNSandbox`` folder and run ``.\New-HyperVSandbox``. (The legacy ``.\New-SDNSandbox`` name still works via a deprecation shim.)

7. It should take a up to 2 hours to deploy.

8. Using RDP, log into the Console with your creds: User: Contoso\Administrator Password: Password01

9. Launch the link to Windows Admin Center

10. Add the Hyper-Converged Cluster *SDNCluster* to *Windows Admin Center* with *Network Controller*: [https://nc01.contosoc.com](https://nc01.contosoc.com) and you're off and ready to go!

![alt text](res/AddHCCluster.png "Add Hyper-Converged Cluster Connection")

## Configuration Overview

The Hyper-V Sandbox will automatically create and configure the following:

* Active Directory virtual machine
* Windows Admin Center virtual machine
* Routing and Remote Access virtual machine (to emulate a *Top of Rack (ToR)* switch)
* Two node Hyper-V S2D cluster with each having a SET Switch
* Management and Provider VLAN and networks 
* Private, Public, and GRE VIPs automatically configured in Network Controller
* VLAN to provide testing for L3 Gateway Connections


## Learning scenarios

Beyond SDN, the lab surfaces guided example tracks (copied to ``C:\EXAMPLES`` on the AdminCenter VM, each with a matching desktop shortcut):

| Track | Desktop shortcut | Folder |
|---|---|---|
| Active Directory | **Active Directory Examples** | ``Applications/EXAMPLES/ActiveDirectory`` |
| Failover Clustering | **Clustering Examples** | ``Applications/EXAMPLES/FailoverClustering`` |
| Storage & SMB | **Storage and SMB Examples** | ``Applications/EXAMPLES/Storage-and-SMB`` |
| Software-Defined Networking | **SDN Examples** | ``Applications/SDNEXAMPLES`` |

Each track has a README and a starter exercise. The **Failover Cluster Manager**, **DNS**, and **Active Directory Users and Computers** desktop shortcuts complement them.

## Hardware Prerequisites

The Hyper-V Sandbox can run on either a single host or up to 4 Hyper-V hosts connected with either a dumb hub, direct connection (between 2 hosts), unmanaged switch, or a managed switch with the VLANs attached trunked to each used port.

|  Number of Hyper-V Hosts | Memory per Host   | HD Available Free Space   | Processor   |  Hyper-V Switch Type |
|---|---|---|---|---|
| 1  | 64gb | 250gb SSD\NVME   | Intel - 4 core Hyper-V Capable with SLAT   | Installed Automatically by Script  |
| 2 |  32gb | 150gb SSD\NVME   | Intel - 4 core Hyper-V Capable with SLAT   | Same Name External Switch on each host  |
| 4  | 16gb | 150gb SSD\NVME   | Intel - 4 core Hyper-V Capable with SLAT   | Same Name External Switch on each host  |


> **WAC Virtualization Mode (vMode):** The lab now provisions an always-on `wacvmode` VM on SDNMGMT, so SDNMGMT uses 32 GB (up from 24 GB) and the host memory reserve is correspondingly higher. Ensure the physical host has headroom for SDNMGMT (32 GB) plus the two SDNHOSTs.


Please note the following regarding the hardware setup requirements:

* It is recommended that you disable all disconnected network adapters or network adapters that will not be used.

* It is **STRONGLY** recommended that you use SSD or NVME drives (especially in single-host). This project has been tested on a single host with four 5400rpm drives in a Storage Spaces pool with acceptable results, but there are no guarantees.

* If using more than one host, an unmanaged switch or dumb hub should be used to link all of the systems together. If a managed switch is used, ensure that the following VLANS are created and trunked to the ports the host(s) will be using:

   * VLAN 12 – **Provider Network**
   * VLAN 200 - **VLAN for L3 testing** (optional)

> **Note:** The VLANs being used can be changed using the configuration file.

>**Note:** If the default Large MTU (Jumbo Frames) value of 9014 is not supported in the switch or NICs in the environment, you may need to set the SDNLABMTU value to 1514 in the SDN-Configuration file.

## Performance & storage tips (faster deploys without more hardware)

The single biggest, no-cost speedup is **storage choice**:

* **Put the base images _and_ `HostVMPath` on one data volume formatted with ReFS.** The deploy stages the ~20–40 GB `GUI.vhdx`/`CORE.vhdx` parents into `HostVMPath`; on a single **ReFS** volume that copy becomes a near-instant **block clone** (copy-on-write, ~zero extra space) instead of a multi-GB physical copy. This is the largest single I/O cost in a deploy. The wizard detects this automatically and logs *"parent VHDX copy will block-clone"* — no setting required. Block cloning is **intra-volume only**, so the source images and `HostVMPath` must share the same ReFS volume. ReFS cannot be the boot volume — use a data drive. (NTFS still works; you just don't get the free copy.)

The deploy also exposes three opt-in switches in `SDNSandbox-Config.psd1`:

| Setting | Default | What it does |
|---|---|---|
| `OptimizeDefenderDuringDeploy` | `$true` | Temporarily excludes the VHDX working paths from Microsoft Defender real-time scanning during the deploy (removed automatically at the end). Scanning every multi-GB VHDX write is a large hidden cost; best-effort and non-fatal. Set `$false` to leave Defender untouched. |
| `HyperVRolePreStaged` | `$false` | Skips the redundant per-host offline Hyper-V install. Only set `$true` after building your base images with `New-SDNVHDfromISO.ps1 -PreStageHyperV` (which bakes the Hyper-V role into the parents once, instead of installing it into every nested host at deploy time). |
| `EnableParallelCopy` | `$false` | Copies the `GUI`/`CORE` parents (and the per-host copies in multi-host mode) concurrently instead of sequentially. Helps most on **NTFS**; on a single **ReFS** volume the copy is already near-instant so this adds little. |

### NAT Prerequisites

If you wish the environment to have internet access in the Sandbox, create a VMswitch on the FIRST host that maps to a NIC on a network that has internet access the network should use DHCP. The configuration file will need to be updated to include the name of the VMswitch to use for NAT.

### Deploying on a restricted / corporate network

The lab reaches the internet through a chain of NATs that all ride **the host's own internet connection**: the host creates an internal `InternalNAT` switch (`192.168.128.1/24`) with a `New-NetNat`; SDNMGMT gets `192.168.128.5` (gateway `.1`, the host) and forwards DNS to `natDNS`; the Domain Controller then forwards **all** lab DNS to that same `natDNS`. Two things must therefore be true on the host's network, and both commonly fail on corporate/lab networks:

* **`natDNS` must be reachable from the host.** Many corporate networks **block public resolvers** (`8.8.8.8`, `1.1.1.1`) to force internal DNS. When that happens the nested VMs route fine but resolve nothing — so the whole lab looks like it has **"no internet"**. **Fix:** set `natDNS` in `SDNSandbox-Config.psd1` to your **internal/corporate DNS server** (the one the host itself uses).
* **The host needs *direct* (un-proxied) outbound internet.** Windows NAT is layer-3 and **cannot traverse an HTTP proxy**. If the host only reaches the web through a proxy, the nested lab can't get out even though a browser on the host works.

Quick triage (run on the **host**; the second block needs PowerShell Direct into `SDNMGMT`):

```powershell
# HOST — does it resolve via, and is the public resolver blocked?
Resolve-DnsName aka.ms                                   # corporate DNS working?
(Get-DnsClientServerAddress -AddressFamily IPv4).ServerAddresses   # <- use one of these as natDNS
Test-NetConnection aka.ms -Port 443                      # TcpTestSucceeded:True = direct internet (no proxy)
Test-NetConnection 8.8.8.8 -Port 53                      # Ping OK but TcpTestSucceeded:False = public DNS blocked

# SDNMGMT — separate ROUTING from DNS (the usual giveaway):
Test-NetConnection 192.168.128.1 -Port 445               # reaches the host NAT gateway?
Test-NetConnection 1.1.1.1 -Port 443                     # raw routing to the internet (no DNS)
Resolve-DnsName microsoft.com                            # DNS via the DC forwarder
```

Interpretation: **routing works but `Resolve-DnsName` fails → it's `natDNS`** (point it at your corporate DNS). If raw routing to the internet also fails from the host, you're behind a **proxy** and the host's egress must be sorted first.

Already-deployed lab? You don't need a full redeploy — fix the forwarder live on the DC (PowerShell Direct from the host into `contosodc` / `192.168.1.254`):

```powershell
Get-DnsServerForwarder | Remove-DnsServerForwarder -Force
Add-DnsServerForwarder -IPAddress <your-corporate-DNS-IP>
```

> **Jumbo frames:** the lab defaults to `SDNLABMTU = 9014`. If the physical NIC/switch doesn't support jumbo frames you may see "ping works but web/TLS hangs" — set `SDNLABMTU = 1514`. (Subnets are **not** the problem here: the lab uses non-overlapping `192.168.x` / `10.1x.x` ranges, so a host on, say, `10.57.x.x` does not collide — do **not** renumber the lab to fix internet access.)


## Software Prerequisites

### Required VHDX files:

 **GUI.vhdx** - Sysprepped Desktop Experience version of Windows Server 2025 **Datacenter**. Only Windows Server 2025 Datacenter is supported.           
  
**CORE.vhdx** - Same requirements as GUI.vhdx except the Core installation from the same media that the GUI.VHDX file is placed from.

>**Note:** Product Keys WILL be required to be entered into the Configuration File. If you are using VL media, use the [KMS Client Keys](https://docs.microsoft.com/en-us/windows-server/get-started/kmsclientkeys) keys for the version of Windows you are installing.

### Building the VHDX files (New-SDNVHDfromISO.ps1)

``New-SDNVHDfromISO.ps1`` builds the two parent images and slipstreams the newest Windows updates into them. Because every host and SDN virtual machine in the lab is a Hyper-V differencing child (or a direct copy) of GUI.vhdx / CORE.vhdx, patching these two images is all that is required for **every** VM in the sandbox to be up to date.

> For a full step-by-step runbook (prerequisites, offline builds, verification, and troubleshooting) see [New-SDNVHDfromISO-Instructions.md](./New-SDNVHDfromISO-Instructions.md). The script runs a pre-flight check and stops with a clear message if a prerequisite (elevation, Hyper-V/DISM cmdlets, or free disk space) is missing. To target a **Windows Server vNext / Insider** build instead of 2025, see *"Testing Windows Server vNext / Insider preview builds"* in that runbook.

Run from an elevated Windows PowerShell console on the Hyper-V host:

```powershell
# Fully automatic: download eval ISO + latest cumulative update, build both images
.\New-SDNVHDfromISO.ps1
```

Useful parameters:

| Parameter | Default | Description |
|---|---|---|
| ``-VHDType`` | ``Both`` | Build ``GUI``, ``CORE``, or ``Both``. |
| ``-Edition`` | ``Datacenter`` | Windows Server edition to extract (``Datacenter`` or ``Standard``). |
| ``-IsoPath`` | *(none)* | Use a local ISO instead of downloading the evaluation ISO. |
| ``-DownloadISO`` | ``$true`` | Auto-download the evaluation ISO when ``-IsoPath`` is not supplied. |
| ``-DownloadUpdates`` | ``$true`` | Download the latest cumulative update from the Microsoft Update Catalog. |
| ``-UpdatesPath`` | *(none)* | Folder of local ``*.msu`` files to additionally inject (applied in addition to the auto-downloaded CU). |
| ``-VHDSize`` | ``100GB`` | Virtual size of each (dynamic) parent VHDX. |
| ``-WorkPath`` | ``<launchDrive>\SDNVHDBuild`` | Cache folder for the downloaded ISO, updates and DISM scratch (reused across runs). Defaults to the drive the script was launched from, not C:. |
| ``-Parallel`` | *(off)* | Build ``GUI.vhdx`` and ``CORE.vhdx`` concurrently (only when both are selected) to use idle CPU/disk and cut wall-clock time. Trades the per-image live progress bar for periodic heartbeat updates. |
| ``-PreStageHyperV`` | *(off)* | Bake the Hyper-V role into the freshly built parent image(s) so the deploy can skip the per-host offline install. Pair with ``HyperVRolePreStaged = $true`` in ``SDNSandbox-Config.psd1``. Best-effort (needs the ServerManager module on the build host). |

>**Note:** Build artifacts stay on the **drive the script was launched from** by default (not C:). The ISO/updates/scratch go to ``<launchDrive>\SDNVHDBuild`` and the parent images to ``<launchDrive>\SDNVHDs\``. The output paths come from ``guiVHDXPath`` / ``coreVHDXPath`` in ``SDNSandbox-Config.psd1``; if those point at another drive the script re-bases them onto the launch drive and **updates the config in place** (comments preserved) so ``New-HyperVSandbox.ps1`` finds the images in the same place.

>**Note:** The auto-downloaded ISO is the Windows Server 2025 **Evaluation** edition (180-day). The VHDX is built natively with in-box Hyper-V and DISM cmdlets, and the latest cumulative update (plus any Server 2025 **checkpoint** update) is downloaded by querying the Microsoft Update Catalog directly - **no third-party PowerShell modules are required**. If the catalog lookup fails, the build retries and then continues with a warning rather than failing - supply ``-UpdatesPath`` to guarantee a specific update is injected.

## Configuration File (NestedSDN-Config) Reference

The following are a list of settings that are configurable and have been fully tested. You may be able to change some of the other settings and have them work, but they have not been fully tested.

>**Note:** Changing the IP Addresses for Management Network (*default of 192.168.1.0/24*) has been succesfully tested.

>**Performance flags:** `OptimizeDefenderDuringDeploy` (default `$true`), `HyperVRolePreStaged` (default `$false`), and `EnableParallelCopy` (default `$false`) tune deploy speed — see [Performance & storage tips](#performance--storage-tips-faster-deploys-without-more-hardware) above. The opt-in flags default OFF so default deploy behavior is unchanged.


