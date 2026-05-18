#!/bin/bash
# Importiert ein Cloudron-Export-Bundle (von migrate-from-cloudron.sh) in einen
# frisch eingerichteten FreeScout-LXC. Ausführen im LXC als root.

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
info() { echo -e "${BLUE}[i]${NC} $1"; }

[[ $EUID -ne 0 ]] && err "Als root ausführen."

BUNDLE_DIR="${1:-/root/freescout-import}"
[[ -d "$BUNDLE_DIR" ]] || err "Bundle-Verzeichnis nicht gefunden: ${BUNDLE_DIR}"

# Config sourcen (DB_NAME, DB_USER, INSTALL_DIR, DOMAIN, …)
[[ -f /etc/freescout/config ]] || err "/etc/freescout/config fehlt — setup-freescout.sh erst laufen lassen."
# shellcheck source=/dev/null
source /etc/freescout/config
[[ -f /etc/freescout/db-credentials.txt ]] || err "DB-Credentials fehlen."
DB_PASS=$(grep '^DB_PASS=' /etc/freescout/db-credentials.txt | cut -d= -f2-)

clear
echo -e "${BOLD}"
echo "╔══════════════════════════════════════════════╗"
echo "║   FreeScout — Import aus Cloudron-Bundle     ║"
echo "╚══════════════════════════════════════════════╝"
echo -e "${NC}"

# ── Pre-Flight ─────────────────────────────────────────────────────────────
info "Pre-Flight..."
for f in freescout.sql.gz storage.tar.gz modules.tar.gz uploads.tar.gz env-snapshot.txt MANIFEST.sha256; do
    [[ -f "${BUNDLE_DIR}/${f}" ]] || err "Datei fehlt im Bundle: ${f}"
done

info "MANIFEST.sha256 verifizieren..."
(cd "$BUNDLE_DIR" && sha256sum -c MANIFEST.sha256 --quiet) || err "Checksum-Mismatch im Bundle."
log "Manifest OK."

# DB muss leer sein
TABLE_COUNT=$(mariadb -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB_NAME}';" 2>/dev/null || echo "0")
if [[ "$TABLE_COUNT" -gt 0 ]]; then
    warn "DB ${DB_NAME} ist nicht leer (${TABLE_COUNT} Tabellen)."
    read -rp "Trotzdem fortfahren? DB wird komplett überschrieben! [j/N]: " confirm
    [[ "$confirm" != "j" && "$confirm" != "J" ]] && err "Abgebrochen."
    info "Drop + Recreate DB..."
    mariadb -e "DROP DATABASE \`${DB_NAME}\`; CREATE DATABASE \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
fi

# Worker stoppen
supervisorctl stop freescout-worker:* 2>/dev/null || true

# APP_KEY aus Snapshot
APP_KEY=$(grep '^APP_KEY=' "${BUNDLE_DIR}/env-snapshot.txt" | cut -d= -f2-)
[[ -z "$APP_KEY" ]] && err "APP_KEY fehlt im env-snapshot.txt — Migration unmöglich."
log "APP_KEY aus Source-Snapshot verfügbar."

# ── Summary ────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}Zusammenfassung:${NC}"
echo "  Bundle:        ${BUNDLE_DIR}"
echo "  Target-Domain: ${DOMAIN}"
echo "  Target-DB:     ${DB_NAME}"
echo "  APP_KEY:       übernommen aus Source"
echo ""
read -rp "Import starten? [j/N]: " confirm
[[ "$confirm" != "j" && "$confirm" != "J" ]] && err "Abgebrochen."

# ── SQL importieren ────────────────────────────────────────────────────────
info "SQL importieren..."
zcat "${BUNDLE_DIR}/freescout.sql.gz" | mariadb "${DB_NAME}"
log "DB importiert ($(mariadb -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB_NAME}';") Tabellen)."

# ── Archive entpacken ──────────────────────────────────────────────────────
info "Archive entpacken nach ${INSTALL_DIR}..."
cd "$INSTALL_DIR"

# Backup der Default-Files (für Rollback)
[[ -d storage ]] && mv storage storage.orig.$$
[[ -d Modules ]] && mv Modules Modules.orig.$$
[[ -d public/uploads ]] && mv public/uploads public/uploads.orig.$$

tar -xzf "${BUNDLE_DIR}/storage.tar.gz"
tar -xzf "${BUNDLE_DIR}/modules.tar.gz"
tar -xzf "${BUNDLE_DIR}/uploads.tar.gz" 2>/dev/null || true

# Uploads ggf. unter public/ verschieben falls top-level extracted
if [[ -d uploads ]] && [[ ! -d public/uploads ]]; then
    mv uploads public/uploads
fi

# Cleanup-Backups
rm -rf storage.orig.$$ Modules.orig.$$ public/uploads.orig.$$ 2>/dev/null || true
log "Archive entpackt."

# ── .env: APP_KEY + DB-Block setzen ────────────────────────────────────────
info ".env aktualisieren (APP_KEY + DB)..."
sed -i "s|^APP_KEY=.*|APP_KEY=${APP_KEY}|" .env
sed -i "s|^APP_URL=.*|APP_URL=https://${DOMAIN}|" .env

# DB-Block einfügen oder ersetzen
if grep -q "^DB_HOST=" .env; then
    sed -i "s|^DB_HOST=.*|DB_HOST=127.0.0.1|" .env
    sed -i "s|^DB_PORT=.*|DB_PORT=3306|" .env
    sed -i "s|^DB_DATABASE=.*|DB_DATABASE=${DB_NAME}|" .env
    sed -i "s|^DB_USERNAME=.*|DB_USERNAME=${DB_USER}|" .env
    sed -i "s|^DB_PASSWORD=.*|DB_PASSWORD=${DB_PASS}|" .env
else
    cat >> .env <<EOF

DB_CONNECTION=mysql
DB_HOST=127.0.0.1
DB_PORT=3306
DB_DATABASE=${DB_NAME}
DB_USERNAME=${DB_USER}
DB_PASSWORD=${DB_PASS}
EOF
fi
log ".env aktualisiert."

# ── Module: composer install ───────────────────────────────────────────────
info "Composer-Deps für Module nachziehen (falls vorhanden)..."
if [[ -d Modules ]]; then
    for mod_dir in Modules/*/; do
        [[ -f "${mod_dir}composer.json" ]] || continue
        info "  → ${mod_dir}"
        (cd "$mod_dir" && COMPOSER_ALLOW_SUPERUSER=1 \
            composer install --no-dev --no-interaction --quiet 2>/dev/null) || \
            warn "  composer install fehlgeschlagen für ${mod_dir} — manuell prüfen."
    done
fi

# ── Permissions ────────────────────────────────────────────────────────────
info "Permissions setzen..."
chown -R www-data:www-data "$INSTALL_DIR"
chmod -R 755 "${INSTALL_DIR}/storage" "${INSTALL_DIR}/bootstrap/cache"
[[ -d "${INSTALL_DIR}/Modules" ]] && chmod -R 755 "${INSTALL_DIR}/Modules"

# ── Post-Update-Hooks ──────────────────────────────────────────────────────
info "FreeScout-Hooks (clear-cache, after-app-update, migrate)..."
cd "$INSTALL_DIR"
runuser -u www-data -- php artisan freescout:clear-cache 2>&1 | tail -5 || true
runuser -u www-data -- php artisan freescout:after-app-update 2>&1 | tail -5 || true
runuser -u www-data -- php artisan migrate --force 2>&1 | tail -5 || true
log "Hooks ausgeführt."

# ── Supervisor starten ─────────────────────────────────────────────────────
info "Queue-Worker starten..."
supervisorctl reread >/dev/null
supervisorctl update >/dev/null
supervisorctl start freescout-worker:* || warn "Worker konnte nicht gestartet werden — supervisorctl status prüfen."

# ── HTTP-Smoketest ─────────────────────────────────────────────────────────
info "HTTP-Smoketest..."
sleep 2
LXC_IP=$(hostname -I | awk '{print $1}')
HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" "http://${LXC_IP}/login" || echo "000")
case "$HTTP_CODE" in
    200|302) log "HTTP ${HTTP_CODE} — Login-Seite erreichbar." ;;
    *)       warn "HTTP ${HTTP_CODE} — bitte manuell prüfen, z.B. mit:"
             warn "  curl -v http://${LXC_IP}/login"
             warn "  tail -50 /var/log/nginx/freescout-error.log"
             warn "  tail -50 ${INSTALL_DIR}/storage/logs/laravel.log" ;;
esac

# ── Modul-Liste ──────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}Importierte Module:${NC}"
if [[ -d "${INSTALL_DIR}/Modules" ]]; then
    ls -1 "${INSTALL_DIR}/Modules" | sed 's/^/  - /'
else
    echo "  (keine)"
fi

# ── Fertig ─────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   Migration abgeschlossen                    ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BOLD}Login:${NC}  https://${DOMAIN}/login"
echo ""
echo -e "${BOLD}Wenn Module 'License Invalid' anzeigen:${NC}"
echo "  Manage → Modules → Modul deaktivieren + reaktivieren"
echo "  (sollte bei gleicher Domain selten nötig sein)"
echo ""
echo -e "${BOLD}Wenn ausgehende Mails nicht funktionieren:${NC}"
echo "  Manage → Mailboxes → Connection Settings prüfen"
echo "  (SMTP-Settings sind in der DB verschlüsselt; APP_KEY-Match ist Voraussetzung)"
echo ""
