BeforeAll {
    $launcher = (Resolve-Path (Join-Path $PSScriptRoot '..\..\SDNSandbox\New-HyperVSandbox.ps1')).Path
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
    It 'returns the configured path when no candidate has the image' {
        Mock Get-ScriptDriveRoot { 'E:' }
        Mock Get-ScriptRootFolder { 'E:\HyperVSandbox' }
        Mock Write-Host {}
        Mock Test-Path { $false }
        Resolve-ParentVHDXPath -ConfiguredPath 'C:\SDNVHDs\gui.vhdx' -Label 'GUI' | Should -Be 'C:\SDNVHDs\gui.vhdx'
    }
    It 'auto-locates the image beside the wizard script (flat layout)' {
        Mock Get-ScriptDriveRoot { 'X:' }
        Mock Get-ScriptRootFolder { 'E:\HyperVSandbox' }
        Mock Write-Host {}
        Mock Test-Path { $false }
        Mock Test-Path { $true } -ParameterFilter { $LiteralPath -eq 'E:\HyperVSandbox\gui.vhdx' }
        Resolve-ParentVHDXPath -ConfiguredPath 'C:\SDNVHDs\gui.vhdx' -Label 'GUI' | Should -Be 'E:\HyperVSandbox\gui.vhdx'
    }
    It 'auto-locates the image in a SDNVHDs folder beside the wizard script' {
        Mock Get-ScriptDriveRoot { 'X:' }
        Mock Get-ScriptRootFolder { 'E:\HyperVSandbox' }
        Mock Write-Host {}
        Mock Test-Path { $false }
        Mock Test-Path { $true } -ParameterFilter { $LiteralPath -eq 'E:\HyperVSandbox\SDNVHDs\gui.vhdx' }
        Resolve-ParentVHDXPath -ConfiguredPath 'C:\SDNVHDs\gui.vhdx' -Label 'GUI' | Should -Be 'E:\HyperVSandbox\SDNVHDs\gui.vhdx'
    }
    It 'still prefers the drive-rebased path over the script-adjacent fallback' {
        Mock Get-ScriptDriveRoot { 'E:' }
        Mock Get-ScriptRootFolder { 'E:\HyperVSandbox' }
        Mock Write-Host {}
        Mock Test-Path { $false } -ParameterFilter { $LiteralPath -eq 'C:\SDNVHDs\gui.vhdx' }
        Mock Test-Path { $true }  -ParameterFilter { $LiteralPath -eq 'E:\SDNVHDs\gui.vhdx' }
        Mock Test-Path { $true }  -ParameterFilter { $LiteralPath -eq 'E:\HyperVSandbox\gui.vhdx' }
        Resolve-ParentVHDXPath -ConfiguredPath 'C:\SDNVHDs\gui.vhdx' -Label 'GUI' | Should -Be 'E:\SDNVHDs\gui.vhdx'
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
