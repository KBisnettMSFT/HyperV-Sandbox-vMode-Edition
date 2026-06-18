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
    It 'prefers the base-images drive over the script drive when the configured drive is absent' {
        Mock Get-ScriptDriveRoot { 'E:' }   # must NOT be used when the images drive is usable
        Mock Write-Host {}
        Mock Test-Path { $false } -ParameterFilter { $LiteralPath -eq 'V:\' }
        Mock Test-Path { $true }  -ParameterFilter { $LiteralPath -eq 'D:\' }
        Resolve-HostVMPath -ConfiguredPath 'V:\VMs' -PreferredDriveFrom 'D:\SDNVHDs\gui.vhdx' | Should -Be 'D:\VMs'
    }
    It 'falls back to the script drive when both the configured and images drives are absent' {
        Mock Get-ScriptDriveRoot { 'E:' }
        Mock Write-Host {}
        Mock Test-Path { $false }
        Resolve-HostVMPath -ConfiguredPath 'V:\VMs' -PreferredDriveFrom 'D:\SDNVHDs\gui.vhdx' | Should -Be 'E:\VMs'
    }
    It 'leaves a UNC path unchanged' {
        Resolve-HostVMPath -ConfiguredPath '\\srv\share\VMs' | Should -Be '\\srv\share\VMs'
    }
}

Describe 'Get-PathVolumeFileSystem' {
    It 'returns the volume filesystem type for a rooted local path' {
        Mock Get-Volume { [pscustomobject]@{ FileSystemType = 'ReFS' } } -ParameterFilter { $DriveLetter -eq 'V' }
        Get-PathVolumeFileSystem -Path 'V:\VMs\GUI.vhdx' | Should -Be 'ReFS'
    }
    It 'returns nothing for a UNC path' {
        Get-PathVolumeFileSystem -Path '\\srv\share\x.vhdx' | Should -BeNullOrEmpty
    }
    It 'returns nothing (never throws) when the volume cannot be read' {
        Mock Get-Volume { throw 'no volume' }
        Get-PathVolumeFileSystem -Path 'Z:\x' | Should -BeNullOrEmpty
    }
}

Describe 'Test-ReFSBlockCloneEligible' {
    It 'true when source and destination share one ReFS volume' {
        Mock Get-PathVolumeFileSystem { 'ReFS' }
        Test-ReFSBlockCloneEligible -SourcePath 'D:\img\GUI.vhdx' -DestinationPath 'D:\VMs' | Should -BeTrue
    }
    It 'false when the shared volume is NTFS' {
        Mock Get-PathVolumeFileSystem { 'NTFS' }
        Test-ReFSBlockCloneEligible -SourcePath 'D:\img\GUI.vhdx' -DestinationPath 'D:\VMs' | Should -BeFalse
    }
    It 'false when source and destination are on different drives (block clone is intra-volume)' {
        Mock Get-PathVolumeFileSystem { 'ReFS' }
        Test-ReFSBlockCloneEligible -SourcePath 'D:\img\GUI.vhdx' -DestinationPath 'E:\VMs' | Should -BeFalse
    }
    It 'false for a UNC destination' {
        Test-ReFSBlockCloneEligible -SourcePath 'D:\img\GUI.vhdx' -DestinationPath '\\srv\share\VMs' | Should -BeFalse
    }
}

Describe 'Get-VHDXCopyPlan' {
    It 'returns GUI and CORE destinations under the host VM path' {
        $plan = Get-VHDXCopyPlan -guiVHDXPath 'D:\img\gui.vhdx' -coreVHDXPath 'D:\img\core.vhdx' -DestinationFolder 'V:\VMs'
        @($plan).Count        | Should -Be 2
        $plan[0].Source       | Should -Be 'D:\img\gui.vhdx'
        $plan[0].Destination  | Should -Be 'V:\VMs\GUI.vhdx'
        $plan[1].Source       | Should -Be 'D:\img\core.vhdx'
        $plan[1].Destination  | Should -Be 'V:\VMs\CORE.vhdx'
    }
    It 'tolerates a trailing backslash on the destination folder' {
        $plan = Get-VHDXCopyPlan -guiVHDXPath 'g' -coreVHDXPath 'c' -DestinationFolder 'V:\VMs\'
        $plan[0].Destination | Should -Be 'V:\VMs\GUI.vhdx'
    }
}

Describe 'Add/Remove-SandboxDefenderExclusion' {
    BeforeAll {
        # On a runner without Defender, define harmless stubs so the cmdlets are mockable.
        if (-not (Get-Command Add-MpPreference -ErrorAction SilentlyContinue))    { function Add-MpPreference { param($ExclusionPath) } }
        if (-not (Get-Command Remove-MpPreference -ErrorAction SilentlyContinue)) { function Remove-MpPreference { param($ExclusionPath) } }
    }
    It 'adds an exclusion for each unique path and returns the applied paths' {
        Mock Add-MpPreference {}
        Mock Write-Host {}
        $r = Add-SandboxDefenderExclusion -Path 'V:\VMs', 'D:\img', 'V:\VMs'
        @($r).Count | Should -Be 2
        Assert-MockCalled Add-MpPreference -Times 2 -Exactly
    }
    It 'never throws when Defender is unavailable and applies nothing' {
        Mock Add-MpPreference { throw 'Defender not available' }
        Mock Write-Verbose {}
        $r = Add-SandboxDefenderExclusion -Path 'V:\VMs'
        @($r).Count | Should -Be 0
    }
    It 'removes each exclusion best-effort without throwing' {
        Mock Remove-MpPreference {}
        Mock Write-Host {}
        { Remove-SandboxDefenderExclusion -Path 'V:\VMs', 'D:\img' } | Should -Not -Throw
        Assert-MockCalled Remove-MpPreference -Times 2 -Exactly
    }
}

Describe 'Write-DeployPhase' {
    AfterEach { $script:starttime = $null; $script:LastPhaseTime = $null }
    It 'is a silent no-op until the deploy timer has started' {
        $script:starttime = $null
        Mock Write-Host {}
        Write-DeployPhase 'should-not-print'
        Assert-MockCalled Write-Host -Times 0 -Exactly
    }
    It 'prints a timed phase line once the timer is started' {
        $script:starttime = (Get-Date).AddMinutes(-47)
        $script:LastPhaseTime = (Get-Date).AddMinutes(-12)
        Mock Write-Host {}
        Write-DeployPhase 'Test phase'
        Assert-MockCalled Write-Host -Times 1 -Exactly -ParameterFilter { "$Object" -match 'PHASE' -and "$Object" -match 'Test phase' }
    }
}
