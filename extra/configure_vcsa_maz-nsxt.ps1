$Vc = "###VCENTER###"
$vcUser = "###VCENTER_ADMIN###"
$vcPass = '###VCENTER_PASSWD###'
$vlan = '###VLAN###'
$mtu = '1500'
$ClusterName = '###CLUSTER###'
$vds_name = '###VDS###' 
$mgmt_portgroup_vds = '###MGMTPORTGROUP###'
$vmotion_portgroup_vds = '###VMOTIONPORTGROUP###'
$vsan_portgroup_vds = '###VSANPORTGROUP###'

#connect to vCenter
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false -DefaultVIServerMode multiple
Connect-VIServer -Server $Vc -User $vcUser -Password $vcPass

# get versions
$vcenterversion =  $global:DefaultVIServers | Select Name,Version 
$vmhosts = get-vmhost
$esxiversion =  $vmhosts[0].Version 

# Set some extra stuff, need to fix datacenter
$Cluster = Get-Cluster -Name $ClusterName
$mgmt_portgroup_vsw = "Management Network"

# Get the Datacenter Object
$Datacenter = Get-Datacenter

# Get the vSAN Cluster
$Cluster = Get-Cluster -Name $Cluster

#Go over each ESXi host in the cluster to migrate vmk0
Foreach ($ESXhost in ($Cluster | Get-VMHost)) {
	#sanity check on vmk0
	$currentpg = (Get-VMHostNetworkAdapter -Name "vmk0" -VMHost $ESXhost).PortGroupName
	if ( $currentpg -ne $mgmt_portgroup_vds)
	{
		Write-Host "Migrating" $mgmt_portgroup_vsw "to" $mgmt_portgroup_vds "on" $vds_name "on" $ESXhost
		#Retrieve vmk name
		$vmk = Get-VMHostNetworkAdapter -Name vmk0 -VMHost $ESXhost
		#Migrate vmk0 to VDS
		$physicalNic = Get-VMHost $ESXhost | Get-VMHostNetworkAdapter -Physical -Name vmnic0
		Get-VDSwitch -name $vds_name -Location $Datacenter | Add-VDSwitchPhysicalNetworkAdapter -VMHostPhysicalNic $physicalNic -VMHostVirtualNic $vmk -VirtualNicPortgroup $mgmt_portgroup_vds -Confirm:$false
		#vDS doesnt like updates to fast
		Start-Sleep -s 30
	}
	else
	{
		Write-Host "vmk0 is already on" $currentpg "on" $ESXhost
	}
	#remove old vSwitch and portgroup
	$vswitch = Get-VirtualSwitch -VMHost $ESXhost -Name vSwitch0 -ErrorAction SilentlyContinue
	if ($vswitch.count -gt 0) {
		write-host "Removing vswitch: "$vswitch" on host" $ESXhost
		Remove-VirtualSwitch -VirtualSwitch $vswitch -confirm:$false
	}
	else{
		write-host "there is no vswitch0 on host" $ESXhost
	}
}

#configure vmk1 for vmotion and set netstack to vmotion
Foreach ($ESXhost in ($Cluster | Get-VMHost)) {
	$test = Get-VMHostNetworkAdapter -name "vmk1" -vmhost $ESXhost -ErrorAction SilentlyContinue
	if ($test.count -gt 0) {
		write-host "vmk1 already exists on host" $ESXhost
	}
	else{
		$pg = Get-VDPortgroup -Name $vmotion_portgroup_vds
		$octet1 = "10"
		$octet2 = $vlan
		$octet3 = "1"
		$octet4 = (Get-VMHostNetworkAdapter -Name vmk0 -VMHost $ESXhost).IP.Split('.')[-1]
		$ippadd = $octet1+"."+$octet2+"."+$octet3+"."+$octet4
		$gw = $octet1+"."+$octet2+"."+$octet3+".1"
		$myVirtualSwitch = Get-VirtualSwitch -VMHost $ESXhost -Name $vds_name
		Write-Host "Setting vmkernel for vmotion with IP:"$ippadd" on "$pg" on distributed switch: "$myVirtualSwitch
		#Retrieve vmo stack, vmotion stack has no name so ID is to be used
		$vmostack = Get-VMHostNetworkStack -vmhost $ESXhost | ? {$_.ID -eq "vmotion"}
		new-vmhostnetworkadapter -VMhost $ESXhost -PortGroup $pg -VirtualSwitch $myVirtualSwitch -IP $ippadd -SubnetMask "255.255.255.0" -MTU $mtu -NetworkStack $vmostack
		#update DG can only be done after netstack has a vmk 
		Set-VMHostNetworkStack -Network $vmostack -VMKernelGateway $gw -confirm:$false
	}
}

#configure vmk2 for vsan with IP settings and default gateway
Foreach ($ESXhost in ($Cluster | Get-VMHost)) {
	$test = Get-VMHostNetworkAdapter -name "vmk2" -vmhost $ESXhost -ErrorAction SilentlyContinue
	if ($test.count -gt 0) {
		write-host "vmk2 already exists on host" $ESXhost
	}
	else{
		$pg = Get-VDPortgroup -Name $vsan_portgroup_vds
		$octet1 = "10"
		$octet2 = $vlan
		$octet3 = "2"
		$octet4 = (Get-VMHostNetworkAdapter -Name vmk0 -VMHost $ESXhost).IP.Split('.')[-1]
		$ippadd = $octet1+"."+$octet2+"."+$octet3+"."+$octet4
		$gw = $octet1+"."+$octet2+"."+$octet3+".1"
		$myVirtualSwitch = Get-VirtualSwitch -VMHost $ESXhost -Name $vds_name
		Write-Host "Setting vmkernel for vSAN with IP:"$ippadd" on "$pg" on distributed switch: "$myVirtualSwitch
		new-vmhostnetworkadapter -vmhost $ESXhost -PortGroup $pg -VirtualSwitch $myVirtualSwitch -IP $ippadd -SubnetMask "255.255.255.0" -MTU $mtu -VsanTrafficEnabled:$true
		# use esxcli as the default gateway can only be set this way
		$esxcli = Get-EsxCli -VMHost $ESXhost -V2
		#retrieve the settings of the vSAN vmk and add the default gateway
		$vmkName = 'vmk2'
		$if = $esxcli.network.ip.interface.ipv4.get.Invoke(@{interfacename=$vmkName})
		$iArg = @{
			netmask = $if[0].IPv4Netmask
			type    = $if[0].AddressType.ToLower()
			ipv4    = $if[0].IPv4Address
			interfacename = $if[0].Name
			gateway = $gw
		}
		#set the Default gateway for vSAN network
		$esxcli.network.ip.interface.ipv4.set.Invoke($iArg)
	}
	#$esxcli.network.ip.interface.ipv4.get.Invoke(@{interfacename=$vmkName})
}

#remove vmotion from vmk0
Foreach ($ESXhost in ($Cluster | Get-VMHost)) {
	$vmk0 = Get-VMHostNetworkAdapter -name "vmk0" -vmhost $ESXhost -ErrorAction SilentlyContinue
	if ($vmk0.count -gt 0) {
    write-host "Removing vmotion from "$vmk0" on host" $ESXhost
	Set-VMHostNetworkAdapter -VirtualNic $vmk0 -VMotionEnabled $false -Confirm:$false
	}
	else{
	write-host "something is horribly wrong as there is no vmk0"
	exit
	}
}

#####
Disconnect-VIServer -Confirm:$false
