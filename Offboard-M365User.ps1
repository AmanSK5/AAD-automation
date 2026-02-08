<# 
.SYNOPSIS
Offboard one or more users by UPN/email:
- Disable account
- Remove all product licenses
- Remove from DGs, M365 Groups (member/owner), Security Groups
- Remove permissions on all shared mailboxes
- Convert their own mailbox to Shared for Cloud backup pricing to go down
- (Optional) Send Slack notification via Incoming Webhook with the extra paramter when run

.EXAMPLES
# Dry run (no changes)
./Offboard-M365User.ps1 -User amank@amansk.co -WhatIf

# Multiple users + revoke tokens
./Offboard-M365User.ps1 -User amank@amansk.co,amansk@amansk.co -RevokeSignIn

# With Slack notification (Incoming Webhook URL)
./Offboard-M365User.ps1 -User amank@amansk.co -RevokeSignIn -SlackWebhookUrl "https://hooks.slack.com/services/XXX/YYY/ZZZ"

.PARAMETER User
One or more UPNs/emails for users to offboard.

.PARAMETER RevokeSignIn
Also revoke refresh tokens/sign-in sessions (logs them out everywhere).

.PARAMETER SlackWebhookUrl
Slack Incoming Webhook URL. If not provided, Slack notification is skipped.

.NOTES
Requires modules:
  - ExchangeOnlineManagement
  - Microsoft.Graph
Graph scopes needed: User.ReadWrite.All, Group.ReadWrite.All, Directory.ReadWrite.All
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
  [Parameter(Mandatory, Position=0)]
  [string[]]$User,
  [switch]$RevokeSignIn,

  # Slack (optional)
  [string]$SlackWebhookUrl
)

#----------------------------- helpers -----------------------------
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

# Normalize an EXO/Recipient-ish thing to a comparable key (lower-case SMTP/UPN if possible)
function KeyOf {
  param($obj)
  ($obj.PrimarySmtpAddress ?? $obj.WindowsLiveID ?? $obj.ExternalEmailAddress ?? $obj.Name ?? $obj.ToString()).ToString().ToLower()
}

# Resolve a string identity to both Graph user and EXO recipient objects
function Resolve-UserObjects {
  param([Parameter(Mandatory)][string]$Identity)

  $graphUser = $null
  try { $graphUser = Get-MgUser -UserId $Identity -ErrorAction Stop }
  catch {
    # try filter on mail or UPN
    try {
      $escaped = $Identity.Replace("'","''")
      $graphUser = Get-MgUser -Filter "userPrincipalName eq '$escaped' or mail eq '$escaped'" -Property "id,displayName,userPrincipalName,mail,accountEnabled" -ErrorAction Stop
      if ($graphUser -is [System.Array]) { $graphUser = $graphUser | Select-Object -First 1 }
    } catch {}
  }

  if (-not $graphUser) { throw "Could not resolve user in Graph: $Identity" }

  $exoRecipient = $null
  try { $exoRecipient = Get-Recipient -Identity $graphUser.UserPrincipalName -ErrorAction Stop }
  catch {
    try { $exoRecipient = Get-Recipient -Identity $graphUser.Mail -ErrorAction Stop } catch {}
  }

  [pscustomobject]@{
    Graph = $graphUser
    Recipient = $exoRecipient
  }
}

function Send-SlackOffboardMessage {
  param(
    [Parameter(Mandatory)][string]$WebhookUrl,
    [Parameter(Mandatory)][string]$UserUpn,
    [Parameter(Mandatory)][string]$DisplayName
  )

  $today = (Get-Date).ToString('dd/MM/yyyy')

  $text = @"
<!channel> :warning: *User offboarded*

*$DisplayName* ($UserUpn) has been disabled as *today ($today) is their last day*.

Please check with other teams if they have accounts for them so that they can remove them.

Regards,
Aman
"@.Trim()

  try {
    Invoke-RestMethod -Method Post -Uri $WebhookUrl -ContentType 'application/json' -Body (@{ text = $text } | ConvertTo-Json -Depth 4)
    Write-Log "Slack notification sent for $UserUpn" 'INFO'
  } catch {
    Write-Log "Slack notification FAILED for ${UserUpn}: $($_.Exception.Message)" 'WARN'
  }
}

# Safely remove user from all Shared Mailbox permissions across tenant
function Remove-UserFromAllSharedMailboxPerms {
  param(
    [Parameter(Mandatory)][string]$UserKey # lower-case key (smtp/upn)
  )

  Write-Log "Removing shared-mailbox permissions for $UserKey…" 'INFO'
  $shared = Get-Mailbox -RecipientTypeDetails SharedMailbox -ResultSize Unlimited

  foreach ($mbx in $shared) {
    $id = $mbx.Identity

    # FullAccess
    $fa = Get-MailboxPermission -Identity $id | Where-Object {
      -not $_.IsInherited -and $_.User -ne "NT AUTHORITY\SELF"
    }
    foreach ($p in $fa) {
      $k = ($p.User).ToString().ToLower()
      if ($k -eq $UserKey) {
        if ($PSCmdlet.ShouldProcess("FullAccess for $UserKey on '$id'","Remove permission")) {
          Remove-MailboxPermission -Identity $id -User $p.User -AccessRights FullAccess -InheritanceType All `
            -Confirm:$false -ErrorAction SilentlyContinue
          Write-Log "Removed FullAccess on '$id' for $UserKey" 'INFO'
        }
      }
    }

    # SendAs
    $sa = Get-RecipientPermission -Identity $id -ErrorAction SilentlyContinue | Where-Object { $_.AccessRights -contains 'SendAs' }
    foreach ($p in $sa) {
      $k = ($p.Trustee).ToString().ToLower()
      if ($k -eq $UserKey) {
        if ($PSCmdlet.ShouldProcess("SendAs for $UserKey on '$id'","Remove permission")) {
          Remove-RecipientPermission -Identity $id -Trustee $p.Trustee -AccessRights SendAs `
            -Confirm:$false -ErrorAction SilentlyContinue
          Write-Log "Removed SendAs on '$id' for $UserKey" 'INFO'
        }
      }
    }

    # SendOnBehalf
    if ($mbx.GrantSendOnBehalfTo) {
      $sob = @($mbx.GrantSendOnBehalfTo | ForEach-Object { KeyOf $_ })
      if ($sob -contains $UserKey) {
        if ($PSCmdlet.ShouldProcess("SendOnBehalf for $UserKey on '$id'","Remove permission")) {
          Set-Mailbox -Identity $id -GrantSendOnBehalfTo @{ remove = $UserKey } -ErrorAction SilentlyContinue
          Write-Log "Removed SendOnBehalf on '$id' for $UserKey" 'INFO'
        }
      }
    }
  }
}

#----------------------------- connect -----------------------------
Write-Log "Preparing modules…" 'INFO'
Ensure-Module -Name Microsoft.Graph
Ensure-Module -Name ExchangeOnlineManagement

# Graph
if (-not (Get-MgContext)) {
  Write-Log "Connecting to Microsoft Graph (device login)..." 'INFO'
  Connect-MgGraph -Scopes 'User.ReadWrite.All','Group.ReadWrite.All','Directory.ReadWrite.All' | Out-Null
}

# EXO
try { $exoConn = Get-ConnectionInformation -ErrorAction SilentlyContinue } catch { $exoConn = $null }
if (-not $exoConn) {
  Write-Log "Connecting to Exchange Online…" 'INFO'
  Connect-ExchangeOnline | Out-Null
}

#----------------------------- main -----------------------------
foreach ($u in $User) {

  Write-Host ""
  Write-Log "=== Processing $u ===" 'INFO'

  # Resolve
  $res = Resolve-UserObjects -Identity $u
  $gUser = $res.Graph
  $exoRec = $res.Recipient
  $userUpn = $gUser.UserPrincipalName
  $displayName = $gUser.DisplayName
  $userKey = ($gUser.Mail ?? $userUpn).ToLower()

  # 1) Disable account + optionally revoke
  if ($PSCmdlet.ShouldProcess($userUpn, "Disable Entra ID account")) {
    try {
      Update-MgUser -UserId $gUser.Id -AccountEnabled:$false -ErrorAction Stop
      Write-Log "Disabled account." 'INFO'
    } catch { Write-Log "Failed to disable account: $($_.Exception.Message)" 'ERROR' }
  }

  if ($RevokeSignIn) {
    if ($PSCmdlet.ShouldProcess($userUpn, "Revoke sign-in sessions")) {
      try { Revoke-MgUserSignInSession -UserId $gUser.Id -ErrorAction Stop; Write-Log "Revoked sign-in sessions." 'INFO' }
      catch { Write-Log "Failed to revoke sessions: $($_.Exception.Message)" 'WARN' }
    }
  }

  # 2) Remove all product licenses
  try {
    # Use ONLY -Property (or ONLY -Select). We'll use -Property here.
    $uDetail = Get-MgUser -UserId $gUser.Id -Property 'assignedLicenses'
    $skuIds = @($uDetail.AssignedLicenses.SkuId) | Where-Object { $_ }

    if ($skuIds.Count -gt 0) {
      if ($PSCmdlet.ShouldProcess($userUpn, "Remove all licenses ($($skuIds.Count))")) {
        Set-MgUserLicense -UserId $gUser.Id -AddLicenses @() -RemoveLicenses $skuIds -ErrorAction Stop
        Write-Log "Removed licenses." 'INFO'
      }
    } else {
      Write-Log "No licenses assigned." 'INFO'
    }
  } catch {
    Write-Log "License removal issue: $($_.Exception.Message)" 'WARN'
  }

  # 3a) Remove from Security Groups (AAD) via Graph
  Write-Log "Removing from Entra security/M365 groups via Graph (membership/ownership)..." 'INFO'
  try {
    # Transitive memberships
    $memberOf = Get-MgUserMemberOf -UserId $gUser.Id -All -ErrorAction SilentlyContinue
    foreach ($obj in $memberOf) {
      if ($obj.'@odata.type' -eq '#microsoft.graph.group') {
        $gid = $obj.Id
        if ($PSCmdlet.ShouldProcess("$userUpn in Group $gid","Remove member (Graph)")) {
          try { Remove-MgGroupMemberByRef -GroupId $gid -DirectoryObjectId $gUser.Id -ErrorAction Stop } catch {}
        }
      }
    }
    # Ownerships (M365 Groups often)
    $owns = Get-MgUserOwnedObject -UserId $gUser.Id -All -ErrorAction SilentlyContinue | Where-Object { $_.'@odata.type' -eq '#microsoft.graph.group' }
    foreach ($obj in $owns) {
      $gid = $obj.Id
      if ($PSCmdlet.ShouldProcess("$userUpn owner of Group $gid","Remove owner (Graph)")) {
        try { Remove-MgGroupOwnerByRef -GroupId $gid -DirectoryObjectId $gUser.Id -ErrorAction SilentlyContinue } catch {}
      }
    }
  } catch {
    Write-Log "Graph group cleanup issue: $($_.Exception.Message)" 'WARN'
  }

  # 3b) Remove from Distribution Groups & M365 Groups (Exchange side, targeted)
  # Distribution Groups
  Write-Log "Removing from Distribution Groups (Exchange)..." 'INFO'
  $dgList = Get-DistributionGroup -ResultSize Unlimited
  foreach ($dg in $dgList) {
    try {
      $members = Get-DistributionGroupMember -Identity $dg.Identity -ResultSize Unlimited -ErrorAction SilentlyContinue
      if (-not $members) { continue }
      $hit = $members | Where-Object {
        $k = KeyOf $_
        $k -eq $userKey -or $k -eq $userUpn.ToLower()
      }
      if ($hit) {
        if ($PSCmdlet.ShouldProcess("$userUpn in DG '$($dg.DisplayName)'","Remove member")) {
          Remove-DistributionGroupMember -Identity $dg.Identity -Member $hit.Identity `
            -BypassSecurityGroupManagerCheck:$true -Confirm:$false -ErrorAction SilentlyContinue
          Write-Log "DG: removed from '$($dg.DisplayName)'" 'INFO'
        }
      }
    } catch {
      Write-Log "DG cleanup issue in '$($dg.DisplayName)': $($_.Exception.Message)" 'WARN'
    }
  }

  # M365 Groups (Members & Owners) – Exchange views
  Write-Log "Removing from Microsoft 365 Groups (Exchange links)..." 'INFO'
  $uGroups = Get-UnifiedGroup -ResultSize Unlimited
  foreach ($g in $uGroups) {
    foreach ($lt in @('Members','Owners')) {
      try {
        $links = Get-UnifiedGroupLinks -Identity $g.Identity -LinkType $lt -ResultSize Unlimited -ErrorAction SilentlyContinue
        if (-not $links) { continue }
        $hit = $links | Where-Object { (KeyOf $_) -in @($userKey, $userUpn.ToLower()) }
        if ($hit) {
          if ($PSCmdlet.ShouldProcess("$userUpn in M365 Group '$($g.DisplayName)' ($lt)","Remove link")) {
            Remove-UnifiedGroupLinks -Identity $g.Identity -LinkType $lt -Links $userUpn `
              -Confirm:$false -ErrorAction SilentlyContinue
            Write-Log "M365 Group: removed ($lt) from '$($g.DisplayName)'" 'INFO'
          }
        }
      } catch {
        Write-Log "M365 Group cleanup issue in '$($g.DisplayName)': $($_.Exception.Message)" 'WARN'
      }
    }
  }

  # 3c) Remove from ALL Shared Mailbox permissions (FullAccess/SendAs/SendOnBehalf)
  Remove-UserFromAllSharedMailboxPerms -UserKey $userKey

  # 4) Convert their own mailbox to Shared
  try {
    $mbx = $null
    try { $mbx = Get-Mailbox -Identity $userUpn -ErrorAction Stop } catch {}
    if ($mbx) {
      if ($mbx.RecipientTypeDetails -eq 'SharedMailbox') {
        Write-Log "Mailbox already Shared." 'INFO'
      } elseif ($mbx.RecipientTypeDetails -eq 'UserMailbox') {
        if ($PSCmdlet.ShouldProcess($userUpn, "Convert mailbox to Shared")) {
          Set-Mailbox -Identity $mbx.Identity -Type Shared -Confirm:$false -ErrorAction Stop
          Write-Log "Converted mailbox to Shared." 'INFO'
        }
      } else {
        Write-Log "Mailbox type is $($mbx.RecipientTypeDetails); not converting." 'WARN'
      }
    } else {
      Write-Log "No mailbox found to convert (might be cloud-only account without mailbox)." 'WARN'
    }
  } catch {
    Write-Log "Mailbox conversion issue: $($_.Exception.Message)" 'ERROR'
  }

  # 5) Slack notification (optional)
  if ($SlackWebhookUrl) {
    if ($PSCmdlet.ShouldProcess($userUpn, "Send Slack offboarding notification")) {
      Send-SlackOffboardMessage -WebhookUrl $SlackWebhookUrl -UserUpn $userUpn -DisplayName $displayName
    }
  } else {
    Write-Log "SlackWebhookUrl not provided; skipping Slack notification." 'INFO'
  }

  Write-Log "=== Finished $userUpn ===" 'INFO'
}

Write-Host ""
Write-Log "Offboarding run complete." 'INFO'
