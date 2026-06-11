#Requires -Version 5.1
<#
.SYNOPSIS
    DEPRECATED entry point for the Hyper-V Sandbox - vMode Edition lab.

.DESCRIPTION
    The launcher was renamed to New-HyperVSandbox.ps1 as part of the "Hyper-V Sandbox - vMode
    Edition" rebrand. This thin shim forwards all arguments to New-HyperVSandbox.ps1 so existing
    runbooks (and the E:\SDNSandbox workflow) keep working. It will be removed in a future release.

.EXAMPLE
    .\New-SDNSandbox.ps1
    Forwards to .\New-HyperVSandbox.ps1 (deploys the lab).

.EXAMPLE
    .\New-SDNSandbox.ps1 -Delete $true
    Forwards to .\New-HyperVSandbox.ps1 -Delete $true.
#>

Write-Warning "New-SDNSandbox.ps1 is deprecated and will be removed in a future release. Use New-HyperVSandbox.ps1 instead. Forwarding..."
& "$PSScriptRoot\New-HyperVSandbox.ps1" @args
