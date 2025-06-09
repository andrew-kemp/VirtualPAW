
param upn string
param adminPassword string
param adminUsername string = 'vPAW-Admin'
param location string = 'uksouth'
param vmSize string = 'Standard_D2s_v3'
param imagePublisher string = 'MicrosoftWindowsDesktop'
param imageOffer string = 'Windows-11'
param imageSku string = 'win11-21h2-avd'
param imageVersion string = 'latest'
param osDiskSizeGB int = 128
param modulesURL string = 'https://wvdportalstorageblob.blob.core.windows.net/galleryartifacts/Configuration_1.0.02797.442.zip'

module coreInfra 'avd-core.bicep' = {
  name: 'coreInfra'
  params: {
    DefaultPrefix: 'vPAW'
  }
}

module sessionHost 'avd-sessionhost.bicep' = {
  name: 'sessionHost'
  params: {
    upn: upn
    adminPassword: adminPassword
    adminUsername: adminUsername
    location: location
    vmSize: vmSize
    imagePublisher: imagePublisher
    imageOffer: imageOffer
    imageSku: imageSku
    imageVersion: imageVersion
    osDiskSizeGB: osDiskSizeGB
    subnetId: coreInfra.outputs.subnetId
    hostPoolRegistrationInfoToken: coreInfra.outputs.hostPoolRegistrationInfoToken
    modulesURL: modulesURL
  }
}
