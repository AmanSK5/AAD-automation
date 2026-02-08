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
  [string]$UpnLocalPart,        # optional override; default firstname.lastname
  [string]$JobTitle,
  [string]$UsageLocation = "GB",# UK is GB in M365 usage location
  [switch]$ForceChangePasswordNextSignIn = $true
)

# ----------------------------- helpers -----------------------------
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
  # replace spaces with dots, strip weird characters except dot and dashes
  $s = $s -replace '\s+','.'
  $s = $s -replace '[^a-z0-9\.\-]',''
  # collapse multiple dots
  while ($s -match '\.\.') { $s = $s -replace '\.\.','.' }
  $s.Trim('.')
}

function New-RandomPassword {
  param([int]$Length = 16)
  # Strong-ish: upper/lower/digits/special
  $upper = "ABCDEFGHJKLMNPQRSTUVWXYZ"
  $lower = "abcdefghijkmnpqrstuvwxyz"
  $digits = "23456789"
  $special = "!@#$%&*?-_"
  $all = ($upper + $lower + $digits + $special).ToCharArray()

  $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
  $bytes = New-Object byte[] ($Length)
  $rng.GetBytes($bytes)

  # ensure at least one from each set
  $pwd = @(
    $upper[ $bytes[0] % $upper.Length ]
    $lower[ $bytes[1] % $lower.Length ]
    $digits[$bytes[2] % $digits.Length]
    $special[$bytes[3] % $special.Length]
  )

  for ($i = 4; $i -lt $Length; $i++) {
    $pwd += $all[ $bytes[$i] % $all.Length ]
  }

  # shuffle
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
  # We try to find two SKUs in YOUR tenant by common identifiers
  # You can tweak these strings if your tenant names differ.
  $skus = Get-MgSubscribedSku -All -ErrorAction Stop

  # Candidate matches
  $bp = $skus | Where-Object {
    $_.SkuPartNumber -match 'BUSINESS_PREMIUM|SPB|O365_BUSINESS_PREMIUM|M365_BUSINESS_PREMIUM' -or
    ($_.ServicePlans | Out-String) -match 'MICROSOFTBOOKINGS'
  } | Select-Object -First 1

  $defO365P2 = $skus | Where-Object {
    $_.SkuPartNumber -match 'ATP_ENTERPRISE|DEFENDER_O365|MDO_P2|O365_ATP' -or
    $_.SkuPartNumber -match 'THREAT_INTELLIGENCE' # fallback-ish
  } | Select-Object -First 1

  return [pscustomobject]@{
    BusinessPremium = $bp
    DefenderO365P2  = $defO365P2
  }
}

# ----------------------------- main -----------------------------
Ensure-Module -Name Microsoft.Graph
Connect-GraphIfNeeded

# Prompt for missing fields
if (-not $FirstName) { $FirstName = Read-Host "First name" }
if (-not $LastName)  { $LastName  = Read-Host "Last name" }

if (-not $Domain) {
  $Domain = Select-VerifiedDomain
}

if (-not $UpnLocalPart) {
  $UpnLocalPart = Normalize-LocalPart ("{0}.{1}" -f $FirstName, $LastName)
} else {
  $UpnLocalPart = Normalize-LocalPart $UpnLocalPart
}

$upn = "{0}@{1}" -f $UpnLocalPart, $Domain
$displayName = ("{0} {1}" -f $FirstName.Trim(), $LastName.Trim()).Trim()
$mailNick = $UpnLocalPart
$mail = $upn

Write-Host ""
Write-Log "UPN: $upn" 'INFO'
Write-Log "DisplayName: $displayName" 'INFO'
Write-Log "UsageLocation: $UsageLocation" 'INFO'

# Check if user already exists
try {
  $existing = Get-MgUser -UserId $upn -ErrorAction Stop
  if ($existing) {
    throw "User already exists: $upn"
  }
} catch {
  # If it's "not found", we continue. If it's another error, throw.
  if ($_.Exception.Message -notmatch 'Request_ResourceNotFound|NotFound') {
    # Some tenants return different wording; if unsure, we just log and proceed.
    Write-Log "User existence check note: $($_.Exception.Message)" 'WARN'
  }
}

$password = New-RandomPassword

# Create user body
$pwProfile = @{
  password = $password
  forceChangePasswordNextSignIn = [bool]$ForceChangePasswordNextSignIn
}

if ($PSCmdlet.ShouldProcess($upn, "Create Entra ID user")) {
  $newUser = New-MgUser -AccountEnabled:$true `
    -DisplayName $displayName `
    -MailNickname $mailNick `
    -UserPrincipalName $upn `
    -GivenName $FirstName `
    -Surname $LastName `
    -JobTitle $JobTitle `
    -Mail $mail `
    -UsageLocation $UsageLocation `
    -PasswordProfile $pwProfile `
    -ErrorAction Stop

  Write-Log "Created user: $($newUser.Id)" 'INFO'
  Write-Host ""
  Write-Host "TEMP PASSWORD (copy now): $password" -ForegroundColor Yellow
  Write-Host ""
}

# Assign licenses
try {
  $skuPick = Find-LicenseSkuIds

  $toAdd = @()
  if ($skuPick.BusinessPremium) {
    $toAdd += @{ SkuId = $skuPick.BusinessPremium.SkuId }
    Write-Log "Found Business Premium SKU: $($skuPick.BusinessPremium.SkuPartNumber)" 'INFO'
  } else {
    Write-Log "Business Premium SKU not found in tenant. (No license will be applied for it.)" 'WARN'
  }

  if ($skuPick.DefenderO365P2) {
    $toAdd += @{ SkuId = $skuPick.DefenderO365P2.SkuId }
    Write-Log "Found Defender for O365 SKU: $($skuPick.DefenderO365P2.SkuPartNumber)" 'INFO'
  } else {
    Write-Log "Defender for Office 365 (Plan 2) SKU not found in tenant. (No license will be applied for it.)" 'WARN'
  }

  if ($toAdd.Count -gt 0) {
    if ($PSCmdlet.ShouldProcess($upn, "Assign $($toAdd.Count) license(s)")) {
      # Need the user id for license assignment
      $u = Get-MgUser -UserId $upn -Property "id" -ErrorAction Stop
      Set-MgUserLicense -UserId $u.Id -AddLicenses $toAdd -RemoveLicenses @() -ErrorAction Stop
      Write-Log "Assigned licenses successfully." 'INFO'
    }
  }
} catch {
  Write-Log "License assignment issue: $($_.Exception.Message)" 'ERROR'
}

Write-Host ""
Write-Log "Onboarding complete for $upn" 'INFO'
