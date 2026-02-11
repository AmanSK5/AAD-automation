param (
    [Parameter(Mandatory)]
    [string]$SiteUrl,

    [string]$LibraryName = "Documents",

    [int]$VersionsToKeep = 10,

    [switch]$Execute
)

# ==============================
# APP REGISTRATION CONFIG
# ==============================

$ClientId     = $env:SP_CLIENT_ID
$ClientSecret = $env:SP_CLIENT_SECRET

if ([string]::IsNullOrWhiteSpace($ClientId) -or [string]::IsNullOrWhiteSpace($ClientSecret)) {
    throw "Missing SP_CLIENT_ID or SP_CLIENT_SECRET environment variables. Set them in this pwsh session before running."
}

$PageSize = 200

Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "Site:            $SiteUrl"
Write-Host "Library:         $LibraryName"
Write-Host "Versions to keep $VersionsToKeep"
Write-Host "==================================================" -ForegroundColor Cyan

if (-not $Execute) {
    Write-Host ""
    Write-Host "***** DRY RUN MODE *****" -ForegroundColor Yellow
    Write-Host "No versions will be deleted."
    Write-Host ""
}

# ==============================
# CONNECT (INTERACTIVE + APP)
# ==============================
Write-Host "Connecting to SharePoint (app-only via client secret)..." -ForegroundColor Cyan

Connect-PnPOnline `
  -Url $SiteUrl `
  -ClientId $ClientId `
  -ClientSecret $ClientSecret `
  -WarningAction Ignore

$web = Get-PnPWeb
Write-Host "Connected to: $($web.Title)" -ForegroundColor Green
Write-Host ""

# ==============================
# STATS
# ==============================
$totalFiles = 0
$totalVersions = 0
$totalBytes = 0

# ==============================
# GET FILES
# ==============================
$items = Get-PnPListItem `
    -List $LibraryName `
    -PageSize $PageSize `
    -Fields "FileRef","FSObjType","File_x0020_Size"

foreach ($item in $items) {

    if ($item.FileSystemObjectType -ne "File") { continue }

    $totalFiles++
    $fileUrl  = $item.FieldValues.FileRef
    $fileSize = [int64]$item.FieldValues.File_x0020_Size

    $versions = Get-PnPFileVersion -Url $fileUrl
    if ($versions.Count -le $VersionsToKeep) { continue }

    $oldVersions = $versions |
        Sort-Object Created -Descending |
        Select-Object -Skip $VersionsToKeep

    Write-Host ""
    Write-Host "FILE: $fileUrl" -ForegroundColor Cyan

    foreach ($v in $oldVersions) {
        Write-Host "  Version: $($v.Created)" -ForegroundColor Red
        $totalVersions++
        $totalBytes += $fileSize

        if ($Execute) {
            Remove-PnPFileVersion -Url $fileUrl -Identity $v.Id -Force
        }
    }

    Start-Sleep -Milliseconds 200
}

# ==============================
# SUMMARY
# ==============================
$gb = [math]::Round($totalBytes / 1GB, 2)

Write-Host ""
Write-Host "================ SUMMARY ================" -ForegroundColor Green
Write-Host "Files scanned:        $totalFiles"
Write-Host "Versions processed:   $totalVersions"
Write-Host "Estimated space:      $gb GB"
Write-Host "========================================" -ForegroundColor Green

if (-not $Execute) {
    Write-Host ""
    Write-Host "DRY RUN ONLY — NO DATA WAS DELETED" -ForegroundColor Yellow
}