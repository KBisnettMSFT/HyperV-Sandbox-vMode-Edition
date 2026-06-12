# Hyper-V Sandbox — vMode Edition — Design Spec

- **Date:** 2026-06-10
- **Status:** Approach B + the five assumptions **APPROVED by maintainer (2026-06-11)**. Testing & open-source-readiness strategy added (§§9–11); awaiting review of those before planning. **No implementation has been performed.**
- **Author:** KBisnettMSFT (maintainer) + Copilot CLI (brainstorming session)
- **Scope:** Rebrand and reposition the project currently named **"SDN Sandbox"** into **"Hyper-V Sandbox – vMode Edition"**: a nested-Hyper-V learning lab for Windows Server 2025 / vNext where customers can exercise Active Directory, Failover Clustering, SMB, Storage (S2D), and Windows Admin Center **Virtualization Mode (vMode)** — **with SDN kept at the forefront** as a first-class scenario, not removed.
- **Chosen approach:** **B — Hybrid** (rebrand the customer-visible identity, docs, and launcher; scaffold new scenario tracks; **keep** internal VM names, function names, and config keys to avoid regressions). Approaches A and C are recorded in §4 with the rationale for rejecting them.

---

## 1. Goal & positioning

The project began in **2016** as a fast way to stand up online labs for **Microsoft SDN** (originally via SCVMM), and was refactored over time into the current PowerShell + nested-Hyper-V lab, last updated for **Windows Server 2025**. It builds, on one physical Hyper-V host, a virtualized host cluster: a management/jumpbox VM, an AD domain controller, a virtual Top-of-Rack router, Windows Admin Center, and two nested S2D hosts.

**The gap:** customers increasingly want a disposable sandbox to learn and validate **Windows Server 2025 / vNext virtualization and datacenter features** broadly — Active Directory, Failover Clustering, SMB, Storage Spaces Direct — not only SDN. The lab already *builds* most of this infrastructure, but its identity, docs, and on-desktop experience present it as an **SDN-only** tool, so those capabilities are effectively hidden.

**The pivot:** reposition the lab as **"Hyper-V Sandbox – vMode Edition"** — a general Windows Server virtualization/datacenter learning sandbox — while **keeping SDN as a headline, first-class pillar**. "vMode Edition" signals that **Windows Admin Center Virtualization Mode** (the `wacvmode` VM shipped in the recent feature work) is the modern management plane for the lab.

**Success criteria:**
1. Every customer-visible surface (README, in-lab guide, desktop shortcuts, deploy banners, repo/splash) presents the new identity and the broader scenario set.
2. SDN remains clearly first-class (its examples, optional Network Controller deploy, and SDNExpress tooling are untouched and prominently referenced).
3. New scenario tracks (AD, Failover Clustering, SMB, Storage) are discoverable in-lab via docs + example scaffolding + shortcuts.
4. Customers can target **Windows Server 2025 _or_ a vNext/Insider build** for the base images.
5. **No regression**: the deploy still runs end-to-end, and the existing `E:\SDNSandbox` run workflow keeps working.

---

## 2. Background: what the lab already builds (so we don't rebuild it)

Confirmed from `SDNSandbox\New-SDNSandbox.ps1` and `SDNSandbox-Config.psd1`:

| Capability | Where it already exists |
|---|---|
| **Active Directory** | `New-DCVM` creates the `contoso.com` forest (`Install-ADDSForest`) on the `contosodc` VM; AD Users & Computers + DNS shortcuts are placed on the console desktop. |
| **Failover Clustering** | `New-SDNS2DCluster` builds the **`SDNCLUSTER`** S2D failover cluster on `SDNHOST1`/`SDNHOST2`; Failover Cluster Manager shortcut is placed on the desktop. |
| **Storage / S2D / SMB** | S2D pool over `S2D_Disk_Size` disks per host; dedicated `StorageA/StorageB` VLANs and subnets; SMB is inherent to the S2D/CSV path. |
| **Windows Admin Center (aMode)** | `New-AdminCenterVM` builds `admincenter`; host RDP shortcut `AdminCenter.lnk`. |
| **WAC Virtualization Mode (vMode)** | `New-WACvModeVM` builds the always-on `wacvmode` VM (WAC vMode + PostgreSQL); a vMode web-app shortcut lives in the AdminCenter VM next to WAC. |
| **SDN** | `Applications\SDNEXAMPLES\` guided exercises; `Applications\SCRIPTS\SDNExpress-Custom\` tooling; optional auto-NC via `ProvisionLegacyNC` (default `$false`, i.e. learner deploys SDN themselves). |

**Implication:** the AD/Clustering/SMB/Storage "new scenarios" are primarily a **surfacing/positioning + guided-content** effort, **not** new infrastructure. This keeps the rebrand low-risk.

---

## 3. Non-negotiable constraints (drive the design)

1. **One giant script, no test harness.** `New-SDNSandbox.ps1` is **4,730 lines** with **~501** "SDN" string occurrences and no Pester/PSScriptAnalyzer config. The validation baseline is: AST parse clean, `Import-PowerShellDataFile` succeeds, PSScriptAnalyzer reports no *new* Errors, plus a manual deploy checklist (full validation needs a nested-Hyper-V host).
2. **Internal identifiers are load-bearing.** VM names (`SDNMGMT`, `SDNHOST1/2/3`, cluster `SDNCLUSTER`), function names, and `SDN*` config keys are referenced across the main script, every example, the reset/resume/repair tools, and in-guest paths (e.g. `C:\SCRIPTS\SDNSandbox-Config.psd1`). Renaming them is high-churn and regression-prone with no automated safety net.
3. **The config filename is contractually fixed.** The README explicitly says *"do not rename it"* and the script + in-guest copies hard-reference `SDNSandbox-Config.psd1`.
4. **"SDN" is a correct technical term** in `SDNEXAMPLES\` and `SDNExpress-Custom\`. Blanket find/replace there would be *wrong*.
5. **Run/edit environment split.** The maintainer runs the deploy from a copy at `E:\SDNSandbox\`; the repo lives at `C:\SDN-Sandbox-master`. Any launcher rename must preserve the existing run habit.

---

## 4. Approach decision

**Chosen: B — Hybrid.** Rationale and rejected alternatives:

| Approach | What it changes | Verdict | Reason |
|---|---|---|---|
| **A — Cosmetic** | README/guide, desktop shortcuts, banners, repo + splash only. No code/identifier changes. | ❌ as the whole solution | Lowest risk and a good *first phase*, but leaves the launcher and all docs-to-code mapping saying "SDN," and doesn't surface the new scenarios. Insufficient for the pivot. |
| **B — Hybrid** | Everything in A **+** rename the launcher (`New-SDNSandbox.ps1 → New-HyperVSandbox.ps1`) with a back-compat shim, reposition all docs, scaffold AD/Clustering/SMB/Storage example tracks + shortcuts, document WS2025/vNext image sourcing. **Keep** VM names, function names, config keys, and the config filename. | ✅ **Chosen** | Delivers the customer-visible rebrand and "vMode Edition" positioning, keeps SDN first-class, opens room for new scenarios, and **avoids destabilizing the deploy engine**. The internal/external naming mismatch is small and is documented as intentional. |
| **C — Full rename** | Everything in B **+** rename every function, VM (`SDNMGMT→HVMGMT`, `SDNHOST→HVHOST`, `SDNCLUSTER→HVCLUSTER`), and `SDN*` config key across the script, all examples, SDNExpress-Custom, and the reset/resume/repair tools. | ❌ | Highest risk: 500+ edits in a test-harness-free script, VM-name changes ripple through every example and the S2D cluster build, breaks maintainer muscle memory and any external runbooks, and is *semantically wrong* in the SDN content. Effort and regression risk far exceed the benefit of end-to-end name purity. |

---

## 5. Naming decisions (the heart of the hybrid)

### 5a. Rename (customer-visible identity)

| Item | From | To | Notes |
|---|---|---|---|
| Product/platform name | "SDN Sandbox" | **"Hyper-V Sandbox – vMode Edition"** | Used in all docs, banners, splash. |
| Launcher script | `New-SDNSandbox.ps1` | **`New-HyperVSandbox.ps1`** | Git-tracked rename. A thin `New-SDNSandbox.ps1` **shim** remains (see §5c). |
| Root README title/body | "# SDN Sandbox" | New identity + SDN-as-pillar framing | Keep the "not a production solution" caveat. |
| In-lab guide | `SDNSandbox\README.md` ("# SDN Sandbox Guide") | New identity; add AD/Clustering/SMB/Storage sections | |
| Deploy completion banner | "Successfully deployed the SDN Sandbox" | "Successfully deployed Hyper-V Sandbox – vMode Edition" | `New-HyperVSandbox.ps1` ~line 4721; plus the `Delete-…` verbose at ~4242. |
| Desktop shortcut | "SDN Scripts" | **"Lab Scripts"** | Generic; folder it targets is unchanged. |
| Desktop shortcuts (new) | — | **"Clustering Examples", "Storage & SMB Examples", "Active Directory Examples"** | Added beside the existing "SDN Examples" shortcut. |
| Splash image | `res\SDNSandbox.png` | add `res\HyperVSandbox.png` | New graphic is a **follow-on asset** (out of scope for code); README reference updated when the asset exists. Keep old image until then. |
| GitHub repo name | `SDN-Sandbox` | **`HyperV-Sandbox-vMode-Edition`** (suggested) | **Maintainer action** — a repo rename + local folder rename are manual/destructive and are *not* performed here; proposed only. GitHub auto-redirects the old name. |

### 5b. Keep (internal plumbing — documented as intentional)

| Item | Why it stays |
|---|---|
| Config filename `SDNSandbox-Config.psd1` | README contract ("do not rename"); hard-referenced in-guest at `C:\SCRIPTS\SDNSandbox-Config.psd1`. A `# (filename kept for back-compat — Hyper-V Sandbox vMode Edition)` header comment is added. |
| VM names `SDNMGMT`, `SDNHOST1/2/3`, cluster `SDNCLUSTER` | ~501 refs + every example + S2D build + reset/resume/repair tools; no tests to catch breakage. |
| Function names (`Set-SDNMGMT`, `Test-SDNHOSTVMConnection`, `New-SDNS2DCluster`, …) | Internal; renaming is pure churn with regression risk and no user benefit. |
| `SDN*` config keys (`SDNAdminPassword`, `SDNDomainFQDN`, `SDNLABMTU`, `SDNMGMTIP`, …) | Same as above; keys are read throughout the script and examples. |
| Working folder `SDNSandbox\` | Renaming adds churn and breaks the `E:\SDNSandbox` habit for no customer-visible benefit (the folder name isn't surfaced in the lab). Optional future rename. |
| `SDNEXAMPLES\`, `SDNExpress-Custom\` | "SDN" is the correct technical term; these are the first-class SDN pillar. |

A short subsection is added to both READMEs — **"A note on names"** — explaining that internal identifiers retain the historical `SDN*` prefix for stability while the product is "Hyper-V Sandbox – vMode Edition." This makes the mismatch a documented decision rather than an inconsistency.

### 5c. Back-compat launcher shim

`New-SDNSandbox.ps1` becomes a ~10-line shim:

```powershell
# Deprecated entry point. Renamed to New-HyperVSandbox.ps1 in the vMode Edition rebrand.
Write-Warning "New-SDNSandbox.ps1 is deprecated; use New-HyperVSandbox.ps1. Forwarding..."
& "$PSScriptRoot\New-HyperVSandbox.ps1" @args
```

This preserves the maintainer's `E:\SDNSandbox` muscle memory and any external runbooks. The shim is documented as deprecated and slated for eventual removal.

---

## 6. New scenario tracks (AD, Failover Clustering, SMB, Storage)

Since the infrastructure already exists (§2), this is **additive content**, mirroring the proven `SDNEXAMPLES\` layout. **YAGNI:** scaffold the structure + a README + **one** starter exercise per track; do not author exhaustive labs up front.

Proposed structure (additive — nothing moved):

```
SDNSandbox\Applications\
  SDNEXAMPLES\            # unchanged — SDN pillar
  SCRIPTS\               # unchanged
  EXAMPLES\              # NEW umbrella for non-SDN scenario tracks
    ActiveDirectory\     # e.g., 01_Create_OUs_and_Users, README
    FailoverClustering\  # e.g., 01_Inspect_SDNCLUSTER, 02_Drain_and_Move_Role, README
    Storage-and-SMB\     # e.g., 01_Create_CSV_Volume, 02_SMB_Share_and_Continuous_Availability, README
```

Each track README cross-links to the relevant in-lab shortcut and to the existing infra (e.g., Storage exercises point at `SDNCLUSTER`). Desktop shortcuts in §5a surface them. The deploy already copies `Applications\`, so new folders ship automatically.

---

## 7. Windows Server 2025 vs vNext base images

`New-SDNVHDfromISO.ps1` builds the `GUI.vhdx` / `CORE.vhdx` parents and already supports `-IsoPath` (bring-your-own ISO), `-Edition`, and `-DownloadISO`. The lab is OS-agnostic above the image, so building parents from a newer build lets customers validate **new** AD/Clustering/SMB/Storage behavior.

**Decision:**
- **Default unchanged:** auto-download the **Windows Server 2025 Evaluation** ISO + latest CU.
- **vNext path (documented, no new download URLs):** customers supply a **Windows Server vNext / Insider** ISO via `-IsoPath`. Add a guide section **"Testing vNext / preview builds"** covering Insider ISO acquisition, the `-IsoPath`/`-DownloadUpdates:$false` flags, and the support caveat (preview = best-effort).
- **Do not** hard-wire vNext/Insider download URLs (they rotate and sit behind the Insider program). Optionally add an inert `LabImageChannel` doc note in config comments; no behavioral coupling.

---

## 8. Component / file inventory (before → after)

| File | Action |
|---|---|
| `README.md` (root) | Rewrite identity + scenario framing; SDN-as-pillar; "A note on names." |
| `SDNSandbox\README.md` | Rewrite identity; add AD/Clustering/SMB/Storage + vNext sections; update launcher name (note shim). |
| `SDNSandbox\New-SDNSandbox.ps1` | **Rename → `New-HyperVSandbox.ps1`**; update banner/help/synopsis text strings; **no logic/identifier changes**. |
| `SDNSandbox\New-SDNSandbox.ps1` (new shim) | New ~10-line deprecation forwarder. |
| `SDNSandbox\New-WACvModeVM` shortcut text & host banners | Identity strings only. |
| Desktop shortcut creation (in `New-AdminCenterVM`/main flow) | Rename "SDN Scripts"→"Lab Scripts"; add 3 new example shortcuts. |
| `SDNSandbox\New-SDNVHDfromISO-Instructions.md` | Add vNext/Insider section; refresh identity. |
| `SDNSandbox\Applications\EXAMPLES\**` | **New** scaffolding + starter exercises + READMEs. |
| `SDNSandbox\res\HyperVSandbox.png` | **New asset (follow-on)** — placeholder reference until provided. |
| `SDNSandbox-Config.psd1` | Header comment only (identity + "filename kept for back-compat"); **keys unchanged**. |
| `Repair-WACvModeInstall.ps1`, `Resume-SDNSandbox.ps1`, `reset-sdnsandbox.ps1` | Identity strings in comments/output only; **logic unchanged**. (Pre-existing `Password01` hardcoding in `reset-sdnsandbox.ps1` is **out of scope** here — tracked separately.) |

---

## 9. Testing strategy

The lab's "real" output — a multi-VM nested-Hyper-V deployment — **cannot run on GitHub-hosted CI** (it needs nested virtualization, ~64 GB RAM, ~250 GB disk, large downloads, and 1–2 hours). So testing is a pyramid: cheap, deterministic tiers gate every PR; the expensive end-to-end tier is run manually.

**Tier 1 — Static analysis (CI, every PR, GitHub-hosted `windows-latest`):**
- **Parse:** every `*.ps1`/`*.psm1` AST-parses with zero errors.
- **Lint:** `Invoke-ScriptAnalyzer` against a committed `PSScriptAnalyzerSettings.psd1` that *baselines* the known pre-existing warnings (`PSAvoidUsingConvertToSecureStringWithPlainText` ×14, `PSAvoidUsingComputerNameHardcoded` ×5) so only **new** issues fail the build.
- **Config schema:** `Import-PowerShellDataFile SDNSandbox-Config.psd1` succeeds and required keys exist with valid shapes (CIDR, ports, memory units) — reusing the check pattern already written for the vMode work.

**Tier 2 — Unit tests (CI, every PR, Pester 5):**
Cover the **host-independent / pure** functions. Confirmed existing candidates:
- `ConvertTo-ScriptDriveRootedPath` (pure string re-basing — its own comment says *"pure string work"*),
- `Get-ScriptDriveRoot`, `Resolve-ParentVHDXPath`, `Resolve-HostVMPath` (path logic; `Test-Path` is mocked),
- `Get-guiVHDXPath` / `Get-coreVHDXPath` / `Get-ConsoleVHDXPath`, `Test-VHDPath`, `Select-SingleHost`.

Hyper-V/remoting-bound functions (`Get-PhysicalNICMTU`, the VM builders, `Set-SDNMGMT`, …) are **explicitly out of unit scope** — faithfully mocking `Invoke-Command -VMName`/DISM is more fragile than valuable. Going forward, **new or changed pure functions must ship with tests** (enforced by review + the CI gate).

**Tier 3 — End-to-end smoke (manual / optional self-hosted runner):**
- A documented **manual deploy checklist** (the established baseline): full deploy completes; desktop shows the new shortcuts; banner shows the new name; SDN examples present; `wacvmode` reachable.
- A lightweight **load-only smoke test** that dot-sources the launcher (see §9a) and asserts all expected functions are defined and the main flow did **not** execute — catching syntax/refactor breakage without a hypervisor.
- *Optional, later:* a **self-hosted GitHub Actions runner** on nested-virt-capable hardware for periodic real deploys; not required to start.

### 9a. Enabling testability (one small, required code change)

`New-SDNSandbox.ps1` currently **runs its main flow on load**, so a test can't dot-source it to reach the functions. The fix is the standard guard that makes the file **dot-source-safe**:

```powershell
# wraps the existing main-flow region at the bottom of the launcher
if ($MyInvocation.InvocationName -ne '.') {
    # ... existing main execution ...
}
```

Dot-sourcing (`. .\New-HyperVSandbox.ps1`) then defines functions **without** deploying, while `.\New-HyperVSandbox.ps1` still runs normally. This is the enabler for Tiers 2 & 3.
- **Now:** add the guard (Option **T2**, recommended — small, low-risk).
- **Fallback** (zero script change): tests AST-extract functions exactly as `Resume-SDNSandbox.ps1` already does (Option **T1**) — hackier, kept only as a backstop.
- **Future / community:** gradually extract functions into a `HyperVSandbox.psm1` module so the launcher becomes a thin orchestrator (Option **T3**) — best long-term testability, but a large refactor that is **out of scope now** and ideal incremental PR work.

---

## 10. Open-source & community readiness

Goal: publish to GitHub and accept community PRs for Hyper-V enthusiasts. The repo is already **MIT licensed** (permissive, PR-friendly). Add the standard contributor infrastructure:

| Artifact | Purpose |
|---|---|
| `.github/workflows/ci.yml` | Run Tier 1 + Tier 2 on `windows-latest` for every push/PR; status badge in README. |
| `PSScriptAnalyzerSettings.psd1` | Single source of lint rules + the baselined pre-existing warnings. |
| `tests/` (Pester 5) | Unit tests (Tier 2) + the load-only smoke test (Tier 3). CI pins Pester 5 even though the in-box module here is 3.4.0. |
| `CONTRIBUTING.md` | Dev setup, how to run lint/tests locally, the testing tiers, the "E2E needs nested virtualization" reality, branch/PR conventions, and the "A note on names" naming policy. |
| `CODE_OF_CONDUCT.md` | Contributor Covenant. |
| `SECURITY.md` | How to report issues; explicit note that the config ships plaintext product keys + a default `Password01` and is **lab-only, not production**. |
| `.github/ISSUE_TEMPLATE/` + `PULL_REQUEST_TEMPLATE.md` | Bug / feature / **new scenario** templates; PR checklist (lint, tests, ran-or-cannot-run E2E). |
| `.gitignore` | Exclude build/runtime artifacts: `*.har`, `*.vhdx`, `SDNVHDBuild/`, `SDNVHDs/`, scratch. (Also clears the stray 58 MB `admincenter1.har` from `git status`.) |
| `CHANGELOG.md` *(optional)* | Track releases once community contributions begin. |

License is MIT, © 2026 Windows Server PM Team; contributors are recognized via Git history / an optional `CONTRIBUTORS` note.

---

## 11. Phased implementation outline (detail deferred to writing-plans)

Re-sequenced per the maintainer's testing concern so the **testing + open-source foundation comes first** — it de-risks every later phase and is a prerequisite for accepting PRs.

1. **Phase 0 — Testing & OSS foundation (do first).** Add `.gitignore`, `PSScriptAnalyzerSettings.psd1`, the dot-source guard (§9a), a `tests/` project with the load-only smoke test + unit tests for the pure helpers in §9, the CI workflow, and contributor docs (§10). Establishes **green CI before any rename**.
2. **Phase 1 — Docs identity.** Rewrite both READMEs + instructions; add "A note on names"; CI + license badges. No deploy-behavior change.
3. **Phase 2 — Launcher rename + shim.** Git-rename to `New-HyperVSandbox.ps1`; add the deprecation shim; update synopsis/help/banner strings. Tier 1+2 gates active.
4. **Phase 3 — In-lab surfacing.** Rename/add desktop shortcuts; update completion banner and host shortcut descriptions.
5. **Phase 4 — Scenario scaffolding.** Add `Applications\EXAMPLES\` tracks with READMEs + one starter exercise each.
6. **Phase 5 — vNext docs.** "Testing vNext / preview builds" section; config comment note.
7. **Phase 6 — Assets & repo rename (maintainer).** New splash graphic; GitHub repo + local folder rename (manual).

Each phase is independently shippable; Phase 0 stands alone as a valuable foundation even before the rebrand.

---

## 12. Validation gates (per phase / per PR)

§9 is the full testing strategy; this is the quick gate checklist.
- **Every PR (CI, Tier 1+2):** all `*.ps1`/`*.psm1` parse clean; `Invoke-ScriptAnalyzer` against `PSScriptAnalyzerSettings.psd1` shows no *new* errors; `Import-PowerShellDataFile SDNSandbox-Config.psd1` succeeds; Pester unit tests for the pure helpers pass.
- **Shim:** dot-sourcing `New-SDNSandbox.ps1` is a guarded no-op (never deploys); executing it warns and forwards to `New-HyperVSandbox.ps1`.
- **Load-only smoke (Tier 3):** dot-sourcing `New-HyperVSandbox.ps1` defines all expected functions and does **not** execute the main flow.
- **Before merge to master / release (Tier 3, manual):** full nested-Hyper-V deploy completes; desktop shows new shortcuts; banner shows new name; SDN examples present; `wacvmode` reachable.

---

## 13. Risks & mitigations

| Risk | Mitigation |
|---|---|
| Launcher rename breaks the `E:\SDNSandbox` habit or external docs | Back-compat shim (§5c); document in both READMEs. |
| Hidden in-guest references to the script name | Grep the repo for `New-SDNSandbox` before finalizing; only string/launcher refs change, not identifiers. |
| Reviewers expect a *full* rename and see leftover `SDN*` internals | "A note on names" subsection frames it as an explicit, stability-driven decision. |
| Scenario content scope-creep | YAGNI: one starter exercise per track; structure first, depth later. |
| vNext image instability | Best-effort, documented; no hard-wired URLs; default stays WS2025. |
| Accidental commit of the stray 58 MB `admincenter1.har` | Commit only explicit paths; consider adding `*.har` to `.gitignore` in Phase 0. |
| No automated safety net during the rename refactor | Phase 0 establishes CI parse/lint/unit gates **before** any rename (§9, §11). |
| Test scope-creep (trying to unit-test Hyper-V code) | Unit scope limited to pure functions; E2E stays manual (§9 Tier 3). |
| Dot-source guard subtly changes script behavior | Standard idiom; the load-only smoke test asserts main flow is skipped on dot-source and runs on direct invocation. |
| Pester version drift (in-box 3.4.0 vs required 5.x) | CI installs/pins Pester 5; tests authored in Pester 5 syntax. |

---

## 14. Out of scope (YAGNI)

- Renaming VM names, functions, or config keys (Approach C).
- Renaming the `SDNSandbox\` working folder or the config file.
- Fixing the `reset-sdnsandbox.ps1` `Password01` hardcoding (separate, pre-existing issue).
- Authoring exhaustive guided labs for each new track (only starters now).
- Auto-downloading vNext/Insider ISOs.
- Producing the new splash graphic (design asset; provided later).
- Full module extraction / thin-launcher refactor (Option T3) — future, community-friendly.
- Unit-testing Hyper-V/remoting-bound functions (kept as manual Tier 3).

---

## 15. Open questions for maintainer review

**Resolved (2026-06-11):** maintainer is aligned on **Approach B** and the five earlier assumptions (launcher name `New-HyperVSandbox.ps1` + shim, repo rename to `HyperV-Sandbox-vMode-Edition`, scenario tracks AD / FailoverClustering / Storage-and-SMB, vNext via bring-your-own ISO, keep `SDN*` internal names).

**New — testing & open-source (please confirm or redirect):**

1. **Testability change:** OK to add the dot-source guard now (Option **T2**, recommended), or prefer the zero-script-change AST-extract approach (Option **T1**)?
2. **Sequencing:** ship **Phase 0 (testing + OSS foundation)** as its own PR — and possibly its own short spec — *before* the rebrand work, or bundle it into the rebrand branch?
3. **CI matrix:** test on **Windows PowerShell 5.1 only** (the deploy target), or also **PowerShell 7** for the pure helpers?
4. **OSS scope now vs later:** land the full contributor set (CONTRIBUTING / CODE_OF_CONDUCT / SECURITY / templates) in Phase 0, or start with just CI + `.gitignore` + tests and add the docs as a fast follow?

---

## 16. Next step

Maintainer is aligned on Approach B + assumptions (2026-06-11). The remaining decision is the testing/OSS sequencing in §15. On your OK, the next action is to invoke the **writing-plans** skill to turn this spec into a phased, task-by-task plan **starting with Phase 0 (testing + OSS foundation)**, using the validation gates in §12. **No implementation will occur before you approve this updated spec.** (Happy to split Phase 0 into its own spec/PR if you prefer.)
