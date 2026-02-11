# M365 / Entra Toolkit (PowerShell)

PowerShell toolkit for common **Microsoft 365 / Entra ID** administrative tasks.

Designed for IT admins/sysadmins who need a simple, guided interface for identity lifecycle and tenant housekeeping.

---

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
  * M365 groups
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

## Prerequisites

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

### 3) Install Azure CLI (for domain audit script)

Install:
https://learn.microsoft.com/cli/azure/install-azure-cli

Login:

```bash
az login
```

Guest tenant:

```bash
az login --tenant <tenant-id>
```

---

### 4) SharePoint app registration (required for cleanup script)

The SharePoint cleanup script uses **app-only authentication**.

You must create an app registration in Azure:

1. Go to **Azure Portal → Entra ID → App registrations**
2. Click **New registration**
3. Name: `SharePointCleanupApp` (or similar)
4. Leave defaults and create

After creation:

1. Go to **Certificates & secrets**
2. Create a **new client secret**
3. Copy the **Client ID** and **Client Secret**

Then grant SharePoint permissions:

1. Go to **API permissions**
2. Add permission → **SharePoint**
3. Application permissions:

   * `Sites.FullControl.All` (or minimum required)
4. Click **Grant admin consent**

---

## Environment Variables

Set these in the same PowerShell session before running scripts.

### SharePoint (required for cleanup)

```powershell
$env:SP_CLIENT_ID="xxxxx"
$env:SP_CLIENT_SECRET="yyyyy"
```

### Slack (optional for offboarding notifications)

```powershell
$env:SLACK_WEBHOOK_URL="https://hooks.slack.com/services/XXX/YYY/ZZZ"
```

---

## Quick Start

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
  SharePointCleanup.ps1
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
./scripts/New-M365User.ps1 -WhatIf
```

### Offboard user

```powershell
./scripts/Offboard-M365User.ps1 -User test@company.com -RevokeSignIn
```

### SharePoint cleanup

Dry run:

```powershell
./scripts/SharePointCleanup.ps1 -SiteUrl "https://tenant.sharepoint.com/sites/example"
```

Execute:

```powershell
./scripts/SharePointCleanup.ps1 -SiteUrl "https://tenant.sharepoint.com/sites/example" -Execute
```

### Domain audit

```powershell
./scripts/Get-EntraUsersByDomain.ps1 -Domains tangent.co -UserType Member
```

---

## Notes

* Scripts are safe by default.
* Many actions support `-WhatIf`.
* No secrets are stored in scripts.
* Environment variables are session-based unless persisted.
