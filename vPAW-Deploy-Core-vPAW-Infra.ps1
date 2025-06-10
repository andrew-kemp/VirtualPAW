<#
.SYNOPSIS
    Full interactive setup and post-deployment workflow for VirtualPAW (Privileged Access Workstation) in Azure.

.DESCRIPTION
    - Interactive selection/creation of subscription/resource group, infra params, Entra groups.
    - Ensures authentication with Azure CLI, Az PowerShell, Microsoft Graph.
    - Deploys infra using Bicep template; passes Key Vault name as parameter, Bicep creates it.
    - Sets up AAD groups for RBAC, configures RBAC for AVD app groups, updates Session Desktop's friendly name.
    - Automates exclusion of storage apps from Conditional Access policies.
    - Ensures Key Vault access policy for current user before secret ops.
    - Stores/retrieves Host Pool registration key in Key Vault (after deployment).
    - Saves all deployment params and secret info to vPAWConf.inf for reuse.

.NOTES
    - Expects Bicep template and Az/Graph modules installed.
#>

# ---- Logging Function ----
function Write-Log {
    param (
        [string]$Message,
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logPath = Join-Path $PSScriptRoot "vPAWDeploy.log"
    $entry = "$timestamp [$Level] $Message"
    Add-Content -Path $logPath -Value $entry
}

function Ensure-AzConnection {
    try { $null = Get-AzContext -ErrorAction Stop }
    catch { 
        Write-Host "Re-authenticating to Azure..." -ForegroundColor Yellow
        Write-Log "Re-authenticating to Azure..." "WARN"
        Connect-AzAccount | Out-Null 
    }
}

function Ensure-MgGraphConnection {
    try { $null = Get-MgContext -ErrorAction Stop }
    catch { 
        Write-Host "Re-authenticating to Microsoft Graph..." -ForegroundColor Yellow
        Write-Log "Re-authenticating to Microsoft Graph..." "WARN"
        Connect-MgGraph -Scopes "Group.Read.All, Application.Read.All, Policy.ReadWrite.ConditionalAccess" 
    }
}

function Get-ValidatedKeyVaultName {
    param ([string]$DefaultPrefix = "vPAW")
    $defaultKvName = ("${DefaultPrefix}keyvault").ToLower()
    Write-Host "Enter the Key Vault name (3-24 chars, lowercase letters/numbers/dashes, start/end with letter/number)" -ForegroundColor Green
    Write-Host "Default: $defaultKvName"
    $keyVaultName = Read-Host
    if ([string]::IsNullOrEmpty($keyVaultName)) { $keyVaultName = $defaultKvName }
    $keyVaultName = $keyVaultName.Trim().ToLower()
    if ($keyVaultName.Length -lt 3 -or $keyVaultName.Length -gt 24) { 
        Write-Host "Invalid length." -ForegroundColor Red
        Write-Log "Key Vault name invalid length: $keyVaultName" "WARN"
        return $keyVaultName
    }
    if ($keyVaultName -notmatch '^[a-z0-9-]+$') { 
        Write-Host "Invalid chars." -ForegroundColor Red
        Write-Log "Key Vault name invalid chars: $keyVaultName" "WARN"
        return $keyVaultName
    }
    if ($keyVaultName -notmatch '^[a-z0-9].*[a-z0-9]$') { 
        Write-Host "Must start/end with letter/number." -ForegroundColor Red
        Write-Log "Key Vault name does not start/end with letter/number: $keyVaultName" "WARN"
        return $keyVaultName
    }
    if ($keyVaultName -match '--') { 
        Write-Host "No consecutive dashes." -ForegroundColor Red
        Write-Log "Key Vault name has consecutive dashes: $keyVaultName" "WARN"
        return $keyVaultName
    }
    Write-Host "Checking availability of Key Vault name '$keyVaultName'..." -ForegroundColor Cyan
    Write-Log "Checking Key Vault name availability: $keyVaultName"
    try {
        $azResult = az keyvault check-name --name $keyVaultName | ConvertFrom-Json
        if (-not $azResult.nameAvailable) {
            Write-Host "Name in use, try again." -ForegroundColor Red
            Write-Log "Key Vault name already in use: $keyVaultName" "WARN"
            return $keyVaultName
        } else {
            Write-Host "Key Vault name '$keyVaultName' is available and will be created by Bicep deployment." -ForegroundColor Green
            Write-Log "Key Vault name '$keyVaultName' is available."
            return $keyVaultName
        }
    } catch {
        Write-Host "Validation of Key Vault has failed (gateway timeout or other error). Please continue with caution. If the name exists the deployment will fail." -ForegroundColor Yellow
        Write-Log "Key Vault validation failed for $keyVaultName. Exception: $($_.Exception.Message)" "ERROR"
        return $keyVaultName
    }
}

function Get-ValidatedStorageAccountName {
    while ($true) {
        #Clear-Host
        Write-Host "Enter the storage account name (3-24 chars, lowercase letters and numbers only)" -ForegroundColor Green
        $storageAccountName = Read-Host
        $storageAccountName = $storageAccountName.Trim()
        if ([string]::IsNullOrEmpty($storageAccountName)) { Write-Host "Cannot be blank." -ForegroundColor Red; Write-Log "Storage account name blank" "WARN"; Start-Sleep 2; continue }
        if ($storageAccountName.Length -lt 3 -or $storageAccountName.Length -gt 24) { Write-Host "Invalid length." -ForegroundColor Red; Write-Log "Storage account name invalid length: $storageAccountName" "WARN"; Start-Sleep 2; continue }
        if ($storageAccountName -notmatch '^[a-z0-9]{3,24}$') { Write-Host "Invalid characters." -ForegroundColor Red; Write-Log "Storage account name invalid characters: $storageAccountName" "WARN"; Start-Sleep 2; continue }
        Write-Host "Checking availability of the storage account name..." -ForegroundColor Cyan
        Write-Log "Checking storage account name availability: $storageAccountName"
        try {
            $azResult = az storage account check-name --name $storageAccountName | ConvertFrom-Json
        } catch {
            Write-Host "@Validation of Storage account name has failed, please continue with caution. If the name exists the deployment will fail." -ForegroundColor Yellow
            Write-Log "Storage account validation failed for $storageAccountName. Exception: $($_.Exception.Message)" "ERROR"
            return $storageAccountName
        }
        if (-not $azResult.nameAvailable) {
            Write-Host "Name already in use." -ForegroundColor Red
            Write-Log "Storage account name already in use: $storageAccountName" "WARN"
            Start-Sleep 2
            $randomNumber = Get-Random -Minimum 100 -Maximum 999
            $newName = $storageAccountName
            if ($newName.Length -gt 21) { $newName = $newName.Substring(0, 21) }
            $newName += $randomNumber
            Write-Host "Trying '$newName'..." -ForegroundColor Cyan
            Write-Log "Trying alternate storage account name: $newName"
            $azResult = az storage account check-name --name $newName | ConvertFrom-Json
            if ($azResult.nameAvailable) { Write-Host "'$newName' is available." -ForegroundColor Green; Write-Log "Storage account name '$newName' is available." ; Start-Sleep 1; return $newName } else { continue }
        }
        Write-Host "Storage account name is available." -ForegroundColor Green
        Write-Log "Storage account name '$storageAccountName' is available."
        Start-Sleep 1
        return $storageAccountName
    }
}

function Select-BicepTemplateFile {
    #Clear-Host
    $bicepFiles = Get-ChildItem -Path . -File | Where-Object { $_.Name -match '\.bicep$' -or $_.Name -match '\.BICEP$' }
    if (-not $bicepFiles) { Write-Host "No .bicep template files found." -ForegroundColor Red; Write-Log "No .bicep template files found." "ERROR"; return $null }
    Write-Host "Select a Bicep template file:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $bicepFiles.Count; $i++) { Write-Host "$($i + 1)) $($bicepFiles[$i].Name)" -ForegroundColor Cyan }
    Write-Host "Enter the number:" -ForegroundColor Green
    while ($true) {
        $selection = Read-Host
        if ($selection -match '^\d+$' -and $selection -gt 0 -and $selection -le $bicepFiles.Count) {
            $chosenFile = $bicepFiles[$selection - 1].Name
            Write-Host "Selected Bicep template: $chosenFile" -ForegroundColor Cyan
            Write-Log "Selected Bicep template: $chosenFile"
            return $chosenFile
        } else { Write-Host "Invalid selection." -ForegroundColor Red; Write-Log "Invalid bicep template selection: $selection" "WARN" }
    }
}

function Create-AADGroup([string]$groupName) {
    $mailNickname = $groupName -replace '\s',''
    $groupParams = @{
        DisplayName     = $groupName
        MailEnabled     = $false
        MailNickname    = $mailNickname
        SecurityEnabled = $true
    }
    $newGroup = New-MgGroup @groupParams
    Write-Host "Created group '$($newGroup.DisplayName)' with Object ID: $($newGroup.Id)" -ForegroundColor Cyan
    Write-Log "Created AAD group: $($newGroup.DisplayName) ObjectId: $($newGroup.Id)"
    return $newGroup
}

function Select-AADGroupBySubstring([string]$searchSubstring, [string]$role) {
    Write-Host "Searching for Azure AD groups containing '$searchSubstring' for $role..." -ForegroundColor Green
    Write-Log "Searching for Azure AD groups containing '$searchSubstring' for $role..."
    $allGroups = Get-MgGroup -All
    $filteredGroups = $allGroups | Where-Object { $_.DisplayName -match $searchSubstring }
    if (-not $filteredGroups) {
        Write-Host "No groups found containing '$searchSubstring' in the display name." -ForegroundColor Red
        Write-Log "No groups found containing '$searchSubstring' in the display name." "WARN"
        return $null
    }
    Write-Host "Select the $role group from the list below:" -ForegroundColor Cyan
    $i = 1
    foreach ($group in $filteredGroups) {
        Write-Host "$i) $($group.DisplayName) (ObjectId: $($group.Id))" -ForegroundColor Cyan
        $i++
    }
    Write-Host "Enter the number of the $role group to use" -ForegroundColor Green
    $selection = Read-Host
    $selectedGroup = $filteredGroups[$selection - 1]
    Write-Host "Selected group: $($selectedGroup.DisplayName)" -ForegroundColor Cyan
    Write-Log "Selected AAD group for: $($selectedGroup.DisplayName) ObjectId: $($selectedGroup.Id)"
    return $selectedGroup
}

function Ensure-RoleAssignment {
    param (
        [Parameter(Mandatory=$true)][string]$ObjectId,
        [Parameter(Mandatory=$true)][string]$RoleDefinitionName,
        [Parameter(Mandatory=$true)][string]$Scope
    )
    $ra = Get-AzRoleAssignment -ObjectId $ObjectId -RoleDefinitionName $RoleDefinitionName -Scope $Scope -ErrorAction SilentlyContinue
    if (-not $ra) {
        Write-Host "Assigning '$RoleDefinitionName' to object $ObjectId at scope $Scope..." -ForegroundColor Cyan
        Write-Log "Assigning '$RoleDefinitionName' to object $ObjectId at scope $Scope..."
        New-AzRoleAssignment -ObjectId $ObjectId -RoleDefinitionName $RoleDefinitionName -Scope $Scope | Out-Null
    } else {
        Write-Host "'$RoleDefinitionName' already assigned to object $ObjectId at scope $Scope." -ForegroundColor Green
        Write-Log "'$RoleDefinitionName' already assigned to object $ObjectId at scope $Scope."
    }
}

# ------------- Main Script Logic Starts Here -------------

#Clear-Host
Write-Host "Preparing environment: checking modules and connecting to services..." -ForegroundColor Cyan
Write-Log "Preparing environment: checking modules and connecting to services..."

$modules = @("Microsoft.Graph")
foreach ($mod in $modules) {
    $isInstalled = Get-Module -ListAvailable -Name $mod
    if (-not $isInstalled) {
        Write-Host "Installing module $mod..." -ForegroundColor Yellow
        Write-Log "Installing module $mod..." "WARN"
        Install-Module $mod -Scope CurrentUser -Force -AllowClobber
        Write-Host "Please restart your PowerShell session to use $mod safely." -ForegroundColor Cyan
        Write-Log "Installed $mod. Please restart PowerShell session." "ERROR"
        exit 0
    }
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: Azure CLI (az) is not installed. Please install it from https://learn.microsoft.com/en-us/cli/azure/install-azure-cli and log in using 'az login'." -ForegroundColor Red
    Write-Log "Azure CLI not installed." "ERROR"
    exit 1
}

if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
    Write-Host "ERROR: Az.Accounts module is not installed. Please run 'Install-Module Az.Accounts -Scope CurrentUser'." -ForegroundColor Red
    Write-Log "Az.Accounts module not installed." "ERROR"
    exit 1
}

Import-Module Az.Accounts -ErrorAction SilentlyContinue

#Clear-Host
$azLoggedIn = $false
try {
    $azAccount = az account show 2>$null | ConvertFrom-Json
    if ($azAccount) {
        $azLoggedIn = $true
        Write-Host "Already logged in to Azure CLI as $($azAccount.user.name)" -ForegroundColor Cyan
        Write-Log "Already logged in to Azure CLI as $($azAccount.user.name)"
    }
} catch {}
if (-not $azLoggedIn) {
    Write-Host "Logging in to Azure CLI..." -ForegroundColor Yellow
    Write-Log "Logging in to Azure CLI..." "WARN"
    az login | Out-Null
    $azAccount = az account show | ConvertFrom-Json
    Write-Host "Logged in to Azure CLI as $($azAccount.user.name)" -ForegroundColor Cyan
    Write-Log "Logged in to Azure CLI as $($azAccount.user.name)"
}

$azPSLoggedIn = $false
try {
    $azContext = Get-AzContext
    if ($azContext) {
        $azPSLoggedIn = $true
        Write-Host "Already connected to Az PowerShell as $($azContext.Account)" -ForegroundColor Cyan
        Write-Log "Already connected to Az PowerShell as $($azContext.Account)"
    }
} catch {}
if (-not $azPSLoggedIn) {
    Write-Host "Connecting to Az PowerShell..." -ForegroundColor Yellow
    Write-Log "Connecting to Az PowerShell..." "WARN"
    Connect-AzAccount | Out-Null
    $azContext = Get-AzContext
    Write-Host "Connected to Az PowerShell as $($azContext.Account)" -ForegroundColor Cyan
    Write-Log "Connected to Az PowerShell as $($azContext.Account)"
}

$graphLoggedIn = $false
try {
    $mgContext = Get-MgContext
    if ($mgContext) {
        $graphLoggedIn = $true
        Write-Host "Already connected to Microsoft Graph as $($mgContext.Account)" -ForegroundColor Cyan
        Write-Log "Already connected to Microsoft Graph as $($mgContext.Account)"
    }
} catch {}
if (-not $graphLoggedIn) {
    Write-Host "Connecting to Microsoft Graph..." -ForegroundColor Yellow
    Write-Log "Connecting to Microsoft Graph..." "WARN"
    Connect-MgGraph -Scopes "Group.Read.All, Application.Read.All, Policy.ReadWrite.ConditionalAccess"
    $mgContext = Get-MgContext
    Write-Host "Connected to Microsoft Graph as $($mgContext.Account)" -ForegroundColor Cyan
    Write-Log "Connected to Microsoft Graph as $($mgContext.Account)"
}

#Clear-Host
Write-Host "Fetching your Azure subscriptions..." -ForegroundColor Yellow
Write-Log "Fetching Azure subscriptions..."
$subs = az account list --output json | ConvertFrom-Json
if (-not $subs) { Write-Host "No subscriptions found for this account." -ForegroundColor Red; Write-Log "No subscriptions found for this account." "ERROR"; exit 1 }
for ($i = 0; $i -lt $subs.Count; $i++) { Write-Host "$($i+1)) $($subs[$i].name)  ($($subs[$i].id))" -ForegroundColor Cyan }
Write-Host "`nEnter the number of the subscription to use:" -ForegroundColor Green
$subChoice = Read-Host
$chosenSub = $subs[$subChoice - 1]
Write-Host "Using subscription: $($chosenSub.name) ($($chosenSub.id))" -ForegroundColor Yellow
Write-Log "Using subscription: $($chosenSub.name) ($($chosenSub.id))"
az account set --subscription $chosenSub.id
Ensure-AzConnection
Select-AzSubscription -SubscriptionId $chosenSub.id

#Clear-Host
Write-Host "Would you like to use an existing resource group, or create a new one?" -ForegroundColor Green
Write-Host "1) Existing" -ForegroundColor Yellow
Write-Host "2) New" -ForegroundColor Yellow
$rgChoice = Read-Host
if ($rgChoice -eq "1") {
    $rgs = az group list --output json | ConvertFrom-Json
    if (-not $rgs) {
        Write-Host "No resource groups found. You must create a new one." -ForegroundColor Red
        Write-Log "No resource groups found. Creating new one." "WARN"
        $rgChoice = "2"
    } else {
        for ($i = 0; $i -lt $rgs.Count; $i++) { Write-Host "$($i+1)) $($rgs[$i].name)  ($($rgs[$i].location))" -ForegroundColor Cyan }
        Write-Host "`nEnter the number of the resource group to use:" -ForegroundColor Green
        $rgSelect = Read-Host
        $resourceGroup = $rgs[$rgSelect - 1].name
        $resourceGroupLocation = $rgs[$rgSelect - 1].location
        Write-Host "Using resource group: $resourceGroup" -ForegroundColor Yellow
        Write-Log "Using resource group: $resourceGroup ($resourceGroupLocation)"
    }
}
if ($rgChoice -eq "2") {
    Write-Host "Enter a name for the new resource group:" -ForegroundColor Green
    $resourceGroup = Read-Host
    Write-Host "Enter the Azure region for the new resource group (e.g., uksouth, eastus):" -ForegroundColor Green
    $resourceGroupLocation = Read-Host
    Write-Host "Creating resource group $resourceGroup in $resourceGroupLocation..." -ForegroundColor Yellow
    Write-Log "Creating resource group $resourceGroup in $resourceGroupLocation..."
    az group create --name $resourceGroup --location $resourceGroupLocation | Out-Null
    Write-Host "Resource group $resourceGroup created." -ForegroundColor Green
    Write-Log "Resource group $resourceGroup created."
}

#Clear-Host
Write-Host "vPAW User and Admin Entra groups" -ForegroundColor Magenta
Write-Log "vPAW User and Admin Entra groups"
Write-Host ""
Write-Host "1) Use existing Entra groups" -ForegroundColor Yellow
Write-Host "2) Create new Entra groups" -ForegroundColor Yellow
Write-Host ""
$groupsChoice = Read-Host "Select an option (Default: 1)"
if ([string]::IsNullOrEmpty($groupsChoice)) { $groupsChoice = "1" }
#Clear-Host

if ($groupsChoice -eq "1") {
    Write-Host "Enter search substring for group names (e.g. 'PAW')" -ForegroundColor Green
    $groupSearch = Read-Host
    $userGroup = $null
    while (-not $userGroup) {
        #Clear-Host
        $userGroup = Select-AADGroupBySubstring -searchSubstring $groupSearch -role "Users (Contributors)"
        if (-not $userGroup) {
            Write-Host "Please try a different search or ensure the group exists." -ForegroundColor Red
            Write-Log "No Users group found with substring $groupSearch" "WARN"
            Write-Host "Enter search substring for Users group" -ForegroundColor Green
            $groupSearch = Read-Host
        }
    }
    $adminGroup = $null
    while (-not $adminGroup) {
        #Clear-Host
        $adminGroup = Select-AADGroupBySubstring -searchSubstring $groupSearch -role "Admins (Elevated Contributors)"
        if (-not $adminGroup) {
            Write-Host "Please try a different search or ensure the group exists." -ForegroundColor Red
            Write-Log "No Admins group found with substring $groupSearch" "WARN"
            Write-Host "Enter search substring for Admins group" -ForegroundColor Green
            $groupSearch = Read-Host
        }
    }
} else {
    Write-Host "Enter a name for the new Users (Contributors) group" -ForegroundColor Green
    $userGroupName = Read-Host
    #Clear-Host
    $userGroup = Create-AADGroup $userGroupName
    Write-Host "Enter a name for the new Admins (Elevated Contributors) group" -ForegroundColor Green
    $adminGroupName = Read-Host
    #Clear-Host
    $adminGroup = Create-AADGroup $adminGroupName
}

#Clear-Host
Write-Host "Enter the resource prefix (Default: vPAW)" -ForegroundColor Green
$DefaultPrefix = Read-Host
if ([string]::IsNullOrEmpty($DefaultPrefix)) { $DefaultPrefix = "vPAW" }

#Clear-Host
Write-Host "Enter the VNet address prefix (Default: 192.168.250.0/24)" -ForegroundColor Green
$vNetAddressPrefix = Read-Host
if ([string]::IsNullOrEmpty($vNetAddressPrefix)) { $vNetAddressPrefix = "192.168.250.0/24" }

#Clear-Host
Write-Host "Enter the Subnet address prefix (Default: 192.168.250.0/24)" -ForegroundColor Green
$subnetAddressPrefix = Read-Host
if ([string]::IsNullOrEmpty($subnetAddressPrefix)) { $subnetAddressPrefix = "192.168.250.0/24" }

$storageAccountName = Get-ValidatedStorageAccountName
$keyVaultName = Get-ValidatedKeyVaultName -DefaultPrefix $DefaultPrefix

Write-Host "Key Vault $keyVaultName will be created by the Bicep deployment." -ForegroundColor Cyan
Write-Log "Key Vault $keyVaultName will be created by the Bicep deployment."

$bicepTemplateFile = Select-BicepTemplateFile

# ---- Additional Names for INF ----
$hostPoolName        = "$DefaultPrefix-HostPool"
$workspaceName       = "$DefaultPrefix-Workspace"
$appGroupName        = "$DefaultPrefix-AppGroup"
$vNetName            = "$DefaultPrefix-vNet"
$subnetName          = "$DefaultPrefix-Subnet"

# --- Save parameters to vPAWConf.inf for later use, including new values
$vPAWConf = @{
    SubscriptionId        = $chosenSub.id
    SubscriptionName      = $chosenSub.name
    ResourceGroup         = $resourceGroup
    ResourceGroupLocation = $resourceGroupLocation
    DefaultPrefix         = $DefaultPrefix
    VNetAddressPrefix     = $vNetAddressPrefix
    SubnetAddressPrefix   = $subnetAddressPrefix
    StorageAccountName    = $storageAccountName
    KeyVaultName          = $keyVaultName
    UsersGroupId          = $userGroup.Id
    UsersGroupName        = $userGroup.DisplayName
    AdminsGroupId         = $adminGroup.Id
    AdminsGroupName       = $adminGroup.DisplayName
    BicepTemplateFile     = $bicepTemplateFile
    HostPoolName          = $hostPoolName
    WorkspaceName         = $workspaceName
    AppGroupName          = $appGroupName
    VNetName              = $vNetName
    SubnetName            = $subnetName
    SavedAt               = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
}
$vPAWConfPath = Join-Path -Path $PSScriptRoot -ChildPath "vPAWConf.inf"
$vPAWConf | ConvertTo-Json | Out-File -Encoding UTF8 -FilePath $vPAWConfPath
Write-Host "`nAll parameters saved for later use in $vPAWConfPath" -ForegroundColor Green
Write-Log "All parameters saved for later use in $vPAWConfPath"

#Clear-Host
Write-Host ""
Write-Host "-----------------------------" -ForegroundColor Magenta
Write-Host "Deployment Parameter Summary:" -ForegroundColor Magenta
Write-Host "Subscription: $($chosenSub.name) ($($chosenSub.id))" -ForegroundColor Yellow
Write-Host "Resource Group: $resourceGroup" -ForegroundColor Yellow
Write-Host "Resource Group Location: $resourceGroupLocation" -ForegroundColor Yellow
Write-Host "DefaultPrefix: $DefaultPrefix" -ForegroundColor Yellow
Write-Host "vNetAddressPrefix: $vNetAddressPrefix" -ForegroundColor Yellow
Write-Host "subnetAddressPrefix: $subnetAddressPrefix" -ForegroundColor Yellow
Write-Host "storageAccountName: $storageAccountName" -ForegroundColor Yellow
Write-Host "keyVaultName: $keyVaultName" -ForegroundColor Yellow
Write-Host "bicepTemplateFile: $bicepTemplateFile" -ForegroundColor Yellow
Write-Host "HostPoolName: $hostPoolName" -ForegroundColor Cyan
Write-Host "WorkspaceName: $workspaceName" -ForegroundColor Cyan
Write-Host "AppGroupName: $appGroupName" -ForegroundColor Cyan
Write-Host "VNetName: $vNetName" -ForegroundColor Cyan
Write-Host "SubnetName: $subnetName" -ForegroundColor Cyan
if ($userGroup) {
    Write-Host "Users (Contributors) Group:" -ForegroundColor Cyan
    Write-Host "  Object ID:   $($userGroup.Id)" -ForegroundColor Cyan
    Write-Host "  DisplayName: $($userGroup.DisplayName)" -ForegroundColor Cyan
}
if ($adminGroup) {
    Write-Host "Admins (Elevated Contributors) Group:" -ForegroundColor Cyan
    Write-Host "  Object ID:   $($adminGroup.Id)" -ForegroundColor Cyan
    Write-Host "  DisplayName: $($adminGroup.DisplayName)" -ForegroundColor Cyan
}
Write-Host "-----------------------------" -ForegroundColor Magenta

Write-Log "Deployment parameter summary displayed."

Write-Host ""
Write-Host "Would you like to deploy the selected Bicep template now? (y/n)" -ForegroundColor Green
$deployNow = Read-Host

if ($deployNow -eq "y") {
    ##Clear-Host
    Write-Host "Starting deployment..." -ForegroundColor Yellow
    Write-Log "Starting deployment..."
    $paramArgs = @(
        "--resource-group", $resourceGroup,
        "--template-file", $bicepTemplateFile,
        "--parameters",
        "DefaultPrefix=$DefaultPrefix",
        "vNetAddressPrefix=$vNetAddressPrefix",
        "subnetAddressPrefix=$subnetAddressPrefix",
        "storageAccountName=$storageAccountName",
        "smbContributorsGroupId=$($userGroup.Id)",
        "smbElevatedContributorsGroupId=$($adminGroup.Id)",
        "keyVaultName=$keyVaultName"
    )
    Write-Host "az deployment group create $($paramArgs -join ' ')" -ForegroundColor Gray
    Write-Log "az deployment group create $($paramArgs -join ' ')"
    az deployment group create @paramArgs
    Write-Host "`nDeployment command executed." -ForegroundColor Green
    Write-Log "Deployment command executed."
} else {
    Write-Host "Deployment skipped. You can deploy later using the collected parameters." -ForegroundColor Yellow
    Write-Log "Deployment skipped by user."
    exit 0
}

# --- Grant Key Vault Access Policy to Current User ---
try {
    $currentUser = (Get-AzContext).Account
    $currentUserObjectId = (Get-AzADUser -UserPrincipalName $currentUser).Id
    Set-AzKeyVaultAccessPolicy -VaultName $keyVaultName -ObjectId $currentUserObjectId -PermissionsToSecrets get,set,list
    Write-Host "Assigned Key Vault access policy for $currentUser ($currentUserObjectId)." -ForegroundColor Green
    Write-Log "Assigned Key Vault access policy for $currentUser ($currentUserObjectId)."
} catch {
    Write-Host "Failed to assign Key Vault access policy: $($_.Exception.Message)" -ForegroundColor Red
    Write-Log "Failed to assign Key Vault access policy: $($_.Exception.Message)" "ERROR"
}

# --- Host Pool Registration Key and Store in Key Vault ---
try {
    $regInfo = Get-AzWvdRegistrationInfo -ResourceGroupName $resourceGroup -HostPoolName $hostPoolName
    if (-not $regInfo.ExpirationTime -or ($regInfo.ExpirationTime -lt (Get-Date))) {
        Write-Host "No valid registration key found or expired. Generating new key..." -ForegroundColor Yellow
        Write-Log "No valid Host Pool registration key found or expired. Generating new key..." "WARN"
        $regInfo = New-AzWvdRegistrationInfo -ResourceGroupName $resourceGroup -HostPoolName $hostPoolName -ExpirationTime (Get-Date).AddDays(1)
    } else {
        Write-Host "Valid registration key found (expires $($regInfo.ExpirationTime))." -ForegroundColor Green
        Write-Log "Valid Host Pool registration key found (expires $($regInfo.ExpirationTime))."
    }
    $secretValue = @{
        RegistrationToken = $regInfo.Token
        ExpiresOn         = $regInfo.ExpirationTime
    } | ConvertTo-Json
    Set-AzKeyVaultSecret -VaultName $keyVaultName -Name "HostPoolRegistrationKey" -Value $secretValue | Out-Null
    Write-Host "Host Pool registration key stored in Key Vault '$keyVaultName' (secret: HostPoolRegistrationKey)" -ForegroundColor Green
    Write-Log "Host Pool registration key stored in Key Vault '$keyVaultName' (secret: HostPoolRegistrationKey)"
} catch {
    Write-Host "Failed to retrieve/store Host Pool registration key: $($_.Exception.Message)" -ForegroundColor Red
    Write-Log "Failed to retrieve/store Host Pool registration key: $($_.Exception.Message)" "ERROR"
}

# --- ENSURE AZ POWERSHELL/GRAPH CONTEXT IS CORRECT POST-DEPLOYMENT ---
#Clear-Host
Write-Host "Ensuring PowerShell and Microsoft Graph context post-deployment..." -ForegroundColor Cyan
Write-Log "Ensuring PowerShell and Microsoft Graph context post-deployment..."
Ensure-AzConnection
Select-AzSubscription -SubscriptionId $chosenSub.id
Ensure-MgGraphConnection

# --- POST-DEPLOYMENT: RBAC, Desktop, CA Exclusion ---
#Clear-Host
Write-Host "Assigning RBAC and configuring AVD resources..." -ForegroundColor Cyan
Write-Log "Assigning RBAC and configuring AVD resources..."

$userGroupId = $userGroup.Id
$adminGroupId = $adminGroup.Id

Ensure-AzConnection
Select-AzSubscription -SubscriptionId $chosenSub.id

Write-Host "Checking for WVD Application Group: $appGroupName in resource group: $resourceGroup" -ForegroundColor Yellow
Write-Log "Checking for WVD Application Group: $appGroupName in resource group: $resourceGroup"
$appGroup = Get-AzWvdApplicationGroup -Name $appGroupName -ResourceGroupName $resourceGroup -ErrorAction SilentlyContinue
if (-not $appGroup) {
    Write-Host "Application Group '$appGroupName' does not exist in resource group '$resourceGroup'." -ForegroundColor Red
    Write-Log "Application Group '$appGroupName' does not exist in resource group '$resourceGroup'." "ERROR"
    Write-Host "Please create it in the Azure Portal or with PowerShell before running the rest of this script."
    exit 1
}
$appGroupPath = $appGroup.Id

Ensure-RoleAssignment -ObjectId $userGroupId -RoleDefinitionName "Desktop Virtualization User" -Scope $appGroupPath
Ensure-RoleAssignment -ObjectId $adminGroupId -RoleDefinitionName "Desktop Virtualization User" -Scope $appGroupPath

#Clear-Host
Write-Host "Session Desktop friendly name configuration..." -ForegroundColor Cyan
Write-Log "Session Desktop friendly name configuration..."
$sessionDesktop = Get-AzWvdDesktop -ResourceGroupName $resourceGroup -ApplicationGroupName $appGroupName -Name "SessionDesktop" -ErrorAction SilentlyContinue
if ($sessionDesktop) {
    $defaultDesktopName = "vPAW Desktop"
    Write-Host "Enter the friendly name for the Session Desktop (Default: $defaultDesktopName):" -ForegroundColor Green
    $sessionDesktopFriendlyName = Read-Host
    if ([string]::IsNullOrEmpty($sessionDesktopFriendlyName)) {
        $sessionDesktopFriendlyName = $defaultDesktopName
    }
    Write-Host "Updating SessionDesktop friendly name to '$sessionDesktopFriendlyName'..." -ForegroundColor Cyan
    Write-Log "Updating SessionDesktop friendly name to '$sessionDesktopFriendlyName'..."
    Update-AzWvdDesktop -ResourceGroupName $resourceGroup -ApplicationGroupName $appGroupName -Name "SessionDesktop" -FriendlyName $sessionDesktopFriendlyName
} else {
    Write-Host "SessionDesktop not found in $appGroupName. Skipping friendly name update." -ForegroundColor Yellow
    Write-Log "SessionDesktop not found in $appGroupName. Skipping friendly name update." "WARN"
}

#Clear-Host
Write-Host "Configuring Storage App Conditional Access Exclusion..." -ForegroundColor Cyan
Write-Log "Configuring Storage App Conditional Access Exclusion..."
Ensure-MgGraphConnection

Write-Host "--------------------------------------" -ForegroundColor Magenta
Write-Host "Storage App Conditional Access Exclusion" -ForegroundColor Magenta
Write-Host "--------------------------------------" -ForegroundColor Magenta

$applications = @(Get-MgApplication -Filter "startswith(displayName, '[Storage Account]')" | Select-Object DisplayName, AppId, Id)
$selectedApp = $null
if ($applications.Count -eq 0) {
    Write-Host "No applications found starting with '[Storage Account]'." -ForegroundColor Red
    Write-Log "No applications found starting with '[Storage Account]'." "ERROR"
    exit
}

$expectedPrefix = "[Storage Account] $storageAccountName"
$selectedApp = $applications | Where-Object { $_.DisplayName -like "$expectedPrefix*" }
if ($selectedApp) {
    Write-Host "Automatically selected storage app: $($selectedApp.DisplayName) (AppId: $($selectedApp.AppId))" -ForegroundColor Green
    Write-Log "Automatically selected storage app: $($selectedApp.DisplayName) (AppId: $($selectedApp.AppId))"
} else {
    Write-Host "No exact match for '$expectedDisplayName'. Please select from the available '[Storage Account]' apps:" -ForegroundColor Yellow
    Write-Log "No exact match for '$expectedDisplayName'. Prompting user for selection."
    for ($i = 0; $i -lt $applications.Count; $i++) {
        Write-Host "$($i+1): $($applications[$i].DisplayName) | AppId: $($applications[$i].AppId) | ObjectId: $($applications[$i].Id)" -ForegroundColor Yellow
    }
    $selection = Read-Host "`nEnter the number of the application you want to select" -ForegroundColor Green
    if ($selection -match '^\d+$' -and $selection -ge 1 -and $selection -le $applications.Count) {
        $selectedApp = $applications[$selection - 1]
        Write-Log "User selected storage app: $($selectedApp.DisplayName) (AppId: $($selectedApp.AppId))"
    }
}
if (-not $selectedApp) {
    Write-Host "No storage app selected." -ForegroundColor Red
    Write-Log "No storage app selected." "ERROR"
    exit
}
$CAExclude = $selectedApp.AppId
$ObjectId = $selectedApp.Id
Write-Host "`nYou selected: $($selectedApp.DisplayName)" -ForegroundColor Cyan
Write-Host "AppId stored in `$CAExclude: $CAExclude" -ForegroundColor Cyan
Write-Host "ObjectId: $ObjectId" -ForegroundColor Cyan
Write-Log "Storage App selected: $($selectedApp.DisplayName) AppId: $CAExclude ObjectId: $ObjectId"

#Clear-Host
Write-Host "Reviewing Conditional Access policies..." -ForegroundColor Cyan
Write-Log "Reviewing Conditional Access policies..."
$policies = Get-MgIdentityConditionalAccessPolicy
$filteredPolicies = $policies | Where-Object {
    $_.Conditions.Applications.IncludeApplications -contains "All" -and
    $_.DisplayName -notlike "*Microsoft Managed*"
}
Write-Host "`nConditional Access policies targeting ALL apps (excluding 'Microsoft Managed'):" -ForegroundColor Yellow
$filteredPolicies | Select-Object DisplayName, Id, State | Format-Table -AutoSize
Write-Log "Conditional Access policies targeting ALL apps (excluding Microsoft Managed) enumerated."

foreach ($policy in $filteredPolicies) {
    if ($policy.DisplayName -like "Microsoft-managed*") {
        Write-Host "`nSkipping Microsoft-managed policy '$($policy.DisplayName)' (cannot update excluded apps)." -ForegroundColor Yellow
        Write-Log "Skipping Microsoft-managed policy '$($policy.DisplayName)'; cannot update excluded apps." "WARN"
        continue
    }
    $excludedApps = @($policy.Conditions.Applications.ExcludeApplications)
    if (-not $excludedApps.Contains($CAExclude)) {
        $newExcludedApps = $excludedApps + $CAExclude
        $updateBody = @{
            Conditions = @{
                Applications = @{
                    IncludeApplications = $policy.Conditions.Applications.IncludeApplications
                    ExcludeApplications = $newExcludedApps
                }
            }
        }
        Write-Host "`nUpdating policy '$($policy.DisplayName)' (Id: $($policy.Id)) to exclude AppId $CAExclude..." -ForegroundColor Cyan
        Write-Log "Updating policy '$($policy.DisplayName)' (Id: $($policy.Id)) to exclude AppId $CAExclude..."
        try {
            Update-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId $policy.Id -BodyParameter $updateBody
            Write-Host "Policy '$($policy.DisplayName)' updated." -ForegroundColor Green
            Write-Log "Policy '$($policy.DisplayName)' updated to exclude AppId $CAExclude."
        } catch {
            Write-Host "Failed to update policy '$($policy.DisplayName)': $($_.Exception.Message)" -ForegroundColor Red
            Write-Log "Failed to update policy '$($policy.DisplayName)': $($_.Exception.Message)" "ERROR"
        }
    } else {
        Write-Host "`nPolicy '$($policy.DisplayName)' already excludes AppId $CAExclude." -ForegroundColor Green
        Write-Log "Policy '$($policy.DisplayName)' already excludes AppId $CAExclude."
    }
}

#Clear-Host
Write-Host "---------------------------------------------------------------------------------------------------------------" -ForegroundColor Green
Write-Host "Please verify the CA exclusions and permissions in the Entra Portal." -ForegroundColor Green
Write-Host ""
Write-Host "IMPORTANT: Grant Admin Consent in Azure Portal" -ForegroundColor Green
Write-Host "Go to: Azure Portal > App registrations > $($selectedApp.DisplayName) > API permissions > Grant admin consent" -ForegroundColor Green
Write-Host "This is required for openid, profile, and User.Read delegated permissions to be effective." -ForegroundColor Green
Write-Host "---------------------------------------------------------------------------------------------------------------" -ForegroundColor Green
Write-Log "Script completed. Please verify CA exclusions and grant admin consent for $($selectedApp.DisplayName) in Azure Portal."

# --- Prompt to deploy a vPAW session host ---
Write-Host ""
Write-Host "Would you like to deploy a vPAW session host? (y/n)" -ForegroundColor Green
$deploySessionHost = Read-Host

if ($deploySessionHost -eq "n") {
    Write-Host "Deployment complete." -ForegroundColor Green
    exit 0
} elseif ($deploySessionHost -eq "y") {
    # List all .ps1 files in the current directory
    $ps1Files = Get-ChildItem -Path . -File | Where-Object { $_.Extension -eq ".ps1" }
    if (-not $ps1Files) {
        Write-Host "No .ps1 files found in the current directory." -ForegroundColor Red
        exit 1
    }
    Write-Host "Select a PowerShell script to run:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $ps1Files.Count; $i++) {
        Write-Host "$($i+1)) $($ps1Files[$i].Name)" -ForegroundColor Yellow
    }
    Write-Host "Enter the number of the script to run:" -ForegroundColor Green
    while ($true) {
        $selection = Read-Host
        if ($selection -match '^\d+$' -and $selection -ge 1 -and $selection -le $ps1Files.Count) {
            $selectedScript = $ps1Files[$selection - 1].FullName
            Write-Host "Running script: $selectedScript" -ForegroundColor Cyan
            try {
                & $selectedScript
            } catch {
                Write-Host "Failed to run script: $($_.Exception.Message)" -ForegroundColor Red
            }
            break
        } else {
            Write-Host "Invalid selection. Please enter a valid number." -ForegroundColor Red
        }
    }
} else {
    Write-Host "Invalid input. Please enter 'y' or 'n'." -ForegroundColor Red
    exit 1
}