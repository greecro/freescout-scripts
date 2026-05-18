#!/bin/bash
# Exportiert eine FreeScout-Installation, die unter Cloudron läuft.
# Ausführen auf dem Cloudron-Host als root.

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
info() { echo -e "${BLUE}[i]${NC} $1"; }

[[ $EUID -ne 0 ]] && err "Als root ausführen."
command -v cloudron &>/dev/null || err "cloudron-CLI nicht gefunden — Script muss auf dem Cloudron-Host laufen."

clear
echo -e "${BOLD}"
echo "╔══════════════════════════════════════════════╗"
echo "║   FreeScout — Export aus Cloudron            ║"
echo "╚══════════════════════════════════════════════╝"
echo -e "${NC}"

# ── App ermitteln ──────────────────────────────────────────────────────────
read -rp "FreeScout-App-FQDN (z.B. support.brand.de): " APP_FQDN
[[ -z "$APP_FQDN" ]] && err "FQDN darf nicht leer sein."

info "Suche App in Cloudron..."
APP_INFO=$(cloudron list 2>/dev/null | grep "$APP_FQDN" || true)
[[ -z "$APP_INFO" ]] && err "App ${APP_FQDN} nicht in Cloudron gefunden."
APP_ID=$(echo "$APP_INFO" | awk '{print $1}')
log "App-ID: ${APP_ID}"

APP_DATA_DIR="/home/yellowtent/appsdata/${APP_ID}"
[[ ! -d "$APP_DATA_DIR" ]] && err "App-Daten-Verzeichnis nicht gefunden: ${APP_DATA_DIR}"

# Verzeichnisse mit storage/Modules/uploads identifizieren
SUB_DIR=""
for candidate in "data" "."; do
    if [[ -d "${APP_DATA_DIR}/${candidate}/storage" ]] || [[ -d "${APP_DATA_DIR}/${candidate}/Modules" ]]; then
        SUB_DIR="${candidate}"
        break
    fi
done
[[ -z "$SUB_DIR" ]] && err "Konnte storage/Modules nicht unter ${APP_DATA_DIR} finden."
APP_PAYLOAD_DIR="${APP_DATA_DIR}/${SUB_DIR}"
log "Payload-Pfad: ${APP_PAYLOAD_DIR}"

# ── Output-Verzeichnis ─────────────────────────────────────────────────────
DEFAULT_OUT="/tmp/freescout-export-$(date +%Y%m%d-%H%M%S)"
read -rp "Output-Verzeichnis [Standard: ${DEFAULT_OUT}]: " OUT
OUT=${OUT:-$DEFAULT_OUT}
mkdir -p "$OUT"
log "Output: ${OUT}"

# ── Summary ────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}Zusammenfassung:${NC}"
echo "  App-FQDN:    ${APP_FQDN}"
echo "  App-ID:      ${APP_ID}"
echo "  Payload-Dir: ${APP_PAYLOAD_DIR}"
echo "  Output:      ${OUT}"
echo ""
read -rp "Export starten? [j/N]: " confirm
[[ "$confirm" != "j" && "$confirm" != "J" ]] && err "Abgebrochen."

# ── MySQL-Dump via cloudron exec ───────────────────────────────────────────
info "MySQL-Dump..."
cloudron exec --app "$APP_FQDN" -- bash -c \
    'mysqldump --single-transaction --quick --no-tablespaces \
       -h "$CLOUDRON_MYSQL_HOST" \
       -P "${CLOUDRON_MYSQL_PORT:-3306}" \
       -u "$CLOUDRON_MYSQL_USERNAME" \
       -p"$CLOUDRON_MYSQL_PASSWORD" \
       "$CLOUDRON_MYSQL_DATABASE"' \
    | gzip > "${OUT}/freescout.sql.gz"
SQL_SIZE=$(du -h "${OUT}/freescout.sql.gz" | cut -f1)
log "MySQL-Dump: ${SQL_SIZE}"

# ── Tar-Bundles ────────────────────────────────────────────────────────────
info "Storage-Tar (kann je nach Anhang-Volumen dauern)..."
if [[ -d "${APP_PAYLOAD_DIR}/storage" ]]; then
    tar -czf "${OUT}/storage.tar.gz" -C "${APP_PAYLOAD_DIR}" storage
    log "storage.tar.gz: $(du -h "${OUT}/storage.tar.gz" | cut -f1)"
else
    warn "Kein storage/-Verzeichnis gefunden — leeres Archiv erzeugt."
    tar -czf "${OUT}/storage.tar.gz" --files-from /dev/null
fi

info "Modules-Tar..."
if [[ -d "${APP_PAYLOAD_DIR}/Modules" ]]; then
    tar -czf "${OUT}/modules.tar.gz" -C "${APP_PAYLOAD_DIR}" Modules
    log "modules.tar.gz: $(du -h "${OUT}/modules.tar.gz" | cut -f1)"
else
    warn "Kein Modules/-Verzeichnis gefunden — leeres Archiv erzeugt."
    tar -czf "${OUT}/modules.tar.gz" --files-from /dev/null
fi

info "Uploads-Tar..."
UPLOADS_PATH=""
for candidate in "uploads" "public/uploads"; do
    if [[ -d "${APP_PAYLOAD_DIR}/${candidate}" ]]; then
        UPLOADS_PATH="$candidate"
        break
    fi
done
if [[ -n "$UPLOADS_PATH" ]]; then
    tar -czf "${OUT}/uploads.tar.gz" -C "${APP_PAYLOAD_DIR}" "$UPLOADS_PATH"
    log "uploads.tar.gz: $(du -h "${OUT}/uploads.tar.gz" | cut -f1)"
else
    warn "Kein uploads/-Verzeichnis gefunden — leeres Archiv erzeugt."
    tar -czf "${OUT}/uploads.tar.gz" --files-from /dev/null
fi

# ── .env-Snapshot ──────────────────────────────────────────────────────────
info ".env-Snapshot (APP_KEY + ausgewählte Settings)..."
ENV_FILE=""
for candidate in "${APP_PAYLOAD_DIR}/.env" "${APP_DATA_DIR}/.env" "${APP_PAYLOAD_DIR}/env"; do
    if [[ -f "$candidate" ]]; then
        ENV_FILE="$candidate"
        break
    fi
done

if [[ -z "$ENV_FILE" ]]; then
    warn "Keine .env auf dem Host gefunden — versuche aus dem Container zu lesen..."
    cloudron exec --app "$APP_FQDN" -- cat /app/code/.env 2>/dev/null > "${OUT}/.env-raw" || \
        cloudron exec --app "$APP_FQDN" -- cat /app/data/.env 2>/dev/null > "${OUT}/.env-raw" || \
        true
    if [[ -s "${OUT}/.env-raw" ]]; then
        ENV_FILE="${OUT}/.env-raw"
    fi
fi

if [[ -n "$ENV_FILE" ]] && [[ -f "$ENV_FILE" ]]; then
    grep -E '^(APP_KEY|APP_TIMEZONE|APP_LOCALE|FREESCOUT_|LOG_CHANNEL)=' "$ENV_FILE" > "${OUT}/env-snapshot.txt" || true
    rm -f "${OUT}/.env-raw"
    if grep -q '^APP_KEY=' "${OUT}/env-snapshot.txt"; then
        log "env-snapshot.txt geschrieben (APP_KEY enthalten — kritisch für DB-Entschlüsselung!)"
    else
        err "APP_KEY fehlt im env-snapshot — Migration würde verschlüsselte DB-Werte unlesbar machen. Manuell aus FreeScout-Container ermitteln."
    fi
else
    err "Konnte .env nicht ermitteln. APP_KEY muss manuell extrahiert werden."
fi

# ── Version ────────────────────────────────────────────────────────────────
info "Version ermitteln..."
FS_VERSION=$(cloudron exec --app "$APP_FQDN" -- bash -c 'cd /app/code && php artisan --version 2>/dev/null || echo "unbekannt"' || echo "unbekannt")
cat > "${OUT}/version.txt" <<EOF
Source-FQDN:    ${APP_FQDN}
Source-AppID:   ${APP_ID}
Export-Datum:   $(date -Iseconds)
Laravel:        ${FS_VERSION}
EOF

# Versuche FreeScout-Version aus config zu lesen
FS_VERSION_FILE=$(cloudron exec --app "$APP_FQDN" -- bash -c 'cat /app/code/config/app.php 2>/dev/null | grep -i version | head -3' 2>/dev/null || true)
[[ -n "$FS_VERSION_FILE" ]] && echo "FreeScout config: ${FS_VERSION_FILE}" >> "${OUT}/version.txt"

log "version.txt geschrieben."

# ── MANIFEST ───────────────────────────────────────────────────────────────
info "MANIFEST.sha256 erzeugen..."
cd "$OUT"
sha256sum freescout.sql.gz storage.tar.gz modules.tar.gz uploads.tar.gz env-snapshot.txt version.txt > MANIFEST.sha256
cd - >/dev/null

# ── Fertig ─────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   Export fertig                              ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BOLD}Bundle:${NC} ${OUT}/"
ls -lh "$OUT"
echo ""
echo -e "${BOLD}Nächster Schritt — aufs Target-LXC kopieren:${NC}"
echo ""
echo "  rsync -avz --progress ${OUT}/ root@<lxc-ip>:/root/freescout-import/"
echo ""
echo -e "${BOLD}Danach im LXC:${NC}"
echo ""
echo "  bash migrate-import.sh /root/freescout-import/"
echo ""
