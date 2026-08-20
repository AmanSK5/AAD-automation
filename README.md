# M365 / Entra Toolkit (PowerShell)

PowerShell toolkit for automating common **Microsoft 365 / Entra ID** identity lifecycle and tenant administration tasks.

Designed for IT admins and sysadmins who need a simple, guided interface for:

- User onboarding with secure temp passwords and licensing
- Automated offboarding and session revocation
- SharePoint version cleanup
- Domain-based user audits
- Azure idle resource reporting with cost attribution

Built around **Microsoft Graph** with safe defaults and dry-run modes throughout.

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
| New-M365User   |  | Offboard-M365  |  | sharepoint  |  | Get-Entra |  | azure_idle_report |
| (Onboarding)   |  | (Offboarding)  |  | cleanup     |  | UsersByDo |  | (Azure waste      |
|                |  |                |  | (Versions)  |  | main      |  |  report, Python)  |
+-------+--------+  +-------+--------+  +------+------+  +-----+-----+  +--------+----------+
        |                    |                  |               |                  |
        v                    v                  v               v                  v
+-----------------------------+     +-----------+---+   +------+---------+  +------+----------+
| Microsoft Graph API         |     | SharePoint    |   | Azure CLI      |  | Azure CLI       |
| - User creation             |     | PnP API       |   | - az login     |  | - az rest       |
| - License assignment        |     | - Delegated   |   | - Entra user   |  | - Cost Mgmt     |
| - Session revocation        |     |   interactive |   |   queries      |  | - Resource list |
| - Group/mailbox updates     |     | - File version|   +----------------+  | - Disk/NIC/IP   |
| - User and domain queries   |     |   cleanup     |                       |   inventory     |
+-----------------------------+     +---------------+                       +-----------------+
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

- **Delegated interactive authentication** — each operator signs in as themselves
- Dry run by default; `-Execute` required to delete
- Typed confirmation before any deletion
- Configurable version retention per file
- CSV audit log of every version considered, deleted, or failed
- Throttle-aware retry honouring `Retry-After`
- Per-file error handling so one locked file does not abort the run

> **Deletions are permanent.** Versions removed by this script do not go to the
> recycle bin and cannot be recovered. Always run a dry run first and review the
> CSV before using `-Execute`.

> **Performance note.** The script makes one API call per file, which works out
> at roughly two seconds per file. For libraries above a few thousand files,
> use SharePoint's server-side trim jobs instead — see
> [Large libraries](#large-libraries) below.

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

Optional, only needed for the server-side trim jobs described under
[Large libraries](#large-libraries):

```powershell
Install-Module Microsoft.Online.SharePoint.PowerShell -Scope CurrentUser
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

### 5) Configure the SharePoint app registration (cleanup script)

The cleanup script uses **delegated** authentication. The app registration holds
no credentials of its own — no secret, no certificate, nothing to rotate or
distribute. Each operator signs in as themselves, so MFA and Conditional Access
apply as normal and every deletion is attributed to a real person in the
unified audit log.

This is a one-time setup. Once the client ID is committed to this repo, team
members need no configuration at all.

**Create the app**

1. Entra admin centre → Applications → App registrations → New registration
2. Name: `SPO Version Cleanup`
3. Supported account types: **Accounts in this organizational directory only**
4. Leave the redirect URI blank → Register

**Configure the public client redirect**

1. Authentication → Add a platform → **Mobile and desktop applications**
2. Under **Custom redirect URIs**, add `http://localhost`
   (`http`, not `https`. No port, no trailing slash. Loopback is exempt from the
   HTTPS-only rule. Leave the three preset checkboxes unticked.)
3. Scroll to **Advanced settings** → set **Allow public client flows** to **Yes**

Without step 3 the browser sign-in completes but the token is never handed back
to the local session, and the script hangs.

**Add delegated permissions**

1. API permissions → Add a permission → **SharePoint** → **Delegated permissions**
2. Select `AllSites.Manage`
3. Click **Grant admin consent**

Only escalate to `AllSites.FullControl` if you hit permission errors on a
specific library. Do **not** add any Application permissions — the app should
never be able to act on its own, only on behalf of a signed-in user who already
has rights to the site.

**Restrict who can use it**

1. Enterprise applications → find the same app → Properties
2. Set **Assignment required?** to **Yes**
3. Users and groups → assign the IT security group

This gives a clean revocation point and a defensible answer at access review.

**Record the client ID**

Copy the **Application (client) ID** from the app registration Overview blade
into the `ClientId` default in `scripts/sharepointcleanup.ps1`. This value is
not a secret and is safe to commit.

---

### 6) Set environment variables

The SharePoint cleanup script needs no environment variables — the client ID is
committed in the script. Override it only if you need to point at a different
app registration:

```powershell
$env:SPO_CLEANUP_CLIENT_ID="xxxxx"
```

Optional (Slack offboarding notifications):

```powershell
$env:SLACK_WEBHOOK_URL="https://hooks.slack.com/services/XXX/YYY/ZZZ"
```

> **Note:** earlier versions of this toolkit used `SP_CLIENT_ID` and
> `SP_CLIENT_SECRET`. Both are obsolete. If you still have them exported in a
> shell profile, remove them — a stale `SP_CLIENT_ID` will not affect the
> current script, but leaving dead credentials in your environment is worth
> tidying up.

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
3) SharePoint version cleanup
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
  sharepointcleanup.ps1
  Get-EntraUsersByDomain.ps1
  azure_idle_report.py
  logs/                    # CSV audit logs (gitignored)
.gitignore
README.md
CHANGELOG.md
```

Add `logs/` to `.gitignore`. The CSV audit logs contain full file paths from
across the tenant and should not be committed.

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

## SharePoint Permissions (version cleanup)

Delegated only, via the app registration in step 5:

- `AllSites.Manage` (SharePoint, delegated)

Because the token is delegated, the effective permission is the intersection of
the app's scope and the signed-in user's own access. A user without rights to a
site cannot touch it regardless of the app's configuration.

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

### SharePoint version cleanup

Dry run (default — nothing is deleted):

```powershell
pwsh ./scripts/sharepointcleanup.ps1 -SiteUrl "https://tenant.sharepoint.com/sites/example"
```

Specify library and retention:

```powershell
pwsh ./scripts/sharepointcleanup.ps1 `
  -SiteUrl "https://tenant.sharepoint.com/sites/example" `
  -LibraryName "Shared Documents" `
  -VersionsToKeep 5
```

Execute (permanent deletion, prompts for typed confirmation):

```powershell
pwsh ./scripts/sharepointcleanup.ps1 -SiteUrl "https://tenant.sharepoint.com/sites/example" -Execute
```

`-VersionsToKeep` counts **historical** versions. The current live version is
always retained and is not included in the count, so `-VersionsToKeep 10` leaves
11 copies of each file.

The reported byte total is an upper bound. SharePoint uses shredded storage, so
actual reclaimed space is lower, and site storage metrics can take 24 hours to
update.

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

## Large libraries

The cleanup script iterates file by file, which is fine for small or targeted
cleanups where the per-version audit trail matters, but does not scale. At
roughly two seconds per file, a 10,000-file library takes over five hours for
the dry run alone.

For anything large, use SharePoint's server-side trim jobs, which run in the
backend and return immediately. These require SharePoint Administrator and are
delegated, so no app registration is involved:

```powershell
Connect-SPOService -Url https://<tenant>-admin.sharepoint.com

# Preview impact
New-SPOListFileVersionBatchDeleteJob -Site "<site-url>" -List "Documents" `
  -MajorVersionLimit 10 -MajorWithMinorVersionsLimit 10 -WhatIf

# Queue the job
New-SPOListFileVersionBatchDeleteJob -Site "<site-url>" -List "Documents" `
  -MajorVersionLimit 10 -MajorWithMinorVersionsLimit 10
```

These jobs also permanently delete and bypass the recycle bin. Run the impact
analysis first. Some parameters are still rolling out, so check
`Get-Command New-SPOListFileVersionBatchDeleteJob -Syntax` against your tenant.

To stop the problem recurring, enable intelligent versioning
(`EnableAutoExpirationVersionTrim`) at tenant or site level rather than
re-running cleanup on a schedule.

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

### SharePoint cleanup: 401 Unauthorized on Get-PnPWeb

`Connect-PnPOnline` does not validate against SharePoint at connect time, so it
appears to succeed and the first real call is where the token is rejected.

Check in this order:

1. **Stale environment variables.** If `SP_CLIENT_ID` is still exported from an
   older version of this toolkit, unset it: `Remove-Item Env:SP_CLIENT_ID`
2. **API permissions not granted.** Confirm `AllSites.Manage` is present with
   admin consent granted (green tick) on the app registration.
3. **Assignment required.** If assignment is enforced, confirm your account is
   in the assigned group.

Note that app-only authentication with a client secret no longer works against
SharePoint at all. Azure ACS was retired in April 2026 and secret-based app-only
tokens now fail validation regardless of whether the credential itself has
expired. This is why the script uses delegated auth.

### SharePoint cleanup: no browser window opens

Usually a cached token. PnP caches under `~/.IdentityService` — delete that
directory to force a fresh interactive sign-in.

If a browser opens but sign-in fails with `AADSTS700016`, the client ID in the
script is wrong or the app does not exist in your tenant.

### SharePoint cleanup: appears to hang after "Enumerating items"

Progress prints once per page of 500 items. On a large library the first page
can take ten minutes or more. Confirm it is alive by watching the CSV grow:

```powershell
wc -l ./scripts/logs/versioncleanup-<...>.csv
```

If the count is climbing it is working. See [Large libraries](#large-libraries)
for the faster alternative.

### SharePoint cleanup: some deletions fail

Expected. Files under a retention label, in a preservation hold library, or
currently checked out cannot have versions removed. These are logged as failures
in the CSV with the underlying reason and do not stop the run.

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
- The onboarding script supports `-WhatIf`. The SharePoint cleanup script uses
  `-Execute` instead: it dry runs unless explicitly told otherwise.
- No secrets are stored in scripts. The SharePoint client ID is committed
  deliberately — a client ID is not a credential.
- Environment variables are used for sensitive values.
- The Azure idle report is read-only and never deletes or modifies resources.
- SharePoint version deletion is **permanent** and bypasses the recycle bin.

---

## Changelog

### v1.4

- SharePoint cleanup migrated from app-only client secret to delegated interactive auth (Azure ACS retired April 2026)
- Added CSV audit logging, throttle-aware retry, per-file error handling and typed confirmation on execute
- Fixed version size accounting — previously used current file size per version, inflating reclaimed-space estimates
- Wrapper now passes `-WhatIf` only to scripts that declare it, and traps script errors instead of exiting the menu
- Wrapper option 3 now prompts for library, retention and execute mode
- Documented server-side trim jobs for large libraries

### v1.3

- Added Azure idle resource report (Python) to the toolkit
- Updated Invoke-M365Toolkit.ps1 with menu option 5 and RunPython helper
- Idle report includes cost attribution, AKS review bucket, remediation hints, and JSON/CSV output