# Veeam Tools — Remove-VeeamLicense

> **GDPR-konformes User-Offboarding für Veeam Backup for Microsoft 365 (VBO)**
> Ein einziges PowerShell-Skript, das einen Mitarbeiter vollständig, atomar und auditierbar aus VBO entfernt.

[![PowerShell 5.1+](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?logo=powershell&logoColor=white)](https://learn.microsoft.com/powershell/)
[![Veeam VBO](https://img.shields.io/badge/Veeam%20VBO-v7%2B-00B336?logo=veeam&logoColor=white)](https://www.veeam.com/backup-microsoft-office-365.html)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

---

## Was macht dieses Tool?

`Remove-VeeamLicense.ps1` automatisiert das **vollständige Offboarding** eines Mitarbeiters aus Veeam Backup for Microsoft 365 in **einem einzigen Lauf**:

- **Entfernt** den User aus *allen* Backup-Jobs (sonst wird die Lizenz beim nächsten Job-Lauf wieder belegt)
- **Löscht** alle Backup-Daten (Mailbox, Archive, OneDrive, SharePoint) aus *allen* Repositories — Art. 17 DSGVO ("Recht auf Löschung")
- **Gibt** die Lizenz frei, damit sie für andere User verfügbar ist
- **Schreibt** ein vollständiges Audit-Transcript für Compliance-Nachweise
- **Liefert** ein strukturiertes Result-Objekt für Automation (ServiceNow, ITSM, Splunk, …)

Ohne dieses Tool müssten Admins jeden Schritt einzeln in der VBO-Konsole abarbeiten — fehleranfällig, zeitaufwendig und ohne maschinenlesbaren Audit-Trail.

---

## Quick Start

```powershell
# 1. Trockenlauf — IMMER zuerst
.\Remove-VeeamLicense.ps1 -Email 'max.mustermann@de.bauer-group.com' -WhatIf

# 2. Echter Lauf, mit Bestätigung
.\Remove-VeeamLicense.ps1 -Email 'max.mustermann@de.bauer-group.com'

# 3. Nicht-interaktiv (z. B. aus ServiceNow)
.\Remove-VeeamLicense.ps1 -Email 'max.mustermann@de.bauer-group.com' -Force
```

---

## Inhaltsverzeichnis

- [Zweck und Hintergrund](#zweck-und-hintergrund)
- [Voraussetzungen](#voraussetzungen)
- [Installation](#installation)
- [Verwendung](#verwendung)
- [Parameter](#parameter)
- [Ablauf](#ablauf)
- [Output und Result-Objekt](#output-und-result-objekt)
- [Logging und Audit-Trail](#logging-und-audit-trail)
- [Exit-Codes](#exit-codes)
- [Fehlerbehandlung](#fehlerbehandlung)
- [Troubleshooting](#troubleshooting)
- [Sicherheitshinweise](#sicherheitshinweise)
- [Bekannte Einschränkungen](#bekannte-einschränkungen)
- [Changelog](#changelog)
- [Lizenz und Kontakt](#lizenz-und-kontakt)

---

## Zweck und Hintergrund

Beim Offboarding eines Mitarbeiters müssen in Veeam Backup for Microsoft 365 mehrere Schritte ausgeführt werden, die im VBO-UI **einzeln und in der richtigen Reihenfolge** abgearbeitet werden müssen. Wird die Reihenfolge verletzt, ist das Ergebnis fehlerhaft:

| Schritt | Wenn vergessen | Folge |
|---|---|---|
| User aus Backup-Jobs entfernen | Lizenz wird beim nächsten Job-Lauf erneut belegt | Lizenzpool blockiert, Compliance-Verstoß |
| Backup-Daten aus Repos löschen | Personenbezogene Daten verbleiben im Backup | DSGVO Art. 17 Verstoß, Bußgeld-Risiko |
| Lizenz freigeben | Lizenzpool wird unnötig blockiert | Höhere Kosten, neue User können nicht aufgenommen werden |

Dieses Skript automatisiert alle drei Schritte in **einem Durchlauf** mit vollständigem Audit-Trail und garantiert die korrekte Reihenfolge.

---

## Voraussetzungen

| Komponente | Anforderung |
|---|---|
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

## Parameter

| Parameter | Typ | Pflicht | Default | Beschreibung |
|---|---|---|---|---|
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

## Output und Result-Objekt

Das Skript gibt am Ende ein `[pscustomobject]` aus, das auch im Fehlerfall verfügbar ist:

```powershell
Email                 : max.mustermann@de.bauer-group.com
Organization          : BAUER GROUP
Timestamp             : 08.04.2026 14:23:17
JobsCleaned           : 3
RepositoriesProcessed : 7
RepositoriesWithData  : 2
LicenseRemoved        : True
Skipped               : False
LogFile               : C:\ProgramData\Veeam\Backup365\Logs\LicenseCleanup\Remove-max_mustermann_de_bauer_group_com-20260408-142317.log
Success               : True
```

| Feld | Bedeutung |
|---|---|
| `Email` | Die bearbeitete E-Mail-Adresse |
| `Organization` | VBO-Organisation, in der gearbeitet wurde |
| `Timestamp` | Startzeitpunkt des Laufs |
| `JobsCleaned` | Anzahl entfernter User-Zuordnungen aus Backup-Jobs |
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
|---|---|
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
|---|---|
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

### v2.1 (aktuell)

- **Neu:** Strukturiertes Result-Objekt (`[pscustomobject]`) für Automation
- **Neu:** Differenzierte Exit-Codes (0/1/2/3) für Wrapper-Skripte
- **Neu:** `-Force` Switch für nicht-interaktive Ausführung
- **Neu:** Case-insensitive Email-Vergleiche (`-ieq`) — robuster gegen Casing-Drift
- **Neu:** Try/Catch um `Get-VBOEntityData` — gesperrte Repos werden übersprungen statt das Skript abzubrechen
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
