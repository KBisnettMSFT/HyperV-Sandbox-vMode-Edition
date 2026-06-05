<#
.SYNOPSIS
    Verifies an already-provisioned WAC Virtualization Mode (vMode) VM and, if needed, cleans up a
    failed/partial WAC install and re-runs ONLY the in-guest installer - without rebuilding the VM.

.DESCRIPTION
    New-WACvModeVM (in New-SDNSandbox.ps1) does two distinct things:
        1. Builds the 'wacvmode' VM on SDNMGMT (differencing disk, unattend/domain-join, NIC/MTU/gateway,
           partition resize) - this is slow and only needs to happen once.
        2. Installs WAC Virtualization Mode INSIDE that VM (VC++ redist, download installer, generate the
           DPAPI-encrypted PostgreSQL INI, run the silent installer).

    If step 2 fails (e.g. the historical plaintext-password bug that popped "You must enter PostgreSQL
    username, password and port!"), there is no need to tear down and rebuild the whole VM. The VM's OS,
    domain membership and networking are already good. This script:

        PHASE 1  Verify the existing VM is healthy (state, memory, vCPU, domain, IP, internet) and report
                 the current WAC/PostgreSQL install state plus the tail of the installer's own Inno log.
        PHASE 2  Clean up a partial install (kill stuck installer processes, best-effort uninstall any
                 partially-installed WAC, remove the stale INI).
        PHASE 3  Re-run ONLY the installer: regenerate the DPAPI INI in-guest (same user that runs setup,
                 so DPAPI CurrentUser-scope decryption succeeds) and launch the silent install with a
                 bounded watchdog. The already-downloaded installer / VC++ redist are reused when present.
        PHASE 4  Re-verify (PostgreSQL service, ports 443/5432, WAC reachable).

    Run this from the PHYSICAL HOST (the same place you run New-SDNSandbox.ps1). It reaches the nested
    vMode VM via host -> SDNMGMT (local admin) -> wacvmode (domain admin), exactly like New-WACvModeVM.

.PARAMETER ConfigPath
    Path to SDNSandbox-Config.psd1. Defaults to .\SDNSandbox-Config.psd1 next to this script.

.PARAMETER VerifyOnly
    Only run PHASE 1 + PHASE 4 read-only checks. Makes NO changes. Use this first to inspect state.

.PARAMETER TimeoutMinutes
    Watchdog timeout for the silent install (default 30). Mirrors New-WACvModeVM.

.EXAMPLE
    # Just look at the current state, change nothing:
    .\Repair-WACvModeInstall.ps1 -VerifyOnly

.EXAMPLE
    # Clean up the failed install and re-run only the installer:
    .\Repair-WACvModeInstall.ps1
#>

[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$VerifyOnly,
    [int]$TimeoutMinutes = 30
)

$ErrorActionPreference = 'Stop'

if (-not $ConfigPath) {
    $ConfigPath = Join-Path $PSScriptRoot 'SDNSandbox-Config.psd1'
}
if (-not (Test-Path $ConfigPath)) {
    throw "Config file not found: $ConfigPath. Pass -ConfigPath 'X:\path\SDNSandbox-Config.psd1'."
}

Write-Host "Loading config: $ConfigPath" -ForegroundColor Cyan
$SDNConfig = Import-PowerShellDataFile $ConfigPath

$localCred = New-Object System.Management.Automation.PSCredential(
    'Administrator',
    (ConvertTo-SecureString $SDNConfig.SDNAdminPassword -AsPlainText -Force)
)

# Everything below runs INSIDE SDNMGMT (which is the Hyper-V host of the nested wacvmode VM).
Invoke-Command -VMName SDNMGMT -Credential $localCred `
    -ArgumentList $SDNConfig, $SDNConfig.SDNAdminPassword, ([bool]$VerifyOnly), $TimeoutMinutes `
    -ScriptBlock {

    param($SDNConfig, $adminPwd, $VerifyOnly, $TimeoutMinutes)

    $ErrorActionPreference = 'Stop'
    $VMName = $SDNConfig.vModeVMName
    $fqdn = $SDNConfig.SDNDomainFQDN
    $netbios = $fqdn.Split('.')[0]

    $domainCred = New-Object System.Management.Automation.PSCredential(
        "$netbios\Administrator",
        (ConvertTo-SecureString $adminPwd -AsPlainText -Force)
    )

    function Write-Section($t) { Write-Host "`n=== $t ===" -ForegroundColor Yellow }

    # ---------------------------------------------------------------- PHASE 1: VM health (host side)
    Write-Section "PHASE 1: VM health"

    $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if (-not $vm) {
        throw "VM '$VMName' does not exist on SDNMGMT. The VM build did not complete - run the full " +
              "New-WACvModeVM (this repair script only re-runs the installer on an existing VM)."
    }

    "VM Name        : $($vm.Name)"
    "State          : $($vm.State)"
    "vCPU           : $($vm.ProcessorCount)   (vMode needs 4)"
    "Memory assigned: $([int]($vm.MemoryAssigned/1MB)) MB   (vMode needs >= 8192; we provision 10240 static)"
    "DynamicMemory  : $($vm.DynamicMemoryEnabled)   (should be False)"

    if ($vm.State -ne 'Running') {
        Write-Host "Starting $VMName ..." -ForegroundColor Cyan
        Start-VM -Name $VMName | Out-Null
    }

    # Wait for PowerShell Direct (domain admin) to answer.
    Write-Host "Waiting for PowerShell Direct into $VMName ..." -ForegroundColor Cyan
    $deadline = (Get-Date).AddMinutes(5)
    while ((Invoke-Command -VMName $VMName -Credential $domainCred { 'ok' } -ErrorAction SilentlyContinue) -ne 'ok') {
        if ((Get-Date) -gt $deadline) {
            throw "Could not reach $VMName via PowerShell Direct as $netbios\Administrator within 5 min. " +
                  "The VM may still be booting or the domain join did not complete."
        }
        Start-Sleep -Seconds 3
    }
    Write-Host "PowerShell Direct: OK" -ForegroundColor Green

    # In-guest read-only inspection. Defined once, reused in PHASE 1 and PHASE 4.
    $inspectSb = {
        $out = [ordered]@{}
        $cs = Get-CimInstance Win32_ComputerSystem
        $out.Domain = $cs.Domain
        $out.PartOfDomain = $cs.PartOfDomain
        $out.TotalMemGB = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
        $out.OSBuild = (Get-CimInstance Win32_OperatingSystem).BuildNumber
        $out.IPv4 = ((Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.IPAddress -ne '127.0.0.1' -and $_.IPAddress -notlike '169.254.*' }).IPAddress) -join ', '

        # Internet reachability (vMode download / VC++ may be needed)
        try { $out.Internet = (Test-NetConnection -ComputerName 'www.microsoft.com' -Port 443 -WarningAction SilentlyContinue).TcpTestSucceeded }
        catch { $out.Internet = $false }

        # WAC install footprint
        $wacDir = Get-ChildItem 'C:\Program Files' -Directory -Filter 'WindowsAdminCenter*' -ErrorAction SilentlyContinue |
            Select-Object -First 1
        $out.WACInstalled = [bool]$wacDir
        $out.WACPath = if ($wacDir) { $wacDir.FullName } else { '(none)' }
        $out.WACService = (Get-Service -Name 'WindowsAdminCenter*' -ErrorAction SilentlyContinue |
                Select-Object -First 1 -ExpandProperty Status) -as [string]
        $out.PostgresService = (Get-Service -Name '*postgres*', '*WACPostgres*' -ErrorAction SilentlyContinue |
                Select-Object -First 1 -ExpandProperty Status) -as [string]

        # Listening ports that matter (443 = WAC, 5432 = PostgreSQL)
        $listen = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue
        $out.Port443 = [bool]($listen | Where-Object LocalPort -eq 443)
        $out.Port5432 = [bool]($listen | Where-Object LocalPort -eq 5432)

        # Any installer still running?
        $out.InstallerRunning = (Get-Process -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like 'WindowsAdminCenterVirtualizationModePreview*' }).Count

        # Tail of the newest Inno Setup install log (the installer's own record of where it stopped)
        $log = Get-ChildItem "$env:TEMP", 'C:\Users\*\AppData\Local\Temp' -Recurse -Filter 'Setup Log*.txt' `
            -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($log) {
            $out.LogFile = $log.FullName
            $out.LogTail = (Get-Content $log.FullName -Tail 12 -ErrorAction SilentlyContinue) -join "`n"
        }
        else { $out.LogFile = '(no Inno Setup log found)'; $out.LogTail = '' }

        [pscustomobject]$out
    }

    $health = Invoke-Command -VMName $VMName -Credential $domainCred -ScriptBlock $inspectSb

    "Domain joined  : $($health.PartOfDomain)  ($($health.Domain))   (expected $fqdn)"
    "Guest RAM seen : $($health.TotalMemGB) GB   (installer env-check needs > 8 GB)"
    "OS build       : $($health.OSBuild)"
    "IPv4           : $($health.IPv4)   (expected $($SDNConfig.vModeIP))"
    "Internet (443) : $($health.Internet)"
    "WAC installed  : $($health.WACInstalled)  $($health.WACPath)"
    "WAC service    : $(if($health.WACService){$health.WACService}else{'(not present)'})"
    "PostgreSQL svc : $(if($health.PostgresService){$health.PostgresService}else{'(not present)'})"
    "Listening 443  : $($health.Port443)    Listening 5432: $($health.Port5432)"
    "Installer procs: $($health.InstallerRunning)"
    "Newest log     : $($health.LogFile)"
    if ($health.LogTail) {
        Write-Host "--- last 12 log lines ---" -ForegroundColor DarkGray
        $health.LogTail
        Write-Host "-------------------------" -ForegroundColor DarkGray
    }

    # Health verdict for the VM itself (independent of WAC).
    $vmHealthy = $health.PartOfDomain -and ($health.Domain -eq $fqdn) -and $health.IPv4
    if ($vmHealthy) { Write-Host "VM deployment looks healthy (OS + domain + network)." -ForegroundColor Green }
    else { Write-Host "VM deployment has problems above - review before reinstalling WAC." -ForegroundColor Red }

    if ($VerifyOnly) {
        Write-Host "`n-VerifyOnly specified: no changes made." -ForegroundColor Cyan
        return
    }

    if (-not $vmHealthy) {
        throw "Refusing to reinstall WAC because the VM is not domain-joined / networked correctly. " +
              "Fix the VM first (or rebuild it with New-WACvModeVM)."
    }

    # ----------------------------------------------- PHASE 2 + 3: clean up + re-run ONLY the installer
    Write-Section "PHASE 2+3: cleanup + reinstall (in-guest as $netbios\Administrator)"

    Invoke-Command -VMName $VMName -Credential $domainCred `
        -ArgumentList $SDNConfig, $VMName, $TimeoutMinutes -ScriptBlock {

        param($SDNConfig, $VMName, $TimeoutMinutes)

        $ErrorActionPreference = 'Stop'
        $VerbosePreference = 'Continue'
        $ProgressPreference = 'SilentlyContinue'

        # --- PHASE 2: cleanup -------------------------------------------------------------
        Write-Verbose "Killing any stuck WAC vMode installer processes"
        Get-Process -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like 'WindowsAdminCenterVirtualizationModePreview*' } |
            ForEach-Object { try { $_.Kill(); $_.WaitForExit(5000) } catch {} }

        # Best-effort uninstall of any partially-installed WAC (Inno Setup leaves unins000.exe).
        $uninst = Get-ChildItem 'C:\Program Files\WindowsAdminCenter*' -Recurse -Filter 'unins*.exe' `
            -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($uninst) {
            Write-Verbose "Found existing WAC uninstaller ($($uninst.FullName)); running silent uninstall"
            try {
                $u = Start-Process -FilePath $uninst.FullName `
                    -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART' -PassThru -Wait
                Write-Verbose "Uninstaller exit code: $($u.ExitCode)"
            }
            catch { Write-Verbose "Uninstaller failed ($($_.Exception.Message)); continuing - installer will overwrite" }
        }
        else { Write-Verbose "No existing WAC install found (nothing to uninstall)" }

        # Remove the stale INI so the new DPAPI one can't be confused with a previous bad one.
        Remove-Item 'C:\deploy\wac-config.ini' -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Path C:\deploy -Force | Out-Null

        # --- PHASE 3: reinstall (installer-only steps from New-WACvModeVM) -----------------

        # VC++ Redistributable prerequisite - skip if the runtime is already present.
        if (Test-Path "$env:SystemRoot\System32\vcruntime140.dll") {
            Write-Verbose "Visual C++ runtime already present - skipping VC++ install"
        }
        else {
            Write-Verbose "Installing Visual C++ Redistributable prerequisite"
            $vcInstalled = $false
            if (Get-Command winget -ErrorAction SilentlyContinue) {
                try {
                    winget install --id "Microsoft.VCRedist.2015+.x64" --silent --accept-source-agreements --accept-package-agreements --disable-interactivity | Out-Null
                    $vcInstalled = $true
                }
                catch { Write-Verbose "winget VC++ install failed; falling back to direct download" }
            }
            if (-not $vcInstalled) {
                $vcPath = "C:\deploy\vc_redist.x64.exe"
                Invoke-WebRequest -Uri "https://aka.ms/vs/17/release/vc_redist.x64.exe" -OutFile $vcPath -UseBasicParsing
                Start-Process -FilePath $vcPath -ArgumentList "/install", "/quiet", "/norestart" -Wait
            }
        }

        # Installer - reuse the existing download if present (avoids re-pulling ~277 MB).
        $vModeInstaller = "C:\deploy\WindowsAdminCenterVirtualizationModePreview.exe"
        if (Test-Path $vModeInstaller) {
            Write-Verbose "Reusing existing installer at $vModeInstaller"
        }
        else {
            Write-Verbose "Downloading WAC Virtualization Mode installer"
            Invoke-WebRequest -Uri $SDNConfig.vModeUri -OutFile $vModeInstaller -UseBasicParsing
        }

        # Regenerate the unattended INI. The PostgreSQL password MUST be DPAPI-encrypted, and the blob
        # must be created by the SAME user that runs the installer (this very session = the domain admin
        # that Start-Process below runs as), so DPAPI CurrentUser-scope decryption succeeds.
        Write-Verbose "Generating DPAPI-encrypted unattended install INI"
        $encryptedPwd = $SDNConfig.SDNAdminPassword | ConvertTo-SecureString -AsPlainText -Force | ConvertFrom-SecureString
        $ini = @"
[AppSettings]
PostgreSQLUsername=postgres
PostgreSQLPassword=$encryptedPwd
PostgreSQLPort=$($SDNConfig.PostgreSQLPort)
"@
        Set-Content -Path "C:\deploy\wac-config.ini" -Value $ini -Force -Encoding ASCII

        # Silent install with a bounded watchdog (identical to New-WACvModeVM).
        Write-Verbose "Installing WAC Virtualization Mode (silent). This typically takes 10-20 minutes."
        $proc = Start-Process -FilePath $vModeInstaller `
            -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/ConfigFile="C:\deploy\wac-config.ini"' -PassThru
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while (-not $proc.HasExited) {
            if ($sw.Elapsed.TotalMinutes -ge $TimeoutMinutes) {
                try { $proc.Kill(); $proc.WaitForExit(5000) } catch {}
                throw ("WAC vMode install did not finish within $TimeoutMinutes minutes. A silent installer " +
                    "that hangs this way has usually popped a hidden dialog. Inside '$VMName', look for an " +
                    "installer process with a non-empty MainWindowTitle, and capture the newest " +
                    "'%TEMP%\Setup Log*.txt' BEFORE retrying.")
            }
            Write-Verbose "  ...vMode install still running (elapsed $([int]$sw.Elapsed.TotalMinutes) min)"
            Start-Sleep -Seconds 30
        }
        $proc.WaitForExit()
        if ($proc.ExitCode -ne 0) {
            throw "WAC vMode installer exited with non-zero code $($proc.ExitCode). Capture the newest " +
                  "'%TEMP%\Setup Log*.txt' inside '$VMName' for the reason."
        }
        Write-Verbose "WAC vMode installer reported success (exit 0)."
    }

    # ----------------------------------------------------------------- PHASE 4: re-verify
    Write-Section "PHASE 4: post-install verification"
    Start-Sleep -Seconds 5
    $after = Invoke-Command -VMName $VMName -Credential $domainCred -ScriptBlock $inspectSb
    "WAC installed  : $($after.WACInstalled)  $($after.WACPath)"
    "WAC service    : $(if($after.WACService){$after.WACService}else{'(not present)'})"
    "PostgreSQL svc : $(if($after.PostgresService){$after.PostgresService}else{'(not present)'})"
    "Listening 443  : $($after.Port443)    Listening 5432: $($after.Port5432)"

    if ($after.WACInstalled -and $after.Port443) {
        Write-Host "`nSUCCESS: WAC vMode is installed and listening on 443." -ForegroundColor Green
        Write-Host "Open: https://$VMName.$fqdn" -ForegroundColor Green
    }
    else {
        Write-Host "`nInstaller exited 0 but WAC is not fully up yet (service may still be starting). " -ForegroundColor Yellow
        Write-Host "Re-run with -VerifyOnly in a minute; if still down, capture the newest %TEMP%\Setup Log*.txt." -ForegroundColor Yellow
    }
}
