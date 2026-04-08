# Remove-VeeamLicense.ps1

**GDPR-konformes Offboarding-Script für Veeam Backup for Microsoft 365 (VBO)**

Entfernt einen User vollständig aus Veeam Backup for Microsoft 365: löscht Backup-Daten aus allen Repositories, entfernt den User aus allen Backup-Jobs und gibt die Lizenz frei.

---

## Inhaltsverzeichnis

- [Zweck](#zweck)
- [Voraussetzungen](#voraussetzungen)
- [Installation](#installation)
- [Verwendung](#verwendung)
- [Parameter](#parameter)
- [Ablauf](#ablauf)
- [Logging](#logging)
- [Fehlerbehandlung](#fehlerbehandlung)
- [Troubleshooting](#troubleshooting)
- [Sicherheitshinweise](#sicherheitshinweise)
- [Changelog](#changelog)

---

## Zweck

Beim Offboarding eines Mitarbeiters müssen in Veeam Backup for Microsoft 365 mehrere Schritte ausgeführt werden, die im Veeam-UI einzeln abgearbeitet werden müssten:

1. User aus allen Backup-Jobs entfernen (sonst wird die Lizenz beim nächsten Job-Lauf wieder belegt)
2. Backup-Daten aus allen Repositories löschen (GDPR-Löschpflicht nach Art. 17 DSGVO)
3. Lizenz freigeben (um den Lizenzpool nicht unnötig zu belasten)

Dieses Script automatisiert alle drei Schritte in einem Durchlauf mit vollständigem Audit-Trail.

---

## Voraussetzungen

| Komponente | Anforderung |
|---|---|
| **Betriebssystem** | Windows Server mit installierter VBO-Konsole |
| **PowerShell** | 5.1 oder höher (7.x empfohlen) |
| **Veeam-Modul** | `Veeam.Archiver.PowerShell` (wird vom Script automatisch geladen) |
| **Berechtigungen** | Lokaler Administrator auf dem VBO-Server, VBO-Administrator-Rolle |
| **VBO-Version** | v7 oder höher (wegen `Get-VBOBackupItem`) |

Ausführung direkt auf dem VBO-Server oder auf einer Maschine mit installierter Veeam-Konsole.

---

## Installation

1. Script in einen geschützten Ordner auf dem VBO-Server kopieren, z. B.:

   ```text
   C:\Scripts\Veeam\Remove-VeeamLicense.ps1
   ```

2. Execution Policy prüfen (einmalig):

   ```powershell
   Get-ExecutionPolicy
   # Falls Restricted:
   Set-ExecutionPolicy -Scope LocalMachine -ExecutionPolicy RemoteSigned
   ```

3. Log-Verzeichnis wird beim ersten Lauf automatisch erstellt:

   ```text
   C:\ProgramData\Veeam\Backup365\Logs\LicenseCleanup\
   ```

---

## Verwendung

### Standardaufruf (Empfehlung: immer zuerst mit `-WhatIf`)

```powershell
# Trockenlauf — zeigt nur an, was getan würde
.\Remove-VeeamLicense.ps1 -Email "mr@de.bauer-group.com" -WhatIf

# Echter Lauf
.\Remove-VeeamLicense.ps1 -Email "mr@de.bauer-group.com"
```

### Nur Lizenz freigeben, Backup-Daten behalten

Nützlich, wenn der User zwar keine Lizenz mehr braucht, die Backups aber aus gesetzlichen Aufbewahrungsgründen (z. B. HGB, AO) noch vorgehalten werden müssen.

```powershell
.\Remove-VeeamLicense.ps1 -Email "mr@de.bauer-group.com" -SkipDataDeletion
```

### Abweichende Organisation

```powershell
.\Remove-VeeamLicense.ps1 -Email "user@example.com" -OrganizationName "KUNDE XY GmbH"
```

### Eigener Log-Pfad

```powershell
.\Remove-VeeamLicense.ps1 -Email "mr@de.bauer-group.com" `
    -LogPath "\\fileserver\audit\veeam-offboarding"
```

---

## Parameter

| Parameter | Typ | Pflicht | Default | Beschreibung |
|---|---|---|---|---|
| `-Email` | `string` | **ja** | — | UPN/E-Mail des Users. Wird per Regex validiert. |
| `-OrganizationName` | `string` | nein | `BAUER GROUP` | Name der VBO-Organisation wie in der VBO-Konsole sichtbar. |
| `-SkipDataDeletion` | `switch` | nein | `$false` | Überspringt Löschung der Backup-Daten, entfernt nur Job-Zuordnungen und Lizenz. |
| `-LogPath` | `string` | nein | `C:\ProgramData\Veeam\Backup365\Logs\LicenseCleanup` | Zielverzeichnis für Transcript-Logs. |
| `-WhatIf` | `switch` | nein | — | Zeigt nur an, welche Aktionen ausgeführt würden. **Immer für ersten Test verwenden.** |
| `-Confirm` | `switch` | nein | — | Erzwingt Bestätigung vor jeder destruktiven Aktion. |
| `-Verbose` | `switch` | nein | — | Gibt zusätzliche Debug-Informationen aus. |

---

## Ablauf

Das Script arbeitet in fünf Schritten ab:

```text
  ┌─────────────────────────────────────────┐
  │ 1. Veeam.Archiver.PowerShell laden      │
  └────────────────┬────────────────────────┘
                   │
  ┌────────────────▼────────────────────────┐
  │ 2. Organisation abrufen                 │
  └────────────────┬────────────────────────┘
                   │
  ┌────────────────▼────────────────────────┐
  │ 3. User aus allen Backup-Jobs entfernen │
  │    (SelectedItems + ExcludedItems)      │
  └────────────────┬────────────────────────┘
                   │
  ┌────────────────▼────────────────────────┐
  │ 4. Backup-Daten aus allen Repositories  │
  │    löschen (Mailbox, Archive,           │
  │    OneDrive, SharePoint)                │
  └────────────────┬────────────────────────┘
                   │
  ┌────────────────▼────────────────────────┐
  │ 5. Lizenz freigeben                     │
  └─────────────────────────────────────────┘
```

Schritt 3 ist kritisch: Ohne Entfernung aus den Jobs würde der User beim nächsten Backup-Lauf wieder automatisch lizenziert werden.

---

## Logging

Jeder Lauf erzeugt ein vollständiges PowerShell-Transcript im LogPath:

```text
Remove-mr_de_bauer-group_com-20260408-142317.log
```

Das Transcript enthält:

- Timestamp des Laufs
- Alle Host-Ausgaben (inklusive der Repository-Iteration)
- Alle Fehler und Warnungen
- Abschlussstatus

**Empfehlung für GDPR-Nachweise:** LogPath auf einen revisionssicheren Share legen (WORM-Storage oder SharePoint-Liste mit Versionierung), um die Löschung nachweisen zu können.

---

## Fehlerbehandlung

Das Script verwendet `$ErrorActionPreference = 'Stop'` und bricht bei jedem Fehler kontrolliert ab. Typisches Verhalten:

| Situation | Verhalten |
|---|---|
| Veeam-Modul nicht installiert | Abbruch mit Fehlermeldung, `exit 1` |
| Organisation nicht gefunden | Abbruch, `exit 1` |
| Keine Backup-Daten vorhanden | Warnung, Lauf geht weiter |
| Repository gesperrt (Job läuft) | Fehler, Abbruch — Script sicher neu starten nach Job-Ende |
| Kein Licensed User vorhanden | Warnung, Script endet erfolgreich (bereits sauber) |
| Unerwarteter Fehler | Transcript wird sauber geschlossen, `exit 1` |

---

## Troubleshooting

### `Get-VBOBackupItem : The term ... is not recognized`

VBO-Version älter als v7. Upgrade auf aktuelle Version oder Script-Anpassung auf `$job.SelectedItems` notwendig.

### `Repository is locked by running job`

Ein Backup-Job läuft gerade auf dem Ziel-Repository. Entweder auf das Job-Ende warten oder den Job manuell pausieren:

```powershell
Stop-VBOJob -Job (Get-VBOJob -Name "Jobname")
```

### `Get-VBOEntityData` läuft sehr lange

Bei großen S3-Backends (insbesondere Cloud-Repos wie `backup-cloud.eu-north1.s3.bauer-group.com`) kann die Iteration mehrere Minuten pro Repository dauern, weil die Objekt-Metadaten remote abgerufen werden. Das ist normal — nicht abbrechen.

### Lizenz wird nach Script-Lauf wieder belegt

Der User ist noch in einem Job enthalten, den das Script nicht erfasst hat (z. B. Gruppen-basierte Selection). Manuell prüfen:

```powershell
Get-VBOJob | ForEach-Object {
    $job = $_
    Get-VBOBackupItem -Job $job | Where-Object { $_.Group -or $_.Site } |
        Select-Object @{N='Job';E={$job.Name}}, Type, DisplayName
}
```

Gruppen-basierte Backups müssen in der Gruppe selbst (AD/Entra) bereinigt werden — das Script kann einzelne User nicht aus einer Gruppen-Selection entfernen.

---

## Sicherheitshinweise

⚠️ **Destruktives Script.** Gelöschte Backup-Daten können nicht wiederhergestellt werden.

- **Immer zuerst mit `-WhatIf` testen**, besonders nach Änderungen am Script.
- Zugriff auf das Script-Verzeichnis auf VBO-Admins beschränken (NTFS-ACL).
- Log-Verzeichnis schreibgeschützt für normale User halten.
- Vor Ausführung prüfen, ob gesetzliche Aufbewahrungsfristen (HGB §257, AO §147) der Datenlöschung entgegenstehen. Im Zweifel `-SkipDataDeletion` verwenden.
- Für Mitarbeiter mit Postfach-Inhalten, die für laufende oder absehbare Rechtsstreitigkeiten relevant sein könnten (Litigation Hold), **keine Löschung** durchführen, bevor Rechtsabteilung zugestimmt hat.

---

## Changelog

### v2.0 (aktuell)

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

## Kontakt

**BAUER GROUP GmbH & Co. KG**
IT-Infrastruktur / VBO-Administration

Bei Fragen oder Problemen: internes Ticket-System.
