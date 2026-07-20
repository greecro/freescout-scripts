#!/bin/bash
# Wöchentliche Backup-Integritätsprüfung: lädt neuesten DB-Dump aus R2,
# entschlüsselt (falls age), prüft gunzip + SQL-Header.
# Mit --deep (am 1. des Monats): Test-Restore in temporäre DB.

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1" | tee -a "$LOG_FILE"; }
warn() { echo -e "${YELLOW}[!]${NC} $1" | tee -a "$LOG_FILE"; }
err()  { echo -e "${RED}[✗]${NC} $1" | tee -a "$LOG_FILE"; ERRORS=$((ERRORS+1)); }

LOG_FILE=/var/log/freescout-backup-verify.log
ERRORS=0

DEEP=false
[[ "${1:-}" == "--deep" ]] && DEEP=true
# Auto-deep am 1. des Monats
[[ "$(date +%d)" == "01" ]] && DEEP=true

[[ $EUID -ne 0 ]] && { echo "Als root ausführen."; exit 1; }
[[ -f /etc/freescout/config ]] || { echo "/etc/freescout/config fehlt."; exit 1; }
# shellcheck source=/dev/null
source /etc/freescout/config

echo "==[ $(date -Iseconds) ${DEEP:+DEEP} ]==" >> "$LOG_FILE"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

REMOTE_DB="r2:${R2_BUCKET}/${R2_PREFIX}db-${APP_HOSTNAME}/"

# ── Neuesten Dump finden ───────────────────────────────────────────────────
log "Suche neuesten Dump in ${REMOTE_DB}..."
LATEST=$(rclone lsf "$REMOTE_DB" --files-only 2>/dev/null | sort | tail -n1 || true)
[[ -z "$LATEST" ]] && err "Kein Dump in R2 gefunden."
[[ -z "$LATEST" ]] && exit 1

log "Latest: ${LATEST}"
rclone copy "${REMOTE_DB}${LATEST}" "$TMP/" --log-file="$LOG_FILE" --log-level INFO

DUMP="${TMP}/${LATEST}"
[[ -f "$DUMP" ]] || err "Download fehlgeschlagen."

# ── Entschlüsselung (falls age) ────────────────────────────────────────────
if [[ "$DUMP" == *.age ]]; then
    log "age-Decrypt..."
    if [[ ! -f /etc/freescout/backup-recipient.txt ]]; then
        warn "Backups sind verschlüsselt, aber kein age-Key konfiguriert — Test übersprungen."
        exit 0
    fi
    # Verify-Decrypt mit privatem Key
    if [[ ! -f /etc/freescout/age-key.txt ]]; then
        warn "Privater age-Key fehlt unter /etc/freescout/age-key.txt — Verify ohne Decrypt."
        exit 0
    fi
    age -d -i /etc/freescout/age-key.txt "$DUMP" > "${DUMP%.age}" 2>>"$LOG_FILE" || err "age-Decrypt fehlgeschlagen."
    DUMP="${DUMP%.age}"
fi

# ── gunzip-Test ────────────────────────────────────────────────────────────
log "gunzip -t Test..."
if gunzip -t "$DUMP" 2>>"$LOG_FILE"; then
    log "gunzip OK."
else
    err "gunzip-Test fehlgeschlagen."
fi

# ── SQL-Header-Check ───────────────────────────────────────────────────────
log "SQL-Header-Check..."
HEADER=$(zcat "$DUMP" 2>/dev/null | head -5)
if echo "$HEADER" | grep -q "MySQL\|MariaDB\|CREATE\|INSERT"; then
    log "SQL-Header OK."
else
    err "SQL-Header verdächtig — kein MySQL/MariaDB-Dump?"
fi

# ── Deep-Test: Test-Restore ────────────────────────────────────────────────
if $DEEP; then
    log "DEEP: Test-Restore in temporäre DB..."
    TEST_DB="${DB_NAME}_verify_$$"
    DB_PASS=$(grep '^DB_PASS=' /etc/freescout/db-credentials.txt | cut -d= -f2-)
    mariadb -e "CREATE DATABASE \`${TEST_DB}\`;"
    if zcat "$DUMP" | mariadb -u"${DB_USER}" -p"${DB_PASS}" "${TEST_DB}" 2>>"$LOG_FILE"; then
        TABLES=$(mariadb -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${TEST_DB}';")
        log "Test-Restore OK: ${TABLES} Tabellen."
        mariadb -e "DROP DATABASE \`${TEST_DB}\`;"
    else
        err "Test-Restore fehlgeschlagen."
        mariadb -e "DROP DATABASE IF EXISTS \`${TEST_DB}\`;" || true
    fi
fi

# ── Storage-Mirror-Statistik ───────────────────────────────────────────────
REMOTE_STORAGE="r2:${R2_BUCKET}/${R2_PREFIX}storage-${APP_HOSTNAME}/"
log "Storage-Mirror-Statistik..."
STATS=$(rclone size "$REMOTE_STORAGE" 2>/dev/null || echo "?")
log "${STATS}"

# ── Slack-Alert bei Fehler ─────────────────────────────────────────────────
if [[ "$ERRORS" -gt 0 ]] && [[ -n "${SLACK_WEBHOOK_URL:-}" ]]; then
    curl -fsS -X POST -H 'Content-type: application/json' \
        --data "{\"text\": \"🔴 FreeScout Backup-Verify: ${ERRORS} Fehler auf ${APP_HOSTNAME}${DEEP:+ (deep)} — siehe ${LOG_FILE}\"}" \
        "$SLACK_WEBHOOK_URL" >/dev/null || true
fi

exit $ERRORS
