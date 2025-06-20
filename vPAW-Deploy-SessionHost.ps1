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