#Requires -Version 5.1

<#
.SYNOPSIS
    Entfernt einen User aus dem Backup-Scope von Veeam Backup for Microsoft 365.

.DESCRIPTION
    Dieses Skript entfernt einen Microsoft-365-User vollständig aus dem
    BACKUP-SCOPE einer VBO-Organisation. Der Microsoft-365-Account selbst
    wird NICHT gelöscht — der User kann weiterhin existieren, anmelden und
    arbeiten. Lediglich die Veeam-Backup-Schiene wird sauber entkoppelt:

        1. Veeam.Archiver.PowerShell-Modul laden
        2. Organisation in der VBO-Instanz auflösen
        3. User aus ALLEN Backup-Jobs entfernen
           (sowohl SelectedItems als auch ExcludedItems)
        4. Backup-Daten aus ALLEN Repositories löschen
           (Mailbox, ArchiveMailbox, OneDrive, Sites)
        5. Lizenz freigeben

    Anwendungsfälle:
        - Klassisches Offboarding (User verlässt Unternehmen)
        - GDPR-Löschanfrage (Art. 17 DSGVO) für aktiven User
        - Backup-Scope-Optimierung (User wechselt in Bereich ohne Backup-Pflicht)
        - Lizenz-Pool-Bereinigung (Mitarbeiter braucht kein VBO-Backup mehr)

    Schritt 3 ist kritisch: Ohne Entfernung aus den Job-Definitionen würde
    der User beim nächsten Job-Lauf wieder automatisch lizenziert werden,
    selbst wenn die Lizenz vorher freigegeben wurde.

    Das Skript unterstützt -WhatIf und -Confirm via SupportsShouldProcess
    und schreibt pro Lauf ein vollständiges PowerShell-Transcript für
    Audit-Nachweise (z. B. GDPR Art. 17 Löschnachweis).

    User-Auflösung:
        Das Skript versucht, den User per Get-VBOOrganizationUser über die
        UserName-Property aufzulösen (in Veeam-Konvention enthält UserName
        den UPN bzw. SMTP). Wenn der User in M365 noch existiert, werden
        die GUIDs (OfficeId / OnPremisesId) für robustes, namens-unab-
        hängiges Matching auf Backup-Daten und Lizenz verwendet. Wenn der
        User in M365 bereits gelöscht wurde, fällt das Skript auf einen
        Best-Effort-Modus mit Namens-Matching zurück.

.PARAMETER Email
    UPN/E-Mail-Adresse des Users, dessen Backup-Schiene entkoppelt
    werden soll. Wird per RFC-konformem Regex validiert. Vergleiche
    erfolgen case-insensitive (-ieq), GUID-Vergleiche bevorzugt.

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

.PARAMETER PassThru
    Gibt am Ende das strukturierte Result-Objekt an die Pipeline aus.
    OHNE diesen Switch zeigt das Skript nur eine kompakte Status-Zeile
    via Write-Host und liefert nichts an die Pipeline. Standardverhalten
    ist "leise" — Automation-Workflows nutzen -PassThru für Konsum.

.OUTPUTS
    Standardmäßig: nichts an die Pipeline (nur kompakter Host-Output).

    Mit -PassThru: [pscustomobject] mit folgenden Feldern:

        Email                 - bearbeitete E-Mail-Adresse
        Organization          - VBO-Organisation
        Timestamp             - Startzeitpunkt des Laufs
        UserResolved          - $true wenn User in M365-Org gefunden wurde
        JobsCleaned           - Anzahl entfernter SelectedItems
        ExcludedItemsCleaned  - Anzahl entfernter ExcludedItems
        RepositoriesProcessed - gescannte Repositories
        RepositoriesWithData  - Repositories mit gefundenen Daten
        LicenseRemoved        - $true wenn Lizenz freigegeben wurde
        Skipped               - $true wenn -SkipDataDeletion gesetzt war
        LogFile               - voller Pfad zum Transcript
        Success               - Gesamtergebnis ($true / $false)

.EXAMPLE
    .\Remove-VeeamLicense.ps1 -Email 'max.mustermann@de.bauer-group.com' -WhatIf

    Trockenlauf — zeigt nur, was getan würde, ohne etwas zu verändern.
    IMMER zuerst so testen, besonders nach Skript-Änderungen.

.EXAMPLE
    .\Remove-VeeamLicense.ps1 -Email 'max.mustermann@de.bauer-group.com'

    Vollständige Backup-Scope-Entkopplung mit Bestätigungs-Prompts vor
    jeder destruktiven Aktion (interaktiver Modus). Der M365-Account
    bleibt unberührt.

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
    $r = .\Remove-VeeamLicense.ps1 -Email 'user@example.com' -Force -PassThru
    if ($r.Success) {
        Send-MgUserMessage -UserId 'compliance@bauer-group.com' `
            -Subject "Backup-Scope-Cleanup $($r.Email) ok" `
            -Body "Log: $($r.LogFile)"
    }

    Konsumieren des Result-Objekts für Audit-Trail-Versand. -PassThru ist
    erforderlich, sonst gibt das Skript nichts an die Pipeline.

.NOTES
    Author     : BAUER GROUP IT
    Version    : 2.5
    Repository : github.com/bauer-group/veeam-tools
    Lizenz     : MIT (siehe LICENSE)
    Tested on  : VBO v7.x, v8.x

    Exit-Codes:
        0  Erfolg
        1  Allgemeiner Laufzeitfehler (siehe Transcript)
        2  Veeam.Archiver.PowerShell-Modul nicht verfügbar
        3  Organisation in der VBO-Instanz nicht gefunden

    Wichtig — was das Skript NICHT tut:
        - Es löscht KEINEN Microsoft-365-Account.
        - Es entzieht KEINE M365-Lizenzen (nur die Veeam-Lizenz).
        - Es prüft KEINEN Litigation Hold (vor Lauf separat prüfen).
        - Es bereinigt KEINE gruppen-basierten Backup-Selections — solche
          User müssen aus der AD-/Entra-Quellgruppe entfernt werden, sonst
          taucht der User beim nächsten Job-Lauf wieder auf.

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
    [switch]$Force,

    [Parameter()]
    [switch]$PassThru
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
    UserResolved          = $false
    JobsCleaned           = 0    # User aus SelectedItems entfernt
    ExcludedItemsCleaned  = 0    # User aus ExcludedItems entfernt
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

# -WhatIf:$false ist hier zwingend — sonst würde Start-Transcript im
# Trockenlauf-Modus übersprungen, und Stop-Transcript am Ende würde
# fehlschlagen, weil keine aktive Aufzeichnung läuft.
Start-Transcript -Path $logFile -Force -WhatIf:$false | Out-Null

$exitCode = 0

try {
    $modeTag = if ($WhatIfPreference) { ' [WhatIf]' } else { '' }
    Write-Host "Veeam Backup-Scope Cleanup$modeTag : $Email" -ForegroundColor Cyan
    Write-Verbose "Organization: $OrganizationName"
    Write-Verbose "Log file: $logFile"

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
    # 2b. User in der M365-Organisation auflösen (für robustes Matching)
    #
    # Get-VBOOrganizationUser nimmt die UserName-Property als Filter, die
    # in Veeam-Konvention den UPN/SMTP enthält (siehe Get-VBOOrganizationUser
    # Doku-Beispiel mit "userAlpha@tech.onmicrosoft.com").
    #
    # Wenn der User in M365 noch existiert, bekommen wir GUIDs (OfficeId /
    # OnPremisesId), mit denen wir Backup-Daten und Lizenz exakt matchen
    # können — unabhängig von Display-Name- oder Casing-Drift.
    #
    # Wenn der User bereits aus M365 gelöscht wurde, läuft das Skript im
    # Best-Effort-Fallback weiter und matched per Namens-Filter.
    # ------------------------------------------------------------------------
    Write-Verbose "Resolving organization user '$Email'"
    $orgUser = $null
    try {
        # Defensiv: -UserName macht laut Doku-Beispiel exaktes Matching, aber
        # falls die Implementierung mehrere Treffer liefert, filtern wir
        # zusätzlich strikt auf exakten Match und nehmen den ersten.
        $orgUser = Get-VBOOrganizationUser -Organization $org -UserName $Email -ErrorAction SilentlyContinue |
            Where-Object { $_.UserName -ieq $Email } |
            Select-Object -First 1
    }
    catch {
        Write-Verbose "Get-VBOOrganizationUser failed: $($_.Exception.Message)"
    }

    if ($orgUser) {
        $result.UserResolved = $true
        Write-Host ("  Resolved: {0} ({1}, {2})" -f $orgUser.DisplayName, $orgUser.Type, $orgUser.LocationType) -ForegroundColor DarkGray
        Write-Verbose ("  OfficeId={0} OnPremisesId={1}" -f $orgUser.OfficeId, $orgUser.OnPremisesId)
    }
    else {
        Write-Host "  Resolved: <not in M365 — fallback to name match>" -ForegroundColor DarkYellow
    }

    # ------------------------------------------------------------------------
    # 3. User aus allen Backup-Jobs entfernen
    #
    # KRITISCH: Dieser Schritt MUSS vor der Lizenz-Freigabe erfolgen.
    # Ansonsten würde der User beim nächsten Job-Lauf wieder
    # automatisch lizenziert werden, weil er in der Job-Definition
    # noch enthalten ist.
    #
    # VBOBackupItem ist eine abstrakte Basis-Klasse. Für User-typed Items
    # ist die konkrete Subklasse VBOBackupUser, die eine .User-Property
    # vom Typ VBOOrganizationUser enthält. Über .User.UserName matchen
    # wir den UPN.
    # ------------------------------------------------------------------------
    Write-Verbose 'Step 3/5: Removing user from all backup jobs'
    $jobs = Get-VBOJob -Organization $org

    foreach ($job in $jobs) {
        # --- Eingeschlossene Items ---
        $included = Get-VBOBackupItem -Job $job | Where-Object {
            $_.User -and $_.User.UserName -ieq $Email
        }
        foreach ($item in $included) {
            if ($PSCmdlet.ShouldProcess($job.Name, "Remove user $Email from job")) {
                Write-Verbose "Removing $Email from job '$($job.Name)'"
                # Remove-VBOBackupItem implementiert SupportsShouldProcess
                # NICHT (siehe Veeam-Doku Syntax: nur [<CommonParameters>],
                # kein [-Confirm]). Daher KEIN -Confirm:$false anhängen,
                # sonst: ParameterBindingException. Confirm-Punkt ist
                # ausschließlich unser ShouldProcess-Aufruf darüber.
                Remove-VBOBackupItem -Job $job -BackupItem $item
                $result.JobsCleaned++
            }
        }

        # --- Ausgeschlossene Items ---
        # Excluded-Listen müssen ebenfalls bereinigt werden, sonst tauchen
        # "Geister-User" in der Audit-View auf.
        # Quirk: Remove-VBOExcludedBackupItem erwartet -BackupItem (nicht
        # -ExcludedBackupItem), obwohl Get-VBOExcludedBackupItem heißt.
        # Beide Cmdlets arbeiten mit demselben Typ [VBOBackupItem], die
        # Parameter-Namen sind jedoch asymmetrisch — Veeam-API-Quirk.
        $excluded = Get-VBOExcludedBackupItem -Job $job | Where-Object {
            $_.User -and $_.User.UserName -ieq $Email
        }
        foreach ($item in $excluded) {
            if ($PSCmdlet.ShouldProcess($job.Name, "Remove excluded user $Email from job")) {
                Write-Verbose "Removing excluded $Email from job '$($job.Name)'"
                # Remove-VBOExcludedBackupItem implementiert SupportsShouldProcess
                # NICHT — kein -Confirm/-WhatIf in der Veeam-Doku-Syntax.
                Remove-VBOExcludedBackupItem -Job $job -BackupItem $item
                $result.ExcludedItemsCleaned++
            }
        }
    }

    # ------------------------------------------------------------------------
    # 4. Backup-Daten aus allen Repositories löschen
    #
    # Wir nutzen die EINGEBAUTEN Filter-Parameter von Get-VBOEntityData
    # statt Property-Reflection auf dem Result. Wenn $orgUser aufgelöst
    # werden konnte, übergeben wir -User direkt — das filtert server-
    # seitig auf die GUID des Users. Sonst Best-Effort über -Name $Email.
    # ------------------------------------------------------------------------
    if (-not $SkipDataDeletion) {
        Write-Verbose 'Step 4/5: Deleting backup data from all repositories'
        $repositories = Get-VBORepository

        foreach ($repo in $repositories) {
            $result.RepositoriesProcessed++
            Write-Verbose "Scanning repository '$($repo.Name)'"

            # Get-VBOEntityData hat zwei distinkte Parameter-Sets:
            #   1) -Repository -Type [-Name] [-Organization]
            #   2) -Repository -User
            # -Type und -User können NICHT kombiniert werden.
            #
            # Strategie:
            #   1. Wenn $orgUser aufgelöst wurde -> ByUser ParameterSet
            #      (server-seitiger Filter über aktuelle GUIDs).
            #   2. Wenn ByUser keine Daten findet (Veeam wirft "User not
            #      found in the repository" als Exception, weil die
            #      Backups z. B. historisch unter anderer ID gespeichert
            #      sind), still fallback auf ByType-Name-Suche.
            #   3. Wenn auch das nichts findet, akzeptieren: keine
            #      Backup-Daten in diesem Repo für diesen User.
            #
            # Andere Exceptions (Repo gelockt, Auth-Fehler, etc.) werden
            # als Warning gemeldet und das Repo wird übersprungen.
            $userData = $null
            $skipRepo = $false

            if ($orgUser) {
                try {
                    $userData = Get-VBOEntityData -Repository $repo -User $orgUser
                }
                catch {
                    if ($_.Exception.Message -match 'User not found in the repository') {
                        # Erwarteter Fall — fall through zum Name-Fallback
                        Write-Verbose "ByUser filter found nothing in '$($repo.Name)'; trying name fallback"
                    }
                    else {
                        Write-Warning "Skipping repository '$($repo.Name)' (ByUser): $($_.Exception.Message)"
                        $skipRepo = $true
                    }
                }
            }

            if ($skipRepo) { continue }

            if (-not $userData) {
                try {
                    $userData = Get-VBOEntityData -Repository $repo -Type User -Name $Email
                }
                catch {
                    if ($_.Exception.Message -match 'not found') {
                        Write-Verbose "ByType-Name filter found nothing in '$($repo.Name)' either"
                    }
                    else {
                        Write-Warning "Skipping repository '$($repo.Name)' (ByType): $($_.Exception.Message)"
                    }
                    continue
                }
            }

            if (-not $userData) { continue }

            $result.RepositoriesWithData++
            foreach ($u in $userData) {
                if ($PSCmdlet.ShouldProcess($repo.Name, "Delete backup data for $Email")) {
                    Write-Verbose "Deleting data from '$($repo.Name)'"
                    Remove-VBOEntityData -Repository $repo -User $u `
                        -Mailbox -ArchiveMailbox -OneDrive -Sites `
                        -Confirm:$false
                }
            }
        }

        if ($result.RepositoriesWithData -eq 0) {
            # Kein Fehler, nur Information — Backups können legitim weg sein.
            Write-Verbose "No backup data found in any repository for $Email"
        }
    }
    else {
        Write-Verbose 'Step 4/5: SKIPPED (-SkipDataDeletion)'
    }

    # ------------------------------------------------------------------------
    # 5. Lizenz freigeben
    #
    # Matching-Strategie:
    #   - Wenn $orgUser aufgelöst wurde: Match per OfficeId / OnPremisesId
    #     (GUID-basiert, robust gegen Namens-Drift).
    #   - Sonst Best-Effort-Fallback per UserName-Property (Veeam-Konvention
    #     UserName == UPN, in der Doku aber nicht garantiert).
    # ------------------------------------------------------------------------
    Write-Verbose 'Step 5/5: Releasing license'
    $allLicensed = Get-VBOLicensedUser -Organization $org

    # All-zeros GUID = "kein Wert" (kommt bei Cloud-only Usern in OnPremisesId
    # vor). Wenn wir das nicht filtern, würde der OnPremisesId-Match ALLE
    # Cloud-only User selectieren -> Array statt Single-Match -> Crash bei
    # Remove-VBOLicensedUser -User $array.
    $emptyGuid = [guid]::Empty

    $licensedMatches = if ($orgUser) {
        $allLicensed | Where-Object {
            ($orgUser.OfficeId     -ne $emptyGuid -and $_.OfficeId     -eq $orgUser.OfficeId) -or
            ($orgUser.OnPremisesId -ne $emptyGuid -and $_.OnPremisesId -eq $orgUser.OnPremisesId)
        }
    }
    else {
        $allLicensed | Where-Object { $_.UserName -ieq $Email }
    }

    # Defensive: bei mehrfachem Match nehmen wir den ersten und warnen.
    $licensedUser = $licensedMatches | Select-Object -First 1
    $matchCount   = @($licensedMatches).Count

    if ($matchCount -gt 1) {
        Write-Warning "Multiple licensed user entries matched ($matchCount). Using first: $($licensedUser.UserName)"
    }

    if (-not $licensedUser) {
        Write-Verbose "No licensed user entry found for $Email (already released?)."
    }
    else {
        if ($PSCmdlet.ShouldProcess($Email, 'Release license')) {
            # Remove-VBOLicensedUser implementiert SupportsShouldProcess
            # NICHT — kein -Confirm/-WhatIf in der Veeam-Doku-Syntax.
            Remove-VBOLicensedUser -User $licensedUser
            $result.LicenseRemoved = $true
        }
    }

    $result.Success = $true

    # Kompakte einzeilige Summary — Details via -Verbose oder im Result-Objekt
    $licenseTag = if ($result.LicenseRemoved) { 'license=released' } else { 'license=kept' }
    $skipTag    = if ($result.Skipped) { ' data=skipped' } else { '' }
    Write-Host ("  Done: jobs={0}+{1} repos={2}/{3} {4}{5}" -f `
        $result.JobsCleaned, $result.ExcludedItemsCleaned, `
        $result.RepositoriesWithData, $result.RepositoriesProcessed, `
        $licenseTag, $skipTag) -ForegroundColor Green
}
catch {
    Write-Error "Aborted: $($_.Exception.Message)"
    $result.Success = $false
    if ($exitCode -eq 0) { $exitCode = 1 }
}
finally {
    # -WhatIf:$false damit Stop-Transcript auch im Trockenlauf läuft.
    # Try/catch zusätzlich, falls Start-Transcript aus anderen Gründen
    # nie aktiv geworden ist (sonst wirft Stop-Transcript trotz
    # SilentlyContinue eine Exception).
    try {
        Stop-Transcript -WhatIf:$false -ErrorAction SilentlyContinue | Out-Null
    }
    catch {
        # Ignorieren — kein aktives Transcript
    }
}

# Result-Objekt nur ausgeben wenn -PassThru gesetzt ist. Standardmäßig
# bekommt der Anwender nur die kompakte Status-Zeile via Write-Host.
# Automation-Workflows nutzen -PassThru für strukturierten Konsum.
if ($PassThru) {
    Write-Output $result
}

exit $exitCode
