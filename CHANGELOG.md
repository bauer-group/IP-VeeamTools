## Changelog

## [1.2.0](https://github.com/bauer-group/IP-VeeamTools/compare/v1.1.1...v1.2.0) (2026-04-08)

### 🚀 Features

* **remove-veeam-license:** added `-PassThru` switch; standardmäßig keine Pipeline-Ausgabe mehr, nur kompakter Host-Output. Mit `-PassThru` zusätzlich vollständiges Result-Objekt für Automation.
* **remove-veeam-license:** Output massiv reduziert — Header und ASCII-Banner entfernt, User-Resolution kompakt einzeilig, Repository-Scan-Status und Schritt-Marker auf `Verbose`, Final-Summary in einer Zeile.
* **remove-veeam-license:** verbesserte Robustheit bei `Remove-VBOLicensedUser -User $licensedUser` — All-Zeros-GUID (`00000000-...`) wird bei `OnPremisesId` als „kein Wert“ behandelt; zusätzlich defensive Begrenzung mit `Select-Object -First 1` und Warning bei Mehrfach-Match.
* **toolkit:** expanded Veeam toolkit with license inventory script.

### 🐛 Bug Fixes

* **veeam:** fixed unsupported `-Confirm` parameters. `-Confirm:$false` wurde von Cmdlets entfernt, die `SupportsShouldProcess` nicht implementieren; nur dort beibehalten, wo die Syntax es explizit unterstützt.
* **veeam:** Repository-Loop verbessert mit Zwei-Stufen-Fallback bei `Get-VBOEntityData` (`-User` → Fallback `-Type User -Name`), „not found“-Fehler werden auf `Verbose` herabgestuft.
* **veeam:** `Get-VBOEntityData` ParameterSet-Konflikt behoben — `-Type` und `-User` werden nicht mehr unzulässig kombiniert.
* **veeam:** `Start-Transcript` wird auch im `-WhatIf`-Modus sauber behandelt (`-WhatIf:$false` + Schutz via `try/catch`).
* **veeam:** defensive Filterung nach `Get-VBOOrganizationUser`, um Fuzzy-Matching zu vermeiden.
* **veeam:** `ExcludedItemsCleaned` Counter im Result ergänzt.
* **veeam:** `Remove-VBOExcludedBackupItem` nutzt den korrekten Parameter `-BackupItem`.
* **veeam:** unsicheres Matching über `UserName`/`Email` entfernt; stattdessen robustes GUID-basiertes Matching über `OfficeId`/`OnPremisesId`.
* **veeam:** Two-stage user resolution eingeführt, inklusive Best-Effort-Fallback wenn der M365-User bereits gelöscht wurde.
* **veeam:** `UserResolved` Feld im Result ergänzt.
* **veeam:** gesperrte oder problematische Repositories werden per `try/catch` sauber übersprungen.

---

## [1.1.1](https://github.com/bauer-group/IP-VeeamTools/compare/v1.1.0...v1.1.1) (2026-04-08)

### 🐛 Bug Fixes

* **veeam:** fixed unsupported `-Confirm` parameters.

---

## [1.1.0](https://github.com/bauer-group/IP-VeeamTools/compare/v1.0.1...v1.1.0) (2026-04-08)

### 🚀 Features

* **toolkit:** expanded Veeam toolkit with license inventory script.
* **license-usage:** read-only Lizenz-Inventur ergänzt.
* **license-usage:** Filter für z. B. Lizenzstatus, Alter/Nicht-Backup-Dauer und optionale Job-Zuordnung ergänzt.
* **license-usage:** CSV-Export ergänzt.
* **license-usage:** optimierter Job-Membership-Cache für bessere Performance.
* **remove-veeam-license:** strukturierte Result-Objekte für Automation ergänzt.
* **remove-veeam-license:** differenzierte Exit-Codes für Wrapper-/Automationsskripte ergänzt.
* **remove-veeam-license:** `-Force` für nicht-interaktive Ausführung ergänzt.
* **remove-veeam-license:** Alias `-UserPrincipalName` / `-UPN` für `-Email` ergänzt.
* **remove-veeam-license:** comment-based Help und Konsumbeispiele erweitert.
* **remove-veeam-license:** Single-Exit-Point verbessert, damit Result auch im Fehlerfall konsistent bleibt.
* **remove-veeam-license:** Log-Dateinamen-Sanitizing verbessert.

---

## [1.0.1](https://github.com/bauer-group/IP-VeeamTools/compare/v1.0.0...v1.0.1) (2026-04-08)

### 🐛 Bug Fixes

* **veeam:** fixed `VBOExcludedBackupItem` parameter name.
* **veeam:** case-insensitive Email-Vergleiche verbessert.
* **veeam:** Reframing/Robustheit im Backup-Scope-Cleanup verbessert; Fokus klar auf Lizenz-/Backup-Bereinigung statt Änderungen am M365-Account.
* **docs:** README erweitert um Hinweise wie „Was das Skript nicht tut“ sowie Details zur User-Auflösung.
* **docs:** Cmdlet-Aufrufe und Property-Zugriffe gegen offizielle Veeam-Doku verifiziert.

---

## [1.0.0](https://github.com/bauer-group/IP-VeeamTools/releases/tag/v1.0.0) (2026-04-08)

### 🚀 Features

* **offboarding:** added comprehensive documentation and setup guide.
* **veeam:** added license offboarding automation script.
* **veeam:** Iteration über alle Repositories statt nur eines festen Repositories.
* **veeam:** automatische Entfernung aus allen Backup-Jobs zur Vermeidung von Re-Lizenzierung.
* **veeam:** automatisches Laden des `Veeam.Archiver.PowerShell`-Moduls.
* **veeam:** Unterstützung für `SupportsShouldProcess` mit `-WhatIf` / `-Confirm`.
* **veeam:** Transcript-Logging mit Timestamp.
* **veeam:** Email-Validierung.
* **veeam:** `-SkipDataDeletion` für reine Lizenz-Freigabe.
* **veeam:** strukturiertes Error-Handling mit `try/catch/finally`.
* **veeam:** `#Requires -Version 5.1` und deklarierter Output-Type.
