# Veeam Tools

> **PowerShell-Toolkit für Veeam Backup for Microsoft 365 (VBO)**
> Listing, Auditierung und sauberes Backup-Scope-Cleanup für M365-User — ohne die M365-Accounts selbst anzufassen.

[![PowerShell 5.1+](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?logo=powershell&logoColor=white)](https://learn.microsoft.com/powershell/)
[![Veeam VBO](https://img.shields.io/badge/Veeam%20VBO-v7%2B-00B336?logo=veeam&logoColor=white)](https://www.veeam.com/backup-microsoft-office-365.html)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

---

## Übersicht

| Skript | Zweck | Wirkt destruktiv? |
| --- | --- | --- |
| [`Get-VeeamLicenseUsage.ps1`](Get-VeeamLicenseUsage.ps1) | Listet alle lizenzierten User mit Backup-Status, Job-Mitgliedschaften und Stale-Days | nein (read-only) |
| [`Remove-VeeamLicense.ps1`](Remove-VeeamLicense.ps1) | Entfernt einen User vollständig aus dem Veeam-Backup-Scope und gibt die Lizenz frei | **ja** |

**Empfohlener Workflow:**

1. **`Get-VeeamLicenseUsage.ps1`** ausführen, um Cleanup-Kandidaten zu identifizieren (Stale-User, Exceeded-Lizenzen, etc.)
2. Liste manuell sichten — vor allem Litigation Hold und gesetzliche Aufbewahrungsfristen prüfen
3. **`Remove-VeeamLicense.ps1 -WhatIf`** für jeden Kandidaten testen
4. Echten Cleanup-Lauf durchführen

---

## Get-VeeamLicenseUsage.ps1 — Lizenz-Inventur

Read-only Inventur der lizenzierten User einer VBO-Organisation. Beantwortet die Frage: **"Welche User belegen unsere Veeam-Lizenzen, und welche sollten weg?"**

### Quick Start

```powershell
# Alle lizenzierten User listen
.\Get-VeeamLicenseUsage.ps1

# User finden, die seit 90+ Tagen nicht mehr gesichert wurden (Cleanup-Kandidaten)
.\Get-VeeamLicenseUsage.ps1 -NotBackedUpForDays 90 |
    Format-Table UserName, LicenseStatus, LastBackupDate, DaysSinceLastBackup

# Nur User mit überschüssiger Lizenz (Pool exceeded)
.\Get-VeeamLicenseUsage.ps1 -LicenseStatus Exceeded

# Vollständiger Audit-Report inkl. Job-Mitgliedschaften, als CSV
.\Get-VeeamLicenseUsage.ps1 -IncludeJobAssignments `
    -ExportCsv 'C:\reports\veeam-license-audit.csv'
```

### Parameter

| Parameter | Typ | Default | Beschreibung |
| --- | --- | --- | --- |
| `-OrganizationName` | `string` | `BAUER GROUP` | Name der VBO-Organisation |
| `-NotBackedUpForDays` | `int` | `0` | Filter: nur User mit Backup-Alter ≥ N Tagen (oder nie gesichert) |
| `-LicenseStatus` | `string` | `All` | Filter: `All`, `Licensed`, `New`, `TemporaryAssigned`, `Exceeded` |
| `-IncludeJobAssignments` | `switch` | `$false` | Erweitert um Job-Mitgliedschaften pro User |
| `-ExportCsv` | `string` | — | CSV-Ausgabepfad (UTF-8) |

### Output-Felder

```text
UserName            : max.mustermann@de.bauer-group.com
LicenseStatus       : Licensed
IsBackedUp          : True
LastBackupDate      : 2026-01-15 03:14:22
DaysSinceLastBackup : 83
OfficeId            : abb37d72-9772-4e8d-b169-69f0db19d1c1
OnPremisesId        : 00000000-0000-0000-0000-000000000000
OrganizationName    : BAUER GROUP
JobNames            : Daily-Mailbox; Daily-OneDrive
```

### Pipeline-Workflow für Cleanup

```powershell
# 1. Stale-User identifizieren
$candidates = .\Get-VeeamLicenseUsage.ps1 -NotBackedUpForDays 180

# 2. Sichten
$candidates | Format-Table UserName, LicenseStatus, LastBackupDate, DaysSinceLastBackup

# 3. Trockenlauf für jeden Kandidaten
$candidates | ForEach-Object {
    .\Remove-VeeamLicense.ps1 -Email $_.UserName -WhatIf
}

# 4. Nach Sichtung: echter Lauf (manuell pro User oder automatisiert)
$candidates | ForEach-Object {
    .\Remove-VeeamLicense.ps1 -Email $_.UserName -Force
}
```

> **Sicherheit:** Das Skript schreibt **nichts** in Veeam zurück. Es ist sicher zur Ausführung in Produktion und parallel zu Backup-Jobs.

---

## Remove-VeeamLicense.ps1 — Backup-Scope-Cleanup

Entfernt einen User vollständig aus dem **Backup-Scope** einer VBO-Organisation in einem einzigen Lauf:

- **Entfernt** den User aus *allen* Backup-Jobs (sonst wird die Veeam-Lizenz beim nächsten Job-Lauf wieder belegt)
- **Löscht** alle Backup-Daten (Mailbox, Archive, OneDrive, SharePoint) aus *allen* Repositories
- **Gibt** die Veeam-Lizenz frei, damit sie für andere User verfügbar ist
- **Schreibt** ein vollständiges Audit-Transcript für Compliance-Nachweise
- **Liefert** ein strukturiertes Result-Objekt für Automation (ServiceNow, ITSM, Splunk, …)

> **Wichtig:** Das Skript fasst den **Microsoft-365-Account selbst nicht an**.
> Der User kann weiterhin existieren, sich anmelden und arbeiten — er wird lediglich aus der Veeam-Backup-Schiene entkoppelt. Die **Veeam**-Lizenz wird freigegeben, **nicht** die M365-Lizenz.

### Anwendungsfälle

| Szenario | Was passiert mit dem M365-Account? |
| --- | --- |
| **Klassisches Offboarding** — Mitarbeiter verlässt das Unternehmen | M365-Account wird separat (z. B. via Entra ID Workflow) deaktiviert |
| **GDPR-Löschanfrage (Art. 17 DSGVO)** für aktiven Mitarbeiter | M365-Account bleibt aktiv, nur Backup-Historie wird gelöscht |
| **Backup-Scope-Optimierung** — User wechselt in Bereich ohne Backup-Pflicht | M365-Account bleibt unverändert |
| **Lizenz-Pool-Bereinigung** — Veeam-Lizenz für andere User freigeben | M365-Account bleibt unverändert |

Ohne dieses Tool müssten Admins jeden Schritt einzeln in der VBO-Konsole abarbeiten — fehleranfällig, zeitaufwendig und ohne maschinenlesbaren Audit-Trail.

---

## Zweck und Hintergrund

Um einen User aus dem Veeam-Backup-Scope zu entfernen, müssen mehrere Schritte in der VBO-Konsole **einzeln und in der richtigen Reihenfolge** ausgeführt werden. Wird die Reihenfolge verletzt, ist das Ergebnis fehlerhaft:

| Schritt | Wenn vergessen | Folge |
| --- | --- | --- |
| User aus Backup-Jobs entfernen | Veeam-Lizenz wird beim nächsten Job-Lauf erneut belegt | Lizenzpool blockiert |
| Backup-Daten aus Repos löschen | Personenbezogene Daten verbleiben im Backup | DSGVO Art. 17 Verstoß, Bußgeld-Risiko |
| Veeam-Lizenz freigeben | Lizenzpool wird unnötig blockiert | Höhere Kosten, neue User können nicht aufgenommen werden |

Dieses Skript automatisiert alle drei Schritte in **einem Durchlauf** mit vollständigem Audit-Trail und garantiert die korrekte Reihenfolge.

---

## Was das Skript NICHT tut

Klare Abgrenzung, um Missverständnisse zu vermeiden:

| Aktion | Tut das Skript? |
| --- | --- |
| Entfernt den User aus VBO-Backup-Jobs | ja |
| Löscht Backup-Daten aus VBO-Repositories | ja |
| Gibt die **Veeam**-Lizenz frei | ja |
| Löscht den Microsoft-365-Account | **NEIN** |
| Entzieht **M365**-Lizenzen (Office, Exchange, Teams) | **NEIN** |
| Deaktiviert den User in Entra ID / Active Directory | **NEIN** |
| Setzt das Passwort zurück | **NEIN** |
| Prüft Litigation Hold automatisch | **NEIN** (vor Lauf separat prüfen) |
| Bereinigt gruppen-basierte Backup-Selections | **NEIN** (Quellgruppe in AD/Entra anpassen) |

Für ein **vollständiges Offboarding** muss zusätzlich ein separater Entra-ID/AD-Workflow laufen, der den Account selbst deaktiviert.

---

## Voraussetzungen

| Komponente | Anforderung |
| --- | --- |
| **Betriebssystem** | Windows Server mit installierter VBO-Konsole |
| **PowerShell** | 5.1 oder höher (7.x empfohlen) |
| **Veeam-Modul** | `Veeam.Archiver.PowerShell` (wird vom Skript automatisch geladen) |
| **VBO-Version** | v7 oder höher (wegen `Get-VBOBackupItem`) |
| **Berechtigungen** | Lokaler Administrator auf dem VBO-Server **und** VBO-Administrator-Rolle |

Das Skript wird direkt **auf dem VBO-Server** oder auf einer Maschine mit installierter Veeam-Konsole ausgeführt.

---

## Installation

1. **Skript in einen geschützten Ordner auf dem VBO-Server kopieren**, z. B.:

   ```text
   C:\Scripts\Veeam\Remove-VeeamLicense.ps1
   ```

2. **NTFS-ACLs setzen** — nur VBO-Admins dürfen lesen/ausführen:

   ```powershell
   icacls 'C:\Scripts\Veeam' /inheritance:r `
       /grant:r 'BUILTIN\Administrators:(OI)(CI)F' `
       /grant:r 'NT AUTHORITY\SYSTEM:(OI)(CI)F' `
       /grant:r 'BAUER\VBO-Admins:(OI)(CI)RX'
   ```

3. **Execution Policy prüfen** (einmalig):

   ```powershell
   Get-ExecutionPolicy
   # Falls Restricted:
   Set-ExecutionPolicy -Scope LocalMachine -ExecutionPolicy RemoteSigned
   ```

4. **Log-Verzeichnis** wird beim ersten Lauf automatisch erstellt:

   ```text
   C:\ProgramData\Veeam\Backup365\Logs\LicenseCleanup\
   ```

---

## Verwendung

### Standardaufruf (immer mit `-WhatIf` testen)

```powershell
# Trockenlauf — zeigt nur an, was getan würde
.\Remove-VeeamLicense.ps1 -Email 'max.mustermann@de.bauer-group.com' -WhatIf

# Echter Lauf mit interaktiven Bestätigungen
.\Remove-VeeamLicense.ps1 -Email 'max.mustermann@de.bauer-group.com'
```

### Nicht-interaktiv (Automation, ServiceNow, Scheduled Task)

```powershell
.\Remove-VeeamLicense.ps1 -Email 'max.mustermann@de.bauer-group.com' -Force
```

`-Force` setzt `$ConfirmPreference = 'None'` für die Skript-Laufzeit. `-WhatIf` bleibt davon unberührt.

### Nur Lizenz freigeben, Backup-Daten behalten

Nützlich, wenn der User zwar keine Lizenz mehr braucht, die Backups aber aus gesetzlichen Aufbewahrungsgründen (HGB §257, AO §147, Litigation Hold) noch vorgehalten werden müssen.

```powershell
.\Remove-VeeamLicense.ps1 -Email 'max.mustermann@de.bauer-group.com' -SkipDataDeletion
```

### Abweichende Organisation

```powershell
.\Remove-VeeamLicense.ps1 `
    -Email 'user@kunde.example.com' `
    -OrganizationName 'KUNDE XY GmbH'
```

### Eigener Log-Pfad (z. B. WORM-Share)

```powershell
.\Remove-VeeamLicense.ps1 `
    -Email 'max.mustermann@de.bauer-group.com' `
    -LogPath '\\fileserver\audit\veeam-offboarding'
```

### Result-Objekt konsumieren

```powershell
$r = .\Remove-VeeamLicense.ps1 -Email 'user@example.com' -Force
if ($r.Success) {
    Write-Host "Offboarding ok — Lizenz freigegeben: $($r.LicenseRemoved)"
    Write-Host "Audit-Log: $($r.LogFile)"
}
else {
    Send-MailMessage -To 'compliance@bauer-group.com' `
        -Subject "Offboarding $($r.Email) FEHLGESCHLAGEN" `
        -Body "Siehe Log: $($r.LogFile)"
}
```

---

## Parameter-Referenz (Remove-VeeamLicense)

| Parameter | Typ | Pflicht | Default | Beschreibung |
| --- | --- | --- | --- | --- |
| `-Email` | `string` | **ja** | — | UPN/E-Mail des Users. Wird per Regex validiert. Aliase: `-UserPrincipalName`, `-UPN`. |
| `-OrganizationName` | `string` | nein | `BAUER GROUP` | Name der VBO-Organisation, exakt wie in der VBO-Konsole sichtbar. |
| `-SkipDataDeletion` | `switch` | nein | `$false` | Überspringt Schritt 4 (Datenlöschung). Job-Bereinigung und Lizenz-Freigabe laufen weiter. |
| `-LogPath` | `string` | nein | `C:\ProgramData\Veeam\Backup365\Logs\LicenseCleanup` | Zielverzeichnis für Transcript-Logs. |
| `-Force` | `switch` | nein | `$false` | Unterdrückt alle Bestätigungs-Prompts. Für nicht-interaktive Ausführung. |
| `-WhatIf` | `switch` | nein | — | Zeigt nur an, welche Aktionen ausgeführt würden. **Immer für ersten Test verwenden.** |
| `-Confirm` | `switch` | nein | — | Erzwingt Bestätigung vor jeder destruktiven Aktion. |
| `-Verbose` | `switch` | nein | — | Gibt Step-Marker und zusätzliche Debug-Informationen aus. |

---

## Ablauf

Das Skript arbeitet in fünf streng sequentiellen Schritten ab:

```text
  ┌─────────────────────────────────────────┐
  │ 1. Veeam.Archiver.PowerShell laden      │  exit 2 wenn Modul fehlt
  └────────────────┬────────────────────────┘
                   │
  ┌────────────────▼────────────────────────┐
  │ 2. Organisation auflösen                │  exit 3 wenn nicht gefunden
  └────────────────┬────────────────────────┘
                   │
  ┌────────────────▼────────────────────────┐
  │ 3. User aus ALLEN Backup-Jobs entfernen │  KRITISCH — verhindert
  │    (SelectedItems + ExcludedItems)      │  Re-Lizenzierung
  └────────────────┬────────────────────────┘
                   │
  ┌────────────────▼────────────────────────┐
  │ 4. Backup-Daten aus ALLEN Repos löschen │  übersprungen mit
  │    (Mailbox, Archive, OneDrive, Sites)  │  -SkipDataDeletion
  └────────────────┬────────────────────────┘
                   │
  ┌────────────────▼────────────────────────┐
  │ 5. Lizenz freigeben                     │
  └────────────────┬────────────────────────┘
                   │
  ┌────────────────▼────────────────────────┐
  │ Result-Objekt ausgeben + Exit-Code      │
  └─────────────────────────────────────────┘
```

> **Warum Reihenfolge wichtig ist:** Schritt 3 *muss* vor Schritt 5 stehen. Wenn der User noch in einer Job-Definition steht, wird er beim nächsten Job-Lauf automatisch wieder lizenziert — dann war Schritt 5 umsonst.

---

## User-Auflösung

Das Skript versucht **vor Schritt 3**, den User in der Microsoft-365-Organisation aufzulösen. Diese Auflösung entscheidet, mit welcher Genauigkeit Backup-Daten und Lizenz später gefunden werden:

```text
Get-VBOOrganizationUser -Organization $org -UserName $Email
                            │
                            ├─► User existiert in M365  ──►  Preferred Path
                            │                                Match per OfficeId / OnPremisesId (GUID)
                            │                                Robust gegen Display-Name-Drift
                            │
                            └─► User nicht gefunden     ──►  Fallback Path
                                                             Match per Name (UPN als String)
                                                             Best-Effort, Warnung im Log
```

### Preferred Path — User existiert in M365

Wenn der User noch in der Microsoft-365-Organisation ist (auch wenn er aus dem Backup ausgeschlossen wird), bekommt das Skript ein `VBOOrganizationUser`-Objekt mit garantierten Identifiern:

- `OfficeId` — die GUID des Users in Microsoft 365
- `OnPremisesId` — die GUID aus on-premises AD (bei Hybrid)

Diese GUIDs werden für das Matching auf folgende Cmdlets verwendet:

- `Get-VBOEntityData -Repository $repo -User $orgUser` (Backup-Daten, ParameterSet ByUser)
- `Get-VBOLicensedUser` Filter per `OfficeId`/`OnPremisesId` (Lizenz)

Vorteile: keine Casing-Probleme, keine Display-Name-Drift, kein Risiko bei Doppel-Namen.

### Fallback Path — User in M365 bereits gelöscht

Wenn der M365-Account schon weg ist (z. B. weil der Offboarding-Workflow ihn bereits entfernt hat), fällt das Skript auf Namens-Matching zurück:

- `Get-VBOEntityData -Repository $repo -Type User -Name $Email` (ParameterSet ByType)
- `Get-VBOLicensedUser | Where-Object { $_.UserName -ieq $Email }`

Das Skript meldet diesen Modus mit einer Warnung im Log und im Result-Objekt (`UserResolved = $false`). Im Best-Effort-Modus kann es vorkommen, dass einzelne verwaiste Backup-Daten nicht gefunden werden — in dem Fall manuell in der VBO-Konsole nachprüfen.

> **Tipp:** Lass diesen Cleanup-Job **bevor** der User aus M365 gelöscht wird laufen. Dann läuft alles im Preferred Path und du bekommst die robustesten Ergebnisse.

---

## Output und Result-Objekt

Das Skript gibt am Ende ein `[pscustomobject]` aus, das auch im Fehlerfall verfügbar ist:

```powershell
Email                 : max.mustermann@de.bauer-group.com
Organization          : BAUER GROUP
Timestamp             : 08.04.2026 14:23:17
UserResolved          : True
JobsCleaned           : 3
ExcludedItemsCleaned  : 1
RepositoriesProcessed : 7
RepositoriesWithData  : 2
LicenseRemoved        : True
Skipped               : False
LogFile               : C:\ProgramData\Veeam\Backup365\Logs\LicenseCleanup\Remove-max_mustermann_de_bauer_group_com-20260408-142317.log
Success               : True
```

| Feld | Bedeutung |
| --- | --- |
| `Email` | Die bearbeitete E-Mail-Adresse |
| `Organization` | VBO-Organisation, in der gearbeitet wurde |
| `Timestamp` | Startzeitpunkt des Laufs |
| `UserResolved` | `$true` wenn der User in M365 aufgelöst wurde (Preferred Path) |
| `JobsCleaned` | Anzahl entfernter User-Zuordnungen aus SelectedItems der Backup-Jobs |
| `ExcludedItemsCleaned` | Anzahl entfernter User-Zuordnungen aus ExcludedItems der Backup-Jobs |
| `RepositoriesProcessed` | Anzahl gescannter Repositories |
| `RepositoriesWithData` | Anzahl Repositories, in denen tatsächlich Daten gefunden wurden |
| `LicenseRemoved` | `$true` wenn die Lizenz freigegeben wurde |
| `Skipped` | `$true` wenn `-SkipDataDeletion` aktiv war |
| `LogFile` | Voller Pfad zum Transcript-Log dieses Laufs |
| `Success` | Gesamtergebnis — `$true` nur wenn alle Schritte ohne Fehler liefen |

---

## Logging und Audit-Trail

Jeder Lauf erzeugt ein vollständiges PowerShell-Transcript im `LogPath`:

```text
Remove-max_mustermann_de_bauer_group_com-20260408-142317.log
```

Das Transcript enthält:

- Timestamp und alle Parameter des Laufs
- Alle Host-Ausgaben inklusive der Repository-Iteration
- Alle Fehler und Warnungen
- Abschluss-Zusammenfassung

> **Empfehlung für GDPR-Nachweise:** `LogPath` auf einen revisionssicheren Share legen — WORM-Storage, Azure Immutable Blob Storage, oder eine SharePoint-Liste mit aktivierter Versionierung. Damit ist die Datenlöschung im Audit nachweisbar.

---

## Exit-Codes

| Code | Bedeutung |
| --- | --- |
| `0` | Erfolg — alle Schritte ohne Fehler durchlaufen |
| `1` | Allgemeiner Laufzeitfehler — siehe Transcript |
| `2` | `Veeam.Archiver.PowerShell` Modul nicht installiert |
| `3` | Organisation nicht in dieser VBO-Instanz gefunden |

Beispiel-Auswertung in einem Wrapper-Skript:

```powershell
.\Remove-VeeamLicense.ps1 -Email $email -Force
switch ($LASTEXITCODE) {
    0 { Write-Host 'OK' -ForegroundColor Green }
    2 { Write-Error 'Veeam-Modul fehlt — Konsole installieren' }
    3 { Write-Error 'Organization-Name in Skript-Aufruf falsch' }
    default { Write-Error "Fehler — Code: $LASTEXITCODE" }
}
```

---

## Fehlerbehandlung

Das Skript verwendet `$ErrorActionPreference = 'Stop'` und bricht bei jedem unerwarteten Fehler kontrolliert ab. Verhalten im Detail:

| Situation | Verhalten |
| --- | --- |
| Veeam-Modul nicht installiert | `exit 2`, klare Fehlermeldung |
| Organisation nicht gefunden | `exit 3`, klare Fehlermeldung |
| Repository gesperrt durch laufenden Job | **Warnung**, dieses Repo wird übersprungen, andere laufen weiter |
| Keine Backup-Daten gefunden | Warnung, Skript läuft weiter (kein Fehler) |
| Kein lizenzierter User vorhanden | Warnung, Skript endet erfolgreich (bereits sauber) |
| Unerwarteter Fehler in Schritt 3-5 | `exit 1`, Result-Objekt mit `Success=$false`, Transcript geschlossen |

In **jedem** Fall wird das Result-Objekt ausgegeben und das Transcript korrekt geschlossen.

---

## Troubleshooting

### `Get-VBOBackupItem : The term ... is not recognized`

VBO-Version älter als v7. Lösung: Upgrade auf aktuelle Version durchführen.

### `Repository is locked by running job`

Ein Backup-Job läuft auf dem Ziel-Repository. Das Skript überspringt das Repo und wirft eine Warnung. Optionen:

```powershell
# 1. Auf Job-Ende warten und erneut ausführen
# 2. Oder Job manuell stoppen:
Stop-VBOJob -Job (Get-VBOJob -Name 'Jobname')
```

### `Get-VBOEntityData` läuft sehr lange

Bei großen S3-Backends (z. B. `backup-cloud.eu-north1.s3.bauer-group.com`) kann die Iteration mehrere Minuten pro Repository dauern, weil die Objekt-Metadaten remote abgerufen werden. **Das ist normal — nicht abbrechen.** Mit `-Verbose` bekommst du Step-Marker, die zeigen, dass das Skript noch arbeitet.

### Lizenz wird nach Skript-Lauf wieder belegt

Der User ist noch in einem **gruppen-basierten Job** enthalten (AD-/Entra-Gruppe als Backup-Selection). Das Skript kann einzelne User nicht aus einer Gruppen-Selection entfernen. Manuelle Prüfung:

```powershell
Get-VBOJob | ForEach-Object {
    $job = $_
    Get-VBOBackupItem -Job $job |
        Where-Object { $_.Group -or $_.Site } |
        Select-Object @{N='Job';E={$job.Name}}, Type, DisplayName
}
```

Lösung: Den User aus der Quellgruppe (AD/Entra) entfernen, dann das Skript erneut laufen lassen.

### Email mit Sonderzeichen wird nicht akzeptiert

Der Regex `^[^@\s]+@[^@\s]+\.[^@\s]+$` ist absichtlich konservativ. Wenn ein gültiger UPN abgelehnt wird (z. B. `max+filter@domain.de`), prüfen ob die Adresse tatsächlich existiert — der Regex deckt RFC-konforme Standard-Adressen ab.

---

## Sicherheitshinweise

> **Destruktives Skript.** Gelöschte Backup-Daten können nicht wiederhergestellt werden.

- **Immer zuerst mit `-WhatIf` testen**, besonders nach Skript-Änderungen.
- **NTFS-ACL** auf dem Skript-Verzeichnis: nur VBO-Admins haben Lese-/Ausführungsrechte.
- **Log-Verzeichnis** schreibgeschützt für normale User halten — idealerweise WORM.
- **Vor Ausführung prüfen**, ob gesetzliche Aufbewahrungsfristen (HGB §257, AO §147) der Datenlöschung entgegenstehen. Im Zweifel `-SkipDataDeletion` verwenden.
- **Litigation Hold:** Für Mitarbeiter mit Postfach-Inhalten, die für laufende oder absehbare Rechtsstreitigkeiten relevant sein könnten, **keine Löschung** durchführen, bevor die Rechtsabteilung schriftlich zugestimmt hat. Das Skript prüft Litigation Hold **nicht** automatisch.
- **4-Augen-Prinzip:** Bei sensiblen Konten (Geschäftsführung, Personalabteilung, Compliance) Lauf mit zweiter Person dokumentieren.

---

## Bekannte Einschränkungen

- **Gruppen-basierte Selections** (AD/Entra-Gruppen) können nicht aufgelöst werden. Solche User müssen aus der Quellgruppe entfernt werden, sonst tauchen sie beim nächsten Job-Lauf wieder auf.
- **Litigation Hold wird nicht geprüft** — das Skript löscht auch Daten von Usern auf Hold, wenn nicht `-SkipDataDeletion` gesetzt ist.
- **Kein Pipeline-Input** — bewusste Design-Entscheidung gegen versehentliche Massen-Löschung. Batch-Verarbeitung über externes Wrapper-Skript mit Schleife.
- **Eine Organisation pro Lauf** — für Multi-Tenant-Cleanups separate Aufrufe pro Organisation nutzen.

---

## Changelog

### v2.5 (aktuell)

- **Bugfix:** `Remove-VBOLicensedUser -User $licensedUser` crashte mit Array, weil das OnPremisesId-Match alle Cloud-only User mit `00000000-...` als OnPremisesId selectiert hat. Fix: All-Zeros-GUID wird jetzt als "kein Wert" behandelt; zusätzlich `Select-Object -First 1` als Defensive plus Warning bei Mehrfach-Match.
- **Output massiv reduziert:** Header und ASCII-Banner weg. User-Resolution kompakt einzeilig (Details via `-Verbose`). Repository-Scan-Status und Schritt-Marker wandern auf `Verbose`-Stream. Final-Summary in einer einzigen Zeile (`jobs=N+M repos=X/Y license=released`). "No backup data" ist jetzt Verbose, nicht Warning.
- **Neu:** `-PassThru` Switch — standardmäßig gibt das Skript nichts an die Pipeline aus, nur Host-Output. Mit `-PassThru` zusätzlich das vollständige Result-Objekt für Automation. Verhindert Konsolen-Spam im interaktiven Gebrauch.

### v2.4

- **Bugfix:** `-Confirm:$false` von `Remove-VBOBackupItem`, `Remove-VBOExcludedBackupItem` und `Remove-VBOLicensedUser` entfernt — diese Cmdlets implementieren `SupportsShouldProcess` nicht (verifiziert gegen Veeam-Doku-Syntax). Ein `-Confirm:$false` führte zu `ParameterBindingException`. Nur `Remove-VBOEntityData` listet `[-Confirm]` explizit in der Doku-Syntax und behält das Argument.
- **Verbessert:** Repository-Loop mit Zwei-Stufen-Fallback — wenn `Get-VBOEntityData -User $orgUser` "User not found in the repository" wirft (Veeam wirft Exception statt null), versucht das Skript automatisch `Get-VBOEntityData -Type User -Name $Email` als Fallback. "Not found"-Exceptions werden auf Verbose herabgestuft (kein Warning), nur unerwartete Fehler bleiben Warnings.

### v2.3

**Remove-VeeamLicense.ps1 v2.3:**

- **Bugfix:** `Get-VBOEntityData` ParameterSet-Konflikt — `-Type` und `-User` sind in **unterschiedlichen** Parameter-Sets und können nicht kombiniert werden (verifiziert gegen Veeam-Doku). Skript wählt jetzt den passenden ParameterSet abhängig davon, ob der User aufgelöst werden konnte.
- **Bugfix:** `Start-Transcript` respektiert `WhatIfPreference` → wurde im `-WhatIf`-Modus übersprungen → `Stop-Transcript` warf Fehler. Fix: `-WhatIf:$false` explizit, plus `try/catch` als Sicherheitsnetz.
- **Neu:** Defensive `Where-Object`-Filterung nach `Get-VBOOrganizationUser`, um gegen mögliche Fuzzy-Matching-Verhalten abzusichern.
- **Neu:** Erweiterte User-Resolution-Ausgabe — zeigt jetzt DisplayName, UserName, Type, LocationType, OfficeId, OnPremisesId zur Verifikation.
- **Neu:** `ExcludedItemsCleaned` Counter im Result-Objekt — Excluded-Items werden separat von SelectedItems gezählt.

**Get-VeeamLicenseUsage.ps1 v1.0 (NEU):**

- Read-only Lizenz-Inventur-Skript
- Filter: `-NotBackedUpForDays`, `-LicenseStatus`, `-IncludeJobAssignments`
- CSV-Export via `-ExportCsv`
- Optimierter Job-Membership-Cache (O(J) statt O(U*J))

### v2.2

- **Bugfix:** `Remove-VBOExcludedBackupItem` benötigt Parameter `-BackupItem`, nicht `-ExcludedBackupItem` (Veeam-API-Asymmetrie)
- **Bugfix:** Filter auf `$_.Email` bei `Get-VBOEntityData`-Ergebnissen entfernt — Property nicht in der Doku garantiert. Stattdessen nutzt das Skript jetzt den eingebauten `-User`-Parameter mit aufgelöstem `VBOOrganizationUser`-Objekt.
- **Bugfix:** `VBOLicensedUser`-Match nutzt jetzt GUIDs (`OfficeId`/`OnPremisesId`) statt unsicherer `UserName`-Property.
- **Neu:** Two-stage user resolution — `Get-VBOOrganizationUser` löst den User vor Schritt 3 auf, GUIDs werden für robustes Matching verwendet
- **Neu:** Best-Effort-Fallback wenn der User in M365 bereits gelöscht wurde
- **Neu:** `UserResolved` Feld im Result-Objekt zeigt an, welcher Pfad genutzt wurde
- **Neu:** Reframing von "License Cleanup" zu "Backup-Scope Cleanup" — Skript fasst den M365-Account nicht an
- **Doku:** Alle Cmdlet-Aufrufe und Property-Zugriffe gegen die offizielle Veeam-Doku verifiziert
- **Doku:** README erweitert um "Was das Skript NICHT tut" und "User-Auflösung"

### v2.1

- **Neu:** Strukturiertes Result-Objekt (`[pscustomobject]`) für Automation
- **Neu:** Differenzierte Exit-Codes (0/1/2/3) für Wrapper-Skripte
- **Neu:** `-Force` Switch für nicht-interaktive Ausführung
- **Neu:** Case-insensitive Email-Vergleiche (`-ieq`)
- **Neu:** Try/Catch um `Get-VBOEntityData` — gesperrte Repos werden übersprungen
- **Neu:** `#Requires -Version 5.1` und `[OutputType([pscustomobject])]`
- **Neu:** Aliase `-UserPrincipalName` / `-UPN` für `-Email`
- **Verbessert:** Comment-based Help vollständig auf deutsch + Beispiele für Konsum
- **Verbessert:** Single-Exit-Point — Result wird IMMER ausgegeben, auch im Fehlerfall
- **Verbessert:** Log-Dateinamen-Sanitizing greift jetzt alle Sonderzeichen ab

### v2.0

- Iteration über **alle** Repositories statt nur eines hardcoded
- Automatische Entfernung aus **allen** Backup-Jobs (verhindert Re-Lizenzierung)
- Automatisches Laden des `Veeam.Archiver.PowerShell`-Moduls
- `SupportsShouldProcess` mit `-WhatIf` / `-Confirm`
- Transcript-Logging mit Timestamp
- Email-Validierung per Regex
- `-SkipDataDeletion` für reine Lizenz-Freigabe
- Strukturiertes Error-Handling mit try/catch/finally

### v1.0

- Initiale Version mit festem Repository und Email-Parameter

---

## Lizenz und Kontakt

Lizenz: **MIT** — siehe [LICENSE](LICENSE).

**BAUER GROUP GmbH & Co. KG**
IT-Infrastruktur / VBO-Administration

Bei Fragen oder Problemen: internes Ticket-System.
