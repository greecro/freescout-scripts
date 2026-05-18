# FreeScout Scripts

Vollautomatisches Setup für [FreeScout](https://github.com/freescout-help-desk/freescout) (PHP/Laravel-Helpdesk) auf Proxmox als LXC-Container. Inklusive Backups nach Cloudflare R2, Queue-Worker via Supervisor, FreeScout-Scheduler via Cron, Authentik-OIDC-Vorbereitung und Migration aus einer bestehenden Cloudron-Installation.

## Architektur

```
Internet → Cloudflare → NPMPlus (SSL, Real-IP) → LXC FreeScout
                                                      │
                                                      ├─ Nginx + PHP 8.3-FPM
                                                      ├─ MariaDB 11 (lokal)
                                                      ├─ Supervisor (Queue-Worker)
                                                      ├─ Cron (FreeScout-Scheduler)
                                                      └─ Backups → r2:backups/freescout/
                                                            ├─ db-<hostname>/      (täglich, gzip + optional age)
                                                            └─ storage-<hostname>/ (täglich, rclone-Mirror)

         SMTP-Outgoing ← pro Mailbox im FreeScout-UI konfiguriert (nicht im .env)
         Authentik-OIDC ← Stub (manuell aktivieren nach Modul-Kauf)
         UptimeKuma ← Push-Webhooks bei Backup-/Health-Fehlern
```

---

## Scripts

| Script | Ausführen auf | Zweck | Wann |
|---|---|---|---|
| `proxmox-create-freescout-ct.sh` | Proxmox Host | Debian-13-LXC anlegen, IP konfigurieren, SSH-Key einspielen | Einmalig |
| `setup-freescout.sh` | LXC | Stack (Nginx, PHP, MariaDB, Supervisor) + FreeScout-Files vorbereiten | Einmalig |
| `migrate-from-cloudron.sh` | Cloudron-Host | Export-Bundle erzeugen (SQL, storage, Modules, uploads, APP_KEY) | Einmalig (bei Migration) |
| `migrate-import.sh` | LXC | Export-Bundle importieren, überspringt Web-Installer | Einmalig (bei Migration) |
| `db-backup.sh` | LXC | MariaDB-Dump → R2 (flock, optional age) | Täglich (Cron 02:00) |
| `storage-backup.sh` | LXC | storage/ + Modules/ → R2 (rclone-Mirror, flock) | Täglich (Cron 03:00) |
| `backup-verify.sh` | LXC | Integritätsprüfung der R2-Backups | Wöchentlich (Cron So 04:00) |
| `update-freescout.sh` | LXC | Pre-Update-Snapshot + git pull + composer + artisan | Bei Bedarf |
| `restore.sh` | LXC | DB + Storage aus R2-Backup wiederherstellen (mit HTTP-Test) | Bei Bedarf |
| `status.sh` | LXC | Dashboard: Version, Disk, Queue, Cron, SSL, letzte Backups | Bei Bedarf |
| `health-check.sh` | LXC | HTTP, DB, Queue-Worker, Cron + Webhook bei Fehler | Bei Bedarf / Cron |

---

## Komplette Einrichtung — Schritt für Schritt

### Schritt 1 — LXC anlegen (Proxmox-Host)

```bash
curl -sO https://git.janzin.net/djanzin/freescout-scripts/raw/branch/main/proxmox-create-freescout-ct.sh
bash proxmox-create-freescout-ct.sh
```

Erstellt einen Debian-13-LXC (Standard: 2 vCPU, 2 GB RAM, 20 GB Disk), konfiguriert IP/SSH, gibt root-Passwort + Verbindungsbefehl aus.

**Empfohlene Ressourcen:**

| Profil | vCPU | RAM | Disk |
|---|---|---|---|
| Klein (< 5 Mailboxes) | 2 | 2 GB | 20 GB |
| Mittel (5–20 Mailboxes) | 4 | 4 GB | 40 GB |
| Groß (> 20 Mailboxes) | 4 | 8 GB | 80 GB |

---

### Schritt 2 — FreeScout-Stack vorbereiten (im LXC)

```bash
ssh root@<lxc-ip>
curl -sO https://git.janzin.net/djanzin/freescout-scripts/raw/branch/main/setup-freescout.sh
bash setup-freescout.sh
```

Installiert MariaDB, PHP 8.3, Nginx, Supervisor, rclone, ufw, fail2ban; legt FreeScout-Files unter `/var/www/freescout` an; konfiguriert Backup-Crons; schreibt `.env` mit APP_KEY + URL (ohne DB-Block — das macht der Web-Installer).

Am Ende werden ausgegeben:
- DB-Credentials (für Web-Installer)
- Web-Installer-URL
- NPMPlus-Hinweis

---

### Schritt 3 — NPMPlus Proxy-Host konfigurieren

Im NPMPlus-UI einen neuen Proxy-Host anlegen:

| Feld | Wert |
|---|---|
| Domain | `<deine-domain>` |
| Scheme | `http` |
| Forward IP | `<lxc-ip>` |
| Forward Port | `80` |
| Block Common Exploits | aktiv |
| Websocket Support | **aktiv** (wichtig für FreeScout-Echo) |
| SSL Certificate | Let's Encrypt, Force SSL, HTTP/2 |

**Custom Nginx Config** (im "Advanced"-Tab):
```nginx
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_set_header X-Real-IP $remote_addr;
```

---

### Schritt 4 — Variante A: Fresh-Install via Web-Installer

Browser öffnen: `https://<deine-domain>/install`

Eintragen:
- **Database**: Host `127.0.0.1`, Port `3306`, DB-Name/User/Pass aus Script-Output (Datei: `/etc/freescout/db-credentials.txt`)
- **Admin-User**: Name + Email + Passwort

Web-Installer migriert DB-Schema und legt Admin-User an.

### Schritt 4 — Variante B: Migration aus Cloudron

**Auf dem Cloudron-Host** (als root):

```bash
curl -sO https://git.janzin.net/djanzin/freescout-scripts/raw/branch/main/migrate-from-cloudron.sh
bash migrate-from-cloudron.sh
```

Erzeugt ein Export-Bundle (`/tmp/freescout-export-<datum>/`) mit:
- `freescout.sql.gz` (MySQL-Dump)
- `storage.tar.gz` (Anhänge)
- `modules.tar.gz` (alle installierten Module)
- `uploads.tar.gz`
- `env-snapshot.txt` (APP_KEY + ausgewählte Settings)
- `MANIFEST.sha256`

**Bundle aufs Target-LXC kopieren:**

```bash
rsync -avz /tmp/freescout-export-<datum>/ root@<lxc-ip>:/root/freescout-import/
```

**Im LXC importieren:**

```bash
ssh root@<lxc-ip>
curl -sO https://git.janzin.net/djanzin/freescout-scripts/raw/branch/main/migrate-import.sh
bash migrate-import.sh /root/freescout-import/
```

Importiert SQL, entpackt Archive, übernimmt **APP_KEY** (kritisch — sonst sind verschlüsselte SMTP-Settings in der DB unleserlich), führt Post-Update-Hooks aus, startet Worker.

Web-Installer entfällt in diesem Modus.

---

### Schritt 5 — Queue-Worker aktivieren

Nach Fresh-Install (entfällt bei Migration — macht `migrate-import.sh` automatisch):

```bash
supervisorctl start freescout-worker:*
supervisorctl status
```

---

### Schritt 6 — Mailbox-SMTP prüfen

FreeScout sendet ausgehende Mails pro Mailbox mit individuellen SMTP-Creds. Diese werden im FreeScout-UI unter **Manage → Mailboxes → Connection Settings** konfiguriert.

- **Bei Migration**: SMTP-Settings kommen mit dem SQL-Dump mit und funktionieren ohne weitere Aktion (sofern APP_KEY korrekt übernommen wurde).
- **Bei Fresh-Install**: pro Mailbox manuell eintragen.

---

### Schritt 7 — Optional: Authentik-OIDC-Aktivierung

FreeScout's OIDC-Anbindung ist ein **kostenpflichtiges Modul** (~49 $). `setup-freescout.sh` hat bereits Authentik-Stubs in `/etc/freescout/oidc.env` abgelegt (falls beim Setup angegeben).

1. **In Authentik:**
   - Provider: OAuth2/OpenID Provider erstellen
   - Application: anlegen, Provider zuweisen
   - Redirect-URI: `https://<deine-domain>/oauth/callback`
2. **In FreeScout:**
   - OAuth/OIDC-Modul auf [freescout.net/modules](https://freescout.net/modules) kaufen
   - Hochladen unter Manage → Modules
   - Aktivieren, Issuer/Client-ID/Secret aus `/etc/freescout/oidc.env` ins UI übernehmen

---

## Backups

- **Layout**: `r2:backups/freescout/db-<hostname>/` (SQL-Dumps), `r2:backups/freescout/storage-<hostname>/` (Files-Mirror)
- **Frequenz**: täglich 02:00 (DB) + 03:00 (storage)
- **Retention**: 7 Tage lokal, danach von rclone-Mirror übernommen (R2-Versioning empfohlen)
- **Encryption (optional)**: age-Verschlüsselung, Recipient Public Key wird bei Setup abgefragt
- **Bandbreite**: `--bwlimit "08:00,8M 22:00,off"` (tagsüber 8 MB/s, nachts unlimitiert)
- **flock-protected**: keine Doppelläufe bei langen Backups
- **Verify**: wöchentlich (So 04:00) — `gunzip -t` + SQL-Header-Check; `--deep` am 1. des Monats macht Test-Restore in temporäre DB
- **Pre-Update-Snapshots**: `update-freescout.sh` legt vor Updates DB + Storage als Snapshot ab (5 retention)

---

## Monitoring & Alerts

- **UptimeKuma**: Push-Webhook bei Setup abgefragt — wird von `db-backup.sh`, `storage-backup.sh`, `backup-verify.sh`, `health-check.sh` bei Fehlern getriggert
- **Format**: `${WEBHOOK_URL}?status=down&msg=<details>`
- **Cron-Schedule**:

| Zeit | Script | Zweck |
|---|---|---|
| `* * * * *` | `php artisan schedule:run` | FreeScout-Scheduler |
| `0 2 * * *` | `db-backup.sh` | DB → R2 |
| `0 3 * * *` | `storage-backup.sh` | storage → R2 |
| `0 4 * * 0` | `backup-verify.sh` | Wöchentliche Verify |

---

## Troubleshooting

| Symptom | Wahrscheinliche Ursache | Lösung |
|---|---|---|
| `/install` öffnet sich, obwohl migriert | `APP_KEY` falsch oder DB leer | `migrate-import.sh` neu laufen lassen, `env-snapshot.txt` prüfen |
| Module zeigen "License Invalid" | Domain hat sich geändert | Im UI Modul deaktivieren + reaktivieren |
| Queue-Worker startet nicht | DB nicht migriert oder Worker abgestürzt | `supervisorctl restart freescout-worker:*`, `journalctl -u supervisor` |
| Cron läuft nicht | Crontab fehlt für `www-data` | `crontab -u www-data -l` prüfen |
| Mails kommen nicht raus | Mailbox-SMTP nicht konfiguriert | UI → Manage → Mailboxes → Connection Settings |
| 502 Bad Gateway | PHP-FPM down | `systemctl status php8.3-fpm`, `journalctl -u php8.3-fpm` |
| R2-Backup schlägt fehl | rclone.conf falsch, Token abgelaufen | `/root/.config/rclone/rclone.conf` prüfen, `rclone lsd r2:` testen |

---

## Lizenz

Diese Scripts sind als Hilfestellung gedacht und kommen **ohne Gewähr**. FreeScout selbst steht unter der AGPL — siehe [github.com/freescout-help-desk/freescout](https://github.com/freescout-help-desk/freescout).
