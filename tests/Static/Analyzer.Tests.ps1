BeforeAll {
    $script:repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $script:coreScripts = @(
        'SDNSandbox\New-HyperVSandbox.ps1',
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
