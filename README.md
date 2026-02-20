# M365 / Entra Toolkit (PowerShell)

PowerShell toolkit for automating common **Microsoft 365 / Entra ID** identity lifecycle and tenant administration tasks.

Designed for IT admins and sysadmins who need a simple, guided interface for:

- User onboarding with secure temp passwords and licensing
- Automated offboarding and session revocation
- SharePoint version cleanup
- Domain-based user audits
- Azure idle resource reporting with cost attribution

Built around **Microsoft Graph** with safe defaults and `-WhatIf` support.

---

## What this demonstrates

- Microsoft Graph automation with PowerShell
- Identity lifecycle automation (onboarding/offboarding)
- Azure resource waste detection and cost analysis
- Secure handling of credentials and environment variables
- Real administrative workflows

---

## Architecture overview

```text
                  +-----------------------------+
                  |  Invoke-M365Toolkit.ps1     |
                  |  (Menu-driven wrapper)      |
                  +-------------+---------------+
                                |
    ---------------------------------------------------------------------
    |                |                  |                |              |
    v                v                  v                v              v
+----------------+  +----------------+  +-------------+  +-----------+  +-------------------+
| New-M365User   |  | Offboard-M365  |  | Cleanup-    |  | Get-Entra |  | azure_idle_report |
| (Onboarding)   |  | (Offboarding)  |  | SharePoint  |  | UsersByDo |  | (Azure waste      |
|                |  |                |  | (Versions)  |  | main      |  |  report, Python)  |
+-------+--------+  +-------+--------+  +------+------+  +-----+-----+  +--------+----------+
        |                    |                  |               |                  |
        v                    v                  v               v                  v
+-----------------------------+     +-----------+---+   +------+---------+  +------+----------+
| Microsoft Graph API         |     | SharePoint    |   | Azure CLI      |  | Azure CLI       |
| - User creation             |     | PnP API       |   | - az login     |  | - az rest       |
| - License assignment        |     | - File version|   | - Entra user   |  | - Cost Mgmt     |
| - Session revocation        |     |   cleanup     |   |   queries      |  | - Resource list |
| - Group/mailbox updates     |     +---------------+   +----------------+  | - Disk/NIC/IP   | 
| - User and domain queries   |                                             |   inventory     |
+-----------------------------+                                             +-----------------+
```

---

## Features

### User onboarding

- Creates a new Entra ID user
- Mandatory job title
- Generates a secure temporary password
- Automatically assigns:
  - Microsoft 365 Business Premium
  - Defender for Office 365 (Plan 2)
- Supports interactive and parameter-driven modes
- Supports `-WhatIf` dry runs

---

### User offboarding

- Disables account
- Revokes sign-in sessions (optional)
- Removes all licenses
- Removes from:
  - Security groups
  - Microsoft 365 groups
  - Distribution lists
- Removes shared mailbox permissions
- Converts mailbox to shared
- Optional Slack notification

---

### SharePoint version cleanup

- App-only authentication
- Dry run by default
- Removes old file versions
- Configurable version retention

---

### Domain user audit

- Lists users by domain
- Member or Guest filtering
- Shows enabled/disabled status
- Optional accurate mode

---

### Azure idle resource report

- Scans all subscriptions in a tenant for idle/wasted resources
- Detects orphaned managed disks, unattached public IPs, unattached NICs, stopped (not deallocated) VMs
- Separates AKS-linked resources into a review bucket (cluster storage/network that may still be needed)
- Optional old snapshot detection with configurable age threshold
- Cost attribution via Azure Cost Management API (last 30 days)
- Includes remediation hints (az CLI commands) for each finding
- Supports text, JSON, and CSV output formats
- Subscription filtering by name or ID

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

### 3) Install Azure CLI

Required for the domain audit and the Azure idle resource report.

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

### 4) Install Python 3 (for Azure idle resource report)

The idle resource report is a Python script. It requires Python 3 and the Azure CLI.

#### macOS (Homebrew)
```bash
brew install python
```

#### Windows
Install from:  
https://www.python.org/downloads/

No additional pip packages are required — the script uses only the standard library and shells out to `az`.

---

### 5) Configure SharePoint app registration (cleanup script)

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

- Microsoft Graph
- Application permissions:
  - `Sites.ReadWrite.All`

Click **Grant admin consent**.

---

### 6) Set environment variables

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

### 7) Run the toolkit

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
5) Azure idle resource report
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
  azure_idle_report.py
README.md
CHANGELOG.md
```

---

## Microsoft Graph Permissions

When prompted during `Connect-MgGraph`, approve:

### Onboarding
- User.ReadWrite.All
- Directory.ReadWrite.All
- Organization.Read.All

### Offboarding
- User.ReadWrite.All
- Group.ReadWrite.All
- Directory.ReadWrite.All

### Domain audit
- User.Read.All  
or  
- Directory.Read.All

---

## Azure Permissions (idle resource report)

The logged-in Azure CLI identity needs:

- **Reader** on each subscription (for resource inventory)
- **Cost Management Reader** on each subscription (for cost data — optional, the report works without it)

---

## Direct Script Usage

### Onboard user (dry run)

```powershell
pwsh ./scripts/New-M365User.ps1 -WhatIf
```

---

### Offboard user

```powershell
pwsh ./scripts/Offboard-M365User.ps1 -User admin@amansk.co -RevokeSignIn
```

---

### SharePoint cleanup

Dry run:

```powershell
pwsh ./scripts/Cleanup-SharePoint.ps1 -SiteUrl "https://tenant.sharepoint.com/sites/example"
```

Execute:

```powershell
pwsh ./scripts/Cleanup-SharePoint.ps1 -SiteUrl "https://tenant.sharepoint.com/sites/example" -Execute
```

---

### Domain audit

```powershell
pwsh ./scripts/Get-EntraUsersByDomain.ps1 -Domains amansk.co -UserType Member
```

---

### Azure idle resource report

Text output (default):

```bash
python3 ./scripts/azure_idle_report.py --tenant <tenant-id>
```

With snapshots and JSON output:

```bash
python3 ./scripts/azure_idle_report.py --tenant <tenant-id> --include-snapshots --output-format json
```

Skip cost lookups (faster):

```bash
python3 ./scripts/azure_idle_report.py --tenant <tenant-id> --no-cost
```

Scan specific subscriptions only:

```bash
python3 ./scripts/azure_idle_report.py --tenant <tenant-id> --only-subs "Prod,Staging"
```

---

## Troubleshooting

### Graph login does not appear or scripts hang at "Connecting to Microsoft Graph"

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

### Azure idle report: "Cost data unavailable"

The logged-in identity needs **Cost Management Reader** on the subscription. This is optional — the report still runs and shows all resources, just without cost figures.

### Azure idle report: "az not found"

Ensure Azure CLI is installed and on your PATH. On macOS with Homebrew:

```bash
brew install azure-cli
```

---

## Notes

- Scripts are safe by default and support dry-run modes.
- Many actions support `-WhatIf`.
- No secrets are stored in scripts.
- Environment variables are used for sensitive values.
- The Azure idle report is read-only and never deletes or modifies resources.

---

## Changelog

### v1.3
- Added Azure idle resource report (Python) to the toolkit
- Updated Invoke-M365Toolkit.ps1 with menu option 5 and RunPython helper
- Idle report includes cost attribution, AKS review bucket, remediation hints, and JSON/CSV output