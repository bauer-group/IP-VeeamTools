#Requires -Version 5.1

<#
.SYNOPSIS
    Listet alle lizenzierten User einer Veeam-Backup-365-Organisation auf,
    inklusive Backup-Status, Job-Mitgliedschaften und Lizenz-Pool-Metriken.

.DESCRIPTION
    Read-only Inventur-Skript für die Veeam-Lizenz-Pool-Analyse.
    Beantwortet die Frage: "Welche User belegen aktuell eine Veeam-Lizenz,
    und welche davon sollten aus dem Backup-Scope entfernt werden?"

    Liefert pro User die wichtigsten Felder aus VBOLicensedUser plus
    optional die Job-Mitgliedschaften (welche Backup-Jobs enthalten den
    User aktuell). Repository-Daten werden NICHT gescannt — das wäre zu
    langsam für Listing-Zwecke. Für detaillierte Daten-Analyse ist
    Get-VBOEntityData direkt zu verwenden.

    Anwendungsfälle:
        - Lizenz-Pool-Audit ("wer belegt unsere VBO-Lizenzen?")
        - Identifikation verwaister User (lange nicht gesichert)
        - Identifikation überschüssiger Lizenzen (LicenseStatus = Exceeded)
        - Vorbereitung für Remove-VeeamLicense.ps1 Cleanup-Läufe
        - Compliance-/Cost-Reports für Management

    Das Skript schreibt nichts in Veeam zurück und ist sicher für
    Produktion und parallel zu laufenden Backup-Jobs.

.PARAMETER OrganizationName
    Name der VBO-Organisation, exakt wie in der VBO-Konsole sichtbar.
    Default: 'BAUER GROUP'

.PARAMETER NotBackedUpForDays
    Filter: Nur User zurückgeben, deren letztes Backup mindestens N Tage
    zurückliegt. Auch User ohne LastBackupDate (nie gesichert) werden
    eingeschlossen, wenn N > 0. Default: 0 (kein Filter).

.PARAMETER LicenseStatus
    Filter: Nur User mit bestimmtem LicenseStatus.
    Werte (laut Veeam-Doku): Licensed, New, TemporaryAssigned, Exceeded
    Default: 'All' (kein Filter)

.PARAMETER IncludeJobAssignments
    Erweitert jeden User um die Liste der Backup-Jobs, in denen er als
    SelectedItem enthalten ist. Erfordert einen einmaligen Walk durch
    alle Jobs der Organisation — pro Lauf, nicht pro User.

.PARAMETER ExportCsv
    Pfad zu einer CSV-Ausgabedatei. Wenn gesetzt, wird das Ergebnis
    dorthin exportiert (UTF-8, NoTypeInformation). Output an die Pipeline
    erfolgt zusätzlich.

.OUTPUTS
    [pscustomobject] pro lizenziertem User mit folgenden Feldern:

        UserName            - Name (per Veeam-Konvention der UPN)
        LicenseStatus       - Licensed | New | TemporaryAssigned | Exceeded
        IsBackedUp          - $true wenn der User je gesichert wurde
        LastBackupDate      - Zeitpunkt des letzten Backups (oder $null)
        DaysSinceLastBackup - Tage seit letztem Backup ($null wenn nie)
        OfficeId            - GUID in Microsoft 365
        OnPremisesId        - GUID in on-premises AD (bei Hybrid)
        OrganizationName    - VBO-Organisation
        JobNames            - Semikolon-getrennt, nur mit -IncludeJobAssignments

.EXAMPLE
    .\Get-VeeamLicenseUsage.ps1

    Listet alle lizenzierten User der Standard-Organisation als Tabelle.

.EXAMPLE
    .\Get-VeeamLicenseUsage.ps1 -NotBackedUpForDays 90 |
        Format-Table UserName, LicenseStatus, LastBackupDate, DaysSinceLastBackup

    Findet alle User, die seit 90+ Tagen nicht mehr gesichert wurden —
    klassische Cleanup-Kandidaten.

.EXAMPLE
    .\Get-VeeamLicenseUsage.ps1 -LicenseStatus Exceeded

    Zeigt alle User, deren Lizenz den Pool überschreitet (LicenseStatus
    Exceeded). Diese verursachen sofortigen Handlungsbedarf.

.EXAMPLE
    .\Get-VeeamLicenseUsage.ps1 -IncludeJobAssignments `
        -ExportCsv 'C:\reports\veeam-license-audit.csv'

    Vollständiger Audit-Report inklusive Job-Mitgliedschaften, exportiert
    nach CSV. Eignet sich als Anlage für Compliance-Berichte.

.EXAMPLE
    # Workflow: stale User identifizieren -> nach Sichtung bereinigen
    $candidates = .\Get-VeeamLicenseUsage.ps1 -NotBackedUpForDays 180

    $candidates | Format-Table UserName, LastBackupDate, DaysSinceLastBackup

    # Nach manueller Sichtung pro User Cleanup ausführen:
    $candidates | ForEach-Object {
        .\Remove-VeeamLicense.ps1 -Email $_.UserName -WhatIf
    }

.NOTES
    Author     : BAUER GROUP IT
    Version    : 1.0
    Repository : github.com/bauer-group/veeam-tools
    Lizenz     : MIT (siehe LICENSE)
    Tested on  : VBO v7.x, v8.x

    Read-only — modifiziert KEINE Veeam-Konfiguration und KEINE Daten.
    Sicher zur Ausführung in Produktion und parallel zu Backup-Jobs.

.LINK
    https://helpcenter.veeam.com/docs/vbo365/powershell/get-vbolicenseduser.html

.LINK
    https://github.com/bauer-group/veeam-tools
#>

[CmdletBinding()]
[OutputType([pscustomobject])]
param(
    [Parameter()]
    [string]$OrganizationName = 'BAUER GROUP',

    [Parameter()]
    [ValidateRange(0, 36500)]
    [int]$NotBackedUpForDays = 0,

    [Parameter()]
    [ValidateSet('All', 'Licensed', 'New', 'TemporaryAssigned', 'Exceeded')]
    [string]$LicenseStatus = 'All',

    [Parameter()]
    [switch]$IncludeJobAssignments,

    [Parameter()]
    [string]$ExportCsv
)

$ErrorActionPreference = 'Stop'

# ----------------------------------------------------------------------------
# 1. Veeam-Modul laden
# ----------------------------------------------------------------------------
if (-not (Get-Module -ListAvailable -Name Veeam.Archiver.PowerShell)) {
    throw 'Veeam.Archiver.PowerShell module not found. Install VBO console first.'
}
if (-not (Get-Module -Name Veeam.Archiver.PowerShell)) {
    Import-Module Veeam.Archiver.PowerShell -ErrorAction Stop
}

# ----------------------------------------------------------------------------
# 2. Organisation auflösen
# ----------------------------------------------------------------------------
$org = Get-VBOOrganization -Name $OrganizationName -ErrorAction SilentlyContinue
if (-not $org) {
    throw "Organization '$OrganizationName' not found in this VBO instance."
}

Write-Verbose "Fetching licensed users for organization '$OrganizationName'..."

# ----------------------------------------------------------------------------
# 3. Lizenzierte User abrufen
# ----------------------------------------------------------------------------
$licensedUsers = Get-VBOLicensedUser -Organization $org

if ($LicenseStatus -ne 'All') {
    $licensedUsers = $licensedUsers | Where-Object { $_.LicenseStatus -eq $LicenseStatus }
}

if (-not $licensedUsers) {
    Write-Warning "No licensed users found for organization '$OrganizationName' (filter: $LicenseStatus)."
    return
}

# ----------------------------------------------------------------------------
# 4. (optional) Job-Mitgliedschaften vorab in Hash-Map cachen
#
# Statt für jeden User einzeln durch alle Jobs zu walken (O(U*J)), bauen
# wir EINMAL eine Map UserName -> [JobName, ...] (O(J)). Bei z.B. 500
# Usern und 20 Jobs spart das den Faktor 500.
# ----------------------------------------------------------------------------
$jobMembership = @{}
if ($IncludeJobAssignments) {
    Write-Verbose 'Building job membership cache...'
    $jobs = Get-VBOJob -Organization $org

    foreach ($job in $jobs) {
        $items = Get-VBOBackupItem -Job $job
        foreach ($item in $items) {
            if ($item.User -and $item.User.UserName) {
                $key = $item.User.UserName.ToLowerInvariant()
                if (-not $jobMembership.ContainsKey($key)) {
                    $jobMembership[$key] = New-Object System.Collections.Generic.List[string]
                }
                $jobMembership[$key].Add($job.Name)
            }
        }
    }
    Write-Verbose ("Job membership cache built: {0} users in {1} jobs" -f $jobMembership.Count, $jobs.Count)
}

# ----------------------------------------------------------------------------
# 5. Result-Objekte bauen
# ----------------------------------------------------------------------------
$now = Get-Date
$results = foreach ($lu in $licensedUsers) {

    $daysSince = if ($lu.LastBackupDate) {
        [int]([math]::Floor(($now - $lu.LastBackupDate).TotalDays))
    }
    else {
        $null
    }

    $jobNames = ''
    if ($IncludeJobAssignments -and $lu.UserName) {
        $key = $lu.UserName.ToLowerInvariant()
        if ($jobMembership.ContainsKey($key)) {
            $jobNames = ($jobMembership[$key] | Sort-Object -Unique) -join '; '
        }
    }

    [pscustomobject]@{
        UserName            = $lu.UserName
        LicenseStatus       = $lu.LicenseStatus
        IsBackedUp          = $lu.IsBackedUp
        LastBackupDate      = $lu.LastBackupDate
        DaysSinceLastBackup = $daysSince
        OfficeId            = $lu.OfficeId
        OnPremisesId        = $lu.OnPremisesId
        OrganizationName    = $lu.OrganizationName
        JobNames            = $jobNames
    }
}

# ----------------------------------------------------------------------------
# 6. Filter: NotBackedUpForDays
# ----------------------------------------------------------------------------
if ($NotBackedUpForDays -gt 0) {
    $results = $results | Where-Object {
        # Stale User: entweder nie gesichert ODER zu lange her
        (-not $_.IsBackedUp) -or
        ($null -ne $_.DaysSinceLastBackup -and $_.DaysSinceLastBackup -ge $NotBackedUpForDays)
    }
}

# ----------------------------------------------------------------------------
# 7. Optional: CSV-Export
# ----------------------------------------------------------------------------
if ($ExportCsv) {
    $exportDir = Split-Path -Parent $ExportCsv
    if ($exportDir -and -not (Test-Path -LiteralPath $exportDir -PathType Container)) {
        New-Item -ItemType Directory -Path $exportDir -Force | Out-Null
    }
    $results | Export-Csv -Path $ExportCsv -NoTypeInformation -Encoding UTF8
    Write-Host ("Exported {0} users to: {1}" -f @($results).Count, $ExportCsv) -ForegroundColor Green
}

# ----------------------------------------------------------------------------
# 8. Pipeline-Output
# ----------------------------------------------------------------------------
$results
