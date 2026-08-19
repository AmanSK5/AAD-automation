<#
.SYNOPSIS
    Trims file version history in a SharePoint Online document library.

.DESCRIPTION
    Runs in dry-run mode by default. Use -Execute to permanently delete versions.

    Authenticates interactively as the signed-in user (delegated), so every
    deletion is attributed to a real person in the unified audit log and MFA /
    Conditional Access apply as normal. No certificates or secrets required.

    Deleted versions are PERMANENTLY removed. They do not go to the recycle bin
    and cannot be recovered.

.PARAMETER SiteUrl
    Full URL of the site, e.g. https://aman.sharepoint.com/sites/github

.PARAMETER LibraryName
    Document library display name. Defaults to "Documents".

.PARAMETER VersionsToKeep
    Number of HISTORICAL versions to retain per file. The current live version is
    always kept and is not counted here, so -VersionsToKeep 10 leaves 11 copies.

.PARAMETER Execute
    Perform the deletions. Without this switch nothing is deleted.

.PARAMETER NoPrompt
    Skip the typed confirmation when using -Execute. For unattended runs only.

.PARAMETER LogPath
    Directory for the CSV audit log. Defaults to ./logs

.EXAMPLE
    ./Invoke-SPOVersionCleanup.ps1 -SiteUrl https://aman.sharepoint.com/sites/github

.EXAMPLE
    ./Invoke-SPOVersionCleanup.ps1 -SiteUrl https://aman.sharepoint.com/sites/github -LibraryName "Shared Documents" -VersionsToKeep 5 -Execute

.NOTES
    Requires PnP.PowerShell. Install with:
        Install-Module PnP.PowerShell -Scope CurrentUser
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [string]$SiteUrl,

    [string]$LibraryName = "Documents",

    [ValidateRange(0, 5000)]
    [int]$VersionsToKeep = 10,

    [switch]$Execute,

    [switch]$NoPrompt,

    [string]$LogPath = (Join-Path $PSScriptRoot "logs"),

    # Entra app registration used for interactive sign-in. Override with the
    # SP_CLIENT_ID environment variable if you need to point at a different app.
    [string]$ClientId = $(if ($env:SP_CLIENT_ID) { $env:SP_CLIENT_ID } else { "REPLACE-WITH-YOUR-APP-ID" })
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$PageSize   = 500
$MaxRetries = 5

# ==============================
# PRE-FLIGHT
# ==============================

if ($ClientId -eq "REPLACE-WITH-YOUR-APP-ID") {
    throw "No ClientId configured. Set the default in this script or export SP_CLIENT_ID."
}

if (-not (Get-Module -ListAvailable -Name PnP.PowerShell)) {
    throw "PnP.PowerShell is not installed. Run: Install-Module PnP.PowerShell -Scope CurrentUser"
}

Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "Site:              $SiteUrl"
Write-Host "Library:           $LibraryName"
Write-Host "Historical kept:   $VersionsToKeep (plus the current version)"
Write-Host "Mode:              $(if ($Execute) { 'EXECUTE - PERMANENT DELETION' } else { 'DRY RUN' })"
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host ""

if (-not $Execute) {
    Write-Host "***** DRY RUN MODE - nothing will be deleted *****" -ForegroundColor Yellow
    Write-Host ""
}
else {
    Write-Host "***** EXECUTE MODE *****" -ForegroundColor Red
    Write-Host "Versions will be PERMANENTLY deleted. They do NOT go to the recycle bin." -ForegroundColor Red
    Write-Host ""

    if (-not $NoPrompt) {
        $confirm = Read-Host "Type the library name ('$LibraryName') to confirm"
        if ($confirm -ne $LibraryName) {
            Write-Host "Confirmation did not match. Aborting." -ForegroundColor Yellow
            return
        }
        Write-Host ""
    }
}

# ==============================
# AUDIT LOG
# ==============================

if (-not (Test-Path $LogPath)) {
    New-Item -ItemType Directory -Path $LogPath -Force | Out-Null
}

$siteSlug   = ($SiteUrl -replace '^https?://', '' -replace '[^\w\-]', '_')
$stamp      = Get-Date -Format 'yyyyMMdd-HHmmss'
$mode       = if ($Execute) { 'execute' } else { 'dryrun' }
$logFile    = Join-Path $LogPath "versioncleanup-$siteSlug-$mode-$stamp.csv"

# Buffer rows and flush per file so a crash still leaves a usable log.
"Timestamp,FileUrl,VersionId,VersionLabel,VersionCreated,VersionSizeBytes,Action,Result,Detail" |
    Out-File -FilePath $logFile -Encoding utf8

function Write-AuditRow {
    param($FileUrl, $VersionId, $VersionLabel, $VersionCreated, $VersionSize, $Action, $Result, $Detail)

    $escape = { param($v) '"' + ($v -replace '"', '""') + '"' }

    $row = @(
        (& $escape (Get-Date -Format 'o'))
        (& $escape $FileUrl)
        (& $escape $VersionId)
        (& $escape $VersionLabel)
        (& $escape $VersionCreated)
        (& $escape $VersionSize)
        (& $escape $Action)
        (& $escape $Result)
        (& $escape $Detail)
    ) -join ','

    Add-Content -Path $logFile -Value $row
}

# ==============================
# THROTTLE-AWARE RETRY
# ==============================

function Invoke-WithRetry {
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [string]$Context = ""
    )

    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        try {
            return & $Action
        }
        catch {
            $msg = $_.Exception.Message

            # Honour Retry-After if SharePoint gave us one, else exponential backoff.
            $retryAfter = $null
            $response = $_.Exception.InnerException.Response
            if ($null -ne $response -and $null -ne $response.Headers) {
                $retryAfter = $response.Headers['Retry-After']
            }

            $isThrottle = $msg -match '429|throttl|503|too many requests'

            if (-not $isThrottle -or $attempt -eq $MaxRetries) {
                throw
            }

            $wait = if ($retryAfter) { [int]$retryAfter } else { [math]::Pow(2, $attempt) }
            Write-Host "  Throttled$(if($Context){" on $Context"}). Waiting ${wait}s (attempt $attempt/$MaxRetries)..." -ForegroundColor DarkYellow
            Start-Sleep -Seconds $wait
        }
    }
}

# ==============================
# CONNECT
# ==============================

Write-Host "Signing in to SharePoint (a browser window will open)..." -ForegroundColor Cyan

try {
    Connect-PnPOnline -Url $SiteUrl -ClientId $ClientId -Interactive -WarningAction Ignore
}
catch {
    throw "Sign-in failed: $($_.Exception.Message)"
}

$web  = Get-PnPWeb
$conn = Get-PnPConnection
Write-Host "Connected to: $($web.Title)" -ForegroundColor Green
Write-Host "Audit log:    $logFile" -ForegroundColor Green
Write-Host ""

# ==============================
# STATS
# ==============================

$script:totalFiles    = 0
$script:filesTouched  = 0
$script:totalVersions = 0
$script:totalBytes    = 0
$script:failures      = 0
$script:skipped       = 0

# ==============================
# PER-FILE PROCESSING
# ==============================

function Invoke-FileCleanup {
    param($Item)

    $fileUrl = $Item.FieldValues.FileRef
    $script:totalFiles++

    try {
        $versions = @(Invoke-WithRetry -Context $fileUrl -Action {
            Get-PnPFileVersion -Url $fileUrl -Connection $conn
        })
    }
    catch {
        $script:failures++
        Write-Host "  READ FAILED: $fileUrl - $($_.Exception.Message)" -ForegroundColor Magenta
        Write-AuditRow -FileUrl $fileUrl -VersionId '' -VersionLabel '' -VersionCreated '' `
                       -VersionSize '' -Action 'read-versions' -Result 'failed' -Detail $_.Exception.Message
        return
    }

    if ($versions.Count -le $VersionsToKeep) { return }

    $oldVersions = $versions |
        Sort-Object Created -Descending |
        Select-Object -Skip $VersionsToKeep

    $script:filesTouched++
    Write-Host ""
    Write-Host "FILE: $fileUrl" -ForegroundColor Cyan
    Write-Host "  $($versions.Count) versions, removing $($oldVersions.Count)" -ForegroundColor Gray

    foreach ($v in $oldVersions) {

        # Version size is per-version, NOT the current file size. Fall back to 0
        # rather than guessing if the property was not populated.
        $vSize = 0
        if ($v.PSObject.Properties.Name -contains 'Size' -and $null -ne $v.Size) {
            $vSize = [int64]$v.Size
        }

        if (-not $Execute) {
            $script:totalVersions++
            $script:totalBytes += $vSize
            Write-Host "  [dry run] $($v.VersionLabel) - $($v.Created)" -ForegroundColor Yellow
            Write-AuditRow -FileUrl $fileUrl -VersionId $v.Id -VersionLabel $v.VersionLabel `
                           -VersionCreated $v.Created -VersionSize $vSize `
                           -Action 'would-delete' -Result 'dryrun' -Detail ''
            continue
        }

        try {
            Invoke-WithRetry -Context $fileUrl -Action {
                Remove-PnPFileVersion -Url $fileUrl -Identity $v.Id -Force -Connection $conn
            }

            $script:totalVersions++
            $script:totalBytes += $vSize
            Write-Host "  deleted $($v.VersionLabel) - $($v.Created)" -ForegroundColor Red
            Write-AuditRow -FileUrl $fileUrl -VersionId $v.Id -VersionLabel $v.VersionLabel `
                           -VersionCreated $v.Created -VersionSize $vSize `
                           -Action 'delete' -Result 'success' -Detail ''
        }
        catch {
            $script:failures++
            $detail = $_.Exception.Message

            # Retention labels, holds and checked-out files land here. Expected,
            # not fatal - log and keep going.
            Write-Host "  FAILED $($v.VersionLabel): $detail" -ForegroundColor Magenta
            Write-AuditRow -FileUrl $fileUrl -VersionId $v.Id -VersionLabel $v.VersionLabel `
                           -VersionCreated $v.Created -VersionSize $vSize `
                           -Action 'delete' -Result 'failed' -Detail $detail
        }
    }
}

# ==============================
# MAIN LOOP
# ==============================

try {
    Write-Host "Enumerating items in '$LibraryName'..." -ForegroundColor Cyan

    Get-PnPListItem -List $LibraryName -PageSize $PageSize -Connection $conn `
        -Fields "FileRef", "FSObjType", "File_x0020_Size" `
        -ScriptBlock {
            param($batch)

            foreach ($item in $batch) {
                if ($item.FileSystemObjectType -ne "File") {
                    $script:skipped++
                    continue
                }
                Invoke-FileCleanup -Item $item
            }

            Write-Host "  ...$($script:totalFiles) files scanned" -ForegroundColor DarkGray
        } | Out-Null
}
finally {

    # ==============================
    # SUMMARY
    # ==============================

    $gb = [math]::Round($script:totalBytes / 1GB, 2)

    Write-Host ""
    Write-Host "================ SUMMARY ================" -ForegroundColor Green
    Write-Host "Files scanned:        $($script:totalFiles)"
    Write-Host "Non-file items:       $($script:skipped)"
    Write-Host "Files with trims:     $($script:filesTouched)"
    Write-Host "Versions $(if ($Execute) { 'deleted ' } else { 'targeted' }):    $($script:totalVersions)"
    Write-Host "Failures:             $($script:failures)" -ForegroundColor $(if ($script:failures) { 'Magenta' } else { 'Green' })
    Write-Host "Version bytes:        $gb GB (upper bound)"
    Write-Host "Audit log:            $logFile"
    Write-Host "=========================================" -ForegroundColor Green

    Write-Host ""
    Write-Host "Note: shredded storage means actual reclaimed space will be lower" -ForegroundColor DarkGray
    Write-Host "than the figure above. Site storage metrics can take 24h to update." -ForegroundColor DarkGray

    if (-not $Execute) {
        Write-Host ""
        Write-Host "DRY RUN ONLY - NO DATA WAS DELETED" -ForegroundColor Yellow
        Write-Host "Re-run with -Execute to perform the deletion." -ForegroundColor Yellow
    }

    if ($script:failures -gt 0) {
        Write-Host ""
        Write-Host "$($script:failures) operation(s) failed. Check the audit log for detail." -ForegroundColor Magenta
        Write-Host "Common causes: retention labels, legal hold, checked-out files." -ForegroundColor DarkGray
    }

    Disconnect-PnPOnline -ErrorAction SilentlyContinue
}