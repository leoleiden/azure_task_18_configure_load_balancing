$location = "uksouth"
$resourceGroupName = "mate-azure-task-18"

$virtualNetworkName = "todoapp"
$vnetAddressPrefix = "10.20.30.0/24"
$webSubnetName = "webservers"
$webSubnetIpRange = "10.20.30.0/26"
$mngSubnetName = "management"
$mngSubnetIpRange = "10.20.30.128/26"

$sshKeyName = "linuxboxsshkey"
$sshKeyPublicKey = Get-Content "~/.ssh/id_rsa.pub"

$vmImage = "Ubuntu2204"
$vmSize = "Standard_B1s"
$webVmName = "webserver"
$jumpboxVmName = "jumpbox"
$dnsLabel = "matetask" + (Get-Random -Count 1)

$privateDnsZoneName = "or.nottodo"

$lbName = "loadbalancer"
$lbIpAddress = "10.20.30.62"


Write-Host "Creating a resource group $resourceGroupName ..."
New-AzResourceGroup -Name $resourceGroupName -Location $location

Write-Host "Creating web network security group..."
$webHttpRule = New-AzNetworkSecurityRuleConfig -Name "web" -Description "Allow HTTP" `
   -Access Allow -Protocol Tcp -Direction Inbound -Priority 100 -SourceAddressPrefix `
   Internet -SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange 80,443
$webNsg = New-AzNetworkSecurityGroup -ResourceGroupName $resourceGroupName -Location $location -Name `
   $webSubnetName -SecurityRules $webHttpRule

Write-Host "Creating mngSubnet network security group..."
$mngSshRule = New-AzNetworkSecurityRuleConfig -Name "ssh" -Description "Allow SSH" `
   -Access Allow -Protocol Tcp -Direction Inbound -Priority 100 -SourceAddressPrefix `
   Internet -SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange 22
$mngNsg = New-AzNetworkSecurityGroup -ResourceGroupName $resourceGroupName -Location $location -Name `
   $mngSubnetName -SecurityRules $mngSshRule

Write-Host "Creating a virtual network ..."
$webSubnet = New-AzVirtualNetworkSubnetConfig -Name $webSubnetName -AddressPrefix $webSubnetIpRange -NetworkSecurityGroup $webNsg
$mngSubnet = New-AzVirtualNetworkSubnetConfig -Name $mngSubnetName -AddressPrefix $mngSubnetIpRange -NetworkSecurityGroup $mngNsg
$virtualNetwork = New-AzVirtualNetwork -Name $virtualNetworkName -ResourceGroupName $resourceGroupName -Location $location -AddressPrefix $vnetAddressPrefix -Subnet $webSubnet,$mngSubnet

Write-Host "Creating a SSH key resource ..."
New-AzSshKey -Name $sshKeyName -ResourceGroupName $resourceGroupName -PublicKey $sshKeyPublicKey

Write-Host "Creating a web server VM ..."

for (($zone = 1); ($zone -le 2); ($zone++) ) {
   $vmName = "$webVmName-$zone"
   New-AzVm `
   -ResourceGroupName $resourceGroupName `
   -Name $vmName `
   -Location $location `
   -image $vmImage `
   -size $vmSize `
   -SubnetName $webSubnetName `
   -VirtualNetworkName $virtualNetworkName `
   -SshKeyName $sshKeyName 
   $Params = @{
      ResourceGroupName  = $resourceGroupName
      VMName             = $vmName
      Name               = 'CustomScript'
      Publisher          = 'Microsoft.Azure.Extensions'
      ExtensionType      = 'CustomScript'
      TypeHandlerVersion = '2.1'
      Settings          = @{fileUris = @('https://raw.githubusercontent.com/mate-academy/azure_task_18_configure_load_balancing/main/install-app.sh'); commandToExecute = './install-app.sh'}
   }
   Set-AzVMExtension @Params
}

Write-Host "Creating a public IP ..."
$publicIP = New-AzPublicIpAddress -Name $jumpboxVmName -ResourceGroupName $resourceGroupName -Location $location -Sku Basic -AllocationMethod Dynamic -DomainNameLabel $dnsLabel
Write-Host "Creating a management VM ..."
New-AzVm `
-ResourceGroupName $resourceGroupName `
-Name $jumpboxVmName `
-Location $location `
-image $vmImage `
-size $vmSize `
-SubnetName $mngSubnetName `
-VirtualNetworkName $virtualNetworkName `
-SshKeyName $sshKeyName `
-PublicIpAddressName $jumpboxVmName


Write-Host "Creating a private DNS zone ..."
$Zone = New-AzPrivateDnsZone -Name $privateDnsZoneName -ResourceGroupName $resourceGroupName 
$Link = New-AzPrivateDnsVirtualNetworkLink -ZoneName $privateDnsZoneName -ResourceGroupName $resourceGroupName -Name $Zone.Name -VirtualNetworkId $virtualNetwork.Id -EnableRegistration


Write-Host "Creating an A DNS record ..."
$Records = @()
$Records += New-AzPrivateDnsRecordConfig -IPv4Address $lbIpAddress
New-AzPrivateDnsRecordSet -Name "todo" -RecordType A -ResourceGroupName $resourceGroupName -TTL 1800 -ZoneName $privateDnsZoneName -PrivateDnsRecords $Records

# Prepare variables, required for creation and configuration of load balancer - 
# you will need them to setup a load balancer 
$webSubnetId = (Get-AzVirtualNetworkSubnetConfig -Name $webSubnetName -VirtualNetwork $virtualNetwork).Id

# Write your code here -> 
Write-Host "Creating a load balancer ..."

# Створення публічної IP-адреси для фронтенду балансувальника навантаження
# Хоча в завданні вказано "приватний балансувальник", Load Balancer Standard SKU вимагає Frontend IP Configuration. 
# Для приватного Load Balancer IP-адреса буде з приватного діапазону.
$lbFrontendIpConfig = New-AzLoadBalancerFrontendIpConfig -Name "LoadBalancerFrontend" -PrivateIpAddress $lbIpAddress -SubnetId $webSubnetId

# Створення Backend Pool
$bepool = New-AzLoadBalancerBackendAddressPoolConfig -Name "BackendPool"

# Створення Health Probe (порт 8080)
$healthProbe = New-AzLoadBalancerProbeConfig -Name "HealthProbe" -Protocol Tcp -Port 8080 -IntervalInSeconds 5 -ProbeCount 2

# Створення Load Balancing Rule (фронтенд порт 80, бекенд порт 8080)
$lbRule = New-AzLoadBalancerRuleConfig -Name "HttpRule" -FrontendIpConfiguration $lbFrontendIpConfig -BackendAddressPool $bepool -Probe $healthProbe -Protocol Tcp -FrontendPort 80 -BackendPort 8080 -LoadDistribution Default -EnableFloatingIp $false

# Створення Load Balancer
New-AzLoadBalancer -ResourceGroupName $resourceGroupName -Name $lbName -Location $location -FrontendIpConfiguration $lbFrontendIpConfig -BackendAddressPool $bepool -LoadBalancingRule $lbRule -Probe $healthProbe -Sku Standard

# Отримайте фактичний об'єкт балансувальника навантаження після його розгортання.
# Це необхідно, щоб отримати посилання на реальний, розгорнутий Backend Pool.
$actualLoadBalancer = Get-AzLoadBalancer -ResourceGroupName $resourceGroupName -Name $lbName

# Отримайте фактичний пул бекендів з розгорнутого балансувальника навантаження.
# Припускаємо, що у вас лише один пул бекендів, тому використовуємо індекс [0].
# Якщо пулів бекендів кілька, можна використовувати Where-Object за ім'ям:
# $actualBackendPool = $actualLoadBalancer.BackendAddressPools | Where-Object {$_.Name -eq "BackendPool"}
$actualBackendPool = $actualLoadBalancer.BackendAddressPools[0]

Write-Host "Adding VMs to the backend pool"
$vms = Get-AzVm -ResourceGroupName $resourceGroupName | Where-Object {$_.Name.StartsWith($webVmName)}
foreach ($vm in $vms) {
    $nic = Get-AzNetworkInterface -ResourceGroupName $resourceGroupName | Where-Object {$_.Id -eq $vm.NetworkProfile.NetworkInterfaces.Id}     
    $ipCfg = $nic.IpConfigurations | Where-Object {$_.Primary} 
    $ipCfg.LoadBalancerBackendAddressPools.Add($actualBackendPool)
    Set-AzNetworkInterface -NetworkInterface $nic
}
