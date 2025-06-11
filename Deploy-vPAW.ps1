# ==========================
# Shared Utility Functions
# ==========================

function Write-Banner {
    param([string]$Heading)
    $bannerWidth = 51
    $innerWidth = $bannerWidth - 2
    $bannerLine = ('#' * $bannerWidth)
    $emptyLine = ('#' + (' ' * ($bannerWidth - 2)) + '#')
    $centered = $Heading.Trim()
    $centered = $centered.PadLeft(([math]::Floor(($centered.Length + $innerWidth) / 2))).PadRight($innerWidth)
    Write-Host ""
    Write-Host $bannerLine -ForegroundColor Cyan
    Write-Host $emptyLine -ForegroundColor Cyan
    Write-Host ("#"+$centered+"#") -ForegroundColor Cyan
    Write-Host $emptyLine -ForegroundColor Cyan
    Write-Host $bannerLine -ForegroundColor Cyan
    Write-Host ""
}

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

function Ensure-Module {
    param([string]$ModuleName)
    $isInstalled = Get-Module -ListAvailable -Name $ModuleName
    if (-not $isInstalled) {
        Write-Host "Installing module $ModuleName..." -ForegroundColor Yellow
        Write-Log "Installing module $ModuleName..." "WARN"
        Install-Module $ModuleName -Scope CurrentUser -Force -AllowClobber
        Write-Host "Please restart your PowerShell session to use $ModuleName safely." -ForegroundColor Cyan
        Write-Log "Installed $ModuleName. Please restart PowerShell session." "ERROR"
        exit 0
    }
}

function Ensure-AzCli {
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        Write-Host "ERROR: Azure CLI (az) is not installed." -ForegroundColor Red
        Write-Log "Azure CLI not installed." "ERROR"
        exit 1
    }
}

function Ensure-AzAccountModule {
    if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
        Write-Host "ERROR: Az.Accounts module is not installed." -ForegroundColor Red
        Write-Log "Az.Accounts module not installed." "ERROR"
        exit 1
    }
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
function Deploy-CoreInfra {

#############################
#                           #
#   Environment Preparation #
#                           #
#############################
Clear-Host
Write-Banner "Environment Preparation"
# Ensure required modules are present
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

# Authenticate to Azure CLI
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

# Authenticate to Az PowerShell
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

# Authenticate to Microsoft Graph
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
Write-Log "Environment preparation complete."
Start-Sleep 1

#############################
#                           #
#    Subscription Selection #
#                           #
#############################
Clear-Host
Write-Banner "Subscription Selection"
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
Select-AzSubscription -SubscriptionId $chosenSub.id
Write-Log "Subscription selection complete."
Start-Sleep 1

# --- TENANT ID ---
try {
    $tenantId = (Get-AzContext).Tenant.Id
} catch {
    $tenantId = (az account show --query tenantId -o tsv)
}

#############################
#   Resource Group Setup    #
#############################
Clear-Host
Write-Banner "Resource Group Setup"

while ($true) {
    Write-Host "Would you like to use an existing resource group, or create a new one?" -ForegroundColor Green
    Write-Host "1) Existing" -ForegroundColor Yellow
    Write-Host "2) New" -ForegroundColor Yellow
    Write-Host "0) Go Back" -ForegroundColor Yellow
    $rgChoice = Read-Host

    if ($rgChoice -eq "0") {
        Write-Host "Returning to previous menu..." -ForegroundColor Cyan
        # Implement what "go back" means for your script here,
        # such as breaking out to a previous function/menu.
        break
    }

    if ($rgChoice -eq "1") {
        $rgs = az group list --output json | ConvertFrom-Json
        if (-not $rgs) {
            Write-Host "No resource groups found. You must create a new one." -ForegroundColor Red
            Write-Log "No resource groups found. Creating new one." "WARN"
            $rgChoice = "2"
        } else {
            for ($i = 0; $i -lt $rgs.Count; $i++) { Write-Host "$($i+1)) $($rgs[$i].name)  ($($rgs[$i].location))" -ForegroundColor Cyan }
            Write-Host "0) Go Back" -ForegroundColor Yellow
            Write-Host "`nEnter the number of the resource group to use:" -ForegroundColor Green
            $rgSelect = Read-Host
            if ($rgSelect -eq "0") { continue }
            $resourceGroup = $rgs[$rgSelect - 1].name
            $resourceGroupLocation = $rgs[$rgSelect - 1].location
            Write-Host "Using resource group: $resourceGroup" -ForegroundColor Yellow
            Write-Log "Using resource group: $resourceGroup ($resourceGroupLocation)"
            break
        }
    }
    if ($rgChoice -eq "2") {
        Write-Host "Enter a name for the new resource group (or 0 to go back):" -ForegroundColor Green
        $resourceGroup = Read-Host
        if ($resourceGroup -eq "0") { continue }
        Write-Host "Enter the Azure region for the new resource group (e.g., uksouth, eastus or 0 to go back):" -ForegroundColor Green
        $resourceGroupLocation = Read-Host
        if ($resourceGroupLocation -eq "0") { continue }
        Write-Host "Creating resource group $resourceGroup in $resourceGroupLocation..." -ForegroundColor Yellow
        Write-Log "Creating resource group $resourceGroup in $resourceGroupLocation..."
        az group create --name $resourceGroup --location $resourceGroupLocation | Out-Null
        Write-Host "Resource group $resourceGroup created." -ForegroundColor Green
        Write-Log "Resource group $resourceGroup created."
        break
    }
    Write-Host "Invalid selection. Please enter a valid option." -ForegroundColor Red
}
Write-Log "Resource group setup complete."
Start-Sleep 1

#############################
#                           #
# Entra Group Selection/    #
#        Creation           #
#                           #
#############################
Clear-Host
Write-Banner "Entra Group Selection/Creation"

function Create-AADGroup([string]$groupName) {
    # Create a new Azure AD security group
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
    # Present filtered AAD groups for user selection
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

Write-Host "vPAW User and Admin Entra groups" -ForegroundColor Magenta
Write-Host ""
Write-Host "1) Use existing Entra groups" -ForegroundColor Yellow
Write-Host "2) Create new Entra groups" -ForegroundColor Yellow
Write-Host ""
$groupsChoice = Read-Host "Select an option (Default: 1)"
if ([string]::IsNullOrEmpty($groupsChoice)) { $groupsChoice = "1" }

if ($groupsChoice -eq "1") {
    Write-Host "Enter search substring for group names (e.g. 'PAW')" -ForegroundColor Green
    $groupSearch = Read-Host
    $userGroup = $null
    while (-not $userGroup) {
        $userGroup = Select-AADGroupBySubstring -searchSubstring $groupSearch -role "Users (Contributors)"
        if (-not $userGroup) {
            Write-Host "Please try a different search or ensure the group exists." -ForegroundColor Red
            Write-Host "Enter search substring for Users group" -ForegroundColor Green
            $groupSearch = Read-Host
        }
    }
    $adminGroup = $null
    while (-not $adminGroup) {
        $adminGroup = Select-AADGroupBySubstring -searchSubstring $groupSearch -role "Admins (Elevated Contributors)"
        if (-not $adminGroup) {
            Write-Host "Please try a different search or ensure the group exists." -ForegroundColor Red
            Write-Host "Enter search substring for Admins group" -ForegroundColor Green
            $groupSearch = Read-Host
        }
    }
} else {
    Write-Host "Enter a name for the new Users (Contributors) group" -ForegroundColor Green
    $userGroupName = Read-Host
    $userGroup = Create-AADGroup $userGroupName
    Write-Host "Enter a name for the new Admins (Elevated Contributors) group" -ForegroundColor Green
    $adminGroupName = Read-Host
    $adminGroup = Create-AADGroup $adminGroupName
}
Write-Log "Entra group setup complete."
Start-Sleep 1

#############################
#                           #
# Deployment Parameter Input#
#                           #
#############################
Clear-Host
Write-Banner "Deployment Parameter Input"

function Get-ValidatedStorageAccountName {
    # Validate and check storage account name availability, suggest alternates if needed
    while ($true) {
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

function Select-CoreInfraBicepFile {
    # Prefer CoreInfra bicep file, else allow user selection
    $allBicepFiles = Get-ChildItem -Path . -File | Where-Object { $_.Name -match '\.bicep$' -or $_.Name -match '\.BICEP$' }
    $pattern = '(?i)(vPAW[\s\-]*)?Core[\s\-]*Infra'
    $coreInfraFiles = $allBicepFiles | Where-Object { $_.Name -match $pattern }

    if ($coreInfraFiles.Count -eq 1) {
        $file = $coreInfraFiles[0].Name
        Write-Host "Found core infra Bicep file: $file"
        Write-Host "Use this file? (y/n) [default: y]" -ForegroundColor Green -NoNewline
        $resp = Read-Host
        if ([string]::IsNullOrWhiteSpace($resp) -or $resp -eq "y") {
            return $file
        }
    } elseif ($coreInfraFiles.Count -gt 1) {
        Write-Host "Multiple core infra Bicep files found:" -ForegroundColor Cyan
        for ($i = 0; $i -lt $coreInfraFiles.Count; $i++) {
            Write-Host "$($i + 1)) $($coreInfraFiles[$i].Name)" -ForegroundColor Cyan
        }
        Write-Host "Select one by number or press Enter to list all bicep files:" -ForegroundColor Green -NoNewline
        $choice = Read-Host
        if ($choice -match '^\d+$' -and $choice -gt 0 -and $choice -le $coreInfraFiles.Count) {
            return $coreInfraFiles[$choice - 1].Name
        }
    }

    if (-not $allBicepFiles -or $allBicepFiles.Count -eq 0) {
        Write-Host "No .bicep template files found." -ForegroundColor Red
        return $null
    }
    Write-Host "Available .bicep files:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $allBicepFiles.Count; $i++) {
        Write-Host "$($i + 1)) $($allBicepFiles[$i].Name)" -ForegroundColor Cyan
    }
    Write-Host "Enter the number:" -ForegroundColor Green
    while ($true) {
        $selection = Read-Host
        if ($selection -match '^\d+$' -and $selection -gt 0 -and $selection -le $allBicepFiles.Count) {
            $chosenFile = $allBicepFiles[$selection - 1].Name
            Write-Host "Selected Bicep template: $chosenFile" -ForegroundColor Cyan
            return $chosenFile
        } else {
            Write-Host "Invalid selection." -ForegroundColor Red
        }
    }
}

Write-Host "Enter the resource prefix (Default: vPAW)" -ForegroundColor Green
$DefaultPrefix = Read-Host
if ([string]::IsNullOrEmpty($DefaultPrefix)) { $DefaultPrefix = "vPAW" }

Write-Host "Enter the VNet address prefix (Default: 192.168.250.0/24)" -ForegroundColor Green
$vNetAddressPrefix = Read-Host
if ([string]::IsNullOrEmpty($vNetAddressPrefix)) { $vNetAddressPrefix = "192.168.250.0/24" }

Write-Host "Enter the Subnet address prefix (Default: 192.168.250.0/24)" -ForegroundColor Green
$subnetAddressPrefix = Read-Host
if ([string]::IsNullOrEmpty($subnetAddressPrefix)) { $subnetAddressPrefix = "192.168.250.0/24" }

$storageAccountName = Get-ValidatedStorageAccountName
$bicepTemplateFile = Select-CoreInfraBicepFile

# Additional Names for INF
$hostPoolName        = "$DefaultPrefix-HostPool"
$workspaceName       = "$DefaultPrefix-Workspace"
$appGroupName        = "$DefaultPrefix-AppGroup"
$vNetName            = "$DefaultPrefix-vNet"
$subnetName          = "$DefaultPrefix-Subnet"

# Detect and record Bicep files for both CoreInfra and SessionHost
$allBicepFiles = Get-ChildItem -Path . -File | Where-Object { $_.Extension -eq ".bicep" -or $_.Extension -eq ".BICEP" }
$coreInfraBicep = $bicepTemplateFile
$sessionHostBicep = $allBicepFiles | Where-Object { $_.Name -ne $coreInfraBicep }
if ($sessionHostBicep.Count -eq 1) {
    $sessionHostBicepFile = $sessionHostBicep[0].Name
} else {
    $sessionHostBicepFile = ""
}

# Save parameters for reuse
$vPAWConf = @{
    TenantId              = $tenantId
    SubscriptionId        = $chosenSub.id
    SubscriptionName      = $chosenSub.name
    ResourceGroup         = $resourceGroup
    ResourceGroupLocation = $resourceGroupLocation
    DefaultPrefix         = $DefaultPrefix
    VNetAddressPrefix     = $vNetAddressPrefix
    SubnetAddressPrefix   = $subnetAddressPrefix
    StorageAccountName    = $storageAccountName
    UsersGroupId          = $userGroup.Id
    UsersGroupName        = $userGroup.DisplayName
    AdminsGroupId         = $adminGroup.Id
    AdminsGroupName       = $adminGroup.DisplayName
    BicepTemplateFile     = $bicepTemplateFile
    CoreInfraBicep        = $coreInfraBicep
    SessionHostBicep      = $sessionHostBicepFile
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
Write-Log "Deployment parameter input complete."
Start-Sleep 1

#############################
#                           #
# Bicep Template Deployment #
#                           #
#############################
Clear-Host
Write-Banner "Bicep Template Deployment"
Write-Host ""
Write-Host "-----------------------------" -ForegroundColor Magenta
Write-Host "Deployment Parameter Summary:" -ForegroundColor Magenta
Write-Host "TenantId: $tenantId" -ForegroundColor Yellow
Write-Host "Subscription: $($chosenSub.name) ($($chosenSub.id))" -ForegroundColor Yellow
Write-Host "Resource Group: $resourceGroup" -ForegroundColor Yellow
Write-Host "Resource Group Location: $resourceGroupLocation" -ForegroundColor Yellow
Write-Host "DefaultPrefix: $DefaultPrefix" -ForegroundColor Yellow
Write-Host "vNetAddressPrefix: $vNetAddressPrefix" -ForegroundColor Yellow
Write-Host "subnetAddressPrefix: $subnetAddressPrefix" -ForegroundColor Yellow
Write-Host "storageAccountName: $storageAccountName" -ForegroundColor Yellow
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
Write-Host "Would you like to deploy the selected Bicep template now? (y/n) [Default: y]" -ForegroundColor Green
$deployNow = Read-Host
if ([string]::IsNullOrWhiteSpace($deployNow)) { $deployNow = "y" }  # Default to "y" if Enter is pressed


if ($deployNow -eq "y") {
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
        "smbElevatedContributorsGroupId=$($adminGroup.Id)"
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
Write-Log "Deployment section complete."
Start-Sleep 1

#############################
#                           #
#     Post-Deployment:      #
#   RBAC & AVD Config       #
#                           #
#############################
Clear-Host
Write-Banner "Post-Deployment: RBAC & AVD Config"


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

Ensure-AzConnection
Select-AzSubscription -SubscriptionId $chosenSub.id

# --- Start: Resource Group RBAC Assignments ---
$resourceGroupScope = "/subscriptions/$($chosenSub.id)/resourceGroups/$resourceGroup"

# 1. Virtual Machine User Login for vPAW/AVD users group
Ensure-RoleAssignment -ObjectId $userGroup.Id -RoleDefinitionName "Virtual Machine User Login" -Scope $resourceGroupScope

# 2. Virtual Machine User Login for vPAW/AVD admins group
Ensure-RoleAssignment -ObjectId $adminGroup.Id -RoleDefinitionName "Virtual Machine User Login" -Scope $resourceGroupScope

# 3. Virtual Machine Administrator Login for vPAW/AVD admins group
Ensure-RoleAssignment -ObjectId $adminGroup.Id -RoleDefinitionName "Virtual Machine Administrator Login" -Scope $resourceGroupScope

# 4. Desktop Virtualization Power On Contributor for AVD Service Principal
$avdServicePrincipal = Get-AzADServicePrincipal -DisplayName "Azure Virtual Desktop"
if ($avdServicePrincipal) {
    Ensure-RoleAssignment -ObjectId $avdServicePrincipal.Id -RoleDefinitionName "Desktop Virtualization Power On Contributor" -Scope $resourceGroupScope
}
# --- End: Resource Group RBAC Assignments ---

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

$userGroupId = $userGroup.Id
$adminGroupId = $adminGroup.Id

# Assign Desktop Virtualization User at App Group scope
Ensure-RoleAssignment -ObjectId $userGroupId -RoleDefinitionName "Desktop Virtualization User" -Scope $appGroupPath
Ensure-RoleAssignment -ObjectId $adminGroupId -RoleDefinitionName "Desktop Virtualization User" -Scope $appGroupPath

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
Write-Log "RBAC and AVD configuration complete."
Start-Sleep 1

#############################
#                           #
# Conditional Access Policy  #
#        Exclusion          #
#                           #
#############################
Clear-Host
Write-Banner "Conditional Access Policy Exclusion"
Ensure-MgGraphConnection

Write-Host "--------------------------------------" -ForegroundColor Magenta
Write-Host "Storage App Conditional Access Exclusion" -ForegroundColor Magenta
Write-Host "--------------------------------------" -ForegroundColor Magenta

# Make sure $storageAccountName is set before this block!
# Ensure $storageAccountName is set before this
$expectedPrefix = "[Storage Account] $storageAccountName.file.core.windows.net"
$applications = @(Get-MgApplication -Filter "startswith(displayName, '[Storage Account]')" | Select-Object DisplayName, AppId, Id)
$selectedApp = $null

if ($applications.Count -eq 0) {
    Write-Host "No applications found starting with '[Storage Account]'." -ForegroundColor Red
    Write-Log "No applications found starting with '[Storage Account]'." "ERROR"
    exit
}

# Find exact match for [Storage Account] $storageAccountName.file.core.windows.net
$matchingApps = $applications | Where-Object {
    $_.DisplayName.Trim().ToLower() -eq $expectedPrefix.ToLower()
}

if ($matchingApps.Count -eq 1) {
    $selectedApp = $matchingApps[0]
    Write-Host "Automatically selected storage app: $($selectedApp.DisplayName) (AppId: $($selectedApp.AppId))" -ForegroundColor Green
    Write-Log "Automatically selected storage app: $($selectedApp.DisplayName) (AppId: $($selectedApp.AppId))"
} elseif ($matchingApps.Count -gt 1) {
    Write-Host "Multiple storage apps found for '$expectedPrefix'. Please select:" -ForegroundColor Yellow
    for ($i = 0; $i -lt $matchingApps.Count; $i++) {
        Write-Host "$($i+1): $($matchingApps[$i].DisplayName) | AppId: $($matchingApps[$i].AppId) | ObjectId: $($matchingApps[$i].Id)" -ForegroundColor Yellow
    }
    $selection = Read-Host "`nEnter the number of the application you want to select"
    if ($selection -match '^\d+$' -and $selection -ge 1 -and $selection -le $matchingApps.Count) {
        $selectedApp = $matchingApps[$selection - 1]
        Write-Log "User selected storage app: $($selectedApp.DisplayName) (AppId: $($selectedApp.AppId))"
    }
} else {
    # No match for "[Storage Account] $storageAccountName.file.core.windows.net", let user pick from all Storage Account apps
    Write-Host "No app found starting with '$expectedPrefix'. Please select from all '[Storage Account]' apps:" -ForegroundColor Yellow
    for ($i = 0; $i -lt $applications.Count; $i++) {
        Write-Host "$($i+1): $($applications[$i].DisplayName) | AppId: $($applications[$i].AppId) | ObjectId: $($applications[$i].Id)" -ForegroundColor Yellow
    }
    $selection = Read-Host "`nEnter the number of the application you want to select"
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

Write-Host "---------------------------------------------------------------------------------------------------------------" -ForegroundColor Green
Write-Host "Please verify the CA exclusions and permissions in the Entra Portal." -ForegroundColor Green
Write-Host ""
Write-Host "IMPORTANT: Grant Admin Consent in Azure Portal" -ForegroundColor Green
Write-Host "Go to: Azure Portal > App registrations > $($selectedApp.DisplayName) > API permissions > Grant admin consent" -ForegroundColor Green
Write-Host "This is required for openid, profile, and User.Read delegated permissions to be effective." -ForegroundColor Green
Write-Host "---------------------------------------------------------------------------------------------------------------" -ForegroundColor Green
Write-Log "Script completed. Please verify CA exclusions and grant admin consent for $($selectedApp.DisplayName) in Azure Portal."
Write-Log "Conditional Access exclusion complete."
Start-Sleep 1

#############################
#                           #
#     vPAW Session Host     #
#      Deployment (Opt)     #
#                           #
#############################
Clear-Host
Write-Banner "vPAW Session Host Deployment (Opt)"
Write-Host ""
Write-Host "Would you like to deploy a vPAW session host? (y/n) [Default: y]" -ForegroundColor Green
$deploySessionHost = Read-Host
if ([string]::IsNullOrWhiteSpace($deploySessionHost)) { $deploySessionHost = "y" }

if ($deploySessionHost -eq "n") {
    Write-Host "Deployment complete." -ForegroundColor Green
    exit 0
} elseif ($deploySessionHost -eq "y") {
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

Write-Host "`n=== VirtualPAW Deployment Script Complete ===" -ForegroundColor Green
Write-Host "Please verify all actions in Azure Portal as instructed." -ForegroundColor Yellow
Write-Log "Script execution complete."
}

function Deploy-SessionHost {
    <#
.SYNOPSIS
    Fully interactive and repeatable deployment workflow for VirtualPAW personal session hosts in Azure.
    - Loads parameters from previous deployment (vPAWconf.inf) if available, allowing full, partial, or no reuse.
    - Connects to and authenticates with Azure CLI, Az PowerShell, and Microsoft Graph.
    - Guides you through selection/creation of subscription, resource group, host pool, VNet, subnet, and deployment parameters.
    - Prefers SessionHost-related Bicep file but allows full selection if not found.
    - Supports deploying one or more session hosts, collecting user details per host, setting admin credentials, DNS, and prep scripts.
    - Generates and invalidates host pool registration key for secure deployment.
    - Assigns users to their personal session hosts.
    - Optionally adds users to vPAW Users/Admins groups based on selection and .inf configuration.
    - Logs all major activities, prompts, and errors for traceability.
    - Persists session config for future ease of use.
.DESCRIPTION
    - Ensures all required modules and CLIs are present, and authenticates to Azure/Graph.
    - Loads, displays, and allows reuse or override of previous session configuration if present.
    - Prompts for missing or overridden deployment details: subscription, resource group, locations, host pool, VNet, subnet, etc.
    - Securely collects per-host user details and administrator credentials.
    - Selects an appropriate Bicep template (SessionHost-prioritized).
    - Deploys each session host, setting the assignedUser property to the correct user for personal host pools.
    - Invalidates registration key post-deployment.
    - Saves all deployment parameters for future runs.
    - All actions are logged to vPAWSessionHost.log.
#>

function Write-Banner {
    param([string]$Heading)
    $bannerWidth = 51
    $innerWidth = $bannerWidth - 2
    $bannerLine = ('#' * $bannerWidth)
    $emptyLine = ('#' + (' ' * ($bannerWidth - 2)) + '#')
    $centered = $Heading.Trim()
    $centered = $centered.PadLeft(([math]::Floor(($centered.Length + $innerWidth) / 2))).PadRight($innerWidth)
    Write-Host ""
    Write-Host $bannerLine -ForegroundColor Cyan
    Write-Host $emptyLine -ForegroundColor Cyan
    Write-Host ("#"+$centered+"#") -ForegroundColor Cyan
    Write-Host $emptyLine -ForegroundColor Cyan
    Write-Host $bannerLine -ForegroundColor Cyan
    Write-Host ""
}

#############################
#                           #
#   Config and Log Setup    #
#                           #
#############################
# 
$confFile = "vPAWconf.inf"
$logFile = "vPAWSessionHost.log"
$sessionParams = @{}
$fields = @(
    @{Name="SubscriptionName";Prompt="Subscription name";Var="subscriptionName"},
    @{Name="SubscriptionId";Prompt="Subscription ID";Var="subscriptionId"},
    @{Name="ResourceGroup";Prompt="Resource group";Var="resourceGroup"},
    @{Name="ResourceGroupLocation";Prompt="Resource group location";Var="resourceGroupLocation"},
    @{Name="HostPoolName";Prompt="Host pool name";Var="hostPoolName"},
    @{Name="VNetName";Prompt="Virtual network name";Var="vNetName"},
    @{Name="SubnetName";Prompt="Subnet name";Var="subnetName"},
    @{Name="DefaultPrefix";Prompt="Session host prefix";Var="sessionHostPrefix"},
    @{Name="BicepTemplateFile";Prompt="Bicep template file";Var="bicepTemplateFile"},
    @{Name="vPAWUsersGroupDisplayName";Prompt="vPAW Users group display name";Var="vPAWUsersGroupDisplayName"},
    @{Name="vPAWUsersGroupObjectId";Prompt="vPAW Users group objectId";Var="vPAWUsersGroupObjectId"},
    @{Name="vPAWAdminsGroupDisplayName";Prompt="vPAW Admins group display name";Var="vPAWAdminsGroupDisplayName"},
    @{Name="vPAWAdminsGroupObjectId";Prompt="vPAW Admins group objectId";Var="vPAWAdminsGroupObjectId"}
)
function Write-Log {
    param ([string]$Message)
    $timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    Add-Content -Path $logFile -Value "$timestamp - $Message"
}
Write-Log "Script started by $env:USERNAME"
Clear-Host

###################################################
#                                                 #
#              Load Previous Session              #
#                                                 #
###################################################
Write-Banner "Load Previous Session"
$skipPrompts = $false
$lastBicepFile = $null

if (Test-Path $confFile) {
    try {
        $sessionParams = Get-Content $confFile -Raw | ConvertFrom-Json
        $lastBicepFile = $sessionParams.BicepTemplateFile
        Write-Host "Previous session configuration found:" -ForegroundColor Yellow
        $sessionParams.PSObject.Properties | ForEach-Object {
            Write-Host ("{0}: {1}" -f $_.Name, $_.Value) -ForegroundColor Cyan
        }
        Write-Log "Loaded previous session config from $confFile"
        Write-Host "`nWould you like to use these settings? (y = use all, n = ignore, o = override some) [Default: y]" -ForegroundColor Green -NoNewline
        $usePrev = Read-Host
        if ([string]::IsNullOrWhiteSpace($usePrev)) { $usePrev = "y" }
        Write-Log "User chose to reuse previous session config: $usePrev"
        if ($usePrev -eq "y") {
            $skipPrompts = $true
        } elseif ($usePrev -eq "o") {
            foreach ($field in $fields) {
                $currentValue = $sessionParams[$field.Name]
                if ($field.Name -eq "BicepTemplateFile") {
                    Write-Host ("{0} [{1}] (will exclude this from selection): " -f $field.Prompt, $currentValue) -ForegroundColor Yellow
                    $input = $null
                } else {
                    Write-Host ("{0} [{1}]: " -f $field.Prompt, $currentValue) -ForegroundColor Yellow -NoNewline
                    $input = Read-Host
                }
                if (-not [string]::IsNullOrWhiteSpace($input)) {
                    $sessionParams[$field.Name] = $input
                    Write-Log "Field override: $($field.Name) set to $input"
                } else {
                    Write-Log "Field override: $($field.Name) kept as $currentValue"
                }
            }
            $skipPrompts = $true
        }
    } catch {
        Write-Host "Failed to parse $confFile. Will continue as normal." -ForegroundColor Red
        Write-Log "Failed to parse $confFile"
    }
}
Clear-Host
###################################################
#                                                 #
#              Bicep File Selection               #
#                                                 #
###################################################
Write-Banner "Bicep File Selection"
function Select-SessionHostBicepFile {
    $defaultFile = "vPAW-Deploy-SessionHost.bicep"
    $allBicepFiles = Get-ChildItem -Path . -File | Where-Object { $_.Name -match '\.bicep$' -or $_.Name -match '\.BICEP$' }

    # Try to use the default file if it exists
    $default = $allBicepFiles | Where-Object { $_.Name -eq $defaultFile }
    if ($default) {
        Write-Host "Default session host Bicep file detected: $defaultFile" -ForegroundColor Green
        Write-Host "Use this file? (y/n) [default: y]" -ForegroundColor Green -NoNewline
        $resp = Read-Host
        if ([string]::IsNullOrWhiteSpace($resp) -or $resp -eq "y") {
            Write-Log "Auto-selected session host bicep file: $defaultFile"
            return $defaultFile
        }
    }

    # If not using default, or default not found, list all Bicep files for selection
    if (-not $allBicepFiles -or $allBicepFiles.Count -eq 0) {
        Write-Host "No .bicep template files found." -ForegroundColor Red
        Write-Log "No .bicep template files found." "ERROR"
        return $null
    }

    Write-Host "Available .bicep files:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $allBicepFiles.Count; $i++) {
        Write-Host "$($i + 1)) $($allBicepFiles[$i].Name)" -ForegroundColor Cyan
    }
    Write-Host "Enter the number of the Bicep file to use:" -ForegroundColor Green

    while ($true) {
        $selection = Read-Host
        if ($selection -match '^\d+$' -and $selection -gt 0 -and $selection -le $allBicepFiles.Count) {
            $chosenFile = $allBicepFiles[$selection - 1].Name
            Write-Host "Selected Bicep template: $chosenFile" -ForegroundColor Cyan
            Write-Log "User manually selected bicep file: $chosenFile"
            return $chosenFile
        } else {
            Write-Host "Invalid selection." -ForegroundColor Red
        }
    }
}

# Confirm Bicep file from inf, or prompt for selection
$shouldUseInfFile = $false

if ($sessionParams.BicepTemplateFile -and (Test-Path $sessionParams.BicepTemplateFile)) {
    Write-Host "Previous session refers to Bicep file: $($sessionParams.BicepTemplateFile)" -ForegroundColor Yellow
    Write-Host "Use this Bicep file for the current deployment? (y/n) [Default: y]" -ForegroundColor Green -NoNewline
    $resp = Read-Host
    if ([string]::IsNullOrWhiteSpace($resp) -or $resp -eq "y") {
        $bicepTemplateFile = $sessionParams.BicepTemplateFile
        $shouldUseInfFile = $true
        Write-Log "User chose to reuse Bicep file from inf: $bicepTemplateFile"
    }
}

if (-not $shouldUseInfFile) {
    $bicepTemplateFile = Select-SessionHostBicepFile
    $sessionParams.BicepTemplateFile = $bicepTemplateFile
    Write-Log "User selected Bicep file: $bicepTemplateFile"
}


###################################################
#                                                 #
#    Prepare Environment & Connect to Services    #
#                                                 #
###################################################


Write-Banner "Prepare Environment & Connect to Services"
Write-Host "Checking modules and connecting to Az PowerShell and Microsoft Graph..." -ForegroundColor Cyan
Write-Log "Checking modules and authenticating services"
$modules = @(
    "Microsoft.Graph.Authentication",
    "Microsoft.Graph",
    "Microsoft.Graph.Groups",
    "Az.Accounts",
    "Az.DesktopVirtualization"
)
foreach ($mod in $modules) {
    if (-not (Get-Module -ListAvailable -Name $mod)) {
        Write-Host "Installing module $mod..." -ForegroundColor Yellow
        Install-Module $mod -Scope CurrentUser -Force -AllowClobber
        Write-Host "Please restart your PowerShell session to use $mod safely." -ForegroundColor Cyan
        Write-Log "Installed missing module $mod"
        exit 0
    }
    Import-Module $mod -Force
}

# Ensure modules installed and import
$modules = @("Microsoft.Graph", "Microsoft.Graph.Groups", "Az.Accounts", "Az.DesktopVirtualization")
foreach ($mod in $modules) {
    if (-not (Get-Module -ListAvailable -Name $mod)) {
        Write-Host "Installing module $mod..." -ForegroundColor Yellow
        Install-Module $mod -Scope CurrentUser -Force -AllowClobber
        Write-Host "Please restart your PowerShell session to use $mod safely." -ForegroundColor Cyan
        Write-Log "Installed missing module $mod"
        exit 0
    }
    Import-Module $mod -Force
}

# Helper function to ensure Azure connection and context
function Ensure-AzConnection {
    param(
        [string]$SubscriptionId
    )
    try {
        $context = Get-AzContext
        if (-not $context -or [string]::IsNullOrWhiteSpace($context.Account)) {
            Write-Host "No Azure context found, connecting..." -ForegroundColor Yellow
            if ($SubscriptionId) {
                Connect-AzAccount -Subscription $SubscriptionId -ErrorAction Stop
                Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop
            } else {
                Connect-AzAccount -ErrorAction Stop
            }
        } else {
            Write-Host "Already connected to Azure as $($context.Account)" -ForegroundColor Cyan
            if ($SubscriptionId -and $context.Subscription.Id -ne $SubscriptionId) {
                Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop
                Write-Host "Switched to subscription $SubscriptionId" -ForegroundColor Cyan
            }
        }
    } catch {
        Write-Host "Error connecting to Azure: $_" -ForegroundColor Red
        throw
    }
}

# Helper function for Microsoft Graph connection
function Ensure-GraphConnection {
    $graphScopes = @(
        "User.ReadWrite.All",
        "GroupMember.ReadWrite.All",
        "Device.ReadWrite.All"
    )
    $mgContext = $null
    try { $mgContext = Get-MgContext } catch {}
    $missingScopes = if ($mgContext) { $graphScopes | Where-Object { $_ -notin $mgContext.Scopes } } else { $graphScopes }
    if (-not $mgContext -or ($missingScopes.Count -gt 0)) {
        Write-Host "Connecting to Microsoft Graph with required scopes..." -ForegroundColor Yellow
        Connect-MgGraph -Scopes $graphScopes -ErrorAction Stop
        $mgContext = Get-MgContext
        Write-Host "Connected to Microsoft Graph as $($mgContext.Account)" -ForegroundColor Cyan
        Write-Log "Connected to Microsoft Graph as $($mgContext.Account)"
    } else {
        Write-Host "Already connected to Microsoft Graph as $($mgContext.Account)" -ForegroundColor Cyan
        Write-Log "Already connected to Microsoft Graph as $($mgContext.Account)"
    }
}

# Set context if .inf already has needed details and skip resource selection if possible
$missing = $requiredParams | Where-Object { -not ($sessionParams.PSObject.Properties.Name -contains $_) -or [string]::IsNullOrWhiteSpace($sessionParams.$_) }

if ($skipPrompts -and $missing.Count -eq 0) {
    $chosenSub = @{ id = $sessionParams.SubscriptionId; name = $sessionParams.SubscriptionName }
    $resourceGroup = $sessionParams.ResourceGroup
    $resourceGroupLocation = $sessionParams.ResourceGroupLocation
    $hostPoolName = $sessionParams.HostPoolName
    $vNetName = $sessionParams.VNetName
    $subnetName = $sessionParams.SubnetName
    $sessionHostPrefix = $sessionParams.DefaultPrefix
    $vPAWUsersGroupDisplayName = $sessionParams.vPAWUsersGroupDisplayName
    $vPAWUsersGroupObjectId = $sessionParams.vPAWUsersGroupObjectId
    $vPAWAdminsGroupDisplayName = $sessionParams.vPAWAdminsGroupDisplayName
    $vPAWAdminsGroupObjectId = $sessionParams.vPAWAdminsGroupObjectId
    $bicepTemplateFile = $sessionParams.BicepTemplateFile

    # Set Az PowerShell context to chosen subscription
    Ensure-AzConnection -SubscriptionId $chosenSub.id

    Write-Log "Using settings from ${confFile}: Subscription=$($chosenSub.name), ResourceGroup=$resourceGroup, ..."
    $doResourcePrompt = $false
} else {
    $doResourcePrompt = $true
}

# Always check Graph connection before Graph commands
Ensure-GraphConnection
function Pause-With-Timeout {
    param (
        [int]$Seconds = 10
    )
    Write-Host "Press Enter to continue, or wait $Seconds seconds..."
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $Seconds) {
        if ([System.Console]::KeyAvailable) {
            $key = [System.Console]::ReadKey($true)
            if ($key.Key -eq 'Enter') { break }
        }
        Start-Sleep -Milliseconds 100
    }
    Clear-Host
}

###################################################
#                                                 #
#               Prompting Functions               #
#                                                 #
###################################################
# Write-Banner "Prompting Functions"
function Prompt-RequiredParam([string]$PromptText) {
    while ($true) {
        Write-Host $PromptText -ForegroundColor Cyan -NoNewline
        $value = Read-Host
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            Write-Log "Prompted: $PromptText Value: $value"
            return $value
        }
        Write-Host "  This value is required. Please enter a value." -ForegroundColor Red
    }
}
function Prompt-SecurePassword([string]$PromptText) {
    while ($true) {
        Write-Host $PromptText -ForegroundColor Cyan -NoNewline
        $first = Read-Host -AsSecureString
        Write-Host "Confirm password: " -ForegroundColor Cyan -NoNewline
        $second = Read-Host -AsSecureString
        $plainFirst = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($first))
        $plainSecond = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($second))
        if ($plainFirst -eq $plainSecond -and $plainFirst.Length -gt 0) {
            Write-Log "Prompted: $PromptText Value: [hidden]"
            return $plainFirst
        } else {
            Write-Host "  Passwords do not match or were blank. Please try again." -ForegroundColor Red
        }
    }
}
function Prompt-OptionalParam([string]$PromptText, [string]$DefaultValue) {
    Write-Host "$PromptText (Default: $DefaultValue)" -ForegroundColor Cyan -NoNewline
    $value = Read-Host
    if ([string]::IsNullOrWhiteSpace($value)) {
        Write-Log "Prompted: $PromptText Value: $DefaultValue"
        return $DefaultValue
    }
    Write-Log "Prompted: $PromptText Value: $value"
    return $value
}
Clear-Host
###################################################
#                                                 #
#            Subscription/Resource Sel            #
#                                                 #
###################################################
if ($doResourcePrompt) {
    Write-Banner "Subscription/Resource Sel"
    Write-Host "Fetching your Azure subscriptions..." -ForegroundColor Yellow
    $subs = az account list --output json 2>$null | ConvertFrom-Json
    if (-not $subs) {
        Write-Host "No subscriptions found for this account." -ForegroundColor Red
        Write-Log "No subscriptions found for this account"
        exit 1
    }
    for ($i = 0; $i -lt $subs.Count; $i++) {
        Write-Host "$($i+1)) $($subs[$i].name)  ($($subs[$i].id))" -ForegroundColor Cyan
    }
    Write-Host "`nEnter the number of the subscription to use:" -ForegroundColor Green -NoNewline
    $subChoice = Read-Host
    $chosenSub = $subs[$subChoice - 1]
    Write-Host "Using subscription: $($chosenSub.name) ($($chosenSub.id))" -ForegroundColor Yellow
    Write-Log "Subscription: $($chosenSub.name) ($($chosenSub.id))"

    az account set --subscription $chosenSub.id
    Connect-AzAccount -Subscription $chosenSub.id
    Select-AzSubscription -SubscriptionId $chosenSub.id

    $resourceGroup = Prompt-RequiredParam "Enter the resource group name: "
    $resourceGroupLocation = Prompt-RequiredParam "Enter the resource group location: "
    $hostPoolName = Prompt-RequiredParam "Enter the host pool name: "
    $vNetName = Prompt-RequiredParam "Enter the virtual network name: "
    $subnetName = Prompt-RequiredParam "Enter the subnet name: "
    $sessionHostPrefix = Prompt-OptionalParam "Enter the session host prefix" "vPAW"
    $vPAWUsersGroupDisplayName = Prompt-OptionalParam "Enter vPAW Users group display name" "vPAW Users"
    $vPAWUsersGroupObjectId = Prompt-RequiredParam "Enter vPAW Users group objectId: "
    $vPAWAdminsGroupDisplayName = Prompt-OptionalParam "Enter vPAW Admins group display name" "vPAW Admins"
    $vPAWAdminsGroupObjectId = Prompt-RequiredParam "Enter vPAW Admins group objectId: "
    $bicepTemplateFile = $null # Let user select below
    $sessionParams.vPAWUsersGroupDisplayName = $vPAWUsersGroupDisplayName
    $sessionParams.vPAWUsersGroupObjectId = $vPAWUsersGroupObjectId
    $sessionParams.vPAWAdminsGroupDisplayName = $vPAWAdminsGroupDisplayName
    $sessionParams.vPAWAdminsGroupObjectId = $vPAWAdminsGroupObjectId
}
Clear-Host


###################################################
#                                                 #
#               Mask Sensitive Args               #
#                                                 #
###################################################
# Write-Banner "Mask Sensitive Args"
function Mask-SensitiveArgs {
    param([array]$paramArgs)
    $masked = @()
    foreach ($arg in $paramArgs) {
        if ($arg -like "adminPassword=*") {
            $masked += "adminPassword=********"
        } elseif ($arg -like "hostPoolRegistrationInfoToken=*") {
            $masked += "hostPoolRegistrationInfoToken=********"
        } else {
            $masked += $arg
        }
    }
    return $masked
}
Clear-Host


###################################################
#                                                 #
#             Session Host User Input             #
#                                                 #
###################################################
Write-Banner "Session Host User Input"
$hostCount = 1
Write-Host "How many session hosts would you like to deploy? (1-4) [Default: 1]" -ForegroundColor Green -NoNewline
$countInput = Read-Host
if ($countInput -match '^[1-4]$') { $hostCount = [int]$countInput }
$userDetails = @()
for ($i = 1; $i -le $hostCount; $i++) {
    Write-Host "`n=== SESSION HOST USER DETAILS (Host $i of $hostCount) ===" -ForegroundColor Yellow
    $firstName = Prompt-RequiredParam "Enter the first name of the user (userFirstName): "
    $lastName = Prompt-RequiredParam "Enter the last name of the user (userLastName): "
    $upn = Prompt-RequiredParam "Enter the user's UPN (userUPN): "
    $userDetails += [PSCustomObject]@{ FirstName = $firstName; LastName = $lastName; UPN = $upn }
}
Clear-Host

###################################################
#                                                 #
#               Admin & DNS Inputs                #
#                                                 #
###################################################
Write-Banner "Admin & DNS Inputs"
Write-Host "=== ADMIN CREDENTIALS ===" -ForegroundColor Yellow
$adminUsername = Prompt-OptionalParam "Enter the admin username for the session host (adminUsername)" "VPAW-Admin"
$adminPassword = Prompt-SecurePassword "Enter the admin password for the session host (input hidden): "
Write-Log "Admin credentials entered (password not logged)"

Write-Host "=== NAMING & DNS (OPTIONAL) ===" -ForegroundColor Yellow
$vNetResourceGroup = $resourceGroup
$dns1 = Prompt-OptionalParam "Enter the primary DNS server (dns1, leave blank for default)" ""
$dns2 = Prompt-OptionalParam "Enter the secondary DNS server (dns2, leave blank for default)" ""

Write-Host "=== SESSION HOST PREP SCRIPT URL ===" -ForegroundColor Yellow
$sessionHostPrepScriptUrl = Prompt-OptionalParam "Enter the SessionHostPrep.ps1 script URL (sessionHostPrepScriptUrl)" "https://raw.githubusercontent.com/andrew-kemp/CloudPAW/refs/heads/main/SessionHostPrep.ps1"
Clear-Host

###################################################
#                                                 #
#            Hostpool Registration Key            #
#                                                 #
###################################################
Write-Banner "Hostpool Registration Key"
Write-Host "=== Retreiving Registration Key ===" -ForegroundColor Yellow
try {
    $expiry = (Get-Date).ToUniversalTime().AddDays(1).ToString("yyyy-MM-ddTHH:mm:ssZ")
    $regInfoJson = az desktopvirtualization hostpool update `
        --resource-group $resourceGroup `
        --name $hostPoolName `
        --registration-info expiration-time=$expiry registration-token-operation=Update `
        --output json
    $regInfo = $regInfoJson | ConvertFrom-Json
    $hostPoolRegistrationInfoToken = $regInfo.registrationInfo.token
    Write-Host "Registration key generated and will be used for deployment." -ForegroundColor Cyan
    Write-Log "Registration key generated (expires $($regInfo.registrationInfo.expirationTime))"
} catch {
    Write-Host "Could not create registration key automatically: $_" -ForegroundColor Red
    Write-Log "Failed to create registration key: $_"
    $hostPoolRegistrationInfoToken = Prompt-RequiredParam "Enter the registration key for the AVD host pool (hostPoolRegistrationInfoToken): "
}
Clear-Host
###################################################
#                                                 #
#                 Summary Output                  #
#                                                 #
###################################################
$UsersGroupName  = $sessionParams.UsersGroupName
$UsersGroupId    = $sessionParams.UsersGroupId
$AdminsGroupName = $sessionParams.AdminsGroupName
$AdminsGroupId   = $sessionParams.AdminsGroupId
Write-Banner "Summary Output"
Write-Host "========= SUMMARY =========" -ForegroundColor Magenta
Write-Host ("Subscription: ".PadRight(30) + "$($chosenSub.name) ($($chosenSub.id))") -ForegroundColor Green
Write-Host ("Resource Group: ".PadRight(30) + "$resourceGroup") -ForegroundColor Green
Write-Host ("Host Pool: ".PadRight(30) + "$hostPoolName") -ForegroundColor Green
Write-Host ("Virtual Network: ".PadRight(30) + "$vNetName") -ForegroundColor Green
Write-Host ("Subnet: ".PadRight(30) + "$subnetName") -ForegroundColor Green
Write-Host ("sessionHostPrefix: ".PadRight(30) + "$sessionHostPrefix") -ForegroundColor Green
Write-Host ("vNetResourceGroup: ".PadRight(30) + "$vNetResourceGroup") -ForegroundColor Green
Write-Host ("dns1: ".PadRight(30) + "$dns1") -ForegroundColor Green
Write-Host ("dns2: ".PadRight(30) + "$dns2") -ForegroundColor Green
Write-Host ("sessionHostPrepScriptUrl: ".PadRight(30) + "$sessionHostPrepScriptUrl") -ForegroundColor Green
Write-Host ("bicepTemplateFile: ".PadRight(30) + "$bicepTemplateFile") -ForegroundColor Green
Write-Host ("vPAW Users group: ".PadRight(30) + "$UsersGroupName, ($UsersGroupId)") -ForegroundColor Green
Write-Host ("vPAW Admins group: ".PadRight(30) + "$AdminsGroupName, ($AdminsGroupId)") -ForegroundColor Green
Write-Host "User assignments to be created:" -ForegroundColor Green
foreach ($u in $userDetails) {
    Write-Host ("- $($u.FirstName) $($u.LastName) ($($u.UPN))") -ForegroundColor Green
}
Write-Host "===========================" -ForegroundColor Magenta
Write-Log "Summary displayed"
Pause-With-Timeout

###################################################
#                                                 #
#             Group Assignment Prompt             #
#                                                 #
###################################################


Write-Banner "Group Assignment Prompt"
Write-Host "Would you like to add each user to a group?"
Write-Host ("  1) {0} ({1}) only" -f $UsersGroupName, $UsersGroupId)
Write-Host ("  2) {0} ({1}) only" -f $AdminsGroupName, $AdminsGroupId)
Write-Host "  3) Both groups"
Write-Host "  4) Neither"
Write-Host "Select an option (1-4) [Default: 1]:" -ForegroundColor Green -NoNewline
$groupChoice = Read-Host
if ([string]::IsNullOrWhiteSpace($groupChoice)) { $groupChoice = "1" }
Clear-Host

###################################################
#                                                 #
#                Deployment Prompt                #
#                                                 #
###################################################
Write-Banner "Deployment Prompt"
$UsersGroupName  = $sessionParams.UsersGroupName
$UsersGroupId    = $sessionParams.UsersGroupId
$AdminsGroupName = $sessionParams.AdminsGroupName
$AdminsGroupId   = $sessionParams.AdminsGroupId
Write-Host "`nTip: To fully log out in future, run:" -ForegroundColor DarkGray
Write-Host "  Disconnect-MgGraph; az logout; Get-PSSession | Remove-PSSession" -ForegroundColor DarkGray
Write-Host ""
Write-Host "Would you like to deploy the selected Bicep template now? (y/n) [Default: y]" -ForegroundColor Green
$deployNow = Read-Host
if ([string]::IsNullOrWhiteSpace($deployNow)) { $deployNow = "y" }
Write-Log "User chose to deploy: $deployNow"

if ($deployNow -eq "y") {
    $sessionHostNames = @()
    foreach ($user in $userDetails) {
        $sessionHostName = "$sessionHostPrefix-$($user.FirstName)$($user.LastName)"
        $sessionHostNames += $sessionHostName

        # ========== VM EXISTENCE CHECK ==========
        $vmExists = $false
        try {
            az vm show --name $sessionHostName --resource-group $resourceGroup --output none 2>$null
            if ($LASTEXITCODE -eq 0) {
                $vmExists = $true
            }
        } catch {}
        
        if ($vmExists) {
            Write-Host "WARNING: Session host VM '$sessionHostName' already exists in resource group '$resourceGroup'. Skipping Bicep deployment for this host." -ForegroundColor Yellow
            Write-Log "Session host VM '$sessionHostName' already exists. Skipping Bicep deployment."
        } else {
    Write-Host "`nStarting deployment for $($user.FirstName) $($user.LastName) ($($user.UPN))..." -ForegroundColor Yellow
    Write-Log "Deploying session host for $($user.UPN)"

    $paramArgs = @(
        "--resource-group", $resourceGroup,
        "--template-file", $bicepTemplateFile,
        "--parameters",
        "sessionHostPrefix=$sessionHostPrefix",
        "userFirstName=$($user.FirstName)",
        "userLastName=$($user.LastName)",
        "userUPN=$($user.UPN)",
        "adminUsername=$adminUsername",
        "adminPassword=$adminPassword",
        "hostPoolRegistrationInfoToken=$hostPoolRegistrationInfoToken",
        "vNetResourceGroup=$vNetResourceGroup",
        "vNetName=$vNetName",
        "subnetName=$subnetName",
        "dns1=$dns1",
        "dns2=$dns2",
        "sessionHostPrepScriptUrl=$sessionHostPrepScriptUrl"
)

    Write-Host "az deployment group create $((Mask-SensitiveArgs $paramArgs) -join ' ')" -ForegroundColor Gray
    try {
        az deployment group create @paramArgs
        Write-Host "`nDeployment command executed for $($user.UPN)." -ForegroundColor Green
        Write-Log "Deployment command executed for $($user.UPN) successfully"
    } catch {
        $errMsg = $_.Exception.Message
        Write-Host ("Deployment command failed for {0}: {1}" -f $user.UPN, $errMsg) -ForegroundColor Red
        Write-Log ("Deployment command failed for {0}: {1}" -f $user.UPN, $errMsg)
    }
        }
    }
    Pause-With-Timeout

    #############################
    # Assign User to SessionHost#
    #############################
    Write-Banner "Assign User to SessionHost"
    foreach ($user in $userDetails) {
        $sessionHostName = "$sessionHostPrefix-$($user.FirstName)$($user.LastName)"
        try {
            Update-AzWvdSessionHost `
                -ResourceGroupName $resourceGroup `
                -HostPoolName $hostPoolName `
                -Name $sessionHostName `
                -AssignedUser $user.UPN
            Write-Host "Assigned $($user.UPN) to session host $sessionHostName using Update-AzWvdSessionHost." -ForegroundColor Cyan
            Write-Log "Assigned $($user.UPN) to session host $sessionHostName using Update-AzWvdSessionHost"
        } catch {
            $errMsg = $_.Exception.Message
            Write-Host ("Failed to assign {0} to session host {1}: {2}" -f $user.UPN, $sessionHostName, $errMsg) -ForegroundColor Red
            Write-Log ("Failed to assign {0} to session host {1}: {2}" -f $user.UPN, $sessionHostName, $errMsg)
        }
    }
    Pause-With-Timeout

    #############################
    #       Add to Groups       #
    #############################
    $usersGroupLabel  = "$UsersGroupName ($UsersGroupId)"
$adminsGroupLabel = "$AdminsGroupName ($AdminsGroupId)"

foreach ($user in $userDetails) {
    $userUpn = $user.UPN
    try {
        $mgUser = Get-MgUser -Filter "userPrincipalName eq '$userUpn'"
        if (-not $mgUser) { throw "User not found" }
        $userObjectId = $mgUser.Id
        Write-Host "Found $userUpn with ObjectId $userObjectId" -ForegroundColor Green
    } catch {
        $errMsg = $_.Exception.Message
        Write-Host "Failed to locate user $userUpn in Entra ID: $errMsg" -ForegroundColor Red
        Write-Log "Failed to locate user $userUpn in Entra ID: $errMsg"
        continue
    }

    if ($groupChoice -eq "1" -or $groupChoice -eq "3") {
        try {
            $isMember = Get-MgGroupMember -GroupId $UsersGroupId -All | Where-Object { $_.Id -eq $userObjectId }
            if ($isMember) {
                Write-Host ("{0} is already a member of {1}" -f $userUpn, $usersGroupLabel) -ForegroundColor Yellow
                Write-Log ("{0} already in {1}" -f $userUpn, $usersGroupLabel)
            } else {
                New-MgGroupMember -GroupId $UsersGroupId -DirectoryObjectId $userObjectId -ErrorAction Stop
                Write-Host ("Added {0} (ObjectId: {1}) to {2}:" -f $userUpn, $userObjectId, $usersGroupLabel) -ForegroundColor Cyan
                Write-Log ("Added {0} (ObjectId: {1}) to {2}" -f $userUpn, $userObjectId, $usersGroupLabel)
            }
        } catch {
            $errMsg = $_.Exception.Message
            Write-Host ("Failed to add {0} to {1}: {2}" -f $userUpn, $usersGroupLabel, $errMsg) -ForegroundColor Red
            Write-Log ("Failed to add {0} to {1}: {2}" -f $userUpn, $usersGroupLabel, $errMsg)
        }
    }

    if ($groupChoice -eq "2" -or $groupChoice -eq "3") {
        try {
            $isMember = Get-MgGroupMember -GroupId $AdminsGroupId -All | Where-Object { $_.Id -eq $userObjectId }
            if ($isMember) {
                Write-Host ("{0} is already a member of {1}" -f $userUpn, $adminsGroupLabel) -ForegroundColor Yellow
                Write-Log ("{0} already in {1}" -f $userUpn, $adminsGroupLabel)
            } else {
                New-MgGroupMember -GroupId $AdminsGroupId -DirectoryObjectId $userObjectId -ErrorAction Stop
                Write-Host ("Added {0} (ObjectId: {1}) to {2}:" -f $userUpn, $userObjectId, $adminsGroupLabel) -ForegroundColor Cyan
                Write-Log ("Added {0} (ObjectId: {1}) to {2}" -f $userUpn, $userObjectId, $adminsGroupLabel)
            }
        } catch {
            $errMsg = $_.Exception.Message
            Write-Host ("Failed to add {0} to {1}: {2}" -f $userUpn, $adminsGroupLabel, $errMsg) -ForegroundColor Red
            Write-Log ("Failed to add {0} to {1}: {2}" -f $userUpn, $adminsGroupLabel, $errMsg)
        }
    }
}
    Pause-With-Timeout

    ##############################
    #      VM Auto-Shutdown     #
    #############################
    Write-Banner "Configure VM Auto-Shutdown"
    foreach ($user in $userDetails) {
        $vmName = "$sessionHostPrefix-$($user.FirstName)$($user.LastName)"
        $upn = $user.UPN
        Write-Host "Setting auto-shutdown for VM: $vmName (Notify: $upn)" -ForegroundColor Yellow
        az vm auto-shutdown --resource-group $resourceGroup --name $vmName --time 1800 --email $upn 2>&1 | Write-Host
    }
    Pause-With-Timeout

    #############################
    # Set Device Extension Attributes
    #############################
    Write-Banner "Set vPAW Device Extension Attributes"
    $params = @{
        extensionAttributes = @{
            extensionAttribute1 = "virtual Privileged Access Workstation"
        }
    }
    $devices = Get-MgDevice -Filter "startswith(displayName,'$resourceGroup')"
    foreach ($device in $devices) {
        Write-Host "Tagging device: $($device.displayName) ($($device.Id))" -ForegroundColor Cyan
        Update-MgDevice -DeviceId $device.Id -BodyParameter $params
    }
    Write-Log "Device extension attributes set for all devices with displayName starting with '$resourceGroup'"
    Pause-With-Timeout

    #############################
    # Invalidate Reg. Key/Save  #
    #############################
    Write-Banner "Invalidate Reg. Key/Save Config"
    Write-Host "Invalidating host pool registration key for security..." -ForegroundColor Yellow
    try {
        az desktopvirtualization hostpool update `
            --resource-group $resourceGroup `
            --name $hostPoolName `
            --registration-info registration-token-operation=Delete `
            --output none
        Write-Host "Registration key invalidated." -ForegroundColor Cyan
        Write-Log "Host pool registration key invalidated"
    } catch {
        $errMsg = $_.Exception.Message
        Write-Host "Failed to invalidate the host pool registration key: $errMsg" -ForegroundColor Red
        Write-Log "Failed to invalidate host pool registration key: $errMsg"
    }

    # NOTE: This script only reads from vPAWconf.inf and never writes or modifies it.

    Write-Host "`n===== vPAW Session Host deployment workflow completed =====" -ForegroundColor Magenta
    Write-Log "Workflow completed"

} else {
    Write-Host "Deployment skipped. You can deploy later using the collected parameters." -ForegroundColor Yellow
    Write-Log "Deployment skipped by user"
    exit 0
}
}

# === MAIN MENU ===
while ($true) {
    Clear-Host
    Write-Banner "VirtualPAW Deployment Menu"
    Write-Host "1) Core Infrastructure Deployment (with session host option)"
    Write-Host "2) Deploy Additional Session Host(s) Only"
    Write-Host "3) Exit"
    $choice = Read-Host "Select an option (1-3)"
    switch ($choice) {
        "1" { Deploy-CoreInfra }
        "2" { Deploy-SessionHost }
        "3" { Write-Host "Exiting..."; break }
        default { Write-Host "Invalid selection. Please choose 1, 2, or 3." -ForegroundColor Red }
    }
}