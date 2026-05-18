#!/bin/bash
# Dashboard: FreeScout-Version, Disk, DB, Queue, Cron, SSL, letzte Backups.

set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
ok()    { echo -e "  ${GREEN}●${NC} $1"; }
nok()   { echo -e "  ${RED}●${NC} $1"; }
maybe() { echo -e "  ${YELLOW}●${NC} $1"; }
hdr()   { echo -e "\n${BOLD}== $1 ==${NC}"; }

[[ -f /etc/freescout/config ]] || { echo "/etc/freescout/config fehlt."; exit 1; }
# shellcheck source=/dev/null
source /etc/freescout/config
DB_PASS=$(grep '^DB_PASS=' /etc/freescout/db-credentials.txt | cut -d= -f2-)

clear
echo -e "${BOLD}FreeScout Dashboard — ${DOMAIN} (${APP_HOSTNAME})${NC}"
echo "$(date)"

# ── System ────────────────────────────────────────────────────────────────
hdr "System"
echo "  Uptime: $(uptime -p)"
echo "  Load:   $(awk '{print $1, $2, $3}' /proc/loadavg)"
DISK=$(df -h --output=avail / | tail -n1 | xargs)
DISK_USED_PCT=$(df --output=pcent / | tail -n1 | tr -dc '0-9')
if [[ "$DISK_USED_PCT" -lt 80 ]]; then ok "Disk frei: ${DISK} (${DISK_USED_PCT} % belegt)"
elif [[ "$DISK_USED_PCT" -lt 90 ]]; then maybe "Disk frei: ${DISK} (${DISK_USED_PCT} % belegt)"
else nok "Disk frei: ${DISK} (${DISK_USED_PCT} % belegt) — kritisch"
fi
echo "  RAM:    $(free -h | awk '/Mem:/ {print $3 " / " $2}')"

# ── FreeScout ─────────────────────────────────────────────────────────────
hdr "FreeScout"
if [[ -d "$INSTALL_DIR" ]]; then
    FS_VER=$(cd "$INSTALL_DIR" && sudo -u www-data git describe --tags --always 2>/dev/null || echo "unbekannt")
    ok "Installation: ${INSTALL_DIR} (Git: ${FS_VER})"
else
    nok "INSTALL_DIR fehlt: ${INSTALL_DIR}"
fi
PHP_VER=$(php -v | head -1 | awk '{print $2}')
ok "PHP: ${PHP_VER}"

# ── Services ──────────────────────────────────────────────────────────────
hdr "Services"
for svc in nginx php8.3-fpm mariadb supervisor cron fail2ban; do
    if systemctl is-active --quiet "$svc"; then
        ok "${svc} läuft"
    else
        nok "${svc} läuft NICHT"
    fi
done

# ── Datenbank ─────────────────────────────────────────────────────────────
hdr "Datenbank"
if mariadb -u"${DB_USER}" -p"${DB_PASS}" -e "USE \`${DB_NAME}\`;" 2>/dev/null; then
    TABLES=$(mariadb -u"${DB_USER}" -p"${DB_PASS}" -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB_NAME}';")
    SIZE=$(mariadb -u"${DB_USER}" -p"${DB_PASS}" -N -e "SELECT ROUND(SUM(data_length+index_length)/1024/1024,1) FROM information_schema.tables WHERE table_schema='${DB_NAME}';")
    ok "${DB_NAME}: ${TABLES} Tabellen, ${SIZE} MB"
else
    nok "DB nicht erreichbar"
fi

# ── Queue-Worker ──────────────────────────────────────────────────────────
hdr "Queue-Worker"
if supervisorctl status freescout-worker:* 2>/dev/null | grep -q RUNNING; then
    ok "freescout-worker läuft"
else
    maybe "freescout-worker NICHT running — starten: supervisorctl start freescout-worker:*"
fi

# ── Cron-Last-Run ─────────────────────────────────────────────────────────
hdr "Scheduler"
LARAVEL_LOG="${INSTALL_DIR}/storage/logs/laravel.log"
if [[ -f "$LARAVEL_LOG" ]]; then
    LAST_SCHED=$(grep -i "schedule" "$LARAVEL_LOG" 2>/dev/null | tail -1 | head -c 80 || echo "kein Eintrag")
    echo "  Last schedule log: ${LAST_SCHED}"
fi
crontab -u www-data -l 2>/dev/null | grep -q "schedule:run" && ok "Crontab für www-data OK" || nok "Crontab fehlt"

# ── SSL ────────────────────────────────────────────────────────────────────
hdr "SSL (${DOMAIN})"
if timeout 5 bash -c "</dev/tcp/${DOMAIN}/443" 2>/dev/null; then
    EXPIRY=$(echo | openssl s_client -servername "$DOMAIN" -connect "${DOMAIN}:443" 2>/dev/null \
        | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
    if [[ -n "$EXPIRY" ]]; then
        DAYS=$(( ($(date -d "$EXPIRY" +%s) - $(date +%s)) / 86400 ))
        if [[ "$DAYS" -gt 30 ]]; then ok "Cert gültig bis ${EXPIRY} (${DAYS} Tage)"
        elif [[ "$DAYS" -gt 7 ]]; then maybe "Cert läuft in ${DAYS} Tagen ab"
        else nok "Cert läuft in ${DAYS} Tagen ab — verlängern!"
        fi
    fi
else
    maybe "Domain ${DOMAIN}:443 nicht erreichbar (NPM noch nicht eingerichtet?)"
fi

# ── Backups ───────────────────────────────────────────────────────────────
hdr "Backups"
DB_BACKUP_DIR=/var/backups/freescout-db
if [[ -d "$DB_BACKUP_DIR" ]]; then
    LAST_DB=$(ls -1t "$DB_BACKUP_DIR" 2>/dev/null | head -1)
    [[ -n "$LAST_DB" ]] && ok "Lokales DB-Backup: ${LAST_DB} ($(du -h "${DB_BACKUP_DIR}/${LAST_DB}" | cut -f1))" || maybe "Kein lokales DB-Backup"
fi

if command -v rclone &>/dev/null; then
    REMOTE_DB="r2:${R2_BUCKET}/${R2_PREFIX}db-${APP_HOSTNAME}/"
    LAST_R2=$(rclone lsf "$REMOTE_DB" --files-only 2>/dev/null | sort | tail -n1 || echo "")
    [[ -n "$LAST_R2" ]] && ok "R2 DB-Backup: ${LAST_R2}" || maybe "Kein R2-DB-Backup"
fi

echo ""
