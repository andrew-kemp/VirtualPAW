param DefaultPrefix string = 'vPAW'
param vNetAddressPrefix string = '192.168.250.0/24'
param subnetAddressPrefix string = '192.168.250.0/24'

// Deploy the Hostpool
resource HostPool 'Microsoft.DesktopVirtualization/hostPools@2021-07-12' = {
  name: '${DefaultPrefix}-HostPool'
  location: resourceGroup().location
  properties: {
    friendlyName: '${DefaultPrefix} Host Pool'
    description: '${DefaultPrefix} Virtual Privileged Access Workstation Host Pool for privileged users to securely access the Microsoft Admin centers from'
    hostPoolType: 'Personal'
    loadBalancerType: 'BreadthFirst'
    maxSessionLimit: 1
    personalDesktopAssignmentType: 'Automatic'
    startVMOnConnect: true
    preferredAppGroupType: 'Desktop'
    customRdpProperty: 'enablecredsspsupport:i:1;authentication level:i:2;enablerdsaadauth:i:1;redirectwebauthn:i:1;'
  }
}

// Deploy the Desktop Application Group
resource AppGroup 'Microsoft.DesktopVirtualization/applicationGroups@2021-07-12' = {
  name: '${DefaultPrefix}-AppGroup'
  location: resourceGroup().location
  properties: {
    description: '${DefaultPrefix} Application Group'
    friendlyName: '${DefaultPrefix} Desktop Application Group'
    hostPoolArmPath: HostPool.id
    applicationGroupType: 'Desktop'
  }
}

// Deploy the Workspace
resource Workspace 'Microsoft.DesktopVirtualization/workspaces@2021-07-12' = {
  name: '${DefaultPrefix}-Workspace'
  location: resourceGroup().location
  properties: {
    description: '${DefaultPrefix} Workspace for Privileged Users'
    friendlyName: '${DefaultPrefix} Workspace'
    applicationGroupReferences: [
      AppGroup.id
    ]
  }
}

// Deploy the network infrastructure
resource vNet 'Microsoft.Network/virtualNetworks@2021-05-01' = {
  name: '${DefaultPrefix}-vNet'
  location: resourceGroup().location
  properties: {
    addressSpace: {
      addressPrefixes: [
        vNetAddressPrefix
      ]
    }
    subnets: [
      {
        name: '${DefaultPrefix}-Subnet'
        properties: {
          addressPrefix: subnetAddressPrefix
        }
      }
    ]
  }
}
