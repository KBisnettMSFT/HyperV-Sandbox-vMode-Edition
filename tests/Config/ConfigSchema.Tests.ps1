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
