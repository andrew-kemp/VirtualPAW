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
Write-Banner "Config and Log Setup"
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
    @{Name="BicepTemplateFile";Prompt="Bicep template file";Var="bicepTemplateFile"}
)

# --- Logging Function ---
function Write-Log {
    param ([string]$Message)
    $timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    Add-Content -Path $logFile -Value "$timestamp - $Message"
}
Write-Log "Script started by $env:USERNAME"

#############################
#                           #
#   Prompting Functions     #
#                           #
#############################
Write-Banner "Prompting Functions"
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

#############################
#                           #
#  Bicep File Selection     #
#                           #
#############################
Write-Banner "Bicep File Selection"
function Select-SessionHostBicepFile {
    param([string]$excludeFile = $null)
    $allBicepFiles = Get-ChildItem -Path . -File | Where-Object { $_.Name -match '\.bicep$' -or $_.Name -match '\.BICEP$' }
    if ($excludeFile) {
        $allBicepFiles = $allBicepFiles | Where-Object { $_.Name -ne $excludeFile }
    }
    $pattern = '(?i)Session[\s\-]?Host'
    $sessionHostFiles = $allBicepFiles | Where-Object { $_.Name -match $pattern }
    if ($sessionHostFiles.Count -eq 1) {
        $file = $sessionHostFiles[0].Name
        Write-Host "Found session host Bicep file: $file"
        Write-Host "Using $file, continue? (y/n) [default: y]" -ForegroundColor Green -NoNewline
        $resp = Read-Host
        if ([string]::IsNullOrWhiteSpace($resp) -or $resp -eq "y") {
            Write-Log "Auto-selected session host bicep file: $file"
            return $file
        }
    } elseif ($sessionHostFiles.Count -gt 1) {
        Write-Host "Multiple session host Bicep files found:" -ForegroundColor Cyan
        for ($i = 0; $i -lt $sessionHostFiles.Count; $i++) {
            Write-Host "$($i + 1)) $($sessionHostFiles[$i].Name)" -ForegroundColor Cyan
        }
        Write-Host "Select one by number or press Enter to list all bicep files:" -ForegroundColor Green -NoNewline
        $choice = Read-Host
        if ($choice -match '^\d+$' -and $choice -gt 0 -and $choice -le $sessionHostFiles.Count) {
            $chosenFile = $sessionHostFiles[$choice - 1].Name
            Write-Log "User selected session host bicep file: $chosenFile"
            return $chosenFile
        }
    }
    if (-not $allBicepFiles -or $allBicepFiles.Count -eq 0) {
        Write-Host "No .bicep template files found." -ForegroundColor Red
        Write-Log "No .bicep template files found." "ERROR"
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
            Write-Log "User manually selected bicep file: $chosenFile"
            return $chosenFile
        } else {
            Write-Host "Invalid selection." -ForegroundColor Red
        }
    }
}

#############################
#                           #
#  Mask Sensitive Args      #
#                           #
#############################
Write-Banner "Mask Sensitive Args"
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

#############################
#                           #
#   Load Previous Session   #
#                           #
#############################
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

#############################
#                           #
#   Prepare Environment     #
#                           #
#############################
Write-Banner "Prepare Environment"
Write-Host "Preparing environment: checking modules and connecting to services..." -ForegroundColor Cyan
Write-Log "Checking modules and Azure CLI presence"

$modules = @("Microsoft.Graph")
foreach ($mod in $modules) {
    $isInstalled = Get-Module -ListAvailable -Name $mod
    if (-not $isInstalled) {
        Write-Host "Installing module $mod..." -ForegroundColor Yellow
        Install-Module $mod -Scope CurrentUser -Force -AllowClobber
        Write-Host "Please restart your PowerShell session to use $mod safely." -ForegroundColor Cyan
        Write-Log "Installed missing module $mod"
        exit 0
    }
}
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: Azure CLI (az) is not installed. Please install it from https://learn.microsoft.com/en-us/cli/azure/install-azure-cli and log in using 'az login'." -ForegroundColor Red
    Write-Log "Azure CLI not installed"
    exit 1
}
if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
    Write-Host "ERROR: Az.Accounts module is not installed. Please run 'Install-Module Az.Accounts -Scope CurrentUser'." -ForegroundColor Red
    Write-Log "Az.Accounts module not installed"
    exit 1
}
Import-Module Az.Accounts -ErrorAction SilentlyContinue

#############################
#                           #
#   Azure CLI & Graph Login #
#                           #
#############################
Write-Banner "Azure CLI & Graph Login"
# --- Azure CLI Login ---
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
    az login | Out-Null
    $azAccount = az account show | ConvertFrom-Json
    Write-Host "Logged in to Azure CLI as $($azAccount.user.name)" -ForegroundColor Cyan
    Write-Log "Logged in to Azure CLI as $($azAccount.user.name)"
}

# --- Az PowerShell Login ---
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
    Connect-AzAccount | Out-Null
    $azContext = Get-AzContext
    Write-Host "Connected to Az PowerShell as $($azContext.Account)" -ForegroundColor Cyan
    Write-Log "Connected to Az PowerShell as $($azContext.Account)"
}

# --- Microsoft Graph Login ---
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
    Connect-MgGraph -Scopes "Group.Read.All, Application.Read.All, Policy.ReadWrite.ConditionalAccess"
    $mgContext = Get-MgContext
    Write-Host "Connected to Microsoft Graph as $($mgContext.Account)" -ForegroundColor Cyan
    Write-Log "Connected to Microsoft Graph as $($mgContext.Account)"
}

#############################
#                           #
# Subscription/Resource Sel #
#                           #
#############################
Write-Banner "Subscription/Resource Sel"
if (-not $skipPrompts) {
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
    Select-AzSubscription -SubscriptionId $chosenSub.id
    $resourceGroup = Prompt-RequiredParam "Enter the resource group name: "
    $resourceGroupLocation = Prompt-RequiredParam "Enter the resource group location: "
    $hostPoolName = Prompt-RequiredParam "Enter the host pool name: "
    $vNetName = Prompt-RequiredParam "Enter the virtual network name: "
    $subnetName = Prompt-RequiredParam "Enter the subnet name: "
    $sessionHostPrefix = Prompt-OptionalParam "Enter the session host prefix" "vPAW"
    $bicepTemplateFile = Select-SessionHostBicepFile -excludeFile $lastBicepFile
} else {
    $chosenSub = @{ id = $sessionParams.SubscriptionId; name = $sessionParams.SubscriptionName }
    $resourceGroup = $sessionParams.ResourceGroup
    $resourceGroupLocation = $sessionParams.ResourceGroupLocation
    $hostPoolName = $sessionParams.HostPoolName
    $vNetName = $sessionParams.VNetName
    $subnetName = $sessionParams.SubnetName
    $sessionHostPrefix = $sessionParams.DefaultPrefix
    $bicepTemplateFile = Select-SessionHostBicepFile -excludeFile $sessionParams.BicepTemplateFile
    az account set --subscription $chosenSub.id
    Select-AzSubscription -SubscriptionId $chosenSub.id
    Write-Log "Using settings from ${confFile}: Subscription=$($chosenSub.name), ResourceGroup=$resourceGroup, ..."
}

#############################
#                           #
#  Session Host User Input  #
#                           #
#############################
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

#############################
#                           #
#   Admin & DNS Inputs      #
#                           #
#############################
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

#############################
#                           #
# Hostpool Registration Key #
#                           #
#############################
Write-Banner "Hostpool Registration Key"
Write-Host "=== HOST POOL REGISTRATION KEY ===" -ForegroundColor Yellow
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

#############################
#                           #
#      Summary Output       #
#                           #
#############################
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
Write-Host "User assignments to be created:" -ForegroundColor Green
foreach ($u in $userDetails) {
    Write-Host ("- $($u.FirstName) $($u.LastName) ($($u.UPN))") -ForegroundColor Green
}
Write-Host "===========================" -ForegroundColor Magenta
Write-Log "Summary displayed"

#############################
#                           #
#    Deployment Prompt      #
#                           #
#############################
Write-Banner "Deployment Prompt"
Write-Host "`nTip: To fully log out in future, run:" -ForegroundColor DarkGray
Write-Host "  Disconnect-MgGraph; az logout; Get-PSSession | Remove-PSSession" -ForegroundColor DarkGray
Write-Host ""
Write-Host "Would you like to deploy the selected Bicep template now? (y/n)" -ForegroundColor Green
$deployNow = Read-Host
Write-Log "User chose to deploy: $deployNow"

if ($deployNow -eq "y") {
    $sessionHostNames = @()
    foreach ($user in $userDetails) {
        $sessionHostName = "$sessionHostPrefix-$($user.FirstName)$($user.LastName)"
        $sessionHostNames += $sessionHostName
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
            Write-Host "`nDeployment command failed for $($user.UPN)." -ForegroundColor Red
            Write-Log "Deployment command failed for $($user.UPN): $_"
        }
    }

    #############################
    #                           #
    # Assign User to SessionHost#
    #                           #
    #############################
    Write-Banner "Assign User to SessionHost"
    for ($i = 0; $i -lt $userDetails.Count; $i++) {
        $user = $userDetails[$i]
        $sessionHostName = $sessionHostNames[$i]

        # Some environments require FQDN, but often it's just the VM name. Adjust if needed.
        try {
            az desktopvirtualization sessionhost update `
                --host-pool-name $hostPoolName `
                --resource-group $resourceGroup `
                --name $sessionHostName `
                --assigned-user $user.UPN
            Write-Host "Assigned $($user.UPN) to session host $sessionHostName." -ForegroundColor Cyan
            Write-Log "Assigned $($user.UPN) to session host $sessionHostName"
        } catch {
            Write-Host "Failed to assign $($user.UPN) to session host $sessionHostName." -ForegroundColor Red
            Write-Log ("Failed to assign {0} to session host {1}: {2}" -f $user.UPN, $sessionHostName, $_)
        }
    }
} else {
    Write-Host "Deployment skipped. You can deploy later using the collected parameters." -ForegroundColor Yellow
    Write-Log "Deployment skipped by user"
    exit 0
}

#############################
#                           #
# Invalidate Reg. Key/Save  #
#                           #
#############################
Write-Banner "Invalidate Reg. Key/Save"
Write-Host "Invalidating registration key for security..." -ForegroundColor Yellow
az desktopvirtualization hostpool update `
  --resource-group $resourceGroup `
  --name $hostPoolName `
  --registration-info expiration-time=1970-01-01T00:00:00Z registration-token-operation=Delete | Out-Null
Write-Host "Registration key removed." -ForegroundColor Green
Write-Log "Registration key invalidated"

Write-Host "Ensuring PowerShell and Microsoft Graph context post-deployment..." -ForegroundColor Cyan
Select-AzSubscription -SubscriptionId $chosenSub.id

# --- Save Session for Future Use ---
$sessionParams = @{
    SubscriptionId = $chosenSub.id
    SubscriptionName = $chosenSub.name
    ResourceGroup = $resourceGroup
    ResourceGroupLocation = $resourceGroupLocation
    HostPoolName = $hostPoolName
    VNetName = $vNetName
    SubnetName = $subnetName
    DefaultPrefix = $sessionHostPrefix
    BicepTemplateFile = $bicepTemplateFile
    SavedAt = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
}
$sessionParams | ConvertTo-Json | Set-Content $confFile
Write-Log "Session parameters saved to $confFile"

Write-Host "`nScript complete." -ForegroundColor Cyan
Write-Log "Script complete"