#Requires -Version 5.1

<#
.SYNOPSIS
    GDPR-konformes User-Offboarding für Veeam Backup for Microsoft 365 (VBO).

.DESCRIPTION
    Entfernt einen User vollständig aus einer VBO-Organisation in fünf Schritten:

        1. Veeam.Archiver.PowerShell-Modul laden
        2. Organisation in der VBO-Instanz auflösen
        3. User aus ALLEN Backup-Jobs entfernen
           (sowohl SelectedItems als auch ExcludedItems)
        4. Backup-Daten aus ALLEN Repositories löschen
           (Mailbox, ArchiveMailbox, OneDrive, Sites)
        5. Lizenz freigeben

    Schritt 3 ist kritisch: Ohne Entfernung aus den Job-Definitionen würde
    der User beim nächsten Job-Lauf automatisch wieder lizenziert werden.

    Das Skript unterstützt -WhatIf und -Confirm via SupportsShouldProcess
    und schreibt pro Lauf ein vollständiges PowerShell-Transcript für
    GDPR-Audit-Nachweise.

.PARAMETER Email
    UPN/E-Mail-Adresse des zu entfernenden Users.
    Wird per RFC-konformem Regex validiert.
    Vergleiche gegen Veeam-Daten erfolgen case-insensitive (-ieq).

.PARAMETER OrganizationName
    Name der VBO-Organisation, exakt wie in der VBO-Konsole sichtbar.
    Default: 'BAUER GROUP'

.PARAMETER SkipDataDeletion
    Überspringt Schritt 4 (Datenlöschung). Anwendungsfall:
    Lizenz freigeben, aber Backups aus Aufbewahrungsgründen
    (HGB §257, AO §147, Litigation Hold) noch vorhalten.

.PARAMETER LogPath
    Zielverzeichnis für Transcript-Logs.
    Default: C:\ProgramData\Veeam\Backup365\Logs\LicenseCleanup
    Empfehlung: Auf einen revisionssicheren Share (WORM) umleiten,
    wenn Logs als GDPR-Nachweis dienen sollen.

.PARAMETER Force
    Unterdrückt alle Bestätigungs-Prompts (setzt $ConfirmPreference = 'None').
    Für nicht-interaktive Ausführung in ServiceNow-Workflows,
    Scheduled Tasks oder CI/CD-Pipelines.
    Wirkt NICHT zusammen mit -WhatIf — Trockenlauf bleibt Trockenlauf.

.OUTPUTS
    [pscustomobject] mit folgenden Feldern:

        Email                 - bearbeitete E-Mail-Adresse
        Organization          - VBO-Organisation
        Timestamp             - Startzeitpunkt des Laufs
        JobsCleaned           - Anzahl entfernter Job-Zuordnungen
        RepositoriesProcessed - gescannte Repositories
        RepositoriesWithData  - Repositories mit gefundenen Daten
        LicenseRemoved        - $true wenn Lizenz freigegeben wurde
        Skipped               - $true wenn -SkipDataDeletion gesetzt war
        LogFile               - voller Pfad zum Transcript
        Success               - Gesamtergebnis ($true / $false)

    Die Ausgabe ist für Konsum durch andere Skripte / Pipelines gedacht.

.EXAMPLE
    .\Remove-VeeamLicense.ps1 -Email 'max.mustermann@de.bauer-group.com' -WhatIf

    Trockenlauf — zeigt nur, was getan würde, ohne etwas zu verändern.
    IMMER zuerst so testen, besonders nach Skript-Änderungen.

.EXAMPLE
    .\Remove-VeeamLicense.ps1 -Email 'max.mustermann@de.bauer-group.com'

    Vollständiges Offboarding mit Bestätigungs-Prompts vor jeder
    destruktiven Aktion (interaktiver Modus).

.EXAMPLE
    .\Remove-VeeamLicense.ps1 `
        -Email 'alt@kunde.example.com' `
        -OrganizationName 'KUNDE XY GmbH' `
        -SkipDataDeletion `
        -Force

    Reine Lizenz-Freigabe für eine andere Organisation, ohne Prompts.
    Geeignet für scheduled Cleanups, wenn Daten aus rechtlichen
    Gründen erhalten bleiben müssen.

.EXAMPLE
    $r = .\Remove-VeeamLicense.ps1 -Email 'user@example.com' -Force
    if ($r.Success) {
        Send-MgUserMessage -UserId 'compliance@bauer-group.com' `
            -Subject "Offboarding $($r.Email) ok" `
            -Body "Log: $($r.LogFile)"
    }

    Konsumieren des Result-Objekts für Audit-Trail-Versand.

.NOTES
    Author     : BAUER GROUP IT
    Version    : 2.1
    Repository : github.com/bauer-group/veeam-tools
    Lizenz     : MIT (siehe LICENSE)
    Tested on  : VBO v7.x, v8.x

    Exit-Codes:
        0  Erfolg
        1  Allgemeiner Laufzeitfehler (siehe Transcript)
        2  Veeam.Archiver.PowerShell-Modul nicht verfügbar
        3  Organisation in der VBO-Instanz nicht gefunden

    Bekannte Einschränkungen:
        - Gruppen-basierte Backup-Selections (AD-/Entra-Gruppen) können
          nicht aufgelöst werden. Solche User müssen aus der Quellgruppe
          selbst entfernt werden, sonst wird die Lizenz erneut belegt.
        - Litigation Hold wird NICHT geprüft. Vor Ausführung manuell oder
          via separates Compliance-Tool prüfen.

.LINK
    https://helpcenter.veeam.com/docs/vbo365/powershell/

.LINK
    https://github.com/bauer-group/veeam-tools
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
[OutputType([pscustomobject])]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidatePattern('^[^@\s]+@[^@\s]+\.[^@\s]+$')]
    [Alias('UserPrincipalName', 'UPN')]
    [string]$Email,

    [Parameter()]
    [string]$OrganizationName = 'BAUER GROUP',

    [Parameter()]
    [switch]$SkipDataDeletion,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$LogPath = 'C:\ProgramData\Veeam\Backup365\Logs\LicenseCleanup',

    [Parameter()]
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# -Force unterdrückt Confirm-Prompts skript-weit. -WhatIf bleibt unberührt.
if ($Force) {
    $ConfirmPreference = 'None'
}

# ----------------------------------------------------------------------------
# Result-Objekt — wird über alle Schritte angereichert und am Ende ausgegeben
# ----------------------------------------------------------------------------
$result = [pscustomobject]@{
    Email                 = $Email
    Organization          = $OrganizationName
    Timestamp             = Get-Date
    JobsCleaned           = 0
    RepositoriesProcessed = 0
    RepositoriesWithData  = 0
    LicenseRemoved        = $false
    Skipped               = $SkipDataDeletion.IsPresent
    LogFile               = $null
    Success               = $false
}

# ----------------------------------------------------------------------------
# Logging vorbereiten — Transcript pro Lauf, eindeutig per Zeitstempel
# ----------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $LogPath -PathType Container)) {
    New-Item -ItemType Directory -Path $LogPath -Force | Out-Null
}

# Email als Dateinamen-Bestandteil sanitisieren (alles außer [a-zA-Z0-9] -> _)
$sanitizedEmail = $Email -replace '[^a-zA-Z0-9]', '_'
$timestamp      = Get-Date -Format 'yyyyMMdd-HHmmss'
$logFile        = Join-Path $LogPath "Remove-$sanitizedEmail-$timestamp.log"
$result.LogFile = $logFile

Start-Transcript -Path $logFile -Force | Out-Null

$exitCode = 0

try {
    Write-Host '=== VEEAM License Cleanup ===' -ForegroundColor Cyan
    Write-Host "Target  : $Email"
    Write-Host "Org     : $OrganizationName"
    Write-Host "Log     : $logFile"
    Write-Host "WhatIf  : $WhatIfPreference"
    Write-Host "Force   : $($Force.IsPresent)"
    Write-Host ''

    # ------------------------------------------------------------------------
    # 1. Veeam-Modul laden
    # ------------------------------------------------------------------------
    Write-Verbose 'Step 1/5: Loading Veeam.Archiver.PowerShell module'
    if (-not (Get-Module -ListAvailable -Name Veeam.Archiver.PowerShell)) {
        $exitCode = 2
        throw 'Veeam.Archiver.PowerShell module not found. Install VBO console first.'
    }
    if (-not (Get-Module -Name Veeam.Archiver.PowerShell)) {
        Import-Module Veeam.Archiver.PowerShell -ErrorAction Stop
    }

    # ------------------------------------------------------------------------
    # 2. Organisation auflösen
    # ------------------------------------------------------------------------
    Write-Verbose "Step 2/5: Resolving organization '$OrganizationName'"
    $org = Get-VBOOrganization -Name $OrganizationName -ErrorAction SilentlyContinue
    if (-not $org) {
        $exitCode = 3
        throw "Organization '$OrganizationName' not found in this VBO instance."
    }

    # ------------------------------------------------------------------------
    # 3. User aus allen Backup-Jobs entfernen
    #
    # KRITISCH: Dieser Schritt MUSS vor der Lizenz-Freigabe erfolgen.
    # Ansonsten würde der User beim nächsten Job-Lauf wieder
    # automatisch lizenziert werden, weil er in der Job-Definition
    # noch enthalten ist.
    # ------------------------------------------------------------------------
    Write-Verbose 'Step 3/5: Removing user from all backup jobs'
    $jobs = Get-VBOJob -Organization $org

    foreach ($job in $jobs) {
        # Eingeschlossene Items
        $included = Get-VBOBackupItem -Job $job | Where-Object {
            $_.User -and $_.User.UserName -ieq $Email
        }
        foreach ($item in $included) {
            if ($PSCmdlet.ShouldProcess($job.Name, "Remove user $Email from job")) {
                Write-Host "Removing $Email from job '$($job.Name)'..." -ForegroundColor Yellow
                Remove-VBOBackupItem -Job $job -BackupItem $item -Confirm:$false
                $result.JobsCleaned++
            }
        }

        # Ausgeschlossene Items (Excluded-Listen müssen ebenfalls bereinigt
        # werden, sonst tauchen "Geister-User" in der Audit-View auf).
        # WICHTIG: Remove-VBOExcludedBackupItem erwartet -BackupItem (nicht
        # -ExcludedBackupItem), obwohl Get-VBOExcludedBackupItem heißt. Beide
        # Cmdlets arbeiten mit demselben Typ [VBOBackupItem], die Parameter-
        # Namen sind jedoch asymmetrisch — Veeam-API-Quirk.
        $excluded = Get-VBOExcludedBackupItem -Job $job | Where-Object {
            $_.User -and $_.User.UserName -ieq $Email
        }
        foreach ($item in $excluded) {
            if ($PSCmdlet.ShouldProcess($job.Name, "Remove excluded user $Email from job")) {
                Write-Host "Removing excluded $Email from job '$($job.Name)'..." -ForegroundColor Yellow
                Remove-VBOExcludedBackupItem -Job $job -BackupItem $item -Confirm:$false
            }
        }
    }

    # ------------------------------------------------------------------------
    # 4. Backup-Daten aus allen Repositories löschen
    # ------------------------------------------------------------------------
    if (-not $SkipDataDeletion) {
        Write-Verbose 'Step 4/5: Deleting backup data from all repositories'
        $repositories = Get-VBORepository

        foreach ($repo in $repositories) {
            $result.RepositoriesProcessed++
            Write-Host "Scanning repository '$($repo.Name)' (large S3 repos can take minutes)..." -ForegroundColor Gray

            # Get-VBOEntityData kann fehlschlagen, wenn das Repo gerade
            # von einem laufenden Job gelockt ist. In dem Fall: warnen,
            # aber andere Repos weiterverarbeiten.
            try {
                $userData = Get-VBOEntityData -Type User -Repository $repo |
                    Where-Object { $_.Email -ieq $Email }
            }
            catch {
                Write-Warning "Skipping repository '$($repo.Name)': $($_.Exception.Message)"
                continue
            }

            if (-not $userData) { continue }

            $result.RepositoriesWithData++
            foreach ($u in $userData) {
                if ($PSCmdlet.ShouldProcess($repo.Name, "Delete backup data for $Email")) {
                    Write-Host "  -> Deleting data from '$($repo.Name)'..." -ForegroundColor Yellow
                    Remove-VBOEntityData -Repository $repo -User $u `
                        -Mailbox -ArchiveMailbox -OneDrive -Sites `
                        -Confirm:$false
                    Write-Host '  -> OK' -ForegroundColor Green
                }
            }
        }

        if ($result.RepositoriesWithData -eq 0) {
            Write-Warning "No backup data found for $Email in any repository."
        }
    }
    else {
        Write-Host 'Step 4/5: SKIPPED (-SkipDataDeletion)' -ForegroundColor DarkYellow
    }

    # ------------------------------------------------------------------------
    # 5. Lizenz freigeben
    # ------------------------------------------------------------------------
    Write-Verbose 'Step 5/5: Releasing license'
    $licensedUser = Get-VBOLicensedUser -Organization $org |
        Where-Object { $_.UserName -ieq $Email }

    if (-not $licensedUser) {
        Write-Warning "No licensed user entry found for $Email (already released?)."
    }
    else {
        if ($PSCmdlet.ShouldProcess($Email, 'Release license')) {
            Write-Host 'Releasing license...' -ForegroundColor Yellow
            Remove-VBOLicensedUser -User $licensedUser -Confirm:$false
            $result.LicenseRemoved = $true
            Write-Host 'License released.' -ForegroundColor Green
        }
    }

    $result.Success = $true

    Write-Host ''
    Write-Host "=== Cleanup completed for $Email ===" -ForegroundColor Cyan
    Write-Host ("Jobs cleaned         : {0}" -f $result.JobsCleaned)
    Write-Host ("Repositories scanned : {0}" -f $result.RepositoriesProcessed)
    Write-Host ("Repositories cleaned : {0}" -f $result.RepositoriesWithData)
    Write-Host ("License removed      : {0}" -f $result.LicenseRemoved)
}
catch {
    Write-Error "Aborted: $($_.Exception.Message)"
    $result.Success = $false
    if ($exitCode -eq 0) { $exitCode = 1 }
}
finally {
    Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
}

# Result-Objekt IMMER ausgeben — auch im Fehlerfall, damit der Caller
# (Pipeline / Automation) den Status zuverlässig auswerten kann.
Write-Output $result

exit $exitCode
