# M365 / Entra Toolkit (PowerShell)

PowerShell toolkit for common **Microsoft 365 / Entra ID** administrative tasks.

Designed for IT admins/sysadmins who need a simple, guided interface for identity lifecycle and tenant housekeeping.

---
## Changelog

### v1.2
- Refactored New-M365User.ps1 to use raw Microsoft Graph API calls
- Fixed password profile serialization issues
- Fixed license assignment errors
- Enforced mandatory Job Title input
- Improved validation and debug logging

## Features

### User onboarding

* Creates a new Entra ID user
* Generates a secure temporary password
* Assigns:

  * Microsoft 365 Business Premium
  * Defender for Office 365 (Plan 2)
* Supports interactive and parameter-driven modes
* Supports `-WhatIf` dry runs

### User offboarding

* Disables account
* Revokes sign-in sessions (optional)
* Removes all licenses
* Removes from:

  * Security groups
  * Microsoft 365 groups
  * Distribution lists
* Removes shared mailbox permissions
* Converts mailbox to shared
* Optional Slack notification

### SharePoint version cleanup

* App-only authentication
* Dry run by default
* Removes old file versions
* Configurable version retention

### Domain user audit

* Lists users by domain
* Member or Guest filtering
* Shows enabled/disabled status
* Optional accurate mode

---

## Quick Start

### 1) Install PowerShell 7

#### Windows

Install from:
https://learn.microsoft.com/powershell/scripting/install/installing-powershell

#### macOS (Homebrew)

```bash
brew install --cask powershell
```

#### Linux (Ubuntu example)

```bash
sudo apt-get update
sudo apt-get install -y powershell
```

Launch PowerShell:

```bash
pwsh
```

---

### 2) Install required PowerShell modules

Run inside PowerShell:

```powershell
Install-Module Microsoft.Graph -Scope CurrentUser
Install-Module ExchangeOnlineManagement -Scope CurrentUser
Install-Module PnP.PowerShell -Scope CurrentUser
```

---

### 3) Install Azure CLI (for domain audit)

Install:
https://learn.microsoft.com/cli/azure/install-azure-cli

Login:

```bash
az login
```

If working in a guest tenant:

```bash
az login --tenant <tenant-id>
```

---

### 4) Configure SharePoint app registration (required for cleanup script)

Create an **App Registration** in Azure:

1. Azure Portal → Entra ID → App registrations
2. New registration
3. Name: `SharePoint-Cleanup`
4. Single tenant
5. Create

Then:

1. Go to **Certificates & secrets**
2. Create a **client secret**
3. Copy the value

Grant API permissions:

* Microsoft Graph
* Application permissions:

  * `Sites.ReadWrite.All`

Click **Grant admin consent**.

---

### 5) Set environment variables

Inside PowerShell:

```powershell
$env:SP_CLIENT_ID="xxxxx"
$env:SP_CLIENT_SECRET="yyyyy"
```

Optional (Slack offboarding notifications):

```powershell
$env:SLACK_WEBHOOK_URL="https://hooks.slack.com/services/XXX/YYY/ZZZ"
```

---

### 6) Run the toolkit

From the repo root:

```powershell
pwsh ./Invoke-M365Toolkit.ps1
```

Menu:

```
1) Onboard user
2) Offboard user
3) SharePoint cleanup
4) Domain user audit
Q) Quit
```

---

## Repository Structure

```
Invoke-M365Toolkit.ps1
scripts/
  New-M365User.ps1
  Offboard-M365User.ps1
  Cleanup-SharePoint.ps1
  Get-EntraUsersByDomain.ps1
README.md
```

---

## Microsoft Graph Permissions

When prompted during `Connect-MgGraph`, approve:

### Onboarding

* User.ReadWrite.All
* Directory.ReadWrite.All
* Organization.Read.All

### Offboarding

* User.ReadWrite.All
* Group.ReadWrite.All
* Directory.ReadWrite.All

### Domain audit

* User.Read.All
  or
* Directory.Read.All

---

## Direct Script Usage

### Onboard user (dry run)

```powershell
pwsh ./scripts/New-M365User.ps1 -WhatIf
```

### Offboard user

```powershell
pwsh ./scripts/Offboard-M365User.ps1 -User test@company.com -RevokeSignIn
```

### SharePoint cleanup

Dry run:

```powershell
pwsh ./scripts/Cleanup-SharePoint.ps1 -SiteUrl "https://tenant.sharepoint.com/sites/example"
```

Execute:

```powershell
pwsh ./scripts/Cleanup-SharePoint.ps1 -SiteUrl "https://tenant.sharepoint.com/sites/example" -Execute
```

### Domain audit

```powershell
pwsh ./scripts/Get-EntraUsersByDomain.ps1 -Domains company.com -UserType Member
```

---

## Troubleshooting

### Graph login does not appear or scripts hang at “Connecting to Microsoft Graph”

Reset the Graph session:

```powershell
Disconnect-MgGraph -ErrorAction SilentlyContinue
```

Reconnect manually:

```powershell
$tenantId = "<your-tenant-id>"

Connect-MgGraph `
  -TenantId $tenantId `
  -Scopes @(
    "User.ReadWrite.All",
    "Directory.ReadWrite.All",
    "Group.ReadWrite.All"
  ) `
  -ContextScope Process `
  -NoWelcome
```

Then run the toolkit again:

```powershell
pwsh ./Invoke-M365Toolkit.ps1
```

---

## Notes

* Scripts are safe by default.
* Many actions support `-WhatIf`.
* No secrets are stored in scripts.
* Environment variables are used for sensitive values.
