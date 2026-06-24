@{

    # This is the PowerShell datafile used to provide configuration information for the SDN Nested lab environment. Product keys and password are not encrypted and will be available on all hosts during installation.
    
    # Version 1.0.0

    # Software download links
     admincenterUri = 'https://go.microsoft.com/fwlink/?linkid=2220149&clcid=0x409&culture=en-us&country=us'
    
    # WAC Virtualization Mode (vMode) - preview. aka.ms/WACDownloadvMode 301-redirects to this direct download.
    vModeUri       = 'https://download.microsoft.com/download/5e854024-dcf1-4e86-9546-7389fd08a34b/WindowsAdminCenterVirtualizationModePreview.exe'
    vModeVMName    = 'wacvmode'
    vModeIP        = '192.168.1.15/24'
    PostgreSQLPort = 5432

    # VHDX Paths
    # If the path below does not exist when New-SDNSandbox.ps1 runs, it auto-locates the image by
    # filename on the drive the wizard is launched from, then beside the wizard script itself (and in
    # a SDNVHDs subfolder next to it). Set an explicit path here to override - the configured path
    # always wins when the image is actually there.
    guiVHDXPath                          = "C:\SDNVHDs\gui.vhdx"               # This value controls the location of the GUI VHDX.              
    coreVHDXPath                         = "C:\SDNVHDs\core.vhdx"              # This value controls the location of the CORE VHDX. 
    

    # SDN Lab Admin Password
    SDNAdminPassword                     = "Password01"                          # Password for all local and domain accounts. Do not include special characters in the password otherwise some unattended installs may fail.

    # VM Configuration
    HostVMPath                           = "V:\VMs"                              # Path where the Nested VMs are stored on all hosts. If this drive does not exist when New-SDNSandbox.ps1 runs, the path is auto-rebased onto the base-images' drive (so the parent copy can ReFS block-clone), else the wizard's drive; set it explicitly to override.
    NestedVMMemoryinGB                   = 100GB                                 # This value controls the amount of RAM for each Nested Hyper-V Host (SDNHOST1-2).
    sdnMGMTMemoryinGB                    = 36GB                                  # RAM for the SDNMGMT Nested VM (Console, Router, Admincenter, DC, and wacvmode VMs). 36GB to host the always-on WAC vMode VM, which is pinned at 10GB static (installer enforces a hard >=8GB minimum).
    InternalSwitch                       = "InternalSwitch"                      # Name of internal switch that the SDN Lab VMs will use in Single Host mode. This only applies when using a single host.


    # Performance optimization (see README "Speed / storage tips")
    # For the FASTEST deploy, place the GUI/CORE base images AND HostVMPath on one data volume
    # formatted with ReFS: the multi-GB parent-VHDX copy then uses ReFS block cloning (near-instant,
    # ~zero extra space). The deploy detects this automatically and logs it - no setting required.
    OptimizeDefenderDuringDeploy         = $true                                 # Temporarily exclude the VHDX working paths from Defender real-time scanning during deploy (removed at the end). Big I/O win; set $false to leave Defender untouched.
    HyperVRolePreStaged                  = $false                                # Set $true only if you built the base images with New-SDNVHDfromISO.ps1 -PreStageHyperV. Skips the redundant per-host offline Hyper-V install.
    EnableParallelCopy                   = $false                                # Copy the GUI/CORE parent images (and per-host copies) concurrently instead of sequentially. Helps most on NTFS; on a single ReFS volume the copy is already near-instant.


    # ProductKeys
    GUIProductKey                        = "D764K-2NDRG-47T6Q-P8T8W-YP6DF"        # Product key for Windows Server 2025 (Desktop Experience) Datacenter Installation

    # SDN Lab Domain
    SDNDomainFQDN                        = "contoso.com"                          # Limit name (not the .com) to 14 characters as the name will be used as the NetBIOS name. 
    DCName                               = "contosodc"                            # Name of the domain controller virtual machine (limit to 14 characters)


    # NAT Configuration
    natHostSubnet                        = "192.168.128.0/24"
    natHostVMSwitchName                  = "InternalNAT"
    natConfigure                         = $true
    natSubnet                            = "192.168.46.0/24"                      # This value is the subnet is the NAT router will use to route to  SDNMGMT to access the Internet. It can be any /24 subnet and is only used for routing.
    natDNS                               = "8.8.8.8"                              # Upstream DNS the lab's DC forwards to. MUST be reachable from the HOST's network. Many corporate/lab networks block public resolvers (8.8.8.8, 1.1.1.1) - if so, nested VMs resolve nothing and appear to have "no internet". Set this to your internal/corporate DNS server. See README "Deploying on a restricted / corporate network".

    # Global MTU
    SDNLABMTU                            = 9014                                   # Controls the MTU for all Hosts. If using multiple physical hosts. Ensure that you have configured MTU on physical nics on the hosts to match this value.


    #SDN Provisioning
    ProvisionLegacyNC                    = $false                             # Provisions Network Controller Automatically.
    ConfigureBGPpeering                  = $true                              # Peers the GW and MUX VMs with the BGP-ToR-Router automatically if ProvisionNC = $true


    ################################################################################################################
    # Edit at your own risk. If you edit the subnets, ensure that you keep using the PreFix /24.                   #
    ################################################################################################################

    # SDNMGMT Management VM's Memory Settings
    MEM_DC                               = 8GB                                     # Memory provided for the Domain Controller VM
    MEM_BGP                              = 4GB                                     # Memory provided for the BGP-ToR-Router
    MEM_Console                          = 4GB                                     # Memory provided for the Windows 10 Console VM
    MEM_WAC                              = 8GB                                     # Memory provided for the Windows Admin Center VM
    MEM_vMode                            = 10GB                                    # Memory for the WAC Virtualization Mode VM. Pinned STATIC and above the installer's hard 8GB minimum (a dynamic/8GB VM balloons below 8GB at idle and fails the install env check).
    MEM_IPSEC                            = 4GB                                     # Memory provided for the ipsec-target VM

    #Cluster S2D Storage Disk Size (per disk)
    S2D_Disk_Size                        = 200GB                                    # Disk size for each of the 4 dynamic VHD disks attached to the 3 SDNHOST VMs that will be used to create the SDNCLUSTER


    # SDN Host IPs
    SDNMGMTIP                            = "192.168.1.11/24"
    SDNHOST1IP                           = "192.168.1.12/24"
    SDNHOST2IP                           = "192.168.1.13/24"
    SDNHOST3IP                           = "192.168.1.14/24"

    # Physical Host Internal IP
    PhysicalHostInternalIP               = "192.168.1.20"                          # IP Address assigned to Internal Switch vNIC in a Single Host Configuration

    # SDN Lab DNS
    SDNLABDNS                            = "192.168.1.254" 

    # SDN Lab Gateway
    SDNLABRoute                          = "192.168.1.1"

    #Management IPs for Console and Domain Controller
    DCIP                                 = "192.168.1.254/24"
    CONSOLEIP                            = "192.168.1.10/24"
    WACIP                                = "192.168.1.9/24"

    # BGP Router Config
    BGPRouterIP_MGMT                     = "192.168.1.1/24"
    BGPRouterIP_ProviderNetwork          = "172.16.0.1/24"
    BGPRouterIP_VLAN200                  = "192.168.200.1/24"
    BGPRouterIP_SimulatedInternet        = "10.10.10.1/24"
    BGPRouterASN                         = "65534"


    # VLANs
    providerVLAN                         = 12
    vlan200VLAN                          = 200
    mgmtVLAN                             = 0
    simInternetVLAN                      = 131
    StorageAVLAN                         = 20
    StorageBVLAN                         = 21

    # Subnets
    MGMTSubnet                           = "192.168.1.0/24"
    GRESubnet                            = "10.11.11.0/24"
    ProviderSubnet                       = "172.16.0.0/24"
    VLAN200Subnet                        = "192.168.200.0/24"
    VLAN200VMNetworkSubnet               = "192.168.44.0/24"
    simInternetSubnet                    = "10.10.10.0/24"
    storageAsubnet                       = "192.168.98.0/24"
    storageBsubnet                       = "192.168.99.0/24"

    # Gateway Target IPs
    GRETARGETIP_BE                       = "192.168.233.100/24"
    GRETARGETIP_FE                       = "10.11.11.35/24"
    IPSECTARGETIP_BE                     = "192.168.111.100/24"
    IPSECTARGETIP_FE                     = "10.11.11.30/24"

    # VIP Subnets
    PrivateVIPSubnet                     = "10.12.12.0/24" 
    PublicVIPSubnet                      = "10.13.13.0/24"

    # SDN ASN
    SDNASN                               = 64512
    WACASN                               = 65533

    # Windows Admin Center HTTPS Port
    WACport                              = 443

    # SDDCInstall
    SDDCInstall                          = $true

}