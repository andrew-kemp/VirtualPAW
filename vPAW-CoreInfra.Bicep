@description('Prefix for resources')
param DefaultPrefix string = 'vPAW'

@description('Address prefix for the virtual network')
param vNetAddressPrefix string = '192.168.250.0/24'

@description('Address prefix for the subnet')
param subnetAddressPrefix string = '192.168.250.0/24'

@minLength(3)
@maxLength(24)
@description('The name of the storage account to create (lowercase, 3-24 chars)')
param storageAccountName string

@description('Object ID of the SMB File Data Contributor Azure AD group')
param smbContributorsGroupId string

@description('Object ID of the SMB File Data Elevated Contributor Azure AD group')
param smbElevatedContributorsGroupId string

@description('Name of the Key Vault to create (must be globally unique)')
param keyVaultName string = '${DefaultPrefix}KeyVault'

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

resource vNet 'Microsoft.Network/virtualNetworks@2021-05-01' = {
  name: '${DefaultPrefix}-vNet'
  location: resourceGroup().location
  properties: {
    addressSpace: {
      addressPrefixes: [
        vNetAddressPrefix
      ]
    }
  }
}

resource subnet 'Microsoft.Network/virtualNetworks/subnets@2021-05-01' = {
  name: '${DefaultPrefix}-Subnet'
  parent: vNet
  properties: {
    addressPrefix: subnetAddressPrefix
    privateEndpointNetworkPolicies: 'Disabled'
  }
}

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountName
  location: resourceGroup().location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    supportsHttpsTrafficOnly: true
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
    }
    azureFilesIdentityBasedAuthentication: {
      directoryServiceOptions: 'AADKERB'
      // NOTE: You must add activeDirectoryProperties for AADKERB to work!
      // activeDirectoryProperties: {
      //   domainName: '<AD domain>'
      //   netBiosDomainName: '<NETBIOS domain>'
      //   forestName: '<forest name>'
      //   domainGuid: '<domain guid>'
      //   domainSid: '<domain sid>'
      //   azureStorageSid: '<storage sid>'
      // }
    }
  }
}

resource storageShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-01-01' = {
  name: '${storageAccount.name}/default/adminstorage'
  properties: {
    accessTier: 'TransactionOptimized'
  }
}

resource storagePrivateEndpoint 'Microsoft.Network/privateEndpoints@2021-05-01' = {
  name: '${storageAccountName}-pe'
  location: resourceGroup().location
  properties: {
    subnet: {
      id: subnet.id
    }
    privateLinkServiceConnections: [
      {
        name: '${storageAccountName}-plsc'
        properties: {
          privateLinkServiceId: storageAccount.id
          groupIds: [
            'file'
          ]
        }
      }
    ]
  }
}

resource smbShareContributorAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageShare.id, smbContributorsGroupId, 'FileShareContributor')
  scope: storageShare
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '0c867c2a-1d8c-454a-a3db-ab2ea1bdc8bb')
    principalId: smbContributorsGroupId
    principalType: 'Group'
  }
}

resource smbShareElevatedContributorAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageShare.id, smbElevatedContributorsGroupId, 'FileShareElevatedContributor')
  scope: storageShare
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'a7264617-510b-434b-a828-9731dc254ea7')
    principalId: smbElevatedContributorsGroupId
    principalType: 'Group'
  }
}

