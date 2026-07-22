#!/bin/bash
# Tägliches Storage-Backup → R2 (rclone-Mirror). flock-protected.

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1" | tee -a "$LOG_FILE"; }
warn() { echo -e "${YELLOW}[!]${NC} $1" | tee -a "$LOG_FILE"; }
err()  { echo -e "${RED}[✗]${NC} $1" | tee -a "$LOG_FILE"; ERRORS=$((ERRORS+1)); }

LOG_FILE=/var/log/freescout-storage-backup.log
ERRORS=0

[[ $EUID -ne 0 ]] && { echo "Als root ausführen."; exit 1; }
[[ -f /etc/freescout/config ]] || { echo "/etc/freescout/config fehlt."; exit 1; }
# shellcheck source=/dev/null
source /etc/freescout/config

LOCKFILE=/var/lock/freescout-storage-backup.lock
exec 9>"$LOCKFILE"
flock -n 9 || { echo "Backup läuft bereits (flock)."; exit 0; }

# notify() + healthchecks laden (No-Op ohne notify.sh / healthchecks.env)
if ! source /etc/freescout/notify.sh 2>/dev/null; then notify(){ :;}; hc_start(){ :;}; hc_report(){ :;}; fi
hc_start "${HC_URL_STORAGE_BACKUP:-}"
trap 'hc_report $?' EXIT

echo "==[ $(date -Iseconds) ]==" >> "$LOG_FILE"

REMOTE_STORAGE="r2:${R2_BUCKET}/${R2_PREFIX}storage-${APP_HOSTNAME}/"
REMOTE_MODULES="r2:${R2_BUCKET}/${R2_PREFIX}modules-${APP_HOSTNAME}/"

# ── Storage-Mirror ─────────────────────────────────────────────────────────
log "rclone sync storage/ → ${REMOTE_STORAGE}"
if rclone sync "${INSTALL_DIR}/storage" "$REMOTE_STORAGE" \
    --exclude "logs/**" --exclude "framework/cache/**" --exclude "framework/sessions/**" --exclude "framework/views/**" \
    --bwlimit "08:00,8M 22:00,off" \
    --transfers 8 --checkers 16 \
    --log-file="$LOG_FILE" --log-level INFO; then
    log "storage/ OK."
else
    err "storage/-Sync fehlgeschlagen."
fi

# ── Modules-Mirror (selten geändert, aber wichtig) ─────────────────────────
if [[ -d "${INSTALL_DIR}/Modules" ]]; then
    log "rclone sync Modules/ → ${REMOTE_MODULES}"
    if rclone sync "${INSTALL_DIR}/Modules" "$REMOTE_MODULES" \
        --bwlimit "08:00,8M 22:00,off" \
        --transfers 4 --checkers 8 \
        --log-file="$LOG_FILE" --log-level INFO; then
        log "Modules/ OK."
    else
        err "Modules/-Sync fehlgeschlagen."
    fi
fi

# ── Slack-Detail bei Fehler (healthchecks meldet Liveness/Fail separat) ────
if [[ "$ERRORS" -gt 0 ]]; then
    notify "FreeScout Storage-Backup" "${ERRORS} Fehler auf ${APP_HOSTNAME} — siehe ${LOG_FILE}"
fi

exit $ERRORS
