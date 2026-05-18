#!/bin/bash
# FreeScout-Update: Pre-Update-Snapshot, git pull, composer, artisan, Worker-Restart.

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

cd "$INSTALL_DIR" || err "INSTALL_DIR nicht gefunden: ${INSTALL_DIR}"

echo -e "${BOLD}FreeScout-Update${NC}"
read -rp "Update jetzt starten? [j/N]: " confirm
[[ "$confirm" != "j" && "$confirm" != "J" ]] && err "Abgebrochen."

# ── Pre-Update-Snapshot ────────────────────────────────────────────────────
SNAP_DIR="/var/snapshots/freescout-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$SNAP_DIR"

DB_PASS=$(grep '^DB_PASS=' /etc/freescout/db-credentials.txt | cut -d= -f2-)
info "Pre-Update-Snapshot: DB-Dump..."
mariadb-dump --single-transaction --quick --no-tablespaces \
    -u"${DB_USER}" -p"${DB_PASS}" "${DB_NAME}" | gzip > "${SNAP_DIR}/db.sql.gz"
log "DB-Snapshot: $(du -h "${SNAP_DIR}/db.sql.gz" | cut -f1)"

info "Pre-Update-Snapshot: Storage..."
tar -czf "${SNAP_DIR}/storage.tar.gz" -C "$INSTALL_DIR" storage
log "Storage-Snapshot: $(du -h "${SNAP_DIR}/storage.tar.gz" | cut -f1)"

# Retention: nur 5 Snapshots
ls -1dt /var/snapshots/freescout-* 2>/dev/null | tail -n +6 | xargs rm -rf 2>/dev/null || true

# ── Maintenance-Mode ───────────────────────────────────────────────────────
info "Maintenance-Mode aktivieren..."
sudo -u www-data php artisan down --message="Update läuft" --retry=60 || true
supervisorctl stop freescout-worker:* || true

# Rollback-Trap
ROLLBACK_NEEDED=true
rollback() {
    $ROLLBACK_NEEDED || return
    warn "Rollback einleiten..."
    sudo -u www-data php artisan up || true
    warn "Snapshot zum Wiederherstellen: ${SNAP_DIR}"
    warn "Manuelles Rollback: bash restore.sh <snapshot-name>"
}
trap rollback ERR

# ── Git Pull ───────────────────────────────────────────────────────────────
info "git pull (Branch: dist)..."
sudo -u www-data git fetch --quiet
sudo -u www-data git checkout dist --quiet 2>/dev/null || true
sudo -u www-data git pull --quiet

# ── Composer ───────────────────────────────────────────────────────────────
info "composer install..."
sudo -u www-data -H COMPOSER_ALLOW_SUPERUSER=0 \
    composer install --no-dev --optimize-autoloader --no-interaction --quiet

# ── Artisan Update-Hooks ───────────────────────────────────────────────────
info "artisan freescout:after-app-update..."
sudo -u www-data php artisan freescout:after-app-update 2>&1 | tail -5 || true

info "artisan migrate --force..."
sudo -u www-data php artisan migrate --force 2>&1 | tail -5

# ── Module: composer install pro Modul ─────────────────────────────────────
if [[ -d Modules ]]; then
    info "Module-Composer..."
    for mod_dir in Modules/*/; do
        [[ -f "${mod_dir}composer.json" ]] || continue
        echo "  → ${mod_dir}"
        (cd "$mod_dir" && sudo -u www-data -H COMPOSER_ALLOW_SUPERUSER=0 \
            composer install --no-dev --no-interaction --quiet 2>/dev/null) || \
            warn "  composer install fehlgeschlagen für ${mod_dir}"
    done
fi

# ── Cache & Permissions ────────────────────────────────────────────────────
info "Cache leeren..."
sudo -u www-data php artisan freescout:clear-cache 2>&1 | tail -3 || true
chown -R www-data:www-data "$INSTALL_DIR"
chmod -R 755 "${INSTALL_DIR}/storage" "${INSTALL_DIR}/bootstrap/cache"

# ── PHP-FPM + Worker neu starten ───────────────────────────────────────────
info "PHP-FPM reload..."
systemctl reload php8.3-fpm

info "Queue-Worker starten..."
supervisorctl start freescout-worker:* || warn "Worker konnte nicht gestartet werden."

# ── Maintenance-Mode aus ───────────────────────────────────────────────────
info "Maintenance-Mode aus..."
sudo -u www-data php artisan up

ROLLBACK_NEEDED=false
trap - ERR

# ── HTTP-Test ──────────────────────────────────────────────────────────────
sleep 2
LXC_IP=$(hostname -I | awk '{print $1}')
HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" "http://${LXC_IP}/login" || echo "000")
case "$HTTP_CODE" in
    200|302) log "HTTP ${HTTP_CODE} — alles OK." ;;
    *)       warn "HTTP ${HTTP_CODE} — bitte manuell prüfen." ;;
esac

echo ""
log "Update abgeschlossen."
echo "Snapshot: ${SNAP_DIR}"
