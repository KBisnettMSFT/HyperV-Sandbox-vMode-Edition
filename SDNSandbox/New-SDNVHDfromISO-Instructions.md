# Building the Hyper-V Sandbox parent images — `New-SDNVHDfromISO.ps1`

This is the step-by-step runbook for creating the two parent VHDX images
(`GUI.vhdx` and `CORE.vhdx`) that `New-HyperVSandbox.ps1` requires. The script also
slipstreams the newest Windows cumulative update into both images.

> **Why this matters:** every host VM (SDNMGMT, SDNHOST1/2, the DC, the BGP "Top of
> Rack" router, Admin Center) and every SDN infrastructure VM (Network Controller,
> MUX, Gateways) is a Hyper-V *differencing child* — or a direct copy — of these two
> parents. Patching `GUI.vhdx` and `CORE.vhdx` patches the **entire** lab in one place.

---

## 1. Prerequisites

The build host must have:

| Requirement | Why | How to satisfy |
|---|---|---|
| **Elevated PowerShell** | Image mounting / DISM | Right-click PowerShell → *Run as administrator* |
| **64-bit Windows** | DISM image servicing | Windows 10/11 or Windows Server 2019+ |
| **Hyper-V PowerShell module** | `New-VHD`/`Mount-VHD` create the parent VHDX | Server: `Install-WindowsFeature Hyper-V-PowerShell`  •  Client: `Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-Management-PowerShell` |
| **DISM cmdlets** | Image apply (`Expand-WindowsImage`) + update injection (`Add-WindowsPackage`) | Built into Windows (the `Dism` module) |
| **~85 GB free disk** | ISO cache + two patched dynamic VHDXs + temp | Free space on the output drive (default `C:\SDNVHDs`) and the work folder |
| **Internet access** | ISO + update + module downloads | Or run fully offline (see §4) |

The VHDX is built **natively** with the in-box Hyper-V (`New-VHD`/`Mount-VHD`) and DISM
(`Expand-WindowsImage`/`Add-WindowsPackage`) cmdlets plus `bcdboot`, and the latest
cumulative update is found and downloaded by querying the **Microsoft Update Catalog
directly**. **No third-party PowerShell modules are installed or required** — everything
uses components already on Windows.

The script runs a **pre-flight check** before downloading or installing anything and
stops immediately with a clear message if any hard requirement above is missing.

---

## 2. Quick start (fully automatic)

From an **elevated** PowerShell prompt in the `SDNSandbox` folder:

```powershell
.\New-SDNVHDfromISO.ps1 -Verbose
```

This will:

1. Download the **Windows Server 2025 Evaluation** ISO (English) from the Microsoft
   Evaluation Center fwlink.
2. Download the **latest cumulative update** (and, for Server 2025, any required
   **checkpoint** update) directly from the Microsoft Update Catalog.
3. Build **both** images — `GUI.vhdx` (Datacenter Desktop Experience) and
   `CORE.vhdx` (Datacenter Core) — with the update injected, at the paths defined in
   `SDNSandbox-Config.psd1` (`guiVHDXPath` / `coreVHDXPath`).

> **Where files land:** by default everything stays on the **drive the script was launched
> from** — never C: (unless you launch from C:). The downloaded ISO, the updates and DISM's
> scratch go to `<launchDrive>\SDNVHDBuild`, and the parent images go to `<launchDrive>\SDNVHDs\`.
> If `SDNSandbox-Config.psd1` points the image paths at a different drive (e.g. the default
> `C:\SDNVHDs\`), the script **re-bases them onto the launch drive and updates the config
> in place** (comments preserved) so the deployment — `New-HyperVSandbox.ps1`, which reads the
> same config — finds the images in the same place. Override the work folder with `-WorkPath`.

`-Verbose` is recommended so you can watch progress; expect the whole run to take
**30–90+ minutes**, mostly during the download and the update commit.

During the run you'll see numbered phase banners with timestamps so you always know what
stage is active, a live progress bar during the ISO download, and **DISM's native
percentage bar** during the long image-build/update-injection steps (so they never look
hung). For example:

```
==== [1/5] Preparing the installation media (ISO)  (10:47:00) ====
  WS2025 Eval ISO  [████████████████░░░░░░░░░░░░░░]  52%  3.95 GB / 7.59 GB   92.4 MB/s   ETA 00:00:40
...
==== [4/5] Building GUI.vhdx (Datacenter Desktop Experience)  (11:09:14) ====
     One of the longest steps - expect roughly 15-40 minutes.
  Building GUI.vhdx (applying the image and injecting 1 update package(s)). A DISM
  progress bar will appear below; this typically takes 15-40 minutes - it is not hung.
```

Each build step and the overall run report their elapsed time on completion.

---

## 3. Common variations

```powershell
# Use your own (e.g. retail) ISO instead of downloading the eval media:
.\New-SDNVHDfromISO.ps1 -IsoPath 'D:\iso\WS2025.iso'

# Build only CORE:
.\New-SDNVHDfromISO.ps1 -VHDType CORE

# Inject extra/specific local updates in addition to (or instead of) the catalog CU:
.\New-SDNVHDfromISO.ps1 -UpdatesPath 'C:\MSU'                 # catalog CU + your *.msu
.\New-SDNVHDfromISO.ps1 -UpdatesPath 'C:\MSU' -DownloadUpdates:$false   # only your *.msu
```

### Key parameters

| Parameter | Default | Notes |
|---|---|---|
| `-ConfigurationDataFile` | `.\SDNSandbox-Config.psd1` | Source of the output VHDX paths |
| `-VHDType` | `Both` | `GUI`, `CORE`, or `Both` |
| `-Edition` | `Datacenter` | `Datacenter` or `Standard` (matches Eval editions too) |
| `-IsoPath` | *(none)* | Use an existing ISO; skips the download |
| `-DownloadISO` | `$true` | Auto-download the eval ISO when `-IsoPath` is omitted |
| `-DownloadUpdates` | `$true` | Auto-download the latest CU from the Update Catalog |
| `-UpdatesPath` | *(none)* | Folder of local `*.msu` files to also inject |
| `-VHDSize` | `100GB` | Virtual size of each (dynamic) parent VHDX |
| `-WorkPath` | `<launchDrive>\SDNVHDBuild` | Cache folder for the ISO, updates and DISM scratch (on the launch drive, not C:) |
| `-Parallel` | *(off)* | Build GUI and CORE at the same time (both selected) - faster on idle hosts; shows heartbeats instead of the live bar |

### Building both images in parallel (`-Parallel`)

By default the two images build **one after another** so you always see DISM's live
percentage bar. On a host with spare CPU/disk (the build is usually bottlenecked on
single-threaded decompression and CBS, not disk I/O), pass `-Parallel` to build
`GUI.vhdx` and `CORE.vhdx` **concurrently** and cut wall-clock time:

- Only applies when **both** images are selected (`-VHDType Both`, the default); it is
  ignored for a single image.
- Each image builds in its own background job with a **dedicated DISM scratch dir**
  (`...\SDNVHDBuild\Scratch-GUI` / `Scratch-CORE`) and its own DISM log, reading from the
  one shared (read-only) ISO mount.
- Two concurrent DISM builds **cannot share one console**, so parallel mode prints a
  periodic heartbeat (`GUI.vhdx: Running | CORE.vhdx: Running`) every 30s instead of the
  per-image progress bar, then verifies each image when it finishes.
- Plan for a little extra free space on the work drive (two scratch dirs expand at once);
  the pre-flight check budgets for this automatically.
- If you interrupt the run, the script stops the in-progress build jobs before dismounting
  the ISO, and each job cleans up its own partial VHDX.

---

## 3a. How updates are injected (and Server 2025 "checkpoint" updates)

The script follows Microsoft's documented offline-servicing sequence
([Add updates to a Windows image](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/servicing-the-image-with-windows-updates-sxs) /
[Update Windows installation media](https://learn.microsoft.com/en-us/windows/deployment/update/media-dynamic-update#update-windows-installation-media)):

1. Apply the OS image to the VHDX (`Expand-WindowsImage`).
2. Add the cumulative update offline (`Add-WindowsPackage`). Any separate servicing-stack
   update is applied first; for Server 2025 the catalog CU is normally the **combined**
   package with the SSU already embedded.
3. Re-run **`bcdboot`** so any boot files updated by the CU are copied to the system
   partition (Microsoft explicitly calls for this after servicing an offline image).

> **Server 2025 checkpoint cumulative updates:** starting with 24H2 / Server 2025, the
> latest CU can require a **checkpoint** CU to be installed first. The script's automatic
> download resolves the catalog's download bundle, so it pulls **both** the target CU and
> any checkpoint into the same folder; `Add-WindowsPackage` then auto-discovers and installs
> the checkpoint from that folder. If a checkpoint is ever missing, injection is best-effort:
> it warns and leaves the image **unpatched but bootable** rather than failing the build.
> For a manual/offline build, use the Microsoft Update Catalog **Download** button (it bundles
> the checkpoint), drop all the `.msu` files into one folder, and pass it with `-UpdatesPath`.

---

## 4. Fully offline build

On a host with no internet:

1. On a connected machine, download the Server 2025 ISO and the latest cumulative
   update from the [Microsoft Update Catalog](https://www.catalog.update.microsoft.com)
   (use the **Download** button so any checkpoint CU comes with it), and copy them to the
   build host. Put all the `.msu` files in one folder.
2. No PowerShell modules are needed at all — the native conversion uses only in-box
   Hyper-V/DISM cmdlets, and skipping the catalog (`-DownloadUpdates:$false`) means no
   network calls are made for updates.
3. Run:

```powershell
.\New-SDNVHDfromISO.ps1 -IsoPath 'D:\WS2025.iso' `
    -UpdatesPath 'D:\Updates' -DownloadISO:$false -DownloadUpdates:$false
```

---

## 5. Verifying the result

* The script prints the final paths in green and runs a built-in check that mounts each
  finished VHDX and confirms the expected KB is present (`Get-WindowsPackage`). A warning
  is shown if the patch is not found.
* You can re-check manually:

```powershell
$mp = (Mount-VHD -Path 'C:\SDNVHDs\GUI.vhdx' -Passthru | Get-Disk |
       Get-Partition | Get-Volume | Where-Object DriveLetter).DriveLetter
Get-WindowsPackage -Path "$mp`:\" | Where-Object PackageName -match 'KB'
Dismount-VHD -Path 'C:\SDNVHDs\GUI.vhdx'
```

After both images exist at the configured paths, continue with the main deployment:
`.\New-HyperVSandbox.ps1` (see `README.md`).

---

## 5a. Cleanup on failure & caching

If the build fails at any point, the script cleans up after itself:

* The **mounted ISO** and any **mounted VHDX** are always dismounted (even on error).
* A **partial/non-bootable VHDX** from a failed conversion is **deleted automatically**
  (so a failed run never leaves tens of GB of dead image behind). If the file is locked
  and can't be removed, you'll get a warning telling you to delete it manually.
* A **partial ISO** from an interrupted streaming download, and a **partial `.msu`** from a
  failed update download, are removed so they can't be silently reused.

What is intentionally **kept** (cache, not bloat) in `-WorkPath` (default
`%TEMP%\SDNVHDBuild`):

* The fully downloaded **ISO** and **cumulative update** — re-running reuses them (verified by
  size/KB) so you don't re-download ~7.6 GB. Delete the `-WorkPath` folder yourself when you
  no longer need the cache.

---

## 6. Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| *"Hyper-V PowerShell cmdlets are unavailable"* | Install the Hyper-V management module (see §1) and re-open PowerShell. |
| *"Not elevated"* | Re-launch PowerShell with **Run as administrator**. |
| *"Insufficient free space on 'C:\'"* | Free space, or point `-WorkPath` and the config output paths at a larger drive. |
| Update download finds nothing / wrong KB | Pass the CU `.msu` files manually with `-UpdatesPath ... -DownloadUpdates:$false`. The build still succeeds without a patch (best-effort) and warns. |
| *"The catalog ... has encountered an error"* | The script queries the Microsoft Update Catalog directly and retries automatically if it returns its error page. If the catalog stays down, the build continues **without** a patch — re-run later, or download the latest Server 2025 cumulative update (Catalog **Download** button) into a folder and pass `-UpdatesPath`. |
| *"bcdboot failed"* / `0xC0E90002` during conversion | This was a bug in the old third-party `WindowsImageTools` path and is fixed: the script now builds the VHDX natively (GPT ESP+MSR+Windows, `Expand-WindowsImage`, then host `bcdboot /f UEFI`). If you still see a bcdboot error, confirm the build host's own OS is healthy (host `bcdboot.exe` is used) and that the output drive is NTFS with free space. |
| Update injection warns / fails (`0x800f0823`, `0x800f081e`, "checkpoint"/"prerequisite") | The Server 2025 CU needs a **checkpoint** update first. Use the catalog **Download** button (it includes the checkpoint), put all `.msu` files in one folder, and pass `-UpdatesPath <folder>`. The build still completes with a bootable (unpatched) image and warns. |
| ISO download is slow / interrupted | The cached ISO is reused if its size matches; just re-run. There is no partial resume, so a size mismatch re-downloads. |

> **Licensing note:** the auto-downloaded ISO is the **Evaluation** edition (expires
> ~180 days; reports an `*Eval` EditionId). That is fine for a throwaway training lab.
> For a licensed or long-lived lab, supply retail media with `-IsoPath`.

## 7. Why a built-in catalog client (and not a module)

There is **no official Microsoft API** for the Microsoft Update Catalog. The catalog is a
website only; every tool that fetches updates programmatically — including the community
`MSCatalog` and `MSCatalogLTS` modules — does the **same thing**: scrape `Search.aspx` to
find updates and POST `DownloadDialog.aspx` to resolve the `.msu` URLs. Microsoft's own
[Media Dynamic Update](https://learn.microsoft.com/en-us/windows/deployment/update/media-dynamic-update)
guidance simply tells you to download from the catalog **website** by hand.

This script originally used the **`MSCatalog`** module (the public PSGallery package by
Ryan Kowalewski / `ryanjan` — *not* a Microsoft first-party module). Version `0.27.0`
throws *"The catalog.microsoft.com site has encountered an error"* even when the catalog is
perfectly healthy (a raw `Invoke-WebRequest` to `Search.aspx` returns **HTTP 200** with
results). The failure is a parser/ViewState bug in the module, not the catalog, and it is
**not** transient — every retry fails identically. So the dependency was removed in favour
of a small built-in client (`Find-CatalogUpdate`, `Get-CatalogDownloadUrls`,
`Get-LatestServerCU`).

### How ours compares to MSCatalogLTS

Both scrape the identical endpoints; the difference is scope and packaging, not technique.

| | **MSCatalogLTS** (community module) | **This script's built-in client** |
|---|---|---|
| Form | External module — `Install-Module` + trust + version-manage | ~80 inline lines — **zero dependencies**, nothing to install or drift |
| Scope | Generic: any product, rich date/size/arch filtering, CSV/JSON/XML/Excel export | Single purpose: "latest WS2025 24H2 cumulative update" |
| Selection | By the filters you specify | Parses the **OS build revision** (`26100.xxxxx`) and auto-picks the highest |
| Checkpoint CU | Returns updates; you orchestrate injection | Auto-keeps the **bundled checkpoint KB** next to the LCU in one folder so DISM auto-discovers it (solves the Server 2025 checkpoint prerequisite for free) |
| On failure | Throws / errors | **Never throws** — warns and continues with a bootable-but-unpatched image |
| Integration | Its own download UI | Reuses the script's `Save-Url` progress bar, size-match caching, and partial-file cleanup |

**Trade-off:** MSCatalogLTS is broader and maintained by others — if the catalog's HTML
layout ever changes, they ship a fix and you `Update-Module`. With the built-in client,
*we* own that fix (a small regex tweak in `Find-CatalogUpdate`), but in exchange the build
has **no third-party dependency that can silently break it** the way `MSCatalog 0.27.0`
did. For a single-purpose lab builder, that exact fit + graceful degradation + the
checkpoint auto-solve outweigh the module's breadth.

> **If the built-in client ever stops finding updates** (catalog markup changed), the fix
> is in `Find-CatalogUpdate` / `Get-CatalogDownloadUrls` in `New-SDNVHDfromISO.ps1` — adjust
> the row/title/`.msu` regexes. As a stop-gap you can always download the CU from the
> catalog **Download** button by hand and pass the folder with `-UpdatesPath`.
