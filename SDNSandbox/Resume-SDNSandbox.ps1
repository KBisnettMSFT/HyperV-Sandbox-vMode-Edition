<#
.SYNOPSIS
    Finishes an SDN Sandbox deployment that stopped at the very end of Set-SDNMGMT (e.g. because the
    WAC Virtualization Mode install failed) WITHOUT re-running the whole multi-hour deploy.

.DESCRIPTION
    In New-SDNSandbox.ps1 the top-level deploy runs, in order:
        ... host prep / NAT / SDN hosts / Set-SDNserver ...
        Set-SDNMGMT            <- builds SDNMGMT, DC, router, AdminCenter, and (LAST line) New-WACvModeVM
        New-HyperConvergedEnvironment   <- provisions Hyper-V logical switches / SET teams on the hosts
        New-SDNS2DCluster               <- creates the Storage Spaces Direct cluster
        (legacy NC + SSO - only If $SDNConfig.ProvisionLegacyNC)
        desktop RDP shortcuts

    Because New-WACvModeVM is the LAST statement in Set-SDNMGMT, a vMode failure aborts the deploy with
    everything BEFORE it already done. Once vMode is fixed/installed, the only remaining work is the two
    functions after Set-SDNMGMT plus the desktop shortcuts. This script replays exactly those steps.

    It re-creates the session state the main script sets up top (config, credentials, WinRM TrustedHosts),
    loads the deploy functions via AST WITHOUT executing the main body, then runs the remaining steps.

    Run from the PHYSICAL HOST (same place you ran New-SDNSandbox.ps1): the remaining functions connect to
    the lab VMs (Admincenter, SDNHOST2) over WinRM by name, which only works from the host.

.PARAMETER ConfigPath
    Path to SDNSandbox-Config.psd1. Defaults to .\SDNSandbox-Config.psd1 next to this script.

.PARAMETER DeployScript
    Path to New-SDNSandbox.ps1 (the function source). Defaults to .\New-SDNSandbox.ps1 next to this script.

.PARAMETER SkipShortcuts
    Skip creating the AdminCenter/WACvMode desktop shortcuts.

.EXAMPLE
    .\Resume-SDNSandbox.ps1
#>

[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$DeployScript,
    [switch]$SkipShortcuts
)

$ErrorActionPreference = 'Stop'
$VerbosePreference = 'Continue'
$WarningPreference = 'SilentlyContinue'

if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot 'SDNSandbox-Config.psd1' }
if (-not $DeployScript) { $DeployScript = Join-Path $PSScriptRoot 'New-SDNSandbox.ps1' }
if (-not (Test-Path $ConfigPath)) { throw "Config file not found: $ConfigPath" }
if (-not (Test-Path $DeployScript)) { throw "Deploy script not found: $DeployScript" }

# --- 1) Session setup the main script does up top (config + credentials + WinRM TrustedHosts) -------
Write-Host "Loading config: $ConfigPath" -ForegroundColor Cyan
$SDNConfig = Import-PowerShellDataFile $ConfigPath

$localCred = New-Object System.Management.Automation.PSCredential(
    'Administrator',
    (ConvertTo-SecureString $SDNConfig.SDNAdminPassword -AsPlainText -Force)
)
$domainCred = New-Object System.Management.Automation.PSCredential(
    "$(($SDNConfig.SDNDomainFQDN.Split('.')[0]))\Administrator",
    (ConvertTo-SecureString $SDNConfig.SDNAdminPassword -AsPlainText -Force)
)

# The remaining functions reach the lab VMs over WinRM by name; the main script sets this.
Set-Item WSMan:\localhost\Client\TrustedHosts * -Confirm:$false -Force

# --- 2) Load the deploy functions WITHOUT re-running the main body (AST extract) ---------------------
Write-Host "Loading deploy functions from $DeployScript (no main-body execution)" -ForegroundColor Cyan
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    (Resolve-Path $DeployScript), [ref]$null, [ref]$null)
$fnDefs = $ast.FindAll(
    { param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
foreach ($fn in $fnDefs) { Invoke-Expression $fn.Extent.Text }

foreach ($needed in 'New-HyperConvergedEnvironment', 'New-SDNS2DCluster') {
    if (-not (Get-Command $needed -ErrorAction SilentlyContinue)) {
        throw "Function '$needed' was not loaded from $DeployScript - cannot resume."
    }
}

# --- 3) Finish the deploy: the two steps that run AFTER Set-SDNMGMT ----------------------------------
# New-HyperConvergedEnvironment references $SDNConfig via $Using:SDNConfig inside its own Invoke-Command,
# so $SDNConfig MUST be visible in this scope (it is - set above).
Write-Host "`n=== Step 1/2: New-HyperConvergedEnvironment (logical switches / SET teams) ===" -ForegroundColor Yellow
New-HyperConvergedEnvironment -localCred $localCred -domainCred $domainCred | Out-Null

Write-Host "`n=== Step 2/2: New-SDNS2DCluster (create S2D cluster - this is the long one) ===" -ForegroundColor Yellow
New-SDNS2DCluster -SDNConfig $SDNConfig -domainCred $domainCred -SDNClusterNode 'SDNHOST2' | Out-Null

# Legacy Network Controller + Single Sign-On are intentionally skipped here: the main script only runs
# them inside  If ($SDNConfig.ProvisionLegacyNC). Honor that same gate.
if ($SDNConfig.ProvisionLegacyNC) {
    Write-Host "`n=== Optional: ProvisionLegacyNC is TRUE - New-SDNEnvironment + SSO ===" -ForegroundColor Yellow
    New-SDNEnvironment -SDNConfig $SDNConfig -domainCred $domainCred | Out-Null
    Write-Verbose "Enabling Single Sign On in WAC"
    enable-singleSignOn -SDNConfig $SDNConfig
}
else {
    Write-Verbose "ProvisionLegacyNC is False - skipping legacy NC + SSO (matches the main deploy)."
}

# --- 4) Desktop RDP shortcuts (cosmetic) ------------------------------------------------------------
if (-not $SkipShortcuts) {
    Write-Host "`n=== Creating desktop RDP shortcuts ===" -ForegroundColor Yellow
    $ws = New-Object -ComObject WScript.Shell
    foreach ($s in @(@{ n = 'AdminCenter'; v = 'AdminCenter' }, @{ n = 'WACvMode'; v = 'wacvmode' })) {
        $path = "C:\Users\Public\Desktop\$($s.n).lnk"
        Remove-Item $path -Force -ErrorAction SilentlyContinue
        $l = $ws.CreateShortcut($path)
        $l.TargetPath = "%windir%\system32\mstsc.exe"
        $l.Arguments = "/v:$($s.v)"
        $l.Description = "$($s.n) link for SDN Sandbox."
        $l.Save()
    }
}

Write-Host "`nSDN Sandbox finishing steps complete." -ForegroundColor Green
Write-Host "Verify the cluster with:" -ForegroundColor Cyan
Write-Host '  Invoke-Command -VMName SDNMGMT -Credential $localCred -ArgumentList $domainCred {' -ForegroundColor DarkGray
Write-Host '      param($dc); Invoke-Command -VMName SDNHOST2 -Credential $dc {' -ForegroundColor DarkGray
Write-Host '          Get-Cluster | Select Name,Domain; Get-ClusterNode | Select Name,State } }' -ForegroundColor DarkGray
