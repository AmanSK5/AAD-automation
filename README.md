M365 / Entra Toolkit (PowerShell)

PowerShell toolkit for common Microsoft 365 / Entra ID administrative tasks, including:

User onboarding

User offboarding

SharePoint version cleanup

Domain-based user audits

Designed for IT admins and junior sysadmins who need a simple, guided interface for common identity lifecycle tasks.

Quick Start

Install PowerShell 7

Install required modules

Login to Azure

Run the toolkit

1) Install required modules (inside PowerShell)
Install-Module Microsoft.Graph -Scope CurrentUser
Install-Module ExchangeOnlineManagement -Scope CurrentUser
Install-Module PnP.PowerShell -Scope CurrentUser
2) Login to Azure (for domain audit)
az login

If working in a guest tenant:

az login --tenant <tenant-id>
3) Set required environment variables (SharePoint only)
$env:SP_CLIENT_ID="xxxxx"
$env:SP_CLIENT_SECRET="yyyyy"
4) Run the toolkit
pwsh ./Invoke-M365Toolkit.ps1
Features
1) User onboarding

Creates a new Entra ID user with:

First name

Last name

Job title

Domain selection

Usage location

Secure temporary password

License assignment:

Microsoft 365 Business Premium

Defender for Office 365 (Plan 2)

2) User offboarding

Performs full offboarding workflow:

Disable account

Revoke sign-in sessions (optional)

Remove all licenses

Remove from:

Security groups

M365 groups

Distribution lists

Remove shared mailbox permissions

Convert mailbox to shared

Optional Slack notification

3) SharePoint version cleanup

Reduces storage by removing old file versions.

App-only authentication

Dry-run by default

Configurable version retention

4) Domain user audit

Lists users by domain with status:

Member or Guest users

Filters by mail or UPN domain

Shows enabled/disabled state

Optional “accurate” mode for real-time status

Prerequisites
PowerShell 7

This toolkit requires PowerShell 7 (pwsh).

Windows

Install from:
https://learn.microsoft.com/powershell/scripting/install/installing-powershell

macOS (Homebrew)
brew install --cask powershell

Launch:

pwsh
Linux (Ubuntu example)
sudo apt-get update
sudo apt-get install -y powershell

Launch:

pwsh
Required PowerShell Modules

Install once inside PowerShell:

Install-Module Microsoft.Graph -Scope CurrentUser
Install-Module ExchangeOnlineManagement -Scope CurrentUser
Install-Module PnP.PowerShell -Scope CurrentUser
Azure CLI (required for domain audit script)

Install:
https://learn.microsoft.com/cli/azure/install-azure-cli

Login:

az login

Guest tenant:

az login --tenant <tenant-id>
Microsoft Graph Permissions

When prompted during Connect-MgGraph, approve:

Onboarding

User.ReadWrite.All

Directory.ReadWrite.All

Organization.Read.All

Offboarding

User.ReadWrite.All

Group.ReadWrite.All

Directory.ReadWrite.All

Domain audit

User.Read.All
or

Directory.Read.All

Environment Variables

Secrets are handled via environment variables instead of being stored in scripts.

Set these inside the PowerShell session before running the toolkit.

SharePoint cleanup (required for script 3)
Variable	Description
SP_CLIENT_ID	SharePoint app registration client ID
SP_CLIENT_SECRET	SharePoint app registration client secret

Set in PowerShell:

$env:SP_CLIENT_ID="xxxxx"
$env:SP_CLIENT_SECRET="yyyyy"
Slack offboarding notifications (optional)
Variable	Description
SLACK_WEBHOOK_URL	Slack incoming webhook URL
$env:SLACK_WEBHOOK_URL="https://hooks.slack.com/services/XXX/YYY/ZZZ"
Usage

Start the interactive toolkit:

pwsh ./Invoke-M365Toolkit.ps1

Menu:

1) Onboard user
2) Offboard user
3) SharePoint cleanup
4) Domain user audit
Q) Quit
Example Commands (Direct Script Use)
Onboard user (dry run)
./New-M365User.ps1 -WhatIf
Offboard user
./Offboard-M365User.ps1 -User test@company.com -RevokeSignIn

With Slack:

./Offboard-M365User.ps1 `
  -User test@company.com `
  -RevokeSignIn `
  -SlackWebhookUrl $env:SLACK_WEBHOOK_URL
SharePoint cleanup (dry run)
./Cleanup-SharePoint.ps1 -SiteUrl "https://tenant.sharepoint.com/sites/example"

Execute deletion:

./Cleanup-SharePoint.ps1 `
  -SiteUrl "https://tenant.sharepoint.com/sites/example" `
  -Execute
Domain audit
./Get-EntraUsersByDomain.ps1 -Domains tangent.co -UserType Member

Accurate mode:

./Get-EntraUsersByDomain.ps1 `
  -Domains tangent.co `
  -UserType Member `
  -Accurate
Repository Structure
Invoke-M365Toolkit.ps1
New-M365User.ps1
Offboard-M365User.ps1
Cleanup-SharePoint.ps1
Get-EntraUsersByDomain.ps1
README.md
Notes

All scripts support -WhatIf where applicable.

Designed to be safe by default (dry-run behaviour where possible).

No secrets stored in scripts.
