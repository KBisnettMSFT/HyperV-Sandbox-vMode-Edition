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
