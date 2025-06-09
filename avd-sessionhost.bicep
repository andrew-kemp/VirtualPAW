
param sessionHostPrefix string = 'vPAW'
param upn string
param adminUsername string = 'vPAW-Admin'
@secure()
param adminPassword string
param hostPoolRegistrationInfoToken string
param location string = 'uksouth'
param vmSize string = 'Standard_D2s_v3'
param imagePublisher string = 'MicrosoftWindowsDesktop'
param imageOffer string = 'Windows-11'
param imageSku string = 'win11-21h2-avd'
param imageVersion string = 'latest'
param osDiskSizeGB int = 128
param subnetId string
param modulesURL string = 'https://wvdportalstorageblob.blob.core.windows.net/galleryartifacts/Configuration_1.0.02797.442.zip'

var nameParts = split(split(upn, '@')[0], '_')
var firstName = nameParts[1]
var lastName = nameParts[2]
var vmName = 'vPAW-${firstName}${lastName}'

resource nic 'Microsoft.Network/networkInterfaces@2020-11-01' = {
  name: '${vmName}-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: subnetId
          }
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2020-12-01' = {
  name: vmName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      adminPassword: adminPassword
    }
    storageProfile: {
      imageReference: {
        publisher: imagePublisher
        offer: imageOffer
        sku: imageSku
        version: imageVersion
      }
      osDisk: {
        createOption: 'FromImage'
        diskSizeGB: osDiskSizeGB
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
  tags: {
    ExtensionAttribute1: 'vPAW'
    Owner: upn
    Role: 'PAW'
  }
}

resource entraIdJoin 'Microsoft.Compute/virtualMachines/extensions@2021-11-01' = {
  parent: vm
  name: '${vmName}-EntraJoinEntrollIntune'
  location: location
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
  parent: vm
  name: '${vmName}-guestAttestationExtension'
  location: location
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

resource sessionPrep 'Microsoft.Compute/virtualMachines/extensions@2021-03-01' = {
  parent: vm
  name: '${vmName}-SessionPrep'
  location: location
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'CustomScriptExtension'
    typeHandlerVersion: '1.10'
    autoUpgradeMinorVersion: true
    settings: {
      fileUris: [
        'https://raw.githubusercontent.com/andrew-kemp/CloudPAW/refs/heads/main/SessionHostPrep.ps1'
      ]
      commandToExecute: 'powershell -ExecutionPolicy Unrestricted -File SessionHostPrep.ps1'
    }
  }
  dependsOn: [
    guestAttestationExtension
  ]
}

resource dcs 'Microsoft.Compute/virtualMachines/extensions@2024-03-01' = {
  parent: vm
  name: '${vmName}-JointoHostPool'
  location: location
  properties: {
    publisher: 'Microsoft.Powershell'
    type: 'DSC'
    typeHandlerVersion: '2.76'
    settings: {
      modulesUrl: modulesURL
      configurationFunction: 'Configuration.ps1\\AddSessionHost'
      properties: {
        hostPoolName: '${sessionHostPrefix}-HostPool'
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
    sessionPrep
  ]
}
