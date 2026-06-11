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
