# freescout-scripts

Vollautomatisches Setup für [FreeScout](https://github.com/freescout-help-desk/freescout) auf Proxmox als Debian-13-LXC-Container — inklusive Cloudron-Migration, tägliche Backups nach Cloudflare R2, Queue-Worker via Supervisor und Ops-Toolbox.

![Shell](https://img.shields.io/badge/shell-bash-green)
![Platform](https://img.shields.io/badge/platform-Proxmox%20%7C%20Debian%2013-blue)
![PHP](https://img.shields.io/badge/PHP-8.3-purple)
![License](https://img.shields.io/badge/license-MIT-lightgrey)

---

## Architektur

```
Internet → Cloudflare → NPMPlus (SSL, Real-IP) → LXC FreeScout
                                                      │
                                                      ├─ Nginx + PHP 8.3-FPM
                                                      ├─ MariaDB 11 (lokal)
                                                      ├─ Supervisor (Queue-Worker)
                                                      ├─ Cron (FreeScout-Scheduler)
                                                      └─ Backups → r2:backups/freescout/
                                                            ├─ db-<hostname>/      (täglich 02:00, gzip + optional age)
                                                            └─ storage-<hostname>/ (täglich 03:00, rclone-Mirror)

         SMTP-Outgoing ← pro Mailbox im FreeScout-UI konfiguriert (nicht in .env)
         Authentik-OIDC ← Stub vorbereitet (Modul separat kaufen, ~49 USD)
         UptimeKuma ← Push-Webhooks bei Backup-/Health-Fehlern
```

---

## Scripts — Übersicht

| Script | Ausführen auf | Zweck | Wann |
|---|---|---|---|
| `proxmox-create-freescout-ct.sh` | Proxmox Host | Debian-13-LXC anlegen, IP + SSH konfigurieren | Einmalig |
| `setup-freescout.sh` | LXC | Stack (Nginx, PHP, MariaDB, Supervisor) + FreeScout installieren | Einmalig |
| `migrate-from-cloudron.sh` | Cloudron-Host | Export-Bundle erzeugen (SQL, storage, Modules, APP_KEY) | Einmalig (Migration) |
| `migrate-import.sh` | LXC | Export-Bundle importieren, Web-Installer überspringen | Einmalig (Migration) |
| `db-backup.sh` | LXC | MariaDB-Dump → R2 (flock, optional age-verschlüsselt) | Täglich |
| `storage-backup.sh` | LXC | storage/ + Modules/ → R2 (rclone-Mirror) | Täglich |
| `backup-verify.sh` | LXC | Integritätsprüfung R2-Backups (+ monatlich Test-Restore) | Wöchentlich |
| `update-freescout.sh` | LXC | Pre-Snapshot + git pull + composer + artisan | Bei Bedarf |
| `restore.sh` | LXC | DB + Storage aus R2 oder lokalem Snapshot wiederherstellen | Bei Bedarf |
| `status.sh` | LXC | Dashboard: Version, Disk, Queue, Cron, SSL, letzte Backups | Bei Bedarf |
| `health-check.sh` | LXC | HTTP, DB, Queue, Cron + Webhook bei Fehler | Bei Bedarf / Cron |

---

## Schritt-für-Schritt-Anleitung

### Voraussetzungen

- Proxmox VE (getestet mit PVE 8.x)
- Debian-13-Template in Proxmox verfügbar (`pveam update && pveam download local debian-13-standard`)
- Cloudflare R2 Bucket + API-Credentials (Access Key ID + Secret)
- Domain mit DNS-Eintrag auf deine IP / NPMPlus
- NPMPlus als Reverse Proxy (oder Nginx Proxy Manager)

---

### Schritt 1 — LXC erstellen (Proxmox-Host)

Auf dem Proxmox-Host als root:

```bash
curl -sO https://raw.githubusercontent.com/greecro/freescout-scripts/main/proxmox-create-freescout-ct.sh
bash proxmox-create-freescout-ct.sh
```

Das Script fragt interaktiv ab:
- Container-ID (default: nächste freie)
- Hostname (default: `freescout`)
- IP-Adresse + Gateway
- Proxmox-Storage, vCPU, RAM, Disk

**Non-interactive (CI/Automation):**
```bash
bash proxmox-create-freescout-ct.sh \
  --ct-id 120 \
  --hostname freescout \
  --ip 10.1.20.10/24 \
  --gateway 10.1.20.1 \
  --storage local-zfs \
  --cores 2 --ram 2048 --disk 20 \
  --yes
```

**Empfohlene Ressourcen:**

| Profil | vCPU | RAM | Disk |
|---|---|---|---|
| Klein (< 5 Mailboxes) | 2 | 2 GB | 20 GB |
| Mittel (5–20 Mailboxes) | 4 | 4 GB | 40 GB |
| Groß (> 20 Mailboxes) | 4 | 8 GB | 80 GB |

---

### Schritt 2 — FreeScout-Stack installieren (im LXC)

Per SSH ins LXC einloggen:

```bash
ssh root@<lxc-ip>
```

Setup-Script laden und ausführen:

```bash
curl -sO https://raw.githubusercontent.com/greecro/freescout-scripts/main/setup-freescout.sh
bash setup-freescout.sh
```

Das Script fragt ab und installiert dann vollautomatisch:

**Abfragen:**
- Domain (FQDN, z.B. `desk.example.com`)
- Locale / Timezone (Standard: `de` / `Europe/Berlin`)
- DB-Name + DB-User (Standard: `freescout`)
- R2-Endpoint, Bucket, Pfad-Prefix, Access Key, Secret Key
- Optionale age-Verschlüsselung für DB-Backups (Public Key)
- Optionaler Authentik-OIDC-Stub (Issuer, Client-ID, Secret)
- Optionale UptimeKuma-Push-Webhook-URL

**Was installiert wird:**
- System: `curl`, `wget`, `git`, `ufw`, `fail2ban`, `supervisor`, `cron`, `rsync`, `age`, `openssh-server`
- MariaDB 11 (apt.mariadb.org)
- PHP 8.3 + Extensions: `fpm`, `mysql`, `gd`, `mbstring`, `xml`, `curl`, `zip`, `bcmath`, `imap`, `intl`, `ldap`
- Nginx
- rclone (für R2-Backups)
- FreeScout (aus `git clone -b dist`)
- Supervisor-Config für Queue-Worker
- Cron-Jobs (FreeScout-Scheduler, DB-Backup, Storage-Backup, Backup-Verify)
- UFW-Firewall (22, 80, 443)
- fail2ban (SSH + Nginx)
- `/etc/freescout/config` (zentrale Konfigurationsdatei für alle Scripts)

Am Ende gibt das Script aus:
- DB-Credentials (Pfad: `/etc/freescout/db-credentials.txt`)
- Web-Installer-URL
- NPMPlus-Konfigurationshinweis

---

### Schritt 3 — NPMPlus Proxy-Host einrichten

Im NPMPlus-UI neuen Proxy-Host anlegen:

| Feld | Wert |
|---|---|
| Domain Names | `desk.example.com` |
| Scheme | `http` |
| Forward Hostname/IP | `<lxc-ip>` |
| Forward Port | `80` |
| Block Common Exploits | ✓ aktiv |
| Websocket Support | ✓ aktiv (wichtig für FreeScout Echo!) |

**SSL-Tab:**
- Let's Encrypt aktivieren
- Force SSL ✓
- HTTP/2 Support ✓

**Advanced-Tab (Custom Nginx Config):**
```nginx
proxy_set_header Host $host;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_set_header X-Real-IP $remote_addr;
```

> **Wichtig:** `proxy_set_header Host $host;` muss gesetzt sein — FreeScout prüft den `Host`-Header gegen `APP_TRUSTED_HOSTS` und lehnt alle Requests ab, wenn der Header fehlt.

---

### Schritt 4A — Fresh-Install via Web-Installer

Browser öffnen: `https://desk.example.com/install`

Eintragen:
- **Database Host:** `127.0.0.1`
- **Database Port:** `3306`
- **Database Name / User / Password:** aus `/etc/freescout/db-credentials.txt`
- **Admin Name / Email / Passwort:** beliebig wählen

Der Web-Installer migriert das DB-Schema und legt den Admin-User an.

> Nach dem Web-Installer: `supervisorctl start freescout-worker:*`

---

### Schritt 4B — Migration aus Cloudron

**Auf dem Cloudron-Host** (als root):

```bash
curl -sO https://raw.githubusercontent.com/greecro/freescout-scripts/main/migrate-from-cloudron.sh
bash migrate-from-cloudron.sh
```

Das Script erkennt automatisch ob `docker` oder `cloudron`-CLI verfügbar ist.

Es wird abgefragt:
- FreeScout-App-FQDN (bisherige Domain in Cloudron)

Das Script erzeugt ein Export-Bundle (z.B. `/tmp/freescout-export-20240601-120000/`) mit:

```
freescout-export-DATUM/
├── freescout.sql.gz       # MySQL-Dump (gzip-komprimiert)
├── storage.tar.gz         # Anhänge, Logs, Cache
├── modules.tar.gz         # Alle installierten Module (inkl. Lizenz-Bindings)
├── uploads.tar.gz         # Public Uploads
├── env-snapshot.txt       # APP_KEY + ausgewählte .env-Settings
└── MANIFEST.sha256        # Checksums für Integritätsprüfung
```

**Bundle aufs Ziel-LXC übertragen:**

```bash
rsync -avz --progress /tmp/freescout-export-DATUM/ root@<lxc-ip>:/root/freescout-import/
```

**Im LXC importieren:**

```bash
ssh root@<lxc-ip>
curl -sO https://raw.githubusercontent.com/greecro/freescout-scripts/main/migrate-import.sh
bash migrate-import.sh /root/freescout-import/
```

`migrate-import.sh` erledigt automatisch:
1. MANIFEST.sha256-Prüfung (Integritätscheck)
2. SQL-Import (DB wird bei Bedarf geleert)
3. Archive entpacken (storage, Modules, uploads)
4. `.env` aktualisieren (APP_KEY übernehmen — **kritisch** für SMTP-Decryption in DB)
5. `APP_TRUSTED_HOSTS` setzen
6. Composer-Deps für Module nachziehen
7. Permissions setzen (`www-data:www-data`)
8. Post-Update-Hooks (`clear-cache`, `after-app-update`, `migrate`, `storage:link`)
9. Queue-Worker starten
10. HTTP-Smoketest (Login-Seite)

> **Nach der Migration:** Falls Module leer oder kaputt erscheinen → Manage → Modules → jedes Modul einmal deaktivieren + reaktivieren (registriert sich neu).

---

### Schritt 5 — Queue-Worker prüfen

```bash
supervisorctl status
# freescout-worker:freescout-worker_00   RUNNING   pid 1234, uptime 0:01:00
```

Falls STOPPED:
```bash
supervisorctl start freescout-worker:*
```

---

### Schritt 6 — Mailbox-SMTP konfigurieren

FreeScout sendet ausgehende Mails **pro Mailbox** mit individuellen SMTP-Credentials.

- **Bei Migration:** SMTP-Settings kommen mit dem SQL-Dump — funktionieren automatisch, sofern APP_KEY korrekt übernommen wurde
- **Bei Fresh-Install:** Manage → Mailboxes → Connection Settings → SMTP-Zugangsdaten eintragen

---

### Schritt 7 (Optional) — Authentik-OIDC

FreeScout's OIDC-Integration ist ein **kostenpflichtiges Modul** (ca. 49 USD, [freescout.net/modules](https://freescout.net/modules)).

1. **In Authentik:** OAuth2/OpenID Provider erstellen, Application anlegen, Redirect-URI: `https://desk.example.com/oauth/callback`
2. **In FreeScout:** Modul hochladen (Manage → Modules), aktivieren, Issuer/Client-ID/Secret aus `/etc/freescout/oidc.env` übernehmen

---

## Backup-Konzept

| Backup-Typ | Pfad | Frequenz | Retention |
|---|---|---|---|
| DB-Dump (gzip) | `r2:backups/freescout/db-<hostname>/` | Täglich 02:00 | 7 Tage lokal, R2 per Versioning |
| Storage-Mirror | `r2:backups/freescout/storage-<hostname>/` | Täglich 03:00 | rclone-Mirror (laufend aktuell) |
| Pre-Update-Snapshot | `/var/snapshots/freescout-<datum>/` | Vor jedem Update | 5 Stück (automatische Rotation) |

**Features:**
- `flock`-protected: keine Doppelläufe bei langen Backups
- Optionale `age`-Verschlüsselung für DB-Dumps (Recipient Public Key)
- Bandbreitenlimit: `08:00–22:00: 8 MB/s`, nachts unlimitiert
- Wöchentliche Integritätsprüfung (`backup-verify.sh`): `gunzip -t` + SQL-Header-Check
- Monatlich (1. des Monats): Test-Restore in temporäre DB mit `--deep`

**Manuelle Befehle:**
```bash
# Manuelles DB-Backup auslösen
bash /usr/local/bin/freescout-db-backup.sh

# R2-Backups prüfen
rclone lsd r2:backups/freescout/

# Restore (interaktiv)
bash /usr/local/bin/freescout-restore.sh
```

---

## Monitoring & Cron-Übersicht

| Zeit | Command | Zweck |
|---|---|---|
| `* * * * *` | `php artisan schedule:run` (www-data) | FreeScout-Scheduler (Queue, Mail-Abruf) |
| `0 2 * * *` | `freescout-db-backup.sh` | DB → R2 |
| `0 3 * * *` | `freescout-storage-backup.sh` | storage → R2 |
| `0 4 * * 0` | `freescout-backup-verify.sh` | Wöchentliche R2-Verify |

Slack-Alert bei Fehlern: POST an `SLACK_WEBHOOK_URL` (Slack Incoming Webhook), JSON `{"text": "…"}`. Nur im Fehlerfall, kein „OK"-Spam.

---

## Update

```bash
bash /usr/local/bin/freescout-update.sh
```

Das Script:
1. Legt Pre-Update-Snapshot in `/var/snapshots/` ab (DB + storage)
2. `git pull` auf dem dist-Branch
3. `composer install --no-dev`
4. `php artisan freescout:clear-cache`
5. `php artisan freescout:after-app-update`
6. `php artisan migrate --force`
7. HTTP-Smoketest — bei Fehler automatischer Rollback zum Snapshot

---

## Troubleshooting

| Symptom | Ursache | Lösung |
|---|---|---|
| `/install` öffnet sich nach Migration | APP_KEY falsch oder DB leer | `migrate-import.sh` erneut ausführen, `env-snapshot.txt` prüfen |
| Leere Seite / Toggle-Navigation nur | Plugin-Konflikt nach Migration | Manage → Modules → Modul deaktivieren + reaktivieren |
| "Untrusted Host" Fehler | `APP_TRUSTED_HOSTS` fehlt in `.env` | `grep APP_TRUSTED_HOSTS /var/www/freescout/.env` prüfen |
| "Untrusted Host" obwohl gesetzt | NPMPlus sendet keinen `Host`-Header | Advanced-Tab: `proxy_set_header Host $host;` hinzufügen |
| Module zeigen "License Invalid" | Domain hat sich geändert | Modul deaktivieren + reaktivieren |
| Queue-Worker STOPPED | DB noch nicht migriert oder Absturz | `supervisorctl start freescout-worker:*`, `journalctl -u supervisor` |
| Mails kommen nicht raus | Mailbox-SMTP fehlt | Manage → Mailboxes → Connection Settings |
| 502 Bad Gateway | PHP-FPM down | `systemctl status php8.3-fpm`, `journalctl -u php8.3-fpm` |
| "valid cache path" Fehler nach Restore | `storage/framework/`-Unterverzeichnisse fehlen (R2 löscht leere Dirs) | `restore.sh` erstellt diese automatisch; oder manuell: `mkdir -p /var/www/freescout/storage/framework/{views,cache/data,sessions}` |
| "Required PHP extensions: ldap" | `php8.3-ldap` nicht installiert | `apt-get install -y php8.3-ldap && systemctl restart php8.3-fpm` |
| R2-Backup 401 Unauthorized | Falsche rclone-Credentials | `/root/.config/rclone/rclone.conf` prüfen, `rclone lsd r2:` testen |
| Permission denied auf storage/ | Ownership-Problem (z.B. nach Restore) | `chown -R www-data:www-data /var/www/freescout/storage` |

---

## Dateistruktur nach Installation

```
/var/www/freescout/          # FreeScout-Root (www-data)
/etc/freescout/
├── config                   # Zentrale Config (sourcen alle Scripts)
├── db-credentials.txt       # DB-Passwort (root:root, 600)
├── oidc.env                 # OIDC-Stub (falls konfiguriert)
└── backup-recipient.txt     # age Public Key (falls konfiguriert)
/usr/local/bin/
├── freescout-db-backup.sh
├── freescout-storage-backup.sh
├── freescout-backup-verify.sh
├── freescout-update.sh
├── freescout-restore.sh
├── freescout-status.sh
└── freescout-health-check.sh
/var/backups/freescout-db/   # Lokale DB-Dumps (7-Tage-Retention)
/var/snapshots/              # Pre-Update-Snapshots (5er-Rotation)
/var/log/
├── freescout-db-backup.log
├── freescout-storage-backup.log
└── freescout-backup-verify.log
```

---

## Lizenz

MIT — diese Scripts sind als Hilfestellung gedacht und kommen ohne Gewähr.

FreeScout selbst steht unter der AGPL. Siehe [github.com/freescout-help-desk/freescout](https://github.com/freescout-help-desk/freescout).
