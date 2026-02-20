param(
  [switch]$WhatIf
)

$ToolkitRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$ScriptsRoot = Join-Path $ToolkitRoot "scripts"

function Ask([string]$Prompt, [string]$Default = "") {
  $suffix = if ($Default) { " [$Default]" } else { "" }
  $v = Read-Host "$Prompt$suffix"
  if ([string]::IsNullOrWhiteSpace($v)) { return $Default }
  return $v
}

function AskYesNo([string]$Prompt, [bool]$Default = $false) {
  $d = if ($Default) { "Y" } else { "N" }
  while ($true) {
    $v = Read-Host "$Prompt (Y/N) [$d]"
    if ([string]::IsNullOrWhiteSpace($v)) { return $Default }
    switch ($v.Trim().ToLower()) {
      "y" { return $true }
      "yes" { return $true }
      "n" { return $false }
      "no" { return $false }
      "q" { return }
    default { Write-Host "Invalid option." -ForegroundColor Yellow }
    }
  }
}

function RunScript {
  param(
    [Parameter(Mandatory)][string]$ScriptName,
    [Parameter()][hashtable]$ScriptParams = @{}
  )

  $path = Join-Path $ScriptsRoot $ScriptName
  if (-not (Test-Path $path)) { throw "Script not found: $path" }

  # Build a clean param set to splat
  $invokeParams = @{}
  foreach ($k in $ScriptParams.Keys) {
    $v = $ScriptParams[$k]
    if ($null -ne $v -and $v -ne "") {
      $invokeParams[$k] = $v
    }
  }

  # Pass -WhatIf through to the called script (if it supports it)
  if ($WhatIf) { $invokeParams["WhatIf"] = $true }

  Write-Host ""
  Write-Host "Running:" -ForegroundColor Cyan
  $paramString = ($invokeParams.GetEnumerator() | ForEach-Object { "-$($_.Key) $($_.Value)" }) -join ' '
  Write-Host "pwsh `"$path`" $paramString" -ForegroundColor Cyan
  Write-Host ""

  & $path @invokeParams
}

function RunPython {
  param(
    [Parameter(Mandatory)][string]$ScriptName,
    [Parameter()][string[]]$Arguments = @()
  )

  $path = Join-Path $ScriptsRoot $ScriptName
  if (-not (Test-Path $path)) { throw "Script not found: $path" }

  # Find python — try python3 first, fall back to python
  $python = Get-Command python3 -ErrorAction SilentlyContinue
  if (-not $python) { $python = Get-Command python -ErrorAction SilentlyContinue }
  if (-not $python) { throw "Python not found. Install Python 3 and ensure it is on PATH." }

  Write-Host ""
  Write-Host "Running:" -ForegroundColor Cyan
  Write-Host "$($python.Source) `"$path`" $($Arguments -join ' ')" -ForegroundColor Cyan
  Write-Host ""

  & $python.Source $path @Arguments
}

while ($true) {
  Write-Host ""
  Write-Host "=== M365 / Entra Toolkit (Desktop/Scripts) ===" -ForegroundColor Green
  Write-Host "1) Onboard user (New-M365User.ps1)"
  Write-Host "2) Offboard user (Offboard-M365User.ps1)"
  Write-Host "3) SharePoint cleanup (Cleanup-SharePoint.ps1)"
  Write-Host "4) Domain user audit (Get-EntraUsersByDomain.ps1)"
  Write-Host "5) Azure idle resource report (azure_idle_report.py)"
  Write-Host "Q) Quit"
  $choice = (Read-Host "Select").Trim()

  switch ($choice.ToLower()) {
    "1" {
      RunScript -ScriptName "New-M365User.ps1" -ScriptParams @{}
    }
    "2" {
        $rawUsers = Ask "User UPN/email (comma separated for multiple)"
        $users = $rawUsers.Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ }

        if (-not $users -or $users.Count -eq 0) {
            Write-Host "No users provided." -ForegroundColor Yellow
            break
        }

        $revoke = AskYesNo "Revoke sign-in sessions? (-RevokeSignIn)" $true
        $sendSlack = AskYesNo "Send Slack notification?" $false

        $params = @{
            User = $users
        }

        if ($revoke) {
            $params["RevokeSignIn"] = $true
        }

        if ($sendSlack) {
            # Prefer env var so juniors aren't pasting secrets everywhere
            $slack = $env:SLACK_WEBHOOK_URL
            if (-not $slack) {
            $slack = Ask "Slack Webhook URL"
            } else {
            Write-Host "Using SLACK_WEBHOOK_URL from environment." -ForegroundColor Cyan
            }

            if ($slack) {
            $params["SlackWebhookUrl"] = $slack
            }
        }

  RunScript -ScriptName "Offboard-M365User.ps1" -ScriptParams $params
    }
    "3" {
      # Adjust these prompts/params to whatever your SP script actually takes
      $site = Ask "SharePoint Site URL"
      RunScript "Sharepointcleanup.ps1" @{
        SiteUrl = $site
      }
    }
    "4" {
  $domainsRaw = Ask "Domains (comma separated, leave blank to be prompted)" ""
  $type       = Ask "UserType (Member/Guest)" "Member"
  $accurate   = AskYesNo "Accurate mode (slower, re-check each user by ID)?" $false

  $params = @{
    UserType  = $type
    Accurate  = $accurate
  }

  # If user entered domains, split into an array and pass them in.
  # If blank, don't pass Domains at all (script will prompt).
  if (-not [string]::IsNullOrWhiteSpace($domainsRaw)) {
    $domainsArr = $domainsRaw.Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    $params["Domains"] = $domainsArr
  }

  RunScript -ScriptName "Get-EntraUsersByDomain.ps1" -ScriptParams $params
    }
    "5" {
      $tenant = Ask "Azure Tenant ID (or leave blank to be prompted by script)" ""
      $deviceCode = AskYesNo "Use device code auth?" $false
      $includeSnapshots = AskYesNo "Include old snapshots?" $false
      $noCost = AskYesNo "Skip cost lookups (faster, no cost figures)?" $false
      $format = Ask "Output format (text/json/csv)" "text"

      $pyArgs = @()

      if ($tenant) { $pyArgs += "--tenant", $tenant }
      if ($deviceCode) { $pyArgs += "--device-code" }
      if ($includeSnapshots) {
        $pyArgs += "--include-snapshots"
        $snapDays = Ask "Snapshot age threshold (days)" "180"
        $pyArgs += "--snapshot-days", $snapDays
      }
      if ($noCost) { $pyArgs += "--no-cost" }
      if ($format -and $format -ne "text") { $pyArgs += "--output-format", $format }

      $skipSubs = Ask "Subscription names/IDs to skip (comma separated, or blank)" ""
      if ($skipSubs) { $pyArgs += "--skip-subs", $skipSubs }

      $onlySubs = Ask "Only scan these subscriptions (comma separated, or blank)" ""
      if ($onlySubs) { $pyArgs += "--only-subs", $onlySubs }

      RunPython -ScriptName "azure_idle_report.py" -Arguments $pyArgs
    }
    "q" { return }
  default { Write-Host "Invalid option." -ForegroundColor Yellow }
  }
}