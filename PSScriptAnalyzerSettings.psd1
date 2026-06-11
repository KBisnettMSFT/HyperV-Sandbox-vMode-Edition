@{
    # Rules excluded BY DESIGN for this lab-only deploy engine. These reflect intentional
    # choices (plaintext lab creds, fixed VM names, an interactive Write-Host wizard, an AST
    # function-loader), not bugs. The CI gate fails on any *Error*-severity finding regardless.
    ExcludeRules = @(
        'PSAvoidUsingConvertToSecureStringWithPlainText',  # creds are built from a documented lab password
        'PSAvoidUsingPlainTextForPassword',                # SDNAdminPassword is a known lab default, not production
        'PSAvoidUsingComputerNameHardcoded',               # fixed lab VM names (SDNMGMT/SDNHOST1/2/3) are intentional
        'PSAvoidUsingWriteHost',                           # the deploy is an interactive console wizard
        'PSUseShouldProcessForStateChangingFunctions',     # New-*/Set-* here are deploy steps, not shipping cmdlets
        'PSAvoidUsingInvokeExpression'                     # AST loader / Resume tooling use it deliberately
    )
}
