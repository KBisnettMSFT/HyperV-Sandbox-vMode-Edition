<#
.SYNOPSIS
    Active Directory starter exercise for the Hyper-V Sandbox - vMode Edition.
    Creates a sample Organizational Unit and a few test users in the lab's contoso.com domain.

.DESCRIPTION
    A gentle first exercise: it adds an OU and some enabled test users, then shows how to list
    them. Idempotent - re-running skips objects that already exist.

.NOTES
    Run from a domain-joined lab VM (the AdminCenter VM or the Console) as contoso\Administrator.
    Requires the ActiveDirectory module (RSAT-AD-PowerShell; already present on the DC).
    Lab default password is Password01 - this is a throwaway lab, never reuse it in production.

.EXAMPLE
    .\01_Create_OU_and_Users.ps1
.EXAMPLE
    .\01_Create_OU_and_Users.ps1 -OUName 'Lab Accounts' -UserCount 5
#>
[CmdletBinding()]
param(
    [string] $OUName    = 'Sandbox Users',
    [string] $DomainDN  = 'DC=contoso,DC=com',
    [int]    $UserCount = 3
)

Import-Module ActiveDirectory -ErrorAction Stop

# 1. Create the OU (unless it already exists).
$ouPath = "OU=$OUName,$DomainDN"
if (-not (Get-ADOrganizationalUnit -Filter "Name -eq '$OUName'" -ErrorAction SilentlyContinue)) {
    New-ADOrganizationalUnit -Name $OUName -Path $DomainDN -ProtectedFromAccidentalDeletion $false
    Write-Host "Created OU: $ouPath" -ForegroundColor Green
}
else {
    Write-Host "OU already exists: $ouPath" -ForegroundColor Yellow
}

# 2. Create test users in the OU (unless they already exist).
$securePwd = ConvertTo-SecureString 'Password01' -AsPlainText -Force
for ($i = 1; $i -le $UserCount; $i++) {
    $sam = 'labuser{0:00}' -f $i
    if (-not (Get-ADUser -Filter "SamAccountName -eq '$sam'" -ErrorAction SilentlyContinue)) {
        New-ADUser -Name $sam -SamAccountName $sam -UserPrincipalName "$sam@contoso.com" `
            -AccountPassword $securePwd -Path $ouPath -Enabled $true -ChangePasswordAtLogon $false
        Write-Host "Created user: $sam" -ForegroundColor Green
    }
    else {
        Write-Host "User already exists: $sam" -ForegroundColor Yellow
    }
}

Write-Host "`nDone. List them with:" -ForegroundColor Cyan
Write-Host "  Get-ADUser -SearchBase '$ouPath' -Filter * | Select-Object Name, SamAccountName, Enabled"
