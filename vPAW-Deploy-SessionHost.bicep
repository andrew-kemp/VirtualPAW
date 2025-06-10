@description('Prefix for the VPAW session host')
param sessionHostPrefix string = 'vPAW'

@description('First name of the user')
param userFirstName string

@description('Last name of the user')
param userLastName string

@description('User Principal Name (UPN) for assignment')
param userUPN string

@description('Admin username for the session host')
param adminUsername string = 'VPAW-Admin'

@secure()
@description('Admin password for the session host')
param adminPassword string

@description('Registration key for the AVD host pool')
param hostPoolRegistrationInfoToken string

@description('Resource group containing the vNet')
param vNetResourceGroup string = 'vPAW'

@description('Name of the vNet')
param vNetName string = 'vPAW-Vnet'

@description('Name of the subnet')
param subnetName string = 'vPAW-Subnet'

@description('Primary DNS server for session host (leave blank for default)')
param dns1 string = ''

@description('Secondary DNS server for session host (leave blank for default or only use one)')
param dns2 string = ''

@description('URL of the SessionHostPrep.ps1 script')
param sessionHostPrepScriptUrl string = 'https://raw.githubusercontent.com/andrew-kemp/CloudPAW/refs/heads/main/SessionHostPrep.ps1'

var sessionHostName = '${sessionHostPrefix}-${userFirstName}${userLastName}'
var modulesURL = 'https://wvdportalstorageblob.blob.${environment().suffixes.storage}/galleryartifacts/Configuration_1.0.02797.442.zip'
var sessionHostPrepScriptName = substring(sessionHostPrepScriptUrl, lastIndexOf(sessionHostPrepScriptUrl, '/') + 1)
var dnsServers = concat(empty(dns1) ? [] : [dns1], empty(dns2) ? [] : [dns2])

resource HostPool 'Microsoft.DesktopVirtualization/hostpools@2021-07-12' existing = {
  name: '${sessionHostPrefix}-HostPool'
}

resource existingSubnet 'Microsoft.Network/virtualNetworks/subnets@2021-05-01' existing = {
  name: '${vNetName}/${subnetName}'
  scope: resourceGroup(vNetResourceGroup)
}

resource nic 'Microsoft.Network/networkInterfaces@2020-11-01' = {
  name: '${sessionHostName}-nic'
  location: resourceGroup().location
  properties: union({
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: existingSubnet.id
          }
        }
      }
    ]
  }, empty(dnsServers) ? {} : {
    dnsSettings: {
      dnsServers: dnsServers
    }
  })
}

resource VM 'Microsoft.Compute/virtualMachines@2020-12-01' = {
  name: sessionHostName
  location: resourceGroup().location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    hardwareProfile: {
      vmSize: 'Standard_d2as_v5'
    }
    osProfile: {
      computerName: sessionHostName
      adminUsername: adminUsername
      adminPassword: adminPassword
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsDesktop'
        offer: 'Windows-11'
        sku: 'win11-24h2-avd'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        diskSizeGB: 256
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
        }
      ]
    }
  }
}

resource entraIdJoin 'Microsoft.Compute/virtualMachines/extensions@2021-11-01' = {
  parent: VM
  name: '${sessionHostName}-EntraJoinEntrollIntune'
  location: resourceGroup().location
  properties: {
    publisher: 'Microsoft.Azure.ActiveDirectory'
    type: 'AADLoginForWindows'
    typeHandlerVersion: '2.2'
    autoUpgradeMinorVersion: true
    enableAutomaticUpgrade: false
    settings: {
      mdmId: '0000000a-0000-0000-c000-000000000000'
    }
  }
}

resource guestAttestationExtension 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = {
  parent: VM
  name: '${sessionHostName}-guestAttestationExtension'
  location: resourceGroup().location
  properties: {
    publisher: 'Microsoft.Azure.Security.WindowsAttestation'
    type: 'GuestAttestation'
    typeHandlerVersion: '1.0'
    autoUpgradeMinorVersion: true
  }
  dependsOn: [
    entraIdJoin
  ]
}

resource SessionPrep 'Microsoft.Compute/virtualMachines/extensions@2021-03-01' = {
  parent: VM
  name: '${sessionHostName}-SessionPrep'
  location: resourceGroup().location
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'CustomScriptExtension'
    typeHandlerVersion: '1.10'
    autoUpgradeMinorVersion: true
    settings: {
      fileUris: [
        sessionHostPrepScriptUrl
      ]
      commandToExecute: 'powershell -ExecutionPolicy Unrestricted -File .\\${sessionHostPrepScriptName} '
    }
  }
  dependsOn: [
    guestAttestationExtension
  ]
}

// Join the SessionHost to the HostPool (registration to be finalized with user assignment post deployment)
resource dcs 'Microsoft.Compute/virtualMachines/extensions@2024-03-01' = {
  parent: VM
  name: '${sessionHostName}-JointoHostPool'
  location: resourceGroup().location
  properties: {
    publisher: 'Microsoft.Powershell'
    type: 'DSC'
    typeHandlerVersion: '2.76'
    settings: {
      modulesUrl: modulesURL
      configurationFunction: 'Configuration.ps1\\AddSessionHost'
      properties: {
        hostPoolName: HostPool.name
        aadJoin: true
      }
    }
    protectedSettings: {
      properties: {
        registrationInfoToken: hostPoolRegistrationInfoToken
      }
    }
  }
  dependsOn: [
    SessionPrep
  ]
}

output postDeploymentInstructions string = '''
MANUAL STEPS REQUIRED:
1. Assign the session host (${sessionHostName}) to user UPN: ${userUPN} as a personal desktop in the AVD HostPool.
   This can be done via Azure Portal or PowerShell:
   Add-RdsSessionHost -TenantName <tenant> -HostPoolName <hostpool> -Name ${sessionHostName} -AssignedUser ${userUPN}
2. Update the AVD enterprise app and grant it permission.
3. Exclude the storage app from Conditional Access policies.
4. Add the folder permissions via a hybrid-joined client.
5. Assign AAD/Entra groups to AVD Application Groups as needed.
6. Update Session Desktop friendly name if required.
7. Update DNS for ${storageAccountName}.file.${environment().suffixes.storage} if using a private endpoint.
'''
