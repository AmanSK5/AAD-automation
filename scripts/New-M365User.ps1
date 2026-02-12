<# 
.SYNOPSIS
Create a new Microsoft 365 user (Entra ID) with standard fields and assign licenses.

.DESCRIPTION
- Creates user with UPN (firstname.lastname@domain)
- Sets DisplayName, GivenName, Surname, JobTitle, UsageLocation
- Generates random password (prints it once)
- Assigns licenses: Business Premium + Defender for Office 365 Plan 2 (if found)
- Optionally prompts interactively if params not provided

.REQUIREMENTS
Modules:
  - Microsoft.Graph

Graph scopes (delegated):
  - User.ReadWrite.All
  - Directory.ReadWrite.All
  - Organization.Read.All  (to list verified domains + subscribed SKUs)

.EXAMPLES
# Interactive prompts
./New-M365User.ps1

# Non-interactive
./New-M365User.ps1 -FirstName "Aman" -LastName "Karir" -Domain "amansk.co" -JobTitle "Sysadmin" -UsageLocation "GB"

# Dry run
./New-M365User.ps1 -FirstName "Aman" -LastName "Karir" -Domain "amansk.co" -WhatIf
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
  [string]$FirstName,
  [string]$LastName,
  [string]$Domain,
  [string]$UpnLocalPart,
  [string]$JobTitle,
  [string]$UsageLocation = "GB",
  [bool]$ForceChangePasswordNextSignIn = $true
)

function Write-Log {
  param([string]$Message, [ValidateSet('INFO','WARN','ERROR')][string]$Level='INFO')
  $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  $c  = @{ INFO = 'Gray'; WARN='Yellow'; ERROR='Red' }[$Level]
  Write-Host "[$ts][$Level] $Message" -ForegroundColor $c
}

function Ensure-Module {
  param([Parameter(Mandatory)][string]$Name)
  if (-not (Get-Module -ListAvailable -Name $Name)) {
    Write-Log "Module '$Name' not found. Installing for current user…" 'WARN'
    Install-Module $Name -Scope CurrentUser -Force -ErrorAction Stop
  }
  Import-Module $Name -ErrorAction Stop | Out-Null
}

function Normalize-LocalPart {
  param([string]$s)
  if (-not $s) { return $null }
  $s = $s.Trim().ToLower()
  $s = $s -replace '\s+','.'
  $s = $s -replace '[^a-z0-9\.\-]',''
  while ($s -match '\.\.') { $s = $s -replace '\.\.','.' }
  $s.Trim('.')
}

function New-RandomPassword {
  param([int]$Length = 16)
  $upper = "ABCDEFGHJKLMNPQRSTUVWXYZ"
  $lower = "abcdefghijkmnpqrstuvwxyz"
  $digits = "23456789"
  $special = "!@#$%&*?-_"
  $all = ($upper + $lower + $digits + $special).ToCharArray()

  $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
  $bytes = New-Object byte[] ($Length)
  $rng.GetBytes($bytes)

  $pwd = @(
    $upper[ $bytes[0] % $upper.Length ]
    $lower[ $bytes[1] % $lower.Length ]
    $digits[$bytes[2] % $digits.Length]
    $special[$bytes[3] % $special.Length]
  )

  for ($i = 4; $i -lt $Length; $i++) {
    $pwd += $all[ $bytes[$i] % $all.Length ]
  }

  $pwd = $pwd | Sort-Object { Get-Random }
  -join $pwd
}

function Connect-GraphIfNeeded {
  if (-not (Get-MgContext)) {
    Write-Log "Connecting to Microsoft Graph..." 'INFO'
    Connect-MgGraph -Scopes @(
      "User.ReadWrite.All",
      "Directory.ReadWrite.All",
      "Organization.Read.All"
    ) | Out-Null
  }
}

function Select-VerifiedDomain {
  $domains = Get-MgDomain -All -ErrorAction Stop | Where-Object { $_.IsVerified -eq $true } | Sort-Object Id
  if (-not $domains) { throw "No verified domains returned by Graph." }

  Write-Host ""
  Write-Host "Verified domains:" -ForegroundColor Cyan
  for ($i=0; $i -lt $domains.Count; $i++) {
    Write-Host ("[{0}] {1}" -f $i, $domains[$i].Id)
  }

  $choice = Read-Host "Pick domain index"
  if ($choice -notmatch '^\d+$') { throw "Invalid selection." }
  $idx = [int]$choice
  if ($idx -lt 0 -or $idx -ge $domains.Count) { throw "Selection out of range." }
  return $domains[$idx].Id
}

function Find-LicenseSkuIds {
  $skus = Get-MgSubscribedSku -All -ErrorAction Stop

  $bp = $skus | Where-Object {
    $_.SkuPartNumber -match 'BUSINESS_PREMIUM|SPB|O365_BUSINESS_PREMIUM|M365_BUSINESS_PREMIUM' -or
    ($_.ServicePlans | Out-String) -match 'MICROSOFTBOOKINGS'
  } | Select-Object -First 1

  $defO365P2 = $skus | Where-Object {
    $_.SkuPartNumber -match 'ATP_ENTERPRISE|DEFENDER_O365|MDO_P2|O365_ATP' -or
    $_.SkuPartNumber -match 'THREAT_INTELLIGENCE'
  } | Select-Object -First 1

  [pscustomobject]@{
    BusinessPremium = $bp
    DefenderO365P2  = $defO365P2
  }
}

# ----------------------------- main -----------------------------
Ensure-Module -Name Microsoft.Graph
Connect-GraphIfNeeded

if (-not $FirstName) { $FirstName = Read-Host "First name" }
if (-not $LastName)  { $LastName  = Read-Host "Last name" }

# Job Title is mandatory: keep prompting until provided
while ([string]::IsNullOrWhiteSpace($JobTitle)) {
  $JobTitle = Read-Host "Job title (required)"
}

if (-not $Domain) { $Domain = Select-VerifiedDomain }

if (-not $UpnLocalPart) {
  $UpnLocalPart = Normalize-LocalPart ("{0}.{1}" -f $FirstName, $LastName)
} else {
  $UpnLocalPart = Normalize-LocalPart $UpnLocalPart
}

$upn = "{0}@{1}" -f $UpnLocalPart, $Domain
$displayName = ("{0} {1}" -f $FirstName.Trim(), $LastName.Trim()).Trim()
$mailNick = $UpnLocalPart

Write-Host ""
Write-Log "UPN: $upn" 'INFO'
Write-Log "DisplayName: $displayName" 'INFO'
Write-Log "JobTitle: $JobTitle" 'INFO'
Write-Log "UsageLocation: $UsageLocation" 'INFO'

# Existence check
try {
  $existing = Get-MgUser -UserId $upn -ErrorAction Stop
  if ($existing) { throw "User already exists: $upn" }
} catch {
  if ($_.Exception.Message -notmatch 'Request_ResourceNotFound|NotFound') {
    Write-Log "User existence check note: $($_.Exception.Message)" 'WARN'
  }
}

$password = New-RandomPassword
Write-Log "Generated temp password length: $($password.Length)" 'INFO'

# --- preflight validation ---
if ([string]::IsNullOrWhiteSpace($displayName)) { throw "displayName is empty." }
if ([string]::IsNullOrWhiteSpace($upn))         { throw "UPN is empty." }
if ([string]::IsNullOrWhiteSpace($mailNick))    { throw "mailNickname is empty." }
if ([string]::IsNullOrWhiteSpace($password))    { throw "Password generation returned empty string." }
if ([string]::IsNullOrWhiteSpace($JobTitle))    { throw "JobTitle is required but empty." }

# Build Graph payload (exact Graph schema) — JobTitle always included
$body = [ordered]@{
  accountEnabled    = $true
  displayName       = $displayName
  mailNickname      = $mailNick
  userPrincipalName = $upn
  givenName         = $FirstName
  surname           = $LastName
  jobTitle          = $JobTitle
  usageLocation     = $UsageLocation
  passwordProfile   = @{
    password                      = $password
    forceChangePasswordNextSignIn = [bool]$ForceChangePasswordNextSignIn
  }
}

Write-Log "DEBUG: body.displayName = '$($body.displayName)' (len=$($body.displayName.Length))" 'INFO'
Write-Log "DEBUG: body.userPrincipalName = '$($body.userPrincipalName)'" 'INFO'

# Redacted payload dump (safe to leave in while debugging)
$redacted = ($body | ConvertTo-Json -Depth 10) -replace '"password"\s*:\s*".*?"','"password": "REDACTED"'
Write-Host "`n=== DEBUG PAYLOAD (REDACTED) ===`n$redacted`n==============================`n"

# ---- CREATE USER (raw POST to Graph; bypass SDK model mapping) ----
if ($PSCmdlet.ShouldProcess($upn, "Create Entra ID user")) {
  $json = $body | ConvertTo-Json -Depth 10

  $newUser = Invoke-MgGraphRequest -Method POST `
    -Uri "https://graph.microsoft.com/v1.0/users" `
    -ContentType "application/json" `
    -Body $json `
    -ErrorAction Stop

  Write-Log "Created user: $($newUser.id)" 'INFO'
  Write-Host ""
  Write-Host "TEMP PASSWORD (copy now): $password" -ForegroundColor Yellow
  Write-Host ""
}

# Assign licenses (raw Graph call to avoid SDK serialization issues)
try {
  $skuPick = Find-LicenseSkuIds

  $addLicenses = @()

  if ($skuPick.BusinessPremium) {
    $addLicenses += @{ skuId = ([string]$skuPick.BusinessPremium.SkuId) }
    Write-Log "Found Business Premium SKU: $($skuPick.BusinessPremium.SkuPartNumber)" 'INFO'
  } else {
    Write-Log "Business Premium SKU not found in tenant. (No license will be applied for it.)" 'WARN'
  }

  if ($skuPick.DefenderO365P2) {
    $addLicenses += @{ skuId = ([string]$skuPick.DefenderO365P2.SkuId) }
    Write-Log "Found Defender for O365 SKU: $($skuPick.DefenderO365P2.SkuPartNumber)" 'INFO'
  } else {
    Write-Log "Defender for Office 365 (Plan 2) SKU not found in tenant. (No license will be applied for it.)" 'WARN'
  }

  if ($addLicenses.Count -gt 0) {
    if ($PSCmdlet.ShouldProcess($upn, "Assign $($addLicenses.Count) license(s)")) {

      $userId = $null
      if ($newUser -and $newUser.id) { $userId = $newUser.id }
      if (-not $userId) {
        $u = Get-MgUser -UserId $upn -Property "id" -ErrorAction Stop
        $userId = $u.Id
      }

      $assignBody = @{
        addLicenses    = $addLicenses
        removeLicenses = @()
      } | ConvertTo-Json -Depth 10

      Write-Host "`n=== DEBUG assignLicense payload ===`n$assignBody`n===============================`n"

      $null = Invoke-MgGraphRequest -Method POST `
        -Uri "https://graph.microsoft.com/v1.0/users/$userId/assignLicense" `
        -ContentType "application/json" `
        -Body $assignBody `
        -ErrorAction Stop

      Write-Log "Assigned licenses successfully." 'INFO'

      $details = Get-MgUserLicenseDetail -UserId $userId -All -ErrorAction SilentlyContinue
      if ($details) {
        Write-Log ("License details now: " + (($details | Select-Object -ExpandProperty SkuPartNumber) -join ", ")) 'INFO'
      } else {
        Write-Log "No license details returned yet (can take a moment). Check Entra UI shortly." 'WARN'
      }
    }
  } else {
    Write-Log "No licenses to add (no matching SKUs found)." 'WARN'
  }
}
catch {
  Write-Log "License assignment issue: $($_.Exception.Message)" 'ERROR'
}

Write-Host ""
Write-Log "Onboarding complete for $upn" 'INFO'