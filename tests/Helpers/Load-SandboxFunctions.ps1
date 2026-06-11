<#
.SYNOPSIS
  DOT-SOURCE this script to define the deploy engine's FUNCTIONS in the caller's scope WITHOUT
  executing its main deployment flow. Mirrors the AST-extraction technique already used by
  Resume-SDNSandbox.ps1, so the launcher itself needs no change.
.PARAMETER Path
  Full path to New-HyperVSandbox.ps1.
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
