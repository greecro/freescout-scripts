#!/bin/bash
# Exportiert eine FreeScout-Installation, die unter Cloudron läuft.
# Ausführen auf dem Cloudron-Host als root.
# Unterstützt zwei Modi:
#   - Docker-Modus  (direkt auf dem Cloudron-Host, kein CLI nötig)
#   - cloudron-CLI  (falls cloudron-CLI installiert + eingeloggt ist)

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
info() { echo -e "${BLUE}[i]${NC} $1"; }

[[ $EUID -ne 0 ]] && err "Als root ausführen."

# Modus erkennen
USE_DOCKER=false
USE_CLOUDRON_CLI=false
if command -v docker &>/dev/null; then
    USE_DOCKER=true
elif command -v cloudron &>/dev/null; then
    USE_CLOUDRON_CLI=true
else
    err "Weder 'docker' noch 'cloudron'-CLI gefunden. Script muss auf dem Cloudron-Host laufen."
fi

clear
echo -e "${BOLD}"
echo "╔══════════════════════════════════════════════╗"
echo "║   FreeScout — Export aus Cloudron            ║"
echo "╚══════════════════════════════════════════════╝"
echo -e "${NC}"

$USE_DOCKER       && info "Modus: Docker (direkt auf dem Host)"
$USE_CLOUDRON_CLI && info "Modus: cloudron-CLI"

# ── App ermitteln ──────────────────────────────────────────────────────────
read -rp "FreeScout-App-FQDN (z.B. support.brand.de): " APP_FQDN
[[ -z "$APP_FQDN" ]] && err "FQDN darf nicht leer sein."

APP_ID=""
CONTAINER_NAME=""
APP_DATA_DIR=""

if $USE_DOCKER; then
    # Container anhand FQDN (Label oder Name) finden
    # Cloudron setzt das Label "fqdn" oder den Container-Namen enthält den App-Hostname
    CONTAINER_NAME=$(docker ps --format '{{.Names}}' | grep -i "$(echo "$APP_FQDN" | cut -d. -f1)" | head -n1 || true)

    if [[ -z "$CONTAINER_NAME" ]]; then
        # Fallback: alle laufenden Container anzeigen, User wählt
        echo ""
        echo "Laufende Container (kein automatischer Match für '${APP_FQDN}'):"
        docker ps --format "  {{.Names}}\t{{.Image}}" | head -20
        echo ""
        read -rp "Container-Name eingeben: " CONTAINER_NAME
    fi
    [[ -z "$CONTAINER_NAME" ]] && err "Kein Container angegeben."

    # App-ID aus Cloudron-Datenverzeichnis ableiten
    # Cloudron hängt App-Daten unter /home/yellowtent/appsdata/<id>/ ein
    APP_DATA_DIR=$(docker inspect "$CONTAINER_NAME" \
        --format '{{range .Mounts}}{{if eq .Destination "/app/data"}}{{.Source}}{{end}}{{end}}' \
        2>/dev/null || true)

    if [[ -z "$APP_DATA_DIR" ]]; then
        # Alternativ: /app/code Mount prüfen
        APP_DATA_DIR=$(docker inspect "$CONTAINER_NAME" \
            --format '{{range .Mounts}}{{if eq .Destination "/app/code"}}{{.Source}}{{end}}{{end}}' \
            2>/dev/null || true)
    fi

    if [[ -z "$APP_DATA_DIR" ]] || [[ ! -d "$APP_DATA_DIR" ]]; then
        # Manueller Fallback
        echo ""
        echo "Mounts dieses Containers:"
        docker inspect "$CONTAINER_NAME" --format '{{range .Mounts}}  {{.Source}} → {{.Destination}}{{"\n"}}{{end}}' 2>/dev/null || true
        echo ""
        read -rp "App-Daten-Verzeichnis (lokaler Host-Pfad mit storage/Modules): " APP_DATA_DIR
    fi
    [[ ! -d "$APP_DATA_DIR" ]] && err "Verzeichnis nicht gefunden: ${APP_DATA_DIR}"
    APP_ID=$(basename "$(dirname "$APP_DATA_DIR")" 2>/dev/null || echo "$CONTAINER_NAME")
    log "Container: ${CONTAINER_NAME}"

else
    # cloudron-CLI Modus
    info "Suche App in Cloudron..."
    APP_INFO=$(cloudron list 2>/dev/null | grep "$APP_FQDN" || true)
    [[ -z "$APP_INFO" ]] && err "App ${APP_FQDN} nicht in Cloudron gefunden."
    APP_ID=$(echo "$APP_INFO" | awk '{print $1}')
    APP_DATA_DIR="/home/yellowtent/appsdata/${APP_ID}"
    [[ ! -d "$APP_DATA_DIR" ]] && err "App-Daten-Verzeichnis nicht gefunden: ${APP_DATA_DIR}"
fi
log "App-ID / Container: ${APP_ID}"

# ── Payload-Verzeichnis (storage/Modules) finden ──────────────────────────
APP_PAYLOAD_DIR=""
for candidate in "$APP_DATA_DIR" "${APP_DATA_DIR}/data" "${APP_DATA_DIR}/app/data"; do
    if [[ -d "${candidate}/storage" ]] || [[ -d "${candidate}/Modules" ]]; then
        APP_PAYLOAD_DIR="$candidate"
        break
    fi
done

if [[ -z "$APP_PAYLOAD_DIR" ]]; then
    echo ""
    warn "Konnte storage/Modules nicht automatisch finden."
    echo "Verzeichnisstruktur unter ${APP_DATA_DIR}:"
    find "$APP_DATA_DIR" -maxdepth 3 -type d 2>/dev/null | head -30 || true
    echo ""
    read -rp "Pfad mit storage/ und Modules/ eingeben: " APP_PAYLOAD_DIR
    [[ ! -d "$APP_PAYLOAD_DIR" ]] && err "Verzeichnis nicht gefunden: ${APP_PAYLOAD_DIR}"
fi
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
echo "  Container:   ${CONTAINER_NAME:-${APP_ID}}"
echo "  Payload-Dir: ${APP_PAYLOAD_DIR}"
echo "  Output:      ${OUT}"
echo ""
read -rp "Export starten? [j/N]: " confirm
[[ "$confirm" != "j" && "$confirm" != "J" ]] && err "Abgebrochen."

# ── MySQL-Dump ─────────────────────────────────────────────────────────────
info "MySQL-Dump..."
if $USE_DOCKER; then
    docker exec "$CONTAINER_NAME" bash -c \
        'mysqldump --single-transaction --quick --no-tablespaces \
           -h "$CLOUDRON_MYSQL_HOST" \
           -P "${CLOUDRON_MYSQL_PORT:-3306}" \
           -u "$CLOUDRON_MYSQL_USERNAME" \
           -p"$CLOUDRON_MYSQL_PASSWORD" \
           "$CLOUDRON_MYSQL_DATABASE"' \
        | gzip > "${OUT}/freescout.sql.gz"
else
    cloudron exec --app "$APP_FQDN" -- bash -c \
        'mysqldump --single-transaction --quick --no-tablespaces \
           -h "$CLOUDRON_MYSQL_HOST" \
           -P "${CLOUDRON_MYSQL_PORT:-3306}" \
           -u "$CLOUDRON_MYSQL_USERNAME" \
           -p"$CLOUDRON_MYSQL_PASSWORD" \
           "$CLOUDRON_MYSQL_DATABASE"' \
        | gzip > "${OUT}/freescout.sql.gz"
fi
[[ ! -s "${OUT}/freescout.sql.gz" ]] && err "MySQL-Dump ist leer — DB-Verbindung im Container fehlgeschlagen?"
log "MySQL-Dump: $(du -h "${OUT}/freescout.sql.gz" | cut -f1)"

# ── Tar-Bundles (direkt vom Host-Filesystem) ───────────────────────────────
info "Storage-Tar..."
if [[ -d "${APP_PAYLOAD_DIR}/storage" ]]; then
    tar -czf "${OUT}/storage.tar.gz" -C "${APP_PAYLOAD_DIR}" storage
    log "storage.tar.gz: $(du -h "${OUT}/storage.tar.gz" | cut -f1)"
else
    warn "Kein storage/-Verzeichnis — leeres Archiv."
    tar -czf "${OUT}/storage.tar.gz" --files-from /dev/null
fi

info "Modules-Tar..."
if [[ -d "${APP_PAYLOAD_DIR}/Modules" ]]; then
    tar -czf "${OUT}/modules.tar.gz" -C "${APP_PAYLOAD_DIR}" Modules
    log "modules.tar.gz: $(du -h "${OUT}/modules.tar.gz" | cut -f1)"
else
    warn "Kein Modules/-Verzeichnis — leeres Archiv."
    tar -czf "${OUT}/modules.tar.gz" --files-from /dev/null
fi

info "Uploads-Tar..."
UPLOADS_PATH=""
for candidate in "uploads" "public/uploads"; do
    [[ -d "${APP_PAYLOAD_DIR}/${candidate}" ]] && UPLOADS_PATH="$candidate" && break
done
if [[ -n "$UPLOADS_PATH" ]]; then
    tar -czf "${OUT}/uploads.tar.gz" -C "${APP_PAYLOAD_DIR}" "$UPLOADS_PATH"
    log "uploads.tar.gz: $(du -h "${OUT}/uploads.tar.gz" | cut -f1)"
else
    warn "Kein uploads/-Verzeichnis — leeres Archiv."
    tar -czf "${OUT}/uploads.tar.gz" --files-from /dev/null
fi

# ── .env-Snapshot (APP_KEY) ────────────────────────────────────────────────
info ".env-Snapshot (APP_KEY + ausgewählte Settings)..."
ENV_FILE=""
for candidate in \
    "${APP_PAYLOAD_DIR}/.env" \
    "${APP_DATA_DIR}/.env" \
    "${APP_DATA_DIR}/data/.env"; do
    [[ -f "$candidate" ]] && ENV_FILE="$candidate" && break
done

if [[ -z "$ENV_FILE" ]]; then
    warn "Keine .env auf dem Host gefunden — lese aus Container..."
    if $USE_DOCKER; then
        docker exec "$CONTAINER_NAME" cat /app/code/.env 2>/dev/null > "${OUT}/.env-raw" || \
        docker exec "$CONTAINER_NAME" cat /app/data/.env 2>/dev/null > "${OUT}/.env-raw" || true
    else
        cloudron exec --app "$APP_FQDN" -- cat /app/code/.env 2>/dev/null > "${OUT}/.env-raw" || \
        cloudron exec --app "$APP_FQDN" -- cat /app/data/.env 2>/dev/null > "${OUT}/.env-raw" || true
    fi
    [[ -s "${OUT}/.env-raw" ]] && ENV_FILE="${OUT}/.env-raw"
fi

if [[ -n "$ENV_FILE" ]] && [[ -f "$ENV_FILE" ]]; then
    grep -E '^(APP_KEY|APP_TIMEZONE|APP_LOCALE|FREESCOUT_|LOG_CHANNEL)=' "$ENV_FILE" > "${OUT}/env-snapshot.txt" || true
    rm -f "${OUT}/.env-raw"
    if grep -q '^APP_KEY=' "${OUT}/env-snapshot.txt"; then
        log "env-snapshot.txt (APP_KEY enthalten — kritisch für DB-Entschlüsselung)"
    else
        err "APP_KEY fehlt in .env — Migration würde SMTP-Credentials in DB unleserlich machen."
    fi
else
    err "Konnte .env nicht finden. APP_KEY muss manuell aus dem Container extrahiert werden:
  docker exec ${CONTAINER_NAME:-<container>} grep APP_KEY /app/code/.env"
fi

# ── Version ────────────────────────────────────────────────────────────────
info "Version ermitteln..."
FS_VERSION="unbekannt"
if $USE_DOCKER; then
    FS_VERSION=$(docker exec "$CONTAINER_NAME" bash -c \
        'cd /app/code 2>/dev/null && php artisan --version 2>/dev/null || echo "unbekannt"' 2>/dev/null || echo "unbekannt")
else
    FS_VERSION=$(cloudron exec --app "$APP_FQDN" -- bash -c \
        'cd /app/code && php artisan --version 2>/dev/null || echo "unbekannt"' 2>/dev/null || echo "unbekannt")
fi
cat > "${OUT}/version.txt" <<EOF
Source-FQDN:    ${APP_FQDN}
Source-App:     ${CONTAINER_NAME:-${APP_ID}}
Export-Datum:   $(date -Iseconds)
Laravel:        ${FS_VERSION}
EOF
log "version.txt geschrieben."

# ── MANIFEST ───────────────────────────────────────────────────────────────
info "MANIFEST.sha256 erzeugen..."
(cd "$OUT" && sha256sum freescout.sql.gz storage.tar.gz modules.tar.gz uploads.tar.gz env-snapshot.txt version.txt > MANIFEST.sha256)

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
