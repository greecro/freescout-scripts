#!/bin/bash
# Restore: DB + Storage aus R2-Backup oder lokalem Pre-Update-Snapshot.

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
info() { echo -e "${BLUE}[i]${NC} $1"; }

[[ $EUID -ne 0 ]] && err "Als root ausführen."
[[ -f /etc/freescout/config ]] || err "/etc/freescout/config fehlt."
# shellcheck source=/dev/null
source /etc/freescout/config
DB_PASS=$(grep '^DB_PASS=' /etc/freescout/db-credentials.txt | cut -d= -f2-)

clear
echo -e "${BOLD}"
echo "╔══════════════════════════════════════════════╗"
echo "║   FreeScout — Restore                        ║"
echo "╚══════════════════════════════════════════════╝"
echo -e "${NC}"

# ── Quelle wählen ──────────────────────────────────────────────────────────
echo "Restore-Quelle:"
echo "  1) Pre-Update-Snapshot (lokal in /var/snapshots/)"
echo "  2) R2-Backup (neueste DB + Storage aus r2:${R2_BUCKET}/${R2_PREFIX})"
read -rp "Auswahl [1/2]: " src

case "$src" in
    1)
        echo ""
        echo "Verfügbare lokale Snapshots:"
        SNAPS=()
        if compgen -G "/var/snapshots/freescout-*" >/dev/null; then
            mapfile -t SNAPS < <(ls -1dt /var/snapshots/freescout-* 2>/dev/null)
            for i in "${!SNAPS[@]}"; do
                printf "  %d) %s\n" "$((i+1))" "$(basename "${SNAPS[$i]}")"
            done
        else
            err "Keine Snapshots vorhanden."
        fi
        read -rp "Snapshot-Nummer: " sn
        SNAPSHOT="${SNAPS[$((sn-1))]}"
        [[ ! -d "$SNAPSHOT" ]] && err "Ungültige Auswahl."
        DB_FILE="${SNAPSHOT}/db.sql.gz"
        STORAGE_FILE="${SNAPSHOT}/storage.tar.gz"
        ;;
    2)
        TMP=$(mktemp -d)
        trap 'rm -rf "$TMP"' EXIT
        info "Lade neuesten DB-Dump aus R2..."
        DB_NAME_LATEST=$(rclone lsf "r2:${R2_BUCKET}/${R2_PREFIX}db-${APP_HOSTNAME}/" --files-only | sort | tail -n1)
        [[ -z "$DB_NAME_LATEST" ]] && err "Kein DB-Backup in R2."
        rclone copy "r2:${R2_BUCKET}/${R2_PREFIX}db-${APP_HOSTNAME}/${DB_NAME_LATEST}" "$TMP/"
        DB_FILE="${TMP}/${DB_NAME_LATEST}"

        # Falls age — Decrypt
        if [[ "$DB_FILE" == *.age ]]; then
            [[ -f /etc/freescout/age-key.txt ]] || err "Privater age-Key fehlt: /etc/freescout/age-key.txt"
            info "age-Decrypt..."
            age -d -i /etc/freescout/age-key.txt "$DB_FILE" > "${DB_FILE%.age}"
            DB_FILE="${DB_FILE%.age}"
        fi

        info "Lade Storage-Mirror aus R2..."
        STORAGE_DIR="${TMP}/storage"
        rclone copy "r2:${R2_BUCKET}/${R2_PREFIX}storage-${APP_HOSTNAME}/" "$STORAGE_DIR/"
        STORAGE_FILE=""  # wird unten anders behandelt
        ;;
    *) err "Ungültige Auswahl." ;;
esac

# ── Bestätigung ────────────────────────────────────────────────────────────
echo ""
warn "Achtung: DB ${DB_NAME} und ${INSTALL_DIR}/storage werden überschrieben!"
read -rp "Wirklich fortfahren? [j/N]: " confirm
[[ "$confirm" != "j" && "$confirm" != "J" ]] && err "Abgebrochen."

# ── Maintenance ────────────────────────────────────────────────────────────
runuser -u www-data -- php -d detect_unicode=0 "${INSTALL_DIR}/artisan" down --message="Restore läuft" || true
supervisorctl stop freescout-worker:* 2>/dev/null || true

# ── DB importieren ─────────────────────────────────────────────────────────
info "DB-Restore..."
mariadb -e "DROP DATABASE \`${DB_NAME}\`; CREATE DATABASE \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
mariadb -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost'; FLUSH PRIVILEGES;"
zcat "$DB_FILE" | mariadb -u"${DB_USER}" -p"${DB_PASS}" "${DB_NAME}"
log "DB importiert."

# ── Storage ────────────────────────────────────────────────────────────────
info "Storage-Restore..."
if [[ -n "$STORAGE_FILE" ]] && [[ -f "$STORAGE_FILE" ]]; then
    rm -rf "${INSTALL_DIR}/storage"
    tar -xzf "$STORAGE_FILE" -C "$INSTALL_DIR"
else
    # R2-Mirror nach lokal
    rsync -a --delete "${TMP}/storage/" "${INSTALL_DIR}/storage/"
fi
chown -R www-data:www-data "${INSTALL_DIR}/storage"
chmod -R 755 "${INSTALL_DIR}/storage"
# Framework-Verzeichnisse sicherstellen (fehlen nach Storage-Restore aus R2-Mirror)
mkdir -p "${INSTALL_DIR}/storage/framework/"{views,cache/data,sessions}
chown -R www-data:www-data "${INSTALL_DIR}/storage/framework"
log "Storage importiert."

# ── Cache + Hooks ──────────────────────────────────────────────────────────
runuser -u www-data -- php "${INSTALL_DIR}/artisan" freescout:clear-cache || true
runuser -u www-data -- php "${INSTALL_DIR}/artisan" up

# ── Worker ─────────────────────────────────────────────────────────────────
supervisorctl start freescout-worker:* || warn "Worker-Start fehlgeschlagen."

# ── HTTP-Test mit Auto-Rollback ────────────────────────────────────────────
sleep 2
LXC_IP=$(hostname -I | awk '{print $1}')
HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" "http://${LXC_IP}/login" || echo "000")
case "$HTTP_CODE" in
    200|302) log "HTTP ${HTTP_CODE} — Restore OK." ;;
    *)       err "HTTP ${HTTP_CODE} — Restore fehlgeschlagen. Manuell prüfen: tail /var/log/nginx/freescout-error.log" ;;
esac
