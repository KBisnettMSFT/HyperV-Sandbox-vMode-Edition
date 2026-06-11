# Active Directory — Hyper-V Sandbox · vMode Edition

The lab deploys a Windows Server **Active Directory** forest, `contoso.com`, on the domain
controller VM (`contosodc`). The other lab VMs (AdminCenter, the hosts) are domain-joined, so this
is a disposable place to learn and validate AD without touching production.

## What the lab already gives you
- Forest / domain: **contoso.com** (NetBIOS `contoso`)
- Domain admin: `contoso\Administrator` / `Password01` *(lab default — never use in production)*
- Desktop shortcuts on the AdminCenter VM: **Active Directory Users and Computers**, **DNS**

## Prerequisites
- Run from a domain-joined lab VM (the **AdminCenter** VM or the **Console**) as `contoso\Administrator`.
- ActiveDirectory RSAT module: `Install-WindowsFeature RSAT-AD-PowerShell` (already present on the DC).

## Starter exercise
- [`01_Create_OU_and_Users.ps1`](01_Create_OU_and_Users.ps1) — creates a sample Organizational Unit and a few test users (idempotent; safe to re-run).

## Ideas to explore next
- Group Policy Objects and OU linking
- Fine-grained password policies
- Delegated administration / RBAC
- AD Sites & Services, replication, and DNS scavenging
