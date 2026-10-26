<#
D-04 — Export Entra ID enterprise apps, app registrations and sign-ins (GEIDIMCP)
Read-only Microsoft Graph PowerShell export. No writes, no secrets copied.

Scope (per ticket + Ivan's 2026-09-16 approval + Paul's 2026-09-23 scope rule):
  - servicePrincipals (enterprise applications)
  - applications (app registrations, incl. API permissions)
  - oauth2PermissionGrants
  - signIns, summarised per app, for the last N days (retention-dependent — confirm with Evgeny)
  - Production apps only get full discovery fields; apps with 0 sign-ins in the window
    are one Scrap Heap line each (GEIDIMCP-81/82), not "suspected legacy" rows.

Run under an approved, signed-in account with delegated (not app-only) permissions,
scoped read-only for the session. Confirm with Evgeny before running:
  1. Actual sign-in log retention (7 / 30 / 90 days; Log Analytics/SIEM if longer needed)
  2. Which account runs this
  3. Time slot to run it
Paste this script in GEIDIMCP-51/D-04 for Ivan's review before running, per his offer.
#>

param(
    [int]$SignInDays = 90,          # adjust to whatever Evgeny confirms is real
    [string]$OutDir = "$PSScriptRoot\..\Daily Tasks\_exports\d04-entra"
)

$ErrorActionPreference = "Stop"

$RequiredScopes = @(
    "Application.Read.All",
    "AuditLog.Read.All",
    "Directory.Read.All"
)

Connect-MgGraph -Scopes $RequiredScopes -NoWelcome

if (-not (Test-Path $OutDir)) {
    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
}
$stamp = Get-Date -Format "yyyy-MM-dd_HHmm"

Write-Host "Exporting service principals (enterprise applications)..."
$servicePrincipals = Get-MgServicePrincipal -All
$servicePrincipals |
    Select-Object Id, AppId, DisplayName, PublisherName, AppOwnerOrganizationId, Tags |
    Export-Csv -Path "$OutDir\servicePrincipals_$stamp.csv" -NoTypeInformation

Write-Host "Exporting app registrations..."
$applications = Get-MgApplication -All
$applications |
    Select-Object Id, AppId, DisplayName, PublisherDomain,
        @{N = "ApiPermissions"; E = { ($_.RequiredResourceAccess | ConvertTo-Json -Compress) } } |
    Export-Csv -Path "$OutDir\applications_$stamp.csv" -NoTypeInformation

Write-Host "Exporting OAuth2 permission grants..."
$oauthGrants = Get-MgOauth2PermissionGrant -All
$oauthGrants |
    Select-Object Id, ClientId, ResourceId, ConsentType, Scope, PrincipalId |
    Export-Csv -Path "$OutDir\oauth2PermissionGrants_$stamp.csv" -NoTypeInformation

Write-Host "Exporting sign-ins for the last $SignInDays day(s)..."
$since = (Get-Date).AddDays(-$SignInDays).ToString("yyyy-MM-ddTHH:mm:ssZ")
$signIns = Get-MgAuditLogSignIn -Filter "createdDateTime ge $since" -All

$signInsByApp = $signIns |
    Group-Object AppId |
    ForEach-Object {
        [PSCustomObject]@{
            AppId          = $_.Name
            AppDisplayName = $_.Group[0].AppDisplayName
            SignInCount    = $_.Count
            LastSignIn     = ($_.Group | Sort-Object CreatedDateTime -Descending | Select-Object -First 1).CreatedDateTime
        }
    }
$signInsByApp | Export-Csv -Path "$OutDir\signIns_by_app_$stamp.csv" -NoTypeInformation

Write-Host ""
Write-Host "Done. Row counts (evidence for acceptance criteria):"
Write-Host "  servicePrincipals: $($servicePrincipals.Count)"
Write-Host "  applications:      $($applications.Count)"
Write-Host "  oauth2Grants:      $($oauthGrants.Count)"
Write-Host "  apps with sign-ins in window: $($signInsByApp.Count)"
Write-Host "Files written to: $OutDir"

Disconnect-MgGraph | Out-Null
