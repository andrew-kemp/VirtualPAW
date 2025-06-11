# Virtual Privileged Access Workstation (vPAW) Deployment

This repository contains PowerShell scripts to deploy the Virtual Privileged Access Workstation (vPAW) solution in Azure. The main script, **Deploy-vPAW.ps1**, provides an interactive menu to deploy the full vPAW solution (core infrastructure and session hosts) or to deploy additional session hosts only.

---

## Features

- **Interactive menu** for full or session host-only deployment
- Automated environment and module checks
- Azure subscription and resource group selection/creation
- Entra ID (Azure AD) group selection or creation
- Bicep template selection and deployment
- RBAC assignment for AVD and VM access
- Conditional Access policy exclusion for storage apps
- Optional session host deployment with user assignment and group membership
- Device tagging and VM auto-shutdown configuration
- Logging of all actions

---

## Requirements

- **PowerShell 7.x** (latest recommended)
- **Azure CLI** (`az`) installed and authenticated
- **Az PowerShell modules**:  
  - `Az.Accounts`
  - `Az.DesktopVirtualization`
- **Microsoft Graph PowerShell modules**:  
  - `Microsoft.Graph`
  - `Microsoft.Graph.Groups`
  - `Microsoft.Graph.Authentication`
- Sufficient Azure and Entra ID (Azure AD) permissions to create resources, assign roles, and manage groups

---

## Getting Started

1. **Clone this repository** and open a PowerShell 7 terminal in the repo directory.

2. **Install required modules** (if not already installed):

    ```powershell
    Install-Module Az.Accounts -Scope CurrentUser
    Install-Module Az.DesktopVirtualization -Scope CurrentUser
    Install-Module Microsoft.Graph -Scope CurrentUser
    Install-Module Microsoft.Graph.Groups -Scope CurrentUser
    Install-Module Microsoft.Graph.Authentication -Scope CurrentUser
    ```

3. **Login to Azure and Microsoft Graph** (the script will prompt if not already authenticated):

    ```powershell
    az login
    Connect-AzAccount
    Connect-MgGraph -Scopes "Group.Read.All, Application.Read.All, Policy.ReadWrite.ConditionalAccess"
    ```

4. **Run the deployment script**:

    ```powershell
    pwsh ./Deploy-vPAW.ps1
    ```

5. **Follow the interactive prompts** to deploy core infrastructure and/or session hosts.

---

## What the Script Does

- Connects to Azure via Azure CLI and Az PowerShell
- Connects to Microsoft Graph for Entra ID (Azure AD) operations
- Deploys Azure resources using Bicep templates
- Sets up AVD host pools, workspaces, and application groups
- Creates or selects Entra ID groups for users and admins
- Assigns RBAC roles for AVD and VM access
- Excludes storage apps from Conditional Access policies as needed
- Optionally deploys session hosts and assigns users to hosts and groups
- Configures VM auto-shutdown and device extension attributes
- Invalidates AVD host pool registration keys for security

---

## Logging

All actions are logged to `vPAWDeploy.log` in the script directory.

---

## Notes

- **PowerShell 7.x is strongly recommended** for compatibility and performance.
- You must have sufficient permissions in Azure and Entra ID (Azure AD).
- The script will prompt for any missing information and guide you through the deployment process.

---

## Author

[Your Name or Organization]

---

## License

[Add your license here, if applicable]
