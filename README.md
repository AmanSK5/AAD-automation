# Azure AD / Microsoft 365 User Automation

PowerShell automation for onboarding and offboarding Microsoft 365 users using Microsoft Graph and Exchange Online.
Even with platforms like Runbooks, Puppet, or other automation tools, PowerShell remains a practical and effective option for common identity lifecycle tasks in Microsoft environments.

This repository contains scripts designed for IT teams to standardise and automate user onboarding and offboarding processes.

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
* Optionally revokes sign-in sessions
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
2. Install required PowerShell modules:

```powershell
Install-Module Microsoft.Graph -Scope CurrentUser
Install-Module ExchangeOnlineManagement -Scope CurrentUser
```

3. Run the scripts from a PowerShell session.

---

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
  -User amank@amansk.co `
  -RevokeSignIn `
  -SlackWebhookUrl "https://hooks.slack.com/services/XXX/YYY/ZZZ"
```

---

## Configuration

Example configuration structure:

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

Do not commit real configuration files or secrets to the repository.

---

## Security Notes

* Do not commit real configuration files, secrets, or webhook URLs.
* Review Graph permissions before use in production.
* The onboarding script generates a temporary password and displays it once.
  Share it with the user via a secure channel and avoid running the script in environments where console output is logged or recorded.

---

## Disclaimer

These scripts are provided as-is.
Always test in a non-production environment before deploying to live tenants.

---

## License

MIT License
