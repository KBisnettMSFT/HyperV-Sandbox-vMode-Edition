BeforeAll {
    $launcher = (Resolve-Path (Join-Path $PSScriptRoot '..\..\SDNSandbox\New-HyperVSandbox.ps1')).Path
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

Describe 'Launcher is dot-source safe (guard skips deployment)' {
    It 'dot-sourcing the launcher does not run the deployment' {
        $launcher = (Resolve-Path (Join-Path $PSScriptRoot '..\..\SDNSandbox\New-HyperVSandbox.ps1')).Path
        # If the dot-source guard failed, execution would fall into the main flow and throw
        # (relative config import, or a Hyper-V-only Get-Counter on a non-Hyper-V CI host).
        { . $launcher } | Should -Not -Throw
    }

    It 'dot-sourcing the deprecation shim is a guarded no-op (does not deploy)' {
        $shim = (Resolve-Path (Join-Path $PSScriptRoot '..\..\SDNSandbox\New-SDNSandbox.ps1')).Path
        # Without the shim's own dot-source guard, this would invoke the engine and deploy (then throw).
        { . $shim } | Should -Not -Throw
    }
}
