<#
.SYNOPSIS
    Entfernt einen User vollständig aus Veeam Backup for Microsoft 365:
    Backup-Daten aus allen Repositories, Job-Zuordnungen und Lizenz.

.DESCRIPTION
    GDPR-konformes Offboarding-Script für VBO. Löscht Mailbox-, Archive-,
    OneDrive- und SharePoint-Daten aus allen Repositories, entfernt den User
    aus allen Backup-Jobs und gibt die Lizenz frei.

.PARAMETER Email
    E-Mail-Adresse (UPN) des zu entfernenden Users.

.PARAMETER OrganizationName
    Name der VBO-Organisation. Default: BAUER GROUP

.PARAMETER SkipDataDeletion
    Entfernt nur die Lizenz, ohne Backup-Daten zu löschen.

.EXAMPLE
    .\Remove-VeeamLicense.ps1 -Email "mr@de.bauer-group.com"

.EXAMPLE
    .\Remove-VeeamLicense.ps1 -Email "mr@de.bauer-group.com" -WhatIf
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[^@\s]+@[^@\s]+\.[^@\s]+$')]
    [string]$Email,

    [string]$OrganizationName = "BAUER GROUP",

    [switch]$SkipDataDeletion,

    [string]$LogPath = "C:\ProgramData\Veeam\Backup365\Logs\LicenseCleanup"
)

$ErrorActionPreference = 'Stop'

# --- Logging vorbereiten ---
if (-not (Test-Path $LogPath)) {
    New-Item -ItemType Directory -Path $LogPath -Force | Out-Null
}
$logFile = Join-Path $LogPath ("Remove-{0}-{1:yyyyMMdd-HHmmss}.log" -f ($Email -replace '[@\.]', '_'), (Get-Date))
Start-Transcript -Path $logFile -Force | Out-Null

try {
    Write-Host "=== VEEAM License Cleanup ===" -ForegroundColor Cyan
    Write-Host "Target : $Email"
    Write-Host "Org    : $OrganizationName"
    Write-Host "Log    : $logFile"
    Write-Host ""

    # --- 1. Veeam-Modul laden ---
    if (-not (Get-Module -Name Veeam.Archiver.PowerShell)) {
        Write-Verbose "Lade Veeam.Archiver.PowerShell..."
        Import-Module Veeam.Archiver.PowerShell -ErrorAction Stop
    }

    # --- 2. Organisation holen ---
    $org = Get-VBOOrganization -Name $OrganizationName -ErrorAction Stop
    if (-not $org) {
        throw "Organisation '$OrganizationName' nicht gefunden."
    }

    # --- 3. User aus allen Backup-Jobs entfernen ---
    # Wichtig: Ohne diesen Schritt wird der User bei Job-Lauf neu lizenziert.
    $jobs = Get-VBOJob -Organization $org
    foreach ($job in $jobs) {
        $selectedItems = Get-VBOBackupItem -Job $job | Where-Object {
            $_.User -and $_.User.UserName -eq $Email
        }
        foreach ($item in $selectedItems) {
            if ($PSCmdlet.ShouldProcess("$($job.Name)", "Remove user $Email from job")) {
                Write-Host "Entferne $Email aus Job '$($job.Name)'..." -ForegroundColor Yellow
                Remove-VBOBackupItem -Job $job -BackupItem $item -Confirm:$false
            }
        }

        $excludedItems = Get-VBOExcludedBackupItem -Job $job | Where-Object {
            $_.User -and $_.User.UserName -eq $Email
        }
        foreach ($item in $excludedItems) {
            if ($PSCmdlet.ShouldProcess("$($job.Name)", "Remove excluded user $Email")) {
                Remove-VBOExcludedBackupItem -Job $job -ExcludedBackupItem $item -Confirm:$false
            }
        }
    }

    # --- 4. Backup-Daten aus ALLEN Repositories löschen ---
    if (-not $SkipDataDeletion) {
        $repositories = Get-VBORepository
        $dataFound = $false

        foreach ($repo in $repositories) {
            Write-Host "Prüfe Repository '$($repo.Name)' (kann bei großen S3-Repos dauern)..." -ForegroundColor Gray

            $userData = Get-VBOEntityData -Type User -Repository $repo |
                Where-Object { $_.Email -eq $Email }

            if (-not $userData) { continue }

            $dataFound = $true
            foreach ($u in $userData) {
                if ($PSCmdlet.ShouldProcess("$($repo.Name)", "Delete backup data for $Email")) {
                    Write-Host "  -> Lösche Daten aus '$($repo.Name)'..." -ForegroundColor Yellow
                    try {
                        Remove-VBOEntityData -Repository $repo `
                            -User $u `
                            -Mailbox -ArchiveMailbox -OneDrive -Sites `
                            -Confirm:$false
                        Write-Host "  -> OK" -ForegroundColor Green
                    }
                    catch {
                        Write-Error "Fehler beim Löschen aus '$($repo.Name)': $_"
                        throw
                    }
                }
            }
        }

        if (-not $dataFound) {
            Write-Warning "Keine Backup-Daten für $Email in irgendeinem Repository gefunden."
        }
    }
    else {
        Write-Host "SkipDataDeletion aktiv — Datenlöschung übersprungen." -ForegroundColor DarkYellow
    }

    # --- 5. Lizenz freigeben ---
    $licensedUser = Get-VBOLicensedUser -Organization $org |
        Where-Object { $_.UserName -eq $Email }

    if (-not $licensedUser) {
        Write-Warning "Kein lizenzierter User für $Email gefunden (ggf. bereits freigegeben)."
    }
    else {
        if ($PSCmdlet.ShouldProcess($Email, "Remove license")) {
            Write-Host "Entferne Lizenz..." -ForegroundColor Yellow
            Remove-VBOLicensedUser -User $licensedUser -Confirm:$false
            Write-Host "Lizenz erfolgreich freigegeben." -ForegroundColor Green
        }
    }

    Write-Host ""
    Write-Host "=== Cleanup abgeschlossen für $Email ===" -ForegroundColor Cyan
}
catch {
    Write-Error "Abbruch: $_"
    exit 1
}
finally {
    Stop-Transcript | Out-Null
}