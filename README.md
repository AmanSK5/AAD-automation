# Azure AD / Microsoft 365 User Automation

PowerShell automation for onboarding and offboarding Microsoft 365 users using Microsoft Graph and Exchange Online. Yes, even with fancy tools like Runbook/Puppet/etc, PowerShell still is a good fit for common tasks in a Microsoft stack. 

This repository contains scripts designed for IT teams to standardise and automate common identity lifecycle tasks.

---

## Features

### Onboarding (`New-M365User.ps1`)

* Interactive or parameter-driven user creation
* Creates Entra ID user with:

  * First name
  * Last name
  * Job title
  * Domain selection
  * Usage location
* Generates secure temporary password
* Assigns:

  * Microsoft 365 Business Premium
  * Defender for Office 365 (Plan 2)

### Offboarding (`Offboard-M365User.ps1`)

* Disables user account
* Revokes sign-in sessions
* Removes licenses
* Removes group memberships
* Cleans shared mailbox permissions
* Converts mailbox to shared
* Optional Slack notification

---

## Requirements

### PowerShell modules

* Microsoft.Graph
* ExchangeOnlineManagement

### Graph permissions

Delegated scopes required:

* `User.ReadWrite.All`
* `Directory.ReadWrite.All`
* `Group.ReadWrite.All`
* `Organization.Read.All`

---

## Setup

1. Clone the repository

## Usage

### Interactive onboarding

```powershell
./New-M365User.ps1
```

### Non-interactive onboarding

```powershell
./New-M365User.ps1 `
  -FirstName "Aman" `
  -LastName "Karir" `
  -Domain "amansk.co" `
  -JobTitle "Sysadmin"
```

### Dry run

```powershell
./New-M365User.ps1 -WhatIf
```

---

### Offboarding a user

```powershell
./Offboard-M365User.ps1 `
  -User amank@amansk.co `
  -RevokeSignIn
```

With Slack notification:

```powershell
./Offboard-M365User.ps1 `
  -User mank@amansk.co `
  -RevokeSignIn `
  -SlackWebhookUrl "https://hooks.slack.com/services/XXX/YYY/ZZZ"
```

---

## Configuration

Example config:

```json
{
  "Tenant": {
    "DefaultUsageLocation": "GB",
    "AllowedDomains": ["amansk.co"]
  },
  "Licensing": {
    "BusinessPremiumSkuPartNumber": "SPB",
    "DefenderO365P2SkuPartNumber": "ATP_ENTERPRISE"
  }
}
```

---

## Security Notes

* Do not commit real configuration files or secrets.
* Review Graph permissions before use in production.

---

## Disclaimer

These scripts are provided as-is.
Always test in a non-production environment before deploying to live tenants.

---

## License

MIT License
