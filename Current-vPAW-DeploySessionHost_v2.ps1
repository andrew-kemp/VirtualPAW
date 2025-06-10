<#
.SYNOPSIS
    Full interactive deployment workflow for VirtualPAW session host in Azure.
.DESCRIPTION
    Connects to Azure, selects subscription, resource group, host pool, vNet, subnet, collects parameters, selects Bicep, and deploys.
#>

# --- Azure CLI Extension Preview Config (Suppresses extension warnings) ---
az config set extension.dynamic_install_allow_preview=true | Out-Null

# --- Utility Prompt Functions ---
function Prompt-RequiredParam([string]$PromptText) {
    while ($true) {
        Write-Host $PromptText -ForegroundColor Cyan -NoNewline
        $value = Read-Host
        if (-not [string]::IsNullOrWhiteSpace($value)) {
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
        return $DefaultValue
    }
    return $value
}
function Select-BicepFile {
    Clear-Host
    Write-Host "=== SELECT SESSION HOST DEPLOYMENT TEMPLATE ===" -ForegroundColor Yellow
    $bicepFiles = Get-ChildItem -Path (Get-Location) -Filter *.bicep | Select-Object -ExpandProperty Name
    if (-not $bicepFiles -or $bicepFiles.Count -eq 0) {
        Write-Host "No .bicep files found in the current folder." -ForegroundColor Red
        return $null
    }
    Write-Host "The following .bicep files were found:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $bicepFiles.Count; $i++) {
        Write-Host "[$($i+1)] $($bicepFiles[$i])" -ForegroundColor Green
    }
    while ($true) {
        Write-Host "Enter the number of the file to use:" -ForegroundColor Cyan -NoNewline
        $choice = Read-Host
        if ($choice -match '^\d+$' -and $choice -ge 1 -and $choice -le $bicepFiles.Count) {
            return $bicepFiles[$choice - 1]
        } else {
            Write-Host "Invalid selection. Please enter a number from the list above." -ForegroundColor Red
        }
    }
}

# --- Ensure Connection Functions ---
function Ensure-AzConnection {
    try { $null = Get-AzContext -ErrorAction Stop }
    catch {
        Write-Host "Re-authenticating to Azure..." -ForegroundColor Yellow
        Connect-AzAccount | Out-Null
    }
}
function Ensure-MgGraphConnection {
    try { $null = Get-MgContext -ErrorAction Stop }
    catch {
        Write-Host "Re-authenticating to Microsoft Graph..." -ForegroundColor Yellow
        Connect-MgGraph -Scopes "Group.Read.All, Application.Read.All, Policy.ReadWrite.ConditionalAccess"
    }
}

# --- Prepare Environment ---
Clear-Host
Write-Host "Preparing environment: checking modules and connecting to services..." -ForegroundColor Cyan

$modules = @("Microsoft.Graph")
foreach ($mod in $modules) {
    $isInstalled = Get-Module -ListAvailable -Name $mod
    if (-not $isInstalled) {
        Write-Host "Installing module $mod..." -ForegroundColor Yellow
        Install-Module $mod -Scope CurrentUser -Force -AllowClobber
        Write-Host "Please restart your PowerShell session to use $mod safely." -ForegroundColor Cyan
        exit 0
    }
}
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: Azure CLI (az) is not installed. Please install it from https://learn.microsoft.com/en-us/cli/azure/install-azure-cli and log in using 'az login'." -ForegroundColor Red
    exit 1
}
if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
    Write-Host "ERROR: Az.Accounts module is not installed. Please run 'Install-Module Az.Accounts -Scope CurrentUser'." -ForegroundColor Red
    exit 1
}
Import-Module Az.Accounts -ErrorAction SilentlyContinue

# --- Azure CLI Login ---
Clear-Host
$azLoggedIn = $false
try {
    $azAccount = az account show 2>$null | ConvertFrom-Json
    if ($azAccount) {
        $azLoggedIn = $true
        Write-Host "Already logged in to Azure CLI as $($azAccount.user.name)" -ForegroundColor Cyan
    }
} catch {}
if (-not $azLoggedIn) {
    Write-Host "Logging in to Azure CLI..." -ForegroundColor Yellow
    az login | Out-Null
    $azAccount = az account show | ConvertFrom-Json
    Write-Host "Logged in to Azure CLI as $($azAccount.user.name)" -ForegroundColor Cyan
}

# --- Az PowerShell Login ---
$azPSLoggedIn = $false
try {
    $azContext = Get-AzContext
    if ($azContext) {
        $azPSLoggedIn = $true
        Write-Host "Already connected to Az PowerShell as $($azContext.Account)" -ForegroundColor Cyan
    }
} catch {}
if (-not $azPSLoggedIn) {
    Write-Host "Connecting to Az PowerShell..." -ForegroundColor Yellow
    Connect-AzAccount | Out-Null
    $azContext = Get-AzContext
    Write-Host "Connected to Az PowerShell as $($azContext.Account)" -ForegroundColor Cyan
}

# --- Microsoft Graph Login ---
$graphLoggedIn = $false
try {
    $mgContext = Get-MgContext
    if ($mgContext) {
        $graphLoggedIn = $true
        Write-Host "Already connected to Microsoft Graph as $($mgContext.Account)" -ForegroundColor Cyan
    }
} catch {}
if (-not $graphLoggedIn) {
    Write-Host "Connecting to Microsoft Graph..." -ForegroundColor Yellow
    Connect-MgGraph -Scopes "Group.Read.All, Application.Read.All, Policy.ReadWrite.ConditionalAccess"
    $mgContext = Get-MgContext
    Write-Host "Connected to Microsoft Graph as $($mgContext.Account)" -ForegroundColor Cyan
}

# --- Subscription Selection ---
Clear-Host
Write-Host "Fetching your Azure subscriptions..." -ForegroundColor Yellow
$subs = az account list --output json 2>$null | ConvertFrom-Json
if (-not $subs) {
    Write-Host "No subscriptions found for this account." -ForegroundColor Red
    exit 1
}
for ($i = 0; $i -lt $subs.Count; $i++) {
    Write-Host "$($i+1)) $($subs[$i].name)  ($($subs[$i].id))" -ForegroundColor Cyan
}
Write-Host "`nEnter the number of the subscription to use:" -ForegroundColor Green -NoNewline
$subChoice = Read-Host
$chosenSub = $subs[$subChoice - 1]
Write-Host "Using subscription: $($chosenSub.name) ($($chosenSub.id))" -ForegroundColor Yellow
az account set --subscription $chosenSub.id
Ensure-AzConnection
Select-AzSubscription -SubscriptionId $chosenSub.id

# --- Resource Group Selection ---
Clear-Host
Write-Host "Would you like to use an existing resource group, or create a new one?" -ForegroundColor Green
Write-Host "1) Existing" -ForegroundColor Yellow
Write-Host "2) New" -ForegroundColor Yellow
$rgChoice = Read-Host

if ($rgChoice -eq "1") {
    $rgs = az group list --output json 2>$null | ConvertFrom-Json
    if (-not $rgs) {
        Write-Host "No resource groups found. You must create a new one." -ForegroundColor Red
        $rgChoice = "2"
    } else {
        for ($i = 0; $i -lt $rgs.Count; $i++) {
            Write-Host "$($i+1)) $($rgs[$i].name)  ($($rgs[$i].location))" -ForegroundColor Cyan
        }
        Write-Host "`nEnter the number of the resource group to use:" -ForegroundColor Green -NoNewline
        $rgSelect = Read-Host
        $resourceGroup = $rgs[$rgSelect - 1].name
        $resourceGroupLocation = $rgs[$rgSelect - 1].location
        Write-Host "Using resource group: $resourceGroup" -ForegroundColor Yellow
    }
}
if ($rgChoice -eq "2") {
    Write-Host "Enter a name for the new resource group:" -ForegroundColor Green -NoNewline
    $resourceGroup = Read-Host
    Write-Host "Enter the Azure region for the new resource group (e.g., uksouth, eastus):" -ForegroundColor Green -NoNewline
    $resourceGroupLocation = Read-Host
    Write-Host "Creating resource group $resourceGroup in $resourceGroupLocation..." -ForegroundColor Yellow
    az group create --name $resourceGroup --location $resourceGroupLocation | Out-Null
    Write-Host "Resource group $resourceGroup created." -ForegroundColor Green
}

# --- Select Host Pool ---
Clear-Host
Write-Host "Fetching Host Pools in resource group $resourceGroup..." -ForegroundColor Yellow
$hostPoolsJson = az desktopvirtualization hostpool list --resource-group $resourceGroup --output json 2>$null

# Only parse if output is not empty and looks like JSON
if ($hostPoolsJson -and $hostPoolsJson.Trim().StartsWith('[')) {
    $hostPools = $hostPoolsJson | ConvertFrom-Json
    if ($hostPools.Count -eq 0) {
        Write-Host "No Host Pools found in $resourceGroup. Please ensure a host pool exists before proceeding." -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "No Host Pools found in $resourceGroup. Please ensure a host pool exists before proceeding." -ForegroundColor Red
    exit 1
}

for ($i = 0; $i -lt $hostPools.Count; $i++) {
    Write-Host "$($i+1)) $($hostPools[$i].name)" -ForegroundColor Cyan
}
Write-Host "Enter the number of the Host Pool to register with:" -ForegroundColor Green -NoNewline
$hostPoolChoice = Read-Host
$hostPoolName = $hostPools[$hostPoolChoice - 1].name
Write-Host "Selected Host Pool: $hostPoolName" -ForegroundColor Yellow

# --- Select Network and Subnet ---
Clear-Host
Write-Host "Fetching Virtual Networks in resource group $resourceGroup..." -ForegroundColor Yellow
$vNetsJson = az network vnet list --resource-group $resourceGroup --output json 2>$null

if ($vNetsJson -and $vNetsJson.Trim().StartsWith('[')) {
    $vNets = $vNetsJson | ConvertFrom-Json
    if ($vNets.Count -eq 0) {
        Write-Host "No virtual networks found in $resourceGroup." -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "No virtual networks found in $resourceGroup." -ForegroundColor Red
    exit 1
}

for ($i = 0; $i -lt $vNets.Count; $i++) {
    Write-Host "$($i+1)) $($vNets[$i].name)" -ForegroundColor Cyan
}
Write-Host "Enter the number of the Virtual Network to use:" -ForegroundColor Green -NoNewline
$vNetChoice = Read-Host
$vNetName = $vNets[$vNetChoice - 1].name

# --- Subnet Selection ---
$subnets = $vNets[$vNetChoice - 1].subnets
if (-not $subnets -or $subnets.Count -eq 0) {
    Write-Host "No subnets found in $vNetName." -ForegroundColor Red
    exit 1
}
for ($i = 0; $i -lt $subnets.Count; $i++) {
    Write-Host "$($i+1)) $($subnets[$i].name)" -ForegroundColor Cyan
}
Write-Host "Enter the number of the Subnet to use:" -ForegroundColor Green -NoNewline
$subnetChoice = Read-Host
$subnetName = $subnets[$subnetChoice - 1].name

# --- Parameter Collection ---
Clear-Host
Write-Host "=== SESSION HOST USER DETAILS ===" -ForegroundColor Yellow
$userFirstName = Prompt-RequiredParam "Enter the first name of the user (userFirstName): "
$userLastName = Prompt-RequiredParam "Enter the last name of the user (userLastName): "
$userUPN = Prompt-RequiredParam "Enter the user's UPN (userUPN): "

Clear-Host
Write-Host "=== ADMIN CREDENTIALS ===" -ForegroundColor Yellow
$adminUsername = Prompt-OptionalParam "Enter the admin username for the session host (adminUsername)" "VPAW-Admin"
$adminPassword = Prompt-SecurePassword "Enter the admin password for the session host (input hidden): "

Clear-Host
Write-Host "=== HOST POOL REGISTRATION KEY ===" -ForegroundColor Yellow
$hostPoolRegistrationInfoToken = Prompt-RequiredParam "Enter the registration key for the AVD host pool (hostPoolRegistrationInfoToken): "

Clear-Host
Write-Host "=== NAMING & DNS (OPTIONAL) ===" -ForegroundColor Yellow
$sessionHostPrefix = Prompt-OptionalParam "Enter the session host prefix (sessionHostPrefix)" "vPAW"
$vNetResourceGroup = $resourceGroup # Since vNet and subnet came from this RG
$dns1 = Prompt-OptionalParam "Enter the primary DNS server (dns1, leave blank for default)" ""
$dns2 = Prompt-OptionalParam "Enter the secondary DNS server (dns2, leave blank for default)" ""

Clear-Host
Write-Host "=== SESSION HOST PREP SCRIPT URL ===" -ForegroundColor Yellow
$sessionHostPrepScriptUrl = Prompt-OptionalParam "Enter the SessionHostPrep.ps1 script URL (sessionHostPrepScriptUrl)" "https://raw.githubusercontent.com/andrew-kemp/AzureVirtualDesktop/refs/heads/main/02a-SessionHostPrep.ps1"

# --- Bicep Template Selection ---
$bicepTemplateFile = Select-BicepFile

# --- Summary ---
Clear-Host
Write-Host "========= SUMMARY =========" -ForegroundColor Magenta
Write-Host ("Subscription: ".PadRight(30) + "$($chosenSub.name) ($($chosenSub.id))") -ForegroundColor Green
Write-Host ("Resource Group: ".PadRight(30) + "$resourceGroup") -ForegroundColor Green
Write-Host ("Host Pool: ".PadRight(30) + "$hostPoolName") -ForegroundColor Green
Write-Host ("Virtual Network: ".PadRight(30) + "$vNetName") -ForegroundColor Green
Write-Host ("Subnet: ".PadRight(30) + "$subnetName") -ForegroundColor Green
Write-Host ("userFirstName: ".PadRight(30) + "$userFirstName") -ForegroundColor Green
Write-Host ("userLastName: ".PadRight(30) + "$userLastName") -ForegroundColor Green
Write-Host ("userUPN: ".PadRight(30) + "$userUPN") -ForegroundColor Green
Write-Host ("adminUsername: ".PadRight(30) + "$adminUsername") -ForegroundColor Green
Write-Host ("adminPassword: ".PadRight(30) + "[hidden]") -ForegroundColor Green
Write-Host ("hostPoolRegistrationInfoToken: ".PadRight(30) + "$hostPoolRegistrationInfoToken") -ForegroundColor Green
Write-Host ("sessionHostPrefix: ".PadRight(30) + "$sessionHostPrefix") -ForegroundColor Green
Write-Host ("vNetResourceGroup: ".PadRight(30) + "$vNetResourceGroup") -ForegroundColor Green
Write-Host ("dns1: ".PadRight(30) + "$dns1") -ForegroundColor Green
Write-Host ("dns2: ".PadRight(30) + "$dns2") -ForegroundColor Green
Write-Host ("sessionHostPrepScriptUrl: ".PadRight(30) + "$sessionHostPrepScriptUrl") -ForegroundColor Green
Write-Host ("bicepTemplateFile: ".PadRight(30) + "$bicepTemplateFile") -ForegroundColor Green
Write-Host "===========================" -ForegroundColor Magenta

# --- Deployment Prompt ---
Write-Host "`nTip: To fully log out in future, run:" -ForegroundColor DarkGray
Write-Host "  Disconnect-MgGraph; az logout; Get-PSSession | Remove-PSSession" -ForegroundColor DarkGray

Write-Host ""
Write-Host "Would you like to deploy the selected Bicep template now? (y/n)" -ForegroundColor Green
$deployNow = Read-Host

if ($deployNow -eq "y") {
    Clear-Host
    Write-Host "Starting deployment..." -ForegroundColor Yellow

    $paramArgs = @(
        "--resource-group", $resourceGroup,
        "--template-file", $bicepTemplateFile,
        "--parameters",
        "sessionHostPrefix=$sessionHostPrefix",
        "userFirstName=$userFirstName",
        "userLastName=$userLastName",
        "userUPN=$userUPN",
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

    Write-Host "az deployment group create $($paramArgs -join ' ')" -ForegroundColor Gray
    az deployment group create @paramArgs
    Write-Host "`nDeployment command executed." -ForegroundColor Green
} else {
    Write-Host "Deployment skipped. You can deploy later using the collected parameters." -ForegroundColor Yellow
    exit 0
}

# --- Ensure Contexts Post-Deployment ---
Clear-Host
Write-Host "Ensuring PowerShell and Microsoft Graph context post-deployment..." -ForegroundColor Cyan
Ensure-AzConnection
Select-AzSubscription -SubscriptionId $chosenSub.id
Ensure-MgGraphConnection

Write-Host "`nScript complete." -ForegroundColor Cyan