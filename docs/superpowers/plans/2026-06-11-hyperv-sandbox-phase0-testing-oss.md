# Hyper-V Sandbox — Phase 0: Testing & Open-Source Foundation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up an automated test + CI foundation and the open-source contributor scaffolding for the lab, **without changing the deployment engine**, so the project can accept community PRs and the later rebrand phases land on green CI.

**Architecture:** Purely **additive** — new files only. Tests load the deploy engine's *function definitions* via AST extraction (the exact technique `Resume-SDNSandbox.ps1` already uses), so `New-SDNSandbox.ps1` is **not edited** in Phase 0 (the dot-source guard, spec Option T2, is deferred to the Phase 2 launcher rename where that file is touched anyway). A 3-tier test pyramid runs on GitHub-hosted CI for the cheap deterministic tiers (static analysis + Pester unit tests of pure helpers + config schema + a load-only smoke test); the full nested-Hyper-V deploy stays a manual Tier-3 checklist.

**Tech Stack:** Windows PowerShell 5.1 + PowerShell 7 (CI matrix), Pester 5, PSScriptAnalyzer, GitHub Actions (`windows-latest`).

**Source spec:** `docs/superpowers/specs/2026-06-10-hyperv-sandbox-vmode-edition-design.md` (§§9–12). Approach **B** + assumptions approved 2026-06-11.

---

## Pre-flight notes for the implementer

- **Recommended branch:** create `feature/phase0-testing-oss` off `master` (spec §15 Q2 — Phase 0 ships as its own PR). The design spec/plan docs already live on `feature/hyperv-sandbox-vmode-edition`; this is fine — Phase 0 only adds the files below.
- **Do NOT edit** `SDNSandbox\New-SDNSandbox.ps1` or `SDNSandbox-Config.psd1` in this phase. If a task seems to require it, stop and re-read — Phase 0 is additive.
- **Local tooling:** this machine has Pester **3.4.0** (too old) and PowerShell 7.6. The CI runner installs/imports **Pester 5** automatically. To run tests locally:
  ```powershell
  pwsh -NoProfile -File .\tests\Invoke-CI.ps1
  ```
  To run a single file locally after Pester 5 is installed:
  ```powershell
  Import-Module Pester -MinimumVersion 5.5.0 -Force
  Invoke-Pester -Path .\tests\Unit\PureHelpers.Tests.ps1 -Output Detailed
  ```
- **Reusable validation commands:**
  - Settings load: `Import-PowerShellDataFile .\PSScriptAnalyzerSettings.psd1` → hashtable, no error.
  - Workflow YAML sanity (optional): `Get-Content .\.github\workflows\ci.yml` parses as text; GitHub validates on push.
- **Commit trailer (repo convention):** end every commit message with
  `Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>`
- **No test harness existed before this plan** — these tasks *create* it. The "tests" here assert behavior of *existing* code, so most tasks are: write test → run → it passes green against current code → commit. If a test goes red, that is a real finding; fix forward or record it, do not weaken the test.

---

## File Structure

| File | Responsibility |
|---|---|
| `.gitignore` | Keep binaries/build artifacts (incl. the stray `*.har`, `*.vhdx`) out of the repo. |
| `PSScriptAnalyzerSettings.psd1` | Single source of lint rules + the by-design rule exclusions. |
| `tests/Invoke-CI.ps1` | One entrypoint: ensure Pester 5 + PSScriptAnalyzer, run all Pester tests, exit non-zero on failure. |
| `tests/Helpers/Load-SandboxFunctions.ps1` | Dot-sourceable loader: defines the launcher's functions in the caller scope via AST extraction, **without** running the deploy. |
| `tests/Static/Analyzer.Tests.ps1` | Tier 1 — parse-clean + zero Error-severity analyzer findings on core scripts. |
| `tests/Config/ConfigSchema.Tests.ps1` | Tier 1 — config imports and required keys/shapes are valid. |
| `tests/Unit/PureHelpers.Tests.ps1` | Tier 2 — unit tests for the host-independent helper functions. |
| `tests/Smoke/LoadOnly.Tests.ps1` | Tier 3 (cheap) — launcher parses and all functions define without executing main. |
| `.github/workflows/ci.yml` | Run `tests/Invoke-CI.ps1` on push/PR under a `[pwsh, powershell]` matrix. |
| `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, `SECURITY.md` | Contributor onboarding, conduct, vuln reporting. |
| `.github/ISSUE_TEMPLATE/*`, `.github/PULL_REQUEST_TEMPLATE.md` | Issue/PR scaffolding. |
| `README.md` | Add a CI status badge (single-line insert; full rewrite is Phase 1). |

---

## Task 1: Repo hygiene — `.gitignore`

**Files:**
- Create: `.gitignore`

- [ ] **Step 1: Create `.gitignore`**

```gitignore
# --- Build / runtime artifacts (never commit large binaries) ---
*.vhdx
*.vhd
*.iso
*.har
SDNVHDBuild/
SDNVHDs/
**/TempVModeMount/

# --- Test output ---
**/testResults.xml

# --- Editor / OS cruft ---
.vs/
*.user
Thumbs.db
.DS_Store
```

- [ ] **Step 2: Verify the stray HAR is now ignored**

Run:
```powershell
git status --porcelain
```
Expected: the previously-untracked `admincenter1.har` no longer appears; only `.gitignore` shows as new (`?? .gitignore`).

- [ ] **Step 3: Commit**

```powershell
git add .gitignore
git commit -m "chore: add .gitignore for build artifacts, test output, and editor cruft" -m "Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

## Task 2: Lint settings + Tier-1 static tests + CI runner

**Files:**
- Create: `PSScriptAnalyzerSettings.psd1`
- Create: `tests/Invoke-CI.ps1`
- Create: `tests/Static/Analyzer.Tests.ps1`

- [ ] **Step 1: Create `PSScriptAnalyzerSettings.psd1`**

```powershell
@{
    # Rules excluded BY DESIGN for this lab-only deploy engine. These reflect intentional
    # choices (plaintext lab creds, fixed VM names, an interactive Write-Host wizard, an AST
    # function-loader), not bugs. The CI gate fails on any *Error*-severity finding regardless.
    ExcludeRules = @(
        'PSAvoidUsingConvertToSecureStringWithPlainText',  # creds are built from a documented lab password
        'PSAvoidUsingPlainTextForPassword',                # SDNAdminPassword is a known lab default, not production
        'PSAvoidUsingComputerNameHardcoded',               # fixed lab VM names (SDNMGMT/SDNHOST1/2/3) are intentional
        'PSAvoidUsingWriteHost',                           # the deploy is an interactive console wizard
        'PSUseShouldProcessForStateChangingFunctions',     # New-*/Set-* here are deploy steps, not shipping cmdlets
        'PSAvoidUsingInvokeExpression'                     # AST loader / Resume tooling use it deliberately
    )
}
```

- [ ] **Step 2: Verify the settings file imports**

Run:
```powershell
Import-PowerShellDataFile .\PSScriptAnalyzerSettings.psd1
```
Expected: a hashtable with an `ExcludeRules` array; no error.

- [ ] **Step 3: Create the CI runner `tests/Invoke-CI.ps1`**

```powershell
#Requires -Version 5.1
<#
.SYNOPSIS
  Single CI entrypoint: ensures Pester 5 + PSScriptAnalyzer are available, then runs every
  *.Tests.ps1 under tests\. Exits non-zero on any failure. Works on Windows PowerShell 5.1
  and PowerShell 7.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Write-Host "PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
    Install-PackageProvider -Name NuGet -Force -Scope CurrentUser | Out-Null
}
Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue

function Initialize-RequiredModule {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][version]$MinimumVersion)
    $have = Get-Module -ListAvailable -Name $Name | Where-Object { $_.Version -ge $MinimumVersion }
    if (-not $have) {
        Write-Host "Installing $Name >= $MinimumVersion ..."
        Install-Module $Name -MinimumVersion $MinimumVersion -Force -SkipPublisherCheck -Scope CurrentUser
    }
}
Initialize-RequiredModule -Name Pester           -MinimumVersion '5.5.0'
Initialize-RequiredModule -Name PSScriptAnalyzer -MinimumVersion '1.21.0'

Import-Module Pester -MinimumVersion '5.5.0' -Force

$config = New-PesterConfiguration
$config.Run.Path              = $PSScriptRoot
$config.Run.Exit              = $true
$config.Output.Verbosity      = 'Detailed'
$config.TestResult.Enabled    = $true
$config.TestResult.OutputPath = Join-Path $PSScriptRoot 'testResults.xml'
Invoke-Pester -Configuration $config
```

- [ ] **Step 4: Write the Tier-1 static test `tests/Static/Analyzer.Tests.ps1`**

```powershell
BeforeAll {
    $script:repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $script:coreScripts = @(
        'SDNSandbox\New-SDNSandbox.ps1',
        'SDNSandbox\New-SDNVHDfromISO.ps1',
        'SDNSandbox\Resume-SDNSandbox.ps1',
        'SDNSandbox\Repair-WACvModeInstall.ps1'
    ) | ForEach-Object { Join-Path $script:repo $_ }
    $script:settings = Join-Path $script:repo 'PSScriptAnalyzerSettings.psd1'
}

Describe 'Tier 1: static analysis' {
    It 'every core script parses with zero syntax errors' {
        foreach ($f in $script:coreScripts) {
            $errors = $null
            [System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$null, [ref]$errors) | Out-Null
            $errors | Should -BeNullOrEmpty -Because "$f must parse cleanly"
        }
    }

    It 'PSScriptAnalyzer reports no Error-severity findings on core scripts' {
        Import-Module PSScriptAnalyzer -ErrorAction Stop
        $findings = foreach ($f in $script:coreScripts) {
            Invoke-ScriptAnalyzer -Path $f -Settings $script:settings -Severity Error
        }
        $findings | Should -BeNullOrEmpty -Because 'there are no pre-existing Error-severity issues; new ones must fail CI'
    }
}
```

- [ ] **Step 5: Run the Tier-1 tests and verify they pass**

Run:
```powershell
pwsh -NoProfile -File .\tests\Invoke-CI.ps1
```
Expected: Pester runs `Analyzer.Tests.ps1`; both `It` blocks **PASS** (the deploy scripts parse clean and have no Error-severity findings). If the analyzer surfaces an *Error*, that is a real bug — fix it; do not add it to `ExcludeRules` (excludes are for by-design rule classes, not for silencing genuine errors).

- [ ] **Step 6: Commit**

```powershell
git add PSScriptAnalyzerSettings.psd1 tests/Invoke-CI.ps1 tests/Static/Analyzer.Tests.ps1
git commit -m "test: add Tier-1 static analysis (parse + PSScriptAnalyzer) and CI runner" -m "Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

## Task 3: Tier-1 config schema test

**Files:**
- Create: `tests/Config/ConfigSchema.Tests.ps1`

- [ ] **Step 1: Write the config schema test**

```powershell
BeforeAll {
    $configPath = (Resolve-Path (Join-Path $PSScriptRoot '..\..\SDNSandbox\SDNSandbox-Config.psd1')).Path
    $script:cfg = Import-PowerShellDataFile -Path $configPath
}

Describe 'SDNSandbox-Config.psd1 schema' {
    It 'imports as a hashtable' {
        $script:cfg | Should -BeOfType ([hashtable])
    }

    It 'contains all required keys' {
        $required = @(
            'SDNAdminPassword','SDNDomainFQDN','DCName',
            'guiVHDXPath','coreVHDXPath','HostVMPath',
            'NestedVMMemoryinGB','sdnMGMTMemoryinGB',
            'vModeUri','vModeVMName','vModeIP','MEM_vMode','PostgreSQLPort',
            'SDNMGMTIP','SDNHOST1IP','SDNHOST2IP',
            'providerVLAN','SDNLABMTU','natConfigure'
        )
        foreach ($k in $required) { $script:cfg.Keys | Should -Contain $k }
    }

    It 'vModeIP is CIDR notation' {
        $script:cfg.vModeIP | Should -Match '^\d{1,3}(\.\d{1,3}){3}/\d{1,2}$'
    }

    It 'vModeUri is an https URL' {
        $script:cfg.vModeUri | Should -Match '^https://'
    }

    It 'PostgreSQLPort is a valid TCP port' {
        [int]$script:cfg.PostgreSQLPort | Should -BeGreaterThan 0
        [int]$script:cfg.PostgreSQLPort | Should -BeLessOrEqual 65535
    }

    It 'MEM_vMode is at least 8GB (installer hard minimum)' {
        [int64]$script:cfg.MEM_vMode | Should -BeGreaterOrEqual 8GB
    }

    It 'sdnMGMTMemoryinGB is large enough to host the nested VMs including vMode' {
        [int64]$script:cfg.sdnMGMTMemoryinGB | Should -BeGreaterOrEqual 32GB
    }

    It 'the domain NetBIOS label is 14 characters or fewer' {
        ($script:cfg.SDNDomainFQDN -split '\.')[0].Length | Should -BeLessOrEqual 14
    }
}
```

- [ ] **Step 2: Run and verify it passes**

Run:
```powershell
Import-Module Pester -MinimumVersion 5.5.0 -Force
Invoke-Pester -Path .\tests\Config\ConfigSchema.Tests.ps1 -Output Detailed
```
Expected: all `It` blocks **PASS** against the current config (vModeIP `192.168.1.15/24`, PostgreSQLPort `5432`, MEM_vMode `10GB`, sdnMGMTMemoryinGB `36GB`, label `contoso`).

- [ ] **Step 3: Commit**

```powershell
git add tests/Config/ConfigSchema.Tests.ps1
git commit -m "test: add config schema validation for SDNSandbox-Config.psd1" -m "Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

## Task 4: Function loader + Tier-2 unit tests for pure helpers

**Files:**
- Create: `tests/Helpers/Load-SandboxFunctions.ps1`
- Create: `tests/Unit/PureHelpers.Tests.ps1`

- [ ] **Step 1: Create the AST function loader**

```powershell
<#
.SYNOPSIS
  DOT-SOURCE this script to define the deploy engine's FUNCTIONS in the caller's scope WITHOUT
  executing its main deployment flow. Mirrors the AST-extraction technique already used by
  Resume-SDNSandbox.ps1, so the launcher itself needs no change.
.PARAMETER Path
  Full path to New-SDNSandbox.ps1.
.OUTPUTS
  The names of the functions that were defined (so smoke tests can assert coverage).
.EXAMPLE
  . "$PSScriptRoot\..\Helpers\Load-SandboxFunctions.ps1" -Path $launcherPath
#>
param([Parameter(Mandatory)][string]$Path)

$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$parseErrors)
if ($parseErrors) {
    throw "Parse errors in '$Path': " + (($parseErrors | ForEach-Object { $_.Message }) -join '; ')
}

$fnAsts = $ast.FindAll(
    { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] },
    $true)

# Dot-source each function definition AT THIS SCOPE. Because this script is itself dot-sourced
# by the test, the definitions land in the test's scope where Pester can call and mock them.
foreach ($fn in $fnAsts) {
    . ([scriptblock]::Create($fn.Extent.Text))
}

# Emit the defined names to the caller.
$fnAsts | ForEach-Object { $_.Name }
```

- [ ] **Step 2: Write the pure-helper unit tests**

```powershell
BeforeAll {
    $launcher = (Resolve-Path (Join-Path $PSScriptRoot '..\..\SDNSandbox\New-SDNSandbox.ps1')).Path
    . (Join-Path $PSScriptRoot '..\Helpers\Load-SandboxFunctions.ps1') -Path $launcher | Out-Null
}

Describe 'ConvertTo-ScriptDriveRootedPath' {
    It 're-bases a rooted local path onto another drive' {
        ConvertTo-ScriptDriveRootedPath -Path 'C:\SDNVHDs\gui.vhdx' -DriveRoot 'E:' | Should -Be 'E:\SDNVHDs\gui.vhdx'
    }
    It 'leaves a UNC path unchanged' {
        ConvertTo-ScriptDriveRootedPath -Path '\\srv\share\gui.vhdx' -DriveRoot 'E:' | Should -Be '\\srv\share\gui.vhdx'
    }
    It 'leaves a relative path unchanged' {
        ConvertTo-ScriptDriveRootedPath -Path 'folder\gui.vhdx' -DriveRoot 'E:' | Should -Be 'folder\gui.vhdx'
    }
    It 'returns empty input unchanged' {
        ConvertTo-ScriptDriveRootedPath -Path '' -DriveRoot 'E:' | Should -Be ''
    }
}

Describe 'Get-ScriptDriveRoot' {
    It 'returns a drive qualifier like X:' {
        Get-ScriptDriveRoot | Should -Match '^[A-Za-z]:$'
    }
}

Describe 'Get-guiVHDXPath / Get-coreVHDXPath / Get-ConsoleVHDXPath' {
    It 'appends GUI.vhdx to the host VM path' {
        Get-guiVHDXPath -guiVHDXPath 'ignored' -HostVMPath 'D:\VMs\' | Should -Be 'D:\VMs\GUI.vhdx'
    }
    It 'appends CORE.vhdx to the host VM path' {
        Get-coreVHDXPath -coreVHDXPath 'ignored' -HostVMPath 'D:\VMs\' | Should -Be 'D:\VMs\CORE.vhdx'
    }
    It 'appends Console.vhdx to the host VM path' {
        Get-ConsoleVHDXPath -ConsoleVHDXPath 'ignored' -HostVMPath 'D:\VMs\' | Should -Be 'D:\VMs\Console.vhdx'
    }
}

Describe 'Select-SingleHost' {
    It 'maps every SDNHOST to the local computer name' {
        $r = Select-SingleHost -sdnHOSTs @('SDNHOST1','SDNHOST2')
        @($r).Count        | Should -Be 2
        $r[0].SDNHOST      | Should -Be 'SDNHOST1'
        $r[0].VMHost       | Should -Be $env:COMPUTERNAME
        $r[1].SDNHOST      | Should -Be 'SDNHOST2'
    }
}

Describe 'Resolve-ParentVHDXPath' {
    It 'returns the configured path when the image exists there (override wins)' {
        Mock Test-Path { $true }
        Resolve-ParentVHDXPath -ConfiguredPath 'C:\SDNVHDs\gui.vhdx' -Label 'GUI' | Should -Be 'C:\SDNVHDs\gui.vhdx'
    }
    It 're-bases onto the script drive when the configured path is missing but the rebased one exists' {
        Mock Get-ScriptDriveRoot { 'E:' }
        Mock Write-Host {}
        Mock Test-Path { $false } -ParameterFilter { $LiteralPath -eq 'C:\SDNVHDs\gui.vhdx' }
        Mock Test-Path { $true }  -ParameterFilter { $LiteralPath -eq 'E:\SDNVHDs\gui.vhdx' }
        Resolve-ParentVHDXPath -ConfiguredPath 'C:\SDNVHDs\gui.vhdx' -Label 'GUI' | Should -Be 'E:\SDNVHDs\gui.vhdx'
    }
    It 'returns the configured path when neither location has the image' {
        Mock Get-ScriptDriveRoot { 'E:' }
        Mock Write-Host {}
        Mock Test-Path { $false }
        Resolve-ParentVHDXPath -ConfiguredPath 'C:\SDNVHDs\gui.vhdx' -Label 'GUI' | Should -Be 'C:\SDNVHDs\gui.vhdx'
    }
}

Describe 'Resolve-HostVMPath' {
    It 'returns the configured path when its drive exists (override wins)' {
        Mock Test-Path { $true } -ParameterFilter { $LiteralPath -eq 'V:\' }
        Resolve-HostVMPath -ConfiguredPath 'V:\VMs' | Should -Be 'V:\VMs'
    }
    It 're-bases onto the script drive when the configured drive is absent' {
        Mock Get-ScriptDriveRoot { 'E:' }
        Mock Write-Host {}
        Mock Test-Path { $false } -ParameterFilter { $LiteralPath -eq 'V:\' }
        Resolve-HostVMPath -ConfiguredPath 'V:\VMs' | Should -Be 'E:\VMs'
    }
    It 'leaves a UNC path unchanged' {
        Resolve-HostVMPath -ConfiguredPath '\\srv\share\VMs' | Should -Be '\\srv\share\VMs'
    }
}
```

- [ ] **Step 3: Run the unit tests and verify they pass**

Run:
```powershell
pwsh -NoProfile -File .\tests\Invoke-CI.ps1
```
Expected: the `PureHelpers.Tests.ps1` describes all **PASS** (≈ 16 assertions). If a `Mock Test-Path -ParameterFilter` does not intercept, confirm the function under test calls `Test-Path -LiteralPath` (it does: see `New-SDNSandbox.ps1:275,304`) and that the mock is declared inside the `It`.

- [ ] **Step 4: Commit**

```powershell
git add tests/Helpers/Load-SandboxFunctions.ps1 tests/Unit/PureHelpers.Tests.ps1
git commit -m "test: add unit tests for pure path/host helper functions" -m "Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

> **Note:** `Test-VHDPath` is intentionally **not** unit-tested here — it calls `break` at script scope, which makes isolated invocation unreliable. It is covered indirectly by the manual Tier-3 deploy and is a candidate for refactor (return a bool) in a later phase.

---

## Task 5: Tier-3 load-only smoke test

**Files:**
- Create: `tests/Smoke/LoadOnly.Tests.ps1`

- [ ] **Step 1: Write the smoke test**

```powershell
BeforeAll {
    $launcher = (Resolve-Path (Join-Path $PSScriptRoot '..\..\SDNSandbox\New-SDNSandbox.ps1')).Path
    $script:loadedNames = . (Join-Path $PSScriptRoot '..\Helpers\Load-SandboxFunctions.ps1') -Path $launcher
}

Describe 'Launcher loads without executing the deployment' {
    It 'parses cleanly and defines a substantial set of functions' {
        @($script:loadedNames).Count | Should -BeGreaterThan 30
    }

    It 'defines the key deployment functions' {
        foreach ($fn in @(
            'Set-SDNMGMT','New-DCVM','New-RouterVM','New-AdminCenterVM',
            'New-WACvModeVM','New-SDNS2DCluster','Test-SDNHOSTVMConnection','New-NestedVM')) {
            $script:loadedNames | Should -Contain $fn
        }
    }
}
```

- [ ] **Step 2: Run and verify it passes**

Run:
```powershell
Import-Module Pester -MinimumVersion 5.5.0 -Force
Invoke-Pester -Path .\tests\Smoke\LoadOnly.Tests.ps1 -Output Detailed
```
Expected: both `It` blocks **PASS** (the launcher defines ~40 functions; all listed names are present). Because only function *definitions* are dot-sourced, no VM/deploy code runs.

- [ ] **Step 3: Commit**

```powershell
git add tests/Smoke/LoadOnly.Tests.ps1
git commit -m "test: add load-only smoke test (functions define, deploy does not run)" -m "Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

## Task 6: GitHub Actions CI workflow

**Files:**
- Create: `.github/workflows/ci.yml`

- [ ] **Step 1: Create the workflow**

```yaml
name: CI

on:
  push:
    branches: [ master, 'feature/**' ]
  pull_request:
    branches: [ master ]

jobs:
  test:
    name: Lint + Pester (${{ matrix.shell }})
    runs-on: windows-latest
    strategy:
      fail-fast: false
      matrix:
        shell: [ pwsh, powershell ]
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Run CI test suite
        shell: ${{ matrix.shell }}
        run: .\tests\Invoke-CI.ps1

      - name: Upload test results
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: pester-results-${{ matrix.shell }}
          path: tests/testResults.xml
          if-no-files-found: ignore
```

- [ ] **Step 2: Sanity-check the runner end-to-end locally (acts as the CI would)**

Run:
```powershell
pwsh -NoProfile -File .\tests\Invoke-CI.ps1
```
Expected: Pester discovers all four test files (Static, Config, Unit, Smoke) and reports **0 failed**; a `tests/testResults.xml` is produced (and is git-ignored by Task 1).

- [ ] **Step 3: Commit**

```powershell
git add .github/workflows/ci.yml
git commit -m "ci: run lint + Pester on windows-latest under pwsh and Windows PowerShell 5.1" -m "Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

## Task 7: Contributor docs

**Files:**
- Create: `CONTRIBUTING.md`
- Create: `CODE_OF_CONDUCT.md`
- Create: `SECURITY.md`

- [ ] **Step 1: Create `CONTRIBUTING.md`**

```markdown
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
```

- [ ] **Step 2: Create `CODE_OF_CONDUCT.md`**

```markdown
# Code of Conduct

## Our Pledge

We as members, contributors, and leaders pledge to make participation in our community a harassment-free experience for everyone, regardless of age, body size, visible or invisible disability, ethnicity, sex characteristics, gender identity and expression, level of experience, education, socio-economic status, nationality, personal appearance, race, religion, or sexual identity and orientation.

## Our Standards

Examples of behavior that contributes to a positive environment: demonstrating empathy and kindness, being respectful of differing opinions, giving and gracefully accepting constructive feedback, and focusing on what is best for the community.

Unacceptable behavior includes harassment, trolling, insulting or derogatory comments, public or private harassment, publishing others' private information, and other conduct which could reasonably be considered inappropriate.

## Enforcement

Instances of abusive, harassing, or otherwise unacceptable behavior may be reported to the project maintainers by opening a confidential report (see [SECURITY.md](SECURITY.md) for private contact options). All complaints will be reviewed and investigated promptly and fairly.

## Attribution

This Code of Conduct is adapted from the [Contributor Covenant](https://www.contributor-covenant.org), version 2.1, available at https://www.contributor-covenant.org/version/2/1/code_of_conduct.html.
```

- [ ] **Step 3: Create `SECURITY.md`**

```markdown
# Security Policy

## This is a lab, not a production system

The Hyper-V Sandbox is intentionally insecure for ease of learning:

- The configuration file (`SDNSandbox/SDNSandbox-Config.psd1`) stores **product keys and a default password (`Password01`) in plaintext**, and that file is copied onto lab VMs during deployment.
- The lab is **not** hardened, highly available, or fault tolerant.

**Never deploy it on production networks or with real credentials/keys.**

## Reporting a vulnerability

If you find a security issue in the *scripts themselves* (e.g., something that could harm the host or leak data beyond the documented lab behavior), please report it privately:

1. Preferred: open a **GitHub Security Advisory** ("Report a vulnerability") on this repository.
2. Alternatively, open a regular issue **without** sensitive details and ask a maintainer for a private channel.

Please do not open public issues containing exploit details. We aim to acknowledge reports within a few days.
```

- [ ] **Step 4: Verify the files render (basic check) and commit**

Run:
```powershell
Get-ChildItem CONTRIBUTING.md, CODE_OF_CONDUCT.md, SECURITY.md | Select-Object Name, Length
```
Expected: three files listed with non-zero length.

```powershell
git add CONTRIBUTING.md CODE_OF_CONDUCT.md SECURITY.md
git commit -m "docs: add CONTRIBUTING, CODE_OF_CONDUCT, and SECURITY for open-source readiness" -m "Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

## Task 8: Issue/PR templates + README CI badge

**Files:**
- Create: `.github/ISSUE_TEMPLATE/bug_report.md`
- Create: `.github/ISSUE_TEMPLATE/feature_request.md`
- Create: `.github/ISSUE_TEMPLATE/scenario_request.md`
- Create: `.github/PULL_REQUEST_TEMPLATE.md`
- Modify: `README.md` (insert a CI badge directly under the H1 title)

- [ ] **Step 1: Create `.github/ISSUE_TEMPLATE/bug_report.md`**

```markdown
---
name: Bug report
about: Something in the deploy or scripts didn't work
title: "[Bug] "
labels: bug
---

**What happened**

**What you expected**

**Repro / command run**

**Environment**
- Host OS / PowerShell version:
- Single host or multi-host:
- Base image: Windows Server 2025 / vNext (which build):

**Relevant log output** (paste text, not screenshots where possible)
```

- [ ] **Step 2: Create `.github/ISSUE_TEMPLATE/feature_request.md`**

```markdown
---
name: Feature request
about: Suggest an improvement to the scripts or tooling
title: "[Feature] "
labels: enhancement
---

**Problem / motivation**

**Proposed change**

**Alternatives considered**

**Does this affect the deploy engine (needs a manual nested-Hyper-V test)?** yes / no
```

- [ ] **Step 3: Create `.github/ISSUE_TEMPLATE/scenario_request.md`**

```markdown
---
name: Scenario request
about: Propose a new learning scenario (AD, Failover Clustering, SMB, Storage, SDN, etc.)
title: "[Scenario] "
labels: scenario
---

**Scenario area** (e.g., Failover Clustering / Storage / SMB / Active Directory / SDN)

**What should the learner be able to do or test?**

**Does the existing lab already build the needed infrastructure?** (the lab already provides AD, an S2D failover cluster `SDNCLUSTER`, storage, WAC + vMode)

**Draft exercise steps (optional)**
```

- [ ] **Step 4: Create `.github/PULL_REQUEST_TEMPLATE.md`**

```markdown
## Summary

<!-- What does this PR change and why? -->

## Checklist

- [ ] `pwsh -NoProfile -File .\tests\Invoke-CI.ps1` passes locally
- [ ] Added/updated unit tests for any **pure** function I changed
- [ ] Did **not** rename internal identifiers (`SDNMGMT`/`SDNHOST*`, `SDN*` config keys, `SDNSandbox-Config.psd1`) — see CONTRIBUTING "A note on names"
- [ ] Updated docs if behavior or usage changed
- [ ] End-to-end deploy impact: ☐ none ☐ I ran a manual nested-Hyper-V deploy ☐ needs maintainer to run E2E

## Notes for reviewers
```

- [ ] **Step 5: Add the CI badge to `README.md`**

Insert this line immediately **after** the first H1 line (`# SDN Sandbox`). Use the project's eventual published path (proposed in spec §5a). If the repo is published under a different owner/name, update the path.

```markdown
![CI](https://github.com/KBisnettMSFT/HyperV-Sandbox-vMode-Edition/actions/workflows/ci.yml/badge.svg)
```

Concretely, change:
```markdown
# SDN Sandbox 

SDN Sandbox is a series of scripts that creates a [HyperConverged]...
```
to:
```markdown
# SDN Sandbox 

![CI](https://github.com/KBisnettMSFT/HyperV-Sandbox-vMode-Edition/actions/workflows/ci.yml/badge.svg)

SDN Sandbox is a series of scripts that creates a [HyperConverged]...
```
(The title text itself is rewritten in Phase 1; this task only inserts the badge.)

- [ ] **Step 6: Commit**

```powershell
git add .github/ISSUE_TEMPLATE/bug_report.md .github/ISSUE_TEMPLATE/feature_request.md .github/ISSUE_TEMPLATE/scenario_request.md .github/PULL_REQUEST_TEMPLATE.md README.md
git commit -m "docs: add issue/PR templates and CI status badge" -m "Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
```

---

## Final verification

- [ ] **Run the full suite the way CI will, on both shells:**

```powershell
pwsh       -NoProfile -File .\tests\Invoke-CI.ps1
powershell -NoProfile -File .\tests\Invoke-CI.ps1
```
Expected on **both**: all describes pass, **0 failed**. (First run installs Pester 5 / PSScriptAnalyzer.)

- [ ] **Confirm the deploy engine was not modified:**

```powershell
git diff --stat master -- SDNSandbox/New-SDNSandbox.ps1 SDNSandbox/SDNSandbox-Config.psd1
```
Expected: **no output** (these files are unchanged in Phase 0).

- [ ] **Confirm the working tree is clean and the HAR is ignored:**

```powershell
git status --porcelain
```
Expected: empty (the 58 MB `admincenter1.har` is ignored, not tracked).

---

## Self-review (completed while writing this plan)

- **Spec coverage:** Tier 1 (§9) → Tasks 2–3; Tier 2 (§9) → Task 4; Tier 3 (§9) → Task 5; OSS readiness (§10: CI, settings, tests, CONTRIBUTING/COC/SECURITY, templates, `.gitignore`) → Tasks 1,2,6,7,8; validation gates (§12) → final verification. The dot-source guard (§9a Option T2) is **deliberately deferred** to Phase 2 (launcher rename) and noted as such; Phase 0 uses Option T1 (AST extraction) to stay additive — a refinement recorded here for the maintainer.
- **Placeholder scan:** every step contains real code/commands and expected output; no TBDs.
- **Type/name consistency:** test calls match the real signatures verified in `New-SDNSandbox.ps1` (`ConvertTo-ScriptDriveRootedPath -Path/-DriveRoot`, `Resolve-ParentVHDXPath -ConfiguredPath/-Label`, `Resolve-HostVMPath -ConfiguredPath`, `Get-*VHDXPath -*VHDXPath/-HostVMPath`, `Select-SingleHost -sdnHOSTs`); loader output feeds the smoke test's name assertions.

---

## Execution handoff

Phase 0 is **not** to be implemented until the maintainer approves the spec's testing/OSS strategy. When approved, execute task-by-task via **superpowers:subagent-driven-development** (recommended) or **superpowers:executing-plans**.
