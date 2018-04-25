﻿# Create a full sample UCS configuration from scratch using PowerShell

# Import UCS Powertool Module
Import-Module Cisco.UCSManager

# Declare global variables
$site_id = 1
$pod_id = 1

$environments = @("prd", "acc", "tst", "dev")

$fabrics = @("A", "B")

$hostname_prefix = "ucspe-"

$ip_prefix = "192.168"
$mgmt_block = "218"
$iscsi_blocks = @{A = "103" 
                  B = "104"}
$ip_mask = "255.255.255.0"
$ip_pool_size = 100

$mgmt_vlan = 101
$vmotion_vlan = 102
$iscsi_a_vlan = 103
$iscsi_b_vlan = 104
$nfs_vlan = 105

$dynamic_vlan_start = 1001
$dynamic_vlan_end = 1200

# Connect to UCS Manager using a session xml file and a secure key defined in a key file
$key = ConvertTo-SecureString (Get-Content .\ucs.key)
$handle = Connect-Ucs -Key $key -LiteralPath .\ucs.xml

# Set UCS system name
#
# This uses the generic Set-UcsManagedObject method, because no specific cmdlet exists
$hostname = $hostname_prefix + $site_id + $pod_id
Get-UcsManagedObject -Dn sys | Set-UcsManagedObject -PropertyMap @{name = $hostname} -Force

# Create suborganizations
foreach ($env in $environments) {
    Get-UcsOrg -Level root | Add-UcsOrg $env -ModifyPresent
}

# Assign IP block to ext-mgmt pool and set order to sequential
$first_host = $ip_pool_size + 1
$last_host = $first_host + $ip_pool_size - 1
$first_ip = $ip_prefix+"."+$mgmt_block+"."+$first_host
$last_ip = $ip_prefix+"."+$mgmt_block+"."+$last_host
$gateway = $ip_prefix+"."+$mgmt_block+".254"
$mo = Get-UcsOrg -Level root | Get-UcsIpPool -Name "ext-mgmt"
$mo | Set-UcsIpPool -AssignmentOrder sequential -Force
$mo | Add-UcsIpPoolBlock -DefGw $gateway -From $first_ip -To $last_ip -Subnet $ip_mask -ModifyPresent

# Create management IP pools for each environment
$sub_pool_size = [int]($ip_pool_size/$environments.Length)
$n = 0
foreach ($env in $environments) {
    $pool_name =  $env+"_kvm_ip_dc"+$site_id
    $first_host = 1 + $n * $sub_pool_size
    $last_host = $first_host + $sub_pool_size - 1
    $first_ip = $ip_prefix+"."+$mgmt_block+"."+$first_host
    $last_ip = $ip_prefix+"."+$mgmt_block+"."+$last_host
    $gateway = $ip_prefix+"."+$mgmt_block+".254"
    $mo = Get-UcsOrg -name $env  | Add-UcsIpPool -Name $pool_name -AssignmentOrder "sequential" -Descr "IP pool for $env service profiles" -ModifyPresent
    $mo | Add-UcsIpPoolBlock -DefGw $gateway -From $first_ip -To $last_ip -Subnet $ip_mask -ModifyPresent
    $n = $n + 1
}

# Create mac address pools for fabric A and B
foreach ($fabric in $fabrics) {
    $pool_name = "esxi_mac_"+$fabric.ToLower()+"_dc"+$site_id
    $from_mac = "00:25:B5:"+$site_id+$pod_id+":"+$fabric+"0:00"
    $to_mac = "00:25:B5:"+$site_id+$pod_id+":"+$fabric+"1:FF"
    $mo = Get-UcsOrg -Level root  | Add-UcsMacPool -Name $pool_name -AssignmentOrder sequential -ModifyPresent
    $mo | Add-UcsMacMemberBlock -From $from_mac -To $to_mac -ModifyPresent
}

# Create iSCSI IP pools for each environment
$sub_pool_size = [int]($ip_pool_size/$environments.Length)
$n = 0
foreach ($env in $environments) {
    foreach ($fabric in $fabrics){
		$pool_name = $env+"_iscsi_ip_"+$fabric.ToLower()+"_dc"+$site_id
		$first_host = 1 + $n * $sub_pool_size
		$last_host = $first_host + $sub_pool_size - 1
		$first_ip = $ip_prefix+"."+$iscsi_blocks[$fabric]+"."+$first_host
		$last_ip = $ip_prefix+"."+$iscsi_blocks[$fabric]+"."+$last_host
		$gateway = $ip_prefix+"."+$iscsi_blocks[$fabric]+".254"
		$mo = Get-UcsOrg -name $env  | Add-UcsIpPool -Name $pool_name -AssignmentOrder "sequential" -ModifyPresent
		$mo | Add-UcsIpPoolBlock -DefGw $gateway -From $first_ip -To $last_ip -Subnet $ip_mask -ModifyPresent
	}
	$n = $n + 1
}

# Create IQN pools for each environment
foreach ($env in $environments) {
    foreach ($fabric in $fabrics){
        $pool_name = $env+"_iqn_"+$fabric.ToLower()+"_dc"+$site_id
        $iqn_prefix = "iqn.1987-05.com.cisco"
        $iqn_suffix = "ucs-s"+$site_id+"p"+$pod_id+"-"+$env+"-"+$fabric.ToLower()
        $mo = Get-UcsOrg -name $env  | Add-UcsIqnPoolPool -Name $pool_name -AssignmentOrder "sequential" -Prefix $iqn_prefix -ModifyPresent
        $mo_1 = $mo | Add-UcsIqnPoolBlock -From 1 -Suffix $iqn_suffix -To 160
    }
}

# Create static infrastructure VLANs 
Get-UcsLanCloud | Add-UcsVlan -Id $mgmt_vlan -Name $mgmt_vlan"_mgmt_dc"$site_id -DefaultNet no -ModifyPresent
Get-UcsLanCloud | Add-UcsVlan -Id $vmotion_vlan -Name $vmotion_vlan"_vmotion_dc"$site_id -DefaultNet no -ModifyPresent
Get-UcsLanCloud | Add-UcsVlan -Id $iscsi_a_vlan -Name $iscsi_a_vlan"_iscsi_a_dc"$site_id -DefaultNet no -ModifyPresent
Get-UcsLanCloud | Add-UcsVlan -Id $iscsi_b_vlan -Name $iscsi_b_vlan"_iscsi_b_dc"$site_id -DefaultNet no -ModifyPresent
Get-UcsLanCloud | Add-UcsVlan -Id $nfs_vlan -Name $nfs_vlan"_nfs_dc"$site_id -DefaultNet no -ModifyPresent

# Create dynamic VLANs for VMs
#
# To save time during reruns of the script, we check for existence of the VLAN instead of using the -ModifyPresent switch
$mo = Get-UcsLanCloud
$vlan_names = $mo | Get-UcsManagedObject -ClassId fabricVlan | Select Name | Out-String -Stream
for ($i=$dynamic_vlan_start;$i -le $dynamic_vlan_end; $i++) {
    $vlan_exists = $vlan_names.Contains("vm_dynamic_$i")
    if (-Not $vlan_exists) {
        $mo | Add-UcsVlan -Id $i -Name "vm_dynamic_$i" -DefaultNet no
    }
}

# Set MTU to Jumbo frames (9216 bytes) for Best-Effort QoS class 
Get-UcsBestEffortQosClass | Set-UcsBestEffortQosClass -Mtu 9216 -Force

# Set power control policy to grid redundancy
Get-UcsPowerControlPolicy | Set-UcsPowerControlPolicy -Redundancy grid -Force

# Set chassis discovery policy to 1-link and port-channel
Get-UcsChassisDiscoveryPolicy | Set-UcsChassisDiscoveryPolicy -Action 1-link -LinkAggregationPref port-channel -Force

# Create BIOS policy for ESXi hosts
#
# Based on recommendations from https://datacenterdennis.wordpress.com/2016/12/09/cisco-ucs-bios-policy-recommendations/
$mo = Get-UcsOrg -Level root | Add-UcsBiosPolicy -Descr "BIOS policy for generic ESXi hosts" -Name "esxi_bios" -RebootOnUpdate yes -ModifyPresent
$mo | Set-UcsBiosVfSerialPortAEnable -VpSerialPortAEnable disabled -Force
$mo | Set-UcsBiosVfQuietBoot -VpQuietBoot disabled -Force
$mo | Set-UcsBiosVfPOSTErrorPause -VpPOSTErrorPause disabled -Force
$mo | Set-UcsBiosVfFrontPanelLockout -VpFrontPanelLockout disabled -Force
$mo | Set-UcsBiosVfConsistentDeviceNameControl -VpCDNControl disabled -Force
$mo | Set-UcsBiosVfResumeOnACPowerLoss -VpResumeOnACPowerLoss last-state -Force
$mo | Set-UcsBiosVfQPILinkFrequencySelect -VpQPILinkFrequencySelect auto -Force
$mo | Set-UcsBiosVfQPISnoopMode -VpQPISnoopMode home-snoop -Force
$mo | Set-UcsBiosVfTrustedPlatformModule -VpTrustedPlatformModuleSupport enabled -Force
$mo | Set-UcsBiosVfIntelTrustedExecutionTechnology -VpIntelTrustedExecutionTechnologySupport enabled -Force
$mo | Set-UcsBiosExecuteDisabledBit -VpExecuteDisableBit enabled -Force
$mo | Set-UcsBiosVfDirectCacheAccess -VpDirectCacheAccess enabled -Force
$mo | Set-UcsBiosVfLocalX2Apic -VpLocalX2Apic auto -Force
$mo | Set-UcsBiosVfFrequencyFloorOverride -VpFrequencyFloorOverride enabled -Force
$mo | Set-UcsBiosVfDRAMClockThrottling -VpDRAMClockThrottling auto -Force
$mo | Set-UcsBiosVfInterleaveConfiguration -VpChannelInterleaving auto -VpRankInterleaving auto -Force
$mo | Set-UcsBiosVfAltitude -VpAltitude auto -Force
$mo | Set-UcsBiosTurboBoost -VpIntelTurboBoostTech enabled -Force
$mo | Set-UcsBiosEnhancedIntelSpeedStep -VpEnhancedIntelSpeedStepTech enabled -Force
$mo | Set-UcsBiosHyperThreading -VpIntelHyperThreadingTech enabled -Force
$mo | Set-UcsBiosVfCoreMultiProcessing -VpCoreMultiProcessing all -Force
$mo | Set-UcsBiosVfIntelVirtualizationTechnology -VpIntelVirtualizationTechnology enabled -Force
$mo | Set-UcsBiosVfProcessorEnergyConfiguration -VpEnergyPerformance performance -VpPowerTechnology performance -Force
$mo | Set-UcsBiosVfProcessorCState -VpProcessorCState enabled -Force
$mo | Set-UcsBiosVfProcessorC1E -VpProcessorC1E enabled -Force
$mo | Set-UcsBiosVfCPUPerformance -VpCPUPerformance enterprise -Force
$mo | Set-UcsBiosVfPackageCStateLimit -VpPackageCStateLimit c1 -Force
$mo | Set-UcsBiosVfProcessorC3Report -VpProcessorC3Report disabled -Force
$mo | Set-UcsBiosVfProcessorC6Report -VpProcessorC6Report disabled -Force
$mo | Set-UcsBiosVfProcessorC7Report -VpProcessorC7Report disabled -Force
$mo | Set-UcsBiosVfMaxVariableMTRRSetting -VpProcessorMtrr auto-max -Force
$mo | Set-UcsBiosVfScrubPolicies -VpDemandScrub enabled -VpPatrolScrub enabled -Force
$mo | Set-UcsBiosIntelDirectedIO -VpIntelVTForDirectedIO enabled -Force
$mo | Set-UcsBiosNUMA -VpNUMAOptimized enabled -Force
$mo | Set-UcsBiosLvDdrMode -VpLvDDRMode performance-mode -Force
$mo | Set-UcsBiosVfDramRefreshRate -VpDramRefreshRate auto -Force
$mo | Set-UcsBiosVfSelectMemoryRASConfiguration -VpSelectMemoryRASConfiguration maximum-performance -Force
$mo | Set-UcsBiosVfDDR3VoltageSelection -VpDDR3VoltageSelection ddr3-1350mv -Force
$mo | Set-UcsBiosVfConsoleRedirection -VpConsoleRedirection disabled -Force

# Create iSCSI boot policy
$mo = Get-UcsOrg -Level root | Add-UcsBootPolicy -Name "esxi_iscsi_boot" -BootMode legacy -EnforceVnicName yes -RebootOnUpdate no -Descr "Boot from iSCSI for ESXi hosts" -ModifyPresent
$mo | Add-UcsLsbootVirtualMedia -Access read-only -LunId 0 -Order 1 -ModifyPresent
$mo_1 = $mo | Add-UcsLsbootIScsi -Order 2 -ModifyPresent
$mo_1 | Add-UcsLsbootIScsiImagePath -ISCSIVnicName "iscsi_a" -Type primary -ModifyPresent
$mo_1 | Add-UcsLsbootIScsiImagePath -ISCSIVnicName "iscsi_b" -Type secondary -ModifyPresent

# Creat local disk policy for diskless blades
Get-UcsOrg -Level root | Add-UcsLocalDiskConfigPolicy -Name "no_local_disk" -Mode no-local-storage -FlexFlashState disable -FlexFlashRAIDReportingState disable -ModifyPresent

# Create local disk policy using RAID-1 for servers with local hard disks or SSDs
Get-UcsOrg -Level root | Add-UcsLocalDiskConfigPolicy -Name "local_disk_raid1" -Mode raid-mirrored -ProtectConfig yes -FlexFlashState disable -FlexFlashRAIDReportingState disable -ModifyPresent

# Create maintenance policy set to user-ack, apply on next reboot
Get-UcsOrg -Level root | Add-UcsMaintenancePolicy -Name "user_ack" -UptimeDisr user-ack -SoftShutdownTimer never -TriggerConfig on-next-boot -ModifyPresent

# Set default maintenance policy to user-ack
Get-UcsOrg -Level root | Get-UcsMaintenancePolicy -Name "default" | Set-UcsMaintenancePolicy -UptimeDisr user-ack -Force

# Create a network control policy that enables CDP and disables LLDP
$mo = Get-UcsOrg -Level root  | Add-UcsNetworkControlPolicy -Name "cdp_on_lldp_off" -Cdp enabled -LldpReceive disabled -LldpTransmit disabled -UplinkFailAction link-down -MacRegisterMode only-native-vlan -Descr "CDP enabled, LLDP disabled" -ModifyPresent
$mo | Add-UcsPortSecurityConfig -Forge allow -ModifyPresent 

# Create management vNIC template redundancy pair
$mo = Get-UcsOrg -Level root  | Add-UcsVnicTemplate -Name "esxi_mgmt_a" -IdentPoolName "esxi_mac_a_dc$site_id" -SwitchId A -RedundancyPairType primary -PeerRedundancyTemplName "esxi_mgmt_b" -CdnSource vnic-name -Mtu 1500 -NwCtrlPolicyName "cdp_on_lldp_off" -TemplType updating-template -ModifyPresent
$mo | Add-UcsVnicInterface -Name $mgmt_vlan"_mgmt_dc"$site_id -DefaultNet no -ModifyPresent
$mo = Get-UcsOrg -Level root  | Add-UcsVnicTemplate -Name "esxi_mgmt_b" -IdentPoolName "esxi_mac_b_dc$site_id" -SwitchId B -RedundancyPairType secondary -PeerRedundancyTemplName "esxi_mgmt_a" -CdnSource vnic-name -ModifyPresent

# Create vMotion vNIC template redundancy pair
$mo = Get-UcsOrg -Level root  | Add-UcsVnicTemplate -Name "esxi_vmotion_a" -IdentPoolName "esxi_mac_a_dc$site_id" -SwitchId A -RedundancyPairType primary -PeerRedundancyTemplName "esxi_vmotion_b" -CdnSource vnic-name -Mtu 9000 -NwCtrlPolicyName "cdp_on_lldp_off" -TemplType updating-template -ModifyPresent
$mo | Add-UcsVnicInterface -Name $vmotion_vlan"_vmotion_dc"$site_id -DefaultNet no -ModifyPresent
$mo = Get-UcsOrg -Level root  | Add-UcsVnicTemplate -Name "esxi_vmotion_b" -IdentPoolName "esxi_mac_b_dc$site_id" -SwitchId B -RedundancyPairType secondary -PeerRedundancyTemplName "esxi_vmotion_a" -CdnSource vnic-name -ModifyPresent

# Create NFS vNIC template redundancy pair
$mo = Get-UcsOrg -Level root  | Add-UcsVnicTemplate -Name "esxi_nfs_a" -IdentPoolName "esxi_mac_a_dc$site_id" -SwitchId A -RedundancyPairType primary -PeerRedundancyTemplName "esxi_nfs_b" -CdnSource vnic-name -Mtu 9000 -NwCtrlPolicyName "cdp_on_lldp_off" -TemplType updating-template -ModifyPresent
$mo | Add-UcsVnicInterface -Name $nfs_vlan"_nfs_dc"$site_id -DefaultNet no -ModifyPresent
$mo = Get-UcsOrg -Level root  | Add-UcsVnicTemplate -Name "esxi_nfs_b" -IdentPoolName "esxi_mac_b_dc$site_id" -SwitchId B -RedundancyPairType secondary -PeerRedundancyTemplName "esxi_nfs_a" -CdnSource vnic-name -ModifyPresent

# Create iSCSI A vNIC template
$mo = Get-UcsOrg -Level root  | Add-UcsVnicTemplate -Name "esxi_iscsi_a" -IdentPoolName "esxi_mac_a_dc$site_id" -SwitchId A -Mtu 9000 -NwCtrlPolicyName "cdp_on_lldp_off" -TemplType updating-template -ModifyPresent
$mo | Add-UcsVnicInterface -Name $iscsi_a_vlan"_iscsi_a_dc"$site_id -DefaultNet yes -ModifyPresent

# Create iSCSI B vNIC template
$mo = Get-UcsOrg -Level root  | Add-UcsVnicTemplate -Name "esxi_iscsi_b" -IdentPoolName "esxi_mac_b_dc$site_id" -SwitchId A -Mtu 9000 -NwCtrlPolicyName "cdp_on_lldp_off" -TemplType updating-template -ModifyPresent
$mo | Add-UcsVnicInterface -ModifyPresent -Name $iscsi_b_vlan"_iscsi_b_dc"$site_id -DefaultNet yes

# Disconnect from UCS Manager
Disconnect-Ucs -Ucs $handle
