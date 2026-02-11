<#
.SYNOPSIS
List Entra ID users by domain and show enabled/disabled state.

.DESCRIPTION
Uses Microsoft Graph via Azure CLI (az rest). Supports Member or Guest userType.
Filters by mail OR userPrincipalName (UPN) domain locally, and (optionally) rehydrates
each user by ID to avoid eventual-consistency issues after recent changes.

.REQUIREMENTS
- Azure CLI logged into the correct tenant: az login --tenant <tenantId>
- Microsoft Graph permissions to read users (typically Directory.Read.All / User.Read.All)

.EXAMPLES
# Interactive prompt for domain(s)
./Get-EntraUsersByDomain.ps1

# Non-interactive
./Get-EntraUsersByDomain.ps1 -Domains google.com,google.co.uk -UserType Member

# Guests, accurate
./Get-EntraUsersByDomain.ps1 -Domains google.co -UserType Guest -Accurate
#>

[CmdletBinding(SupportsShouldProcess=$true)]
param(
  [string[]]$Domains,

  [ValidateSet("Member","Guest")]
  [string]$UserType = "Member",

  [switch]$Accurate
)

function Write-Log {
  param([string]$Message, [ValidateSet('INFO','WARN','ERROR')][string]$Level='INFO')
  $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  $c  = @{ INFO = 'Gray'; WARN='Yellow'; ERROR='Red' }[$Level]
  Write-Host "[$ts][$Level] $Message" -ForegroundColor $c
}

function Get-PagedGraphUsers {
  param([string]$Url)

  $all = @()
  while ($Url) {
    $resp = az rest --method GET --url $Url | ConvertFrom-Json
    if ($resp.value) { $all += $resp.value }
    $Url = $resp.'@odata.nextLink'
  }
  return $all
}

# Prompt if not provided
if (-not $Domains -or $Domains.Count -eq 0) {
  $raw = Read-Host "Enter domain(s) to match (comma separated, e.g. google.com,google.co.uk)"
  $Domains = $raw.Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ }
}

# Normalize domains: allow passing with/without "@"
$domainsNorm = $Domains | ForEach-Object {
  $d = $_.Trim()
  if ($d.StartsWith("@")) { $d.Substring(1) } else { $d }
} | Where-Object { $_ }

if ($domainsNorm.Count -eq 0) { throw "No valid domains supplied." }

Write-Log "Querying Graph users (userType = $UserType)..." "INFO"

$select = "id,displayName,userPrincipalName,mail,accountEnabled"
$url = "https://graph.microsoft.com/v1.0/users?`$filter=userType%20eq%20'$UserType'&`$select=$select&`$top=999"

$all = Get-PagedGraphUsers -Url $url
Write-Log "Fetched $($all.Count) users from Graph. Filtering domains..." "INFO"

# Local filter: match mail OR UPN against any supplied domain
$filtered = $all | Where-Object {
  $mail = ($_.mail ?? "")
  $upn  = ($_.userPrincipalName ?? "")
  foreach ($d in $domainsNorm) {
    if ($mail -like "*@$d" -or $upn -like "*@$d") { return $true }
  }
  return $false
}

Write-Log "Matched $($filtered.Count) users for domain(s): $($domainsNorm -join ', ')" "INFO"

if ($Accurate) {
  Write-Log "Accurate mode enabled: re-checking each matched user by ID (slower)..." "WARN"

  $final = foreach ($u in $filtered) {
    try {
      $fresh = az rest --method GET --url "https://graph.microsoft.com/v1.0/users/$($u.id)?`$select=$select" | ConvertFrom-Json
      [pscustomobject]@{
        DisplayName       = $fresh.displayName
        UPN               = $fresh.userPrincipalName
        Mail              = $fresh.mail
        AccountEnabled    = $fresh.accountEnabled
      }
    } catch {
      Write-Log "Failed to rehydrate user id $($u.id): $($_.Exception.Message)" "WARN"
    }
  }
} else {
  $final = $filtered | ForEach-Object {
    [pscustomobject]@{
      DisplayName       = $_.displayName
      UPN               = $_.userPrincipalName
      Mail              = $_.mail
      AccountEnabled    = $_.accountEnabled
    }
  }
}

# False first, then name
$final |
  Sort-Object AccountEnabled, DisplayName |
  Format-Table -AutoSize

# Summary counts
$disabled = @($final | Where-Object { $_.AccountEnabled -eq $false }).Count
$enabled  = @($final | Where-Object { $_.AccountEnabled -eq $true }).Count
Write-Host ""
Write-Log "Summary: Disabled=$disabled, Enabled=$enabled" "INFO"
