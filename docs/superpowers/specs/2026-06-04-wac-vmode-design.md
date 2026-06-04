# WAC Virtualization Mode (vMode) — Design Spec

- **Date:** 2026-06-04
- **Status:** Approved design, pending spec review
- **Author:** SDN Sandbox maintainer + Copilot CLI (brainstorming session)
- **Scope:** Add a second Windows Admin Center deployment — **Virtualization Mode ("vMode")**, currently public preview — to the SDN Sandbox lab, alongside the existing **Administration Mode ("aMode")** WAC that ships on the `admincenter` VM.

---

## 1. Goal

The lab already deploys WAC **aMode** as a nested VM (`admincenter`) on `SDNMGMT`, surfaced to the user via an `AdminCenter` RDP shortcut on the physical host. We want to additionally deploy WAC **vMode** — the Hyper-V/cluster-focused WAC experience (Network ATC intents, CSV/SOFS storage, live migration, cluster onboarding) — which is a natural fit for managing the lab's nested `SDNCLUSTER` (SDNHOST1/SDNHOST2 S2D failover cluster).

Microsoft requires aMode and vMode to be installed on **separate systems**, so vMode cannot share the `admincenter` VM.

## 2. vMode requirements (functional — NOT enforced by the installer)

The vMode preview installer performs **no hard checks** for the items below; they are functional requirements for vMode to work correctly:

- **OS:** Windows Server 2025 Standard or Datacenter.
- **Domain:** Domain-joined, in the **same domain as the Hyper-V hosts it manages** (`contoso.com`), with FQDN DNS resolution.
- **Sizing:** 4 vCPU, ≥ 8 GB RAM, ≥ 10 GB free disk.
- **Not supported on clustered machines.**
- **Prerequisite:** Visual C++ Redistributable (`Microsoft.VCRedist.2015+.x64`).
- Installs a lightweight **PostgreSQL** database (requires username / password / port).
- Self-signed cert (expires after 60 days; preinstalled certs not yet supported in preview).

## 3. Placement decision & rationale

**Decision: a new, always-on, domain-joined nested GUI VM named `wacvmode` on `SDNMGMT`**, mirroring the existing `New-AdminCenterVM` (aMode) build pattern.

Rejected alternatives and why:

| Option | Verdict | Reason |
|---|---|---|
| Install on the existing `admincenter` VM | ❌ | aMode and vMode must be on separate systems. |
| Install directly on `SDNMGMT` host | ❌ | `SDNMGMT` is **workgroup**, not domain-joined (its unattend only sets a DNS suffix; there is no `Add-Computer`/`<JoinDomain>`). Joining it would invert the design — it *hosts* the contoso.com DC as a guest — and bakes a preview product + PostgreSQL onto the deploy-engine box, uncleaned by `reset-sdnsandbox.ps1`. |
| Install on the physical host | ❌ | Host is workgroup relative to the lab, may lack an L3 route into the internal `192.168.1.x` SDN management subnet, pollutes the customer's real machine with a preview product + PostgreSQL + 443 listener, and `reset-sdnsandbox.ps1` won't clean it. |
| Install on SDNHOST1/SDNHOST2 | ❌ | They are the **clustered** nodes (vMode unsupported on clustered machines) and are Server Core. |
| New domain-joined VM on SDNMGMT | ✅ | Same pattern as `admincenter` (which is domain-joined precisely because it is a guest, not a host). Clean, disposable, same-domain, guaranteed on the SDN subnet. |

**Base image:** GUI (clone of `C:\VMs\Base\GUI.vhdx`), matching `admincenter` — the safe, proven path. (Core would save RAM but preview-on-Core is unvalidated.)

## 4. Installer sourcing (confirmed NOT gated)

`https://aka.ms/WACDownloadvMode` issues a `301` straight to an anonymous direct download:

```
https://download.microsoft.com/download/5e854024-dcf1-4e86-9546-7389fd08a34b/WindowsAdminCenterVirtualizationModePreview.exe
```

- ~277 MB, `application/octet-stream`, no login required → fetchable in-build.
- Real filename is **`WindowsAdminCenterVirtualizationModePreview.exe`** (not `WindowsAdminCenterSetup.exe`).
- The build stores the resolved URL in config as `vModeUri` so it can be updated when the preview revs.

## 5. Unattended install (PP2 INI method)

Run **inside the `wacvmode` guest** via `Invoke-Command -VMName wacvmode`:

1. **VC++ redist:** install `Microsoft.VCRedist.2015+.x64` (via winget if available in-guest; otherwise bundle/stage the redist — see Risks).
2. **Download** the installer (BITS / existing `Copy-LargeFile` resilience pattern).
3. **Generate the DPAPI-encrypted Postgres password IN-GUEST** and write the INI:
   ```powershell
   $enc = "Password01" | ConvertTo-SecureString -AsPlainText -Force | ConvertFrom-SecureString
   ```
   > **CRITICAL:** `ConvertFrom-SecureString` uses DPAPI scoped to the **current user + machine**. The encrypted blob MUST be produced inside `wacvmode` under the same account that runs setup. It cannot be pre-encrypted on the host and shipped — it would fail to decrypt.
   ```ini
   [AppSettings]
   PostgreSQLUsername=postgres
   PostgreSQLPassword=<encrypted blob from step 3>
   PostgreSQLPort=5432
   ```
4. **Silent install:**
   ```
   WindowsAdminCenterVirtualizationModePreview.exe /VERYSILENT /ConfigFile="C:\deploy\wac-config.ini"
   ```
5. **Cert:** set the certificate subject name; vMode reachable at `https://wacvmode.contoso.com`.

## 6. Configuration changes (`SDNSandbox-Config.psd1`)

New keys (sit alongside the existing `admincenterUri`, `WACIP`, `WACASN`, `WACport`, `MEM_WAC`):

| Key | Value | Notes |
|---|---|---|
| `vModeUri` | the resolved direct download URL | Update when preview revs. |
| `vModeVMName` | `wacvmode` | |
| `vModeIP` | `192.168.1.10/24` | next free after `WACIP = 192.168.1.9/24` (verify unused). |
| `MEM_vMode` | `8GB` | mirrors `MEM_WAC`. |
| `PostgreSQLPort` | `5432` | |

**Changed key:**

| Key | From | To | Reason |
|---|---|---|---|
| `sdnMGMTMemoryinGB` | `24GB` | `32GB` | Always-on +8 GB vMode VM on an already-oversubscribed SDNMGMT. |

## 7. New build function `New-WACvModeVM`

A near-clone of `New-AdminCenterVM`, invoked from `Set-SDNMGMT` after the aMode/admincenter provisioning:

- Create differencing disk off `C:\VMs\Base\GUI.vhdx` at `D:\VMs\`, resize to 130 GB.
- Inject unattend with **`<Identification><JoinDomain>contoso.com</JoinDomain>`** (domain-joined), ComputerName `wacvmode`, static IP `vModeIP`, DNS → lab DC.
- Start VM, wait for domain join + WinRM.
- Run the §5 install sequence in-guest.

## 8. Post-deploy access & connection registration

- **Host RDP shortcut:** add a `WACvMode.lnk` on `C:\Users\Public\Desktop` (mirrors the `AdminCenter.lnk` block at `New-SDNSandbox.ps1:4261`), `mstsc /v:wacvmode`.
- **Register managed nodes in vMode:** register SDNHOST1, SDNHOST2 and the `SDNCLUSTER` failover cluster as connections in vMode so it manages the lab cluster out of the box.
  > vMode's connection/onboarding model differs from aMode's `/api/connections` REST shape (vMode deploys management agents to Hyper-V hosts/clusters). The exact registration API must be verified during implementation; treat auto-registration as best-effort with a documented manual fallback (add the cluster in the vMode UI).

## 9. Host-memory impact

Bumping `sdnMGMTMemoryinGB` 24→32 GB raises the physical-host memory requirement (SDNMGMT 32 + 2 × SDNHOST `NestedVMMemoryinGB` 100 GB each). Any host-memory precheck in `New-SDNSandbox.ps1` must be updated so the larger SDNMGMT does not trip validation, and the README host-sizing guidance updated.

## 10. Testing / validation

- `New-SDNVHDfromISO`/parse: PSScriptAnalyzer clean + `Get-Command -Syntax`/AST parse of the modified `New-SDNSandbox.ps1`.
- Dry-run the in-guest install block logic where possible (INI generation, URL reachability already verified).
- Full deploy validation: `wacvmode` domain-joined, vMode service answering on 443, `https://wacvmode.contoso.com` loads, SDNHOSTs/cluster visible, host RDP shortcut works.

## 11. Risks & open items

1. **Preview product.** vMode is public preview; installer URL, INI schema, and onboarding API may change. `vModeUri` is config-driven to absorb URL churn.
2. **Connection-registration API.** May differ from aMode's REST; verify during implementation, fall back to manual onboarding instructions.
3. **winget availability in-guest.** The VM gets NAT internet via SDNMGMT, but winget presence on the GUI image is not guaranteed; have a bundled VC++ redist fallback.
4. **60-day self-signed cert.** Acceptable for a lab; document it.
5. **Host-memory precheck** must be revisited (see §9) or deploys on minimally-sized hosts will fail validation.
6. **Always-on cost.** Every deploy now pays the +8 GB and the ~277 MB download; acceptable per the always-on decision.
