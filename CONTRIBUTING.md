# Contributing

Thanks for helping build the **Hyper-V Sandbox – vMode Edition** lab! This is a community project for Windows Server virtualization enthusiasts. SDN remains a first-class scenario alongside Active Directory, Failover Clustering, SMB, and Storage.

## Ground rules

- Be respectful — see [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).
- Keep PRs focused. One logical change per PR.
- This is a **lab tool, not a production solution**. Never add real secrets.

## Dev setup

- Windows with **Windows PowerShell 5.1** (the deploy target) and/or **PowerShell 7**.
- Modules (CI installs these automatically; install locally to run tests):
  ```powershell
  Install-Module Pester           -MinimumVersion 5.5.0 -Force -SkipPublisherCheck -Scope CurrentUser
  Install-Module PSScriptAnalyzer -MinimumVersion 1.21.0 -Force -SkipPublisherCheck -Scope CurrentUser
  ```

## Running the checks

```powershell
pwsh -NoProfile -File .\tests\Invoke-CI.ps1
```
This runs the same suite as CI: static analysis (parse + PSScriptAnalyzer), config-schema validation, unit tests for pure helpers, and the load-only smoke test.

## Testing model (read this)

The full lab is a multi-VM **nested-Hyper-V** deployment and **cannot run on hosted CI** (it needs nested virtualization, ~64 GB RAM, ~250 GB disk, and 1–2 hours). Tests are a pyramid:

| Tier | What | Where |
|---|---|---|
| 1 | Parse + PSScriptAnalyzer + config schema | CI, every PR |
| 2 | Pester unit tests for **pure** functions (no Hyper-V/remoting) | CI, every PR |
| 3 | Full deploy smoke checklist + cheap "load-only" test | Manual / self-hosted |

**If you change or add a pure function, add/Update its unit test.** Hyper-V/remoting code is validated by a maintainer via a manual deploy.

## A note on names

The product is **Hyper-V Sandbox – vMode Edition**, but internal identifiers (VM names `SDNMGMT`/`SDNHOST*`, the `SDN*` config keys, and the `SDNSandbox-Config.psd1` filename) intentionally keep the historical `SDN` prefix for stability. The `SDNEXAMPLES`/`SDNExpress` content keeps "SDN" because that is the correct technical term. Don't mass-rename these.

## Commits & PRs

- Reference an issue when applicable.
- Ensure `Invoke-CI.ps1` passes locally before opening a PR.
- Fill in the PR template checklist (including whether you ran the manual deploy).
