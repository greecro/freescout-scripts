#!/bin/bash
# Tägliches MariaDB-Backup → R2. flock-protected, optional age-verschlüsselt.

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1" | tee -a "$LOG_FILE"; }
warn() { echo -e "${YELLOW}[!]${NC} $1" | tee -a "$LOG_FILE"; }
err()  { echo -e "${RED}[✗]${NC} $1" | tee -a "$LOG_FILE"; ERRORS=$((ERRORS+1)); }

LOG_FILE=/var/log/freescout-db-backup.log
ERRORS=0

[[ $EUID -ne 0 ]] && { echo "Als root ausführen."; exit 1; }
[[ -f /etc/freescout/config ]] || { echo "/etc/freescout/config fehlt."; exit 1; }
# shellcheck source=/dev/null
source /etc/freescout/config
DB_PASS=$(grep '^DB_PASS=' /etc/freescout/db-credentials.txt | cut -d= -f2-)

# flock-Lock
LOCKFILE=/var/lock/freescout-db-backup.lock
exec 9>"$LOCKFILE"
flock -n 9 || { echo "Backup läuft bereits (flock)."; exit 0; }

# notify() + healthchecks laden (No-Op ohne notify.sh / healthchecks.env)
if ! source /etc/freescout/notify.sh 2>/dev/null; then notify(){ :;}; hc_start(){ :;}; hc_report(){ :;}; fi
hc_start "${HC_URL_DB_BACKUP:-}"
trap 'hc_report $?' EXIT

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR=/var/backups/freescout-db
mkdir -p "$BACKUP_DIR"

echo "==[ $(date -Iseconds) ]==" >> "$LOG_FILE"

# ── Dump ──────────────────────────────────────────────────────────────────
DUMP_FILE="${BACKUP_DIR}/${DB_NAME}-${TIMESTAMP}.sql.gz"
log "Dumping ${DB_NAME}..."
if mariadb-dump --single-transaction --quick --no-tablespaces \
    -u"${DB_USER}" -p"${DB_PASS}" "${DB_NAME}" 2>>"$LOG_FILE" | gzip > "$DUMP_FILE"; then
    log "Dump: $(du -h "$DUMP_FILE" | cut -f1)"
else
    err "Dump fehlgeschlagen."
fi

# ── age-Encryption (optional) ──────────────────────────────────────────────
if [[ -f /etc/freescout/backup-recipient.txt ]]; then
    log "age-Encryption..."
    if age -R /etc/freescout/backup-recipient.txt -o "${DUMP_FILE}.age" "$DUMP_FILE" 2>>"$LOG_FILE"; then
        rm -f "$DUMP_FILE"
        DUMP_FILE="${DUMP_FILE}.age"
        log "Verschlüsselt: $(basename "$DUMP_FILE")"
    else
        err "age-Encryption fehlgeschlagen."
    fi
fi

# ── Lokale Retention (7 Tage) ──────────────────────────────────────────────
find "$BACKUP_DIR" -name "${DB_NAME}-*.sql.gz*" -mtime +7 -delete

# ── rclone Mirror nach R2 ──────────────────────────────────────────────────
REMOTE="r2:${R2_BUCKET}/${R2_PREFIX}db-${APP_HOSTNAME}/"
log "rclone sync → ${REMOTE}"
if rclone sync "$BACKUP_DIR" "$REMOTE" \
    --bwlimit "08:00,8M 22:00,off" \
    --transfers 4 --checkers 8 \
    --log-file="$LOG_FILE" --log-level INFO; then
    log "Remote-Sync OK."
else
    err "Remote-Sync fehlgeschlagen."
fi

# ── Slack-Detail bei Fehler (healthchecks meldet Liveness/Fail separat) ────
if [[ "$ERRORS" -gt 0 ]]; then
    notify "FreeScout DB-Backup" "${ERRORS} Fehler auf ${APP_HOSTNAME} — siehe ${LOG_FILE}"
fi

exit $ERRORS
