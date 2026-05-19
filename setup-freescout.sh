#!/bin/bash
# Installiert FreeScout-Stack (Nginx, PHP 8.3, MariaDB, Supervisor) auf Debian 13.
# Ausführen im LXC als root.

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
info() { echo -e "${BLUE}[i]${NC} $1"; }

# ── Cleanup-Trap ───────────────────────────────────────────────────────────
CLEANUP_ENABLED=true
cleanup_on_error() {
    local rc=$?
    [[ $rc -eq 0 ]] && return
    $CLEANUP_ENABLED || return
    echo ""
    warn "Fehler erkannt — räume auf..."
    rm -rf /var/www/freescout 2>/dev/null || true
    if [[ -n "${DB_NAME:-}" ]]; then
        mariadb -e "DROP DATABASE IF EXISTS \`${DB_NAME}\`;" 2>/dev/null || true
        mariadb -e "DROP USER IF EXISTS '${DB_USER}'@'localhost';" 2>/dev/null || true
    fi
    crontab -u www-data -r 2>/dev/null || true
    rm -f /etc/nginx/sites-enabled/freescout.conf 2>/dev/null || true
    rm -f /etc/supervisor/conf.d/freescout-worker.conf 2>/dev/null || true
    warn "Cleanup abgeschlossen. Configs unter /etc/freescout/ bleiben für Debug erhalten."
}
trap cleanup_on_error ERR

[[ $EUID -ne 0 ]] && err "Als root ausführen."

# ── Argument-Parser ────────────────────────────────────────────────────────
NON_INTERACTIVE=false
ARG_DOMAIN=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --domain)    ARG_DOMAIN="$2"; shift 2 ;;
        --yes|-y)    NON_INTERACTIVE=true; shift ;;
        -h|--help)
            cat <<EOF
Usage: $0 [OPTIONS]

Optionen:
  --domain <fqdn>     FreeScout-Domain
  --yes               Skip-Confirmation (non-interactive)
EOF
            exit 0 ;;
        *) err "Unbekannte Option: $1" ;;
    esac
done

# ── Pre-Flight ─────────────────────────────────────────────────────────────
clear
echo -e "${BOLD}"
echo "╔══════════════════════════════════════════════╗"
echo "║   FreeScout-Setup (Debian 13 LXC)            ║"
echo "╚══════════════════════════════════════════════╝"
echo -e "${NC}"

info "Pre-Flight-Checks..."
grep -q "trixie\|VERSION_ID=\"13\"" /etc/os-release || err "Nicht Debian 13 — Setup bricht ab."
df -BG --output=avail / | tail -n1 | grep -qE '^\s*[5-9]G|^\s*[0-9]{2,}G' || err "Weniger als 5 GB Disk frei."
log "OS: Debian 13. Disk: $(df -h --output=avail / | tail -n1 | xargs) frei."

# ── Eingaben ───────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}-- FreeScout --${NC}"
if [[ -n "$ARG_DOMAIN" ]]; then
    DOMAIN="$ARG_DOMAIN"
else
    read -rp "Domain (FQDN, z.B. support.brand.de): " DOMAIN
fi
[[ -z "$DOMAIN" ]] && err "Domain darf nicht leer sein."
[[ ! "$DOMAIN" =~ ^[a-zA-Z0-9.-]+$ ]] && err "Ungültige Domain: ${DOMAIN}"

read -rp "Locale [Standard: de]: " APP_LOCALE
APP_LOCALE=${APP_LOCALE:-de}

read -rp "Timezone [Standard: Europe/Berlin]: " APP_TIMEZONE
APP_TIMEZONE=${APP_TIMEZONE:-Europe/Berlin}

# DNS-Check
info "Prüfe DNS für ${DOMAIN}..."
if ! getent hosts "$DOMAIN" >/dev/null 2>&1; then
    warn "DNS für ${DOMAIN} aktuell nicht auflösbar — du kannst trotzdem fortfahren (NPM/Cloudflare erst später eingerichtet)."
fi

echo ""
echo -e "${BOLD}-- Datenbank (lokal) --${NC}"
read -rp "DB-Name [Standard: freescout]: " DB_NAME
DB_NAME=${DB_NAME:-freescout}
read -rp "DB-User [Standard: freescout]: " DB_USER
DB_USER=${DB_USER:-freescout}
# head-first verhindert SIGPIPE auf tr (würde mit pipefail das Script killen)
DB_PASS=$(head -c 256 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | head -c 24)
[[ ${#DB_PASS} -lt 16 ]] && err "Konnte kein DB-Passwort generieren (urandom?)."
info "DB-Passwort wird auto-generiert."

echo ""
echo -e "${BOLD}-- R2-Backups --${NC}"
read -rp "S3-Endpoint (z.B. https://<account-id>.r2.cloudflarestorage.com): " R2_ENDPOINT
[[ -z "$R2_ENDPOINT" ]] && err "Endpoint darf nicht leer sein."
read -rp "Bucket [Standard: backups]: " R2_BUCKET
R2_BUCKET=${R2_BUCKET:-backups}
read -rp "Pfad-Prefix [Standard: freescout/]: " R2_PREFIX
R2_PREFIX=${R2_PREFIX:-freescout/}
[[ "${R2_PREFIX: -1}" != "/" ]] && R2_PREFIX="${R2_PREFIX}/"
read -rp "R2 Access Key ID: " R2_ACCESS_KEY
[[ -z "$R2_ACCESS_KEY" ]] && err "Access Key darf nicht leer sein."
read -rsp "R2 Secret Access Key: " R2_SECRET_KEY; echo
[[ -z "$R2_SECRET_KEY" ]] && err "Secret Key darf nicht leer sein."

# R2-Endpoint-Reachability
info "Teste R2-Endpoint..."
R2_HOST=$(echo "$R2_ENDPOINT" | sed -E 's#https?://##' | cut -d/ -f1)
if ! timeout 5 bash -c "</dev/tcp/${R2_HOST}/443" 2>/dev/null; then
    warn "R2-Endpoint ${R2_HOST}:443 nicht erreichbar — Backups schlagen evtl. fehl."
fi

echo ""
echo -e "${BOLD}-- age-Verschlüsselung (optional) --${NC}"
read -rp "Backup mit age verschlüsseln? [j/N]: " USE_AGE
AGE_RECIPIENT=""
if [[ "$USE_AGE" == "j" || "$USE_AGE" == "J" ]]; then
    read -rp "age Recipient Public Key (z.B. age1xy...): " AGE_RECIPIENT
    [[ -z "$AGE_RECIPIENT" ]] && err "Recipient darf nicht leer sein."
fi

echo ""
echo -e "${BOLD}-- Authentik-OIDC (optional, Stub) --${NC}"
read -rp "Authentik-OIDC-Werte vorbereiten? [j/N]: " USE_OIDC
OIDC_ISSUER=""; OIDC_CLIENT_ID=""; OIDC_CLIENT_SECRET=""
if [[ "$USE_OIDC" == "j" || "$USE_OIDC" == "J" ]]; then
    read -rp "OIDC Issuer URL: " OIDC_ISSUER
    read -rp "OIDC Client ID: " OIDC_CLIENT_ID
    read -rsp "OIDC Client Secret: " OIDC_CLIENT_SECRET; echo
fi

echo ""
echo -e "${BOLD}-- UptimeKuma (optional) --${NC}"
read -rp "Push-Webhook-URL für Backup-/Health-Fehler (leer = aus): " WEBHOOK_URL

# ── Summary ────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}Zusammenfassung:${NC}"
echo "  Domain:        ${DOMAIN}"
echo "  Locale/TZ:     ${APP_LOCALE} / ${APP_TIMEZONE}"
echo "  DB:            ${DB_NAME} (user: ${DB_USER})"
echo "  R2:            ${R2_ENDPOINT}, ${R2_BUCKET}/${R2_PREFIX}"
echo "  age:           $([[ -n "$AGE_RECIPIENT" ]] && echo "aktiv" || echo "aus")"
echo "  OIDC-Stub:     $([[ -n "$OIDC_ISSUER" ]] && echo "${OIDC_ISSUER}" || echo "aus")"
echo "  Webhook:       $([[ -n "$WEBHOOK_URL" ]] && echo "konfiguriert" || echo "aus")"
echo ""
if ! $NON_INTERACTIVE; then
    read -rp "Installation starten? [j/N]: " confirm
    [[ "$confirm" != "j" && "$confirm" != "J" ]] && err "Abgebrochen."
fi

# ── Phase 1: System-Basics ─────────────────────────────────────────────────
info "Phase 1/16: System-Basics..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl wget unzip git ufw fail2ban supervisor cron rsync \
    ca-certificates apt-transport-https lsb-release gnupg locales tzdata jq age \
    openssh-server >/dev/null
systemctl enable --now ssh 2>/dev/null || systemctl enable --now sshd 2>/dev/null || true

# Locale + Timezone
sed -i 's/^# *\(de_DE.UTF-8\)/\1/' /etc/locale.gen 2>/dev/null || true
sed -i 's/^# *\(en_US.UTF-8\)/\1/' /etc/locale.gen 2>/dev/null || true
locale-gen >/dev/null
update-locale LANG=de_DE.UTF-8 >/dev/null
ln -sf "/usr/share/zoneinfo/${APP_TIMEZONE}" /etc/localtime
echo "$APP_TIMEZONE" > /etc/timezone
log "System-Basics installiert."

# ── Phase 2: MariaDB ───────────────────────────────────────────────────────
info "Phase 2/16: MariaDB..."
apt-get install -y -qq mariadb-server mariadb-client >/dev/null
systemctl enable --now mariadb >/dev/null

# Tuning
cat > /etc/mysql/mariadb.conf.d/99-freescout.cnf <<EOF
[mysqld]
bind-address = 127.0.0.1
innodb_buffer_pool_size = 512M
innodb_log_file_size = 128M
innodb_flush_log_at_trx_commit = 1
innodb_flush_method = O_DIRECT
max_connections = 100
max_allowed_packet = 64M
EOF
systemctl restart mariadb

# DB + User anlegen (idempotent: bei Rerun alten Stand wegräumen)
mariadb -e "DROP DATABASE IF EXISTS \`${DB_NAME}\`;"
mariadb -e "DROP USER IF EXISTS '${DB_USER}'@'localhost';"
mariadb -e "CREATE DATABASE \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
mariadb -e "CREATE USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';"
mariadb -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';"
mariadb -e "FLUSH PRIVILEGES;"
log "MariaDB konfiguriert, DB ${DB_NAME} angelegt."

# ── Phase 3: PHP 8.3 ───────────────────────────────────────────────────────
info "Phase 3/16: PHP 8.3 (Sury-Repo)..."
curl -sSLo /tmp/sury.gpg https://packages.sury.org/php/apt.gpg
mv /tmp/sury.gpg /etc/apt/trusted.gpg.d/sury.gpg
echo "deb https://packages.sury.org/php/ $(lsb_release -sc) main" > /etc/apt/sources.list.d/sury-php.list
apt-get update -qq
apt-get install -y -qq \
    php8.3-fpm php8.3-cli php8.3-common php8.3-mysql php8.3-curl php8.3-xml \
    php8.3-zip php8.3-gd php8.3-intl php8.3-imap php8.3-mbstring php8.3-bcmath \
    php8.3-fileinfo php8.3-tokenizer php8.3-opcache >/dev/null

# PHP-Tuning
PHP_INI=/etc/php/8.3/fpm/php.ini
sed -i 's/^memory_limit = .*/memory_limit = 256M/' "$PHP_INI"
sed -i 's/^upload_max_filesize = .*/upload_max_filesize = 50M/' "$PHP_INI"
sed -i 's/^post_max_size = .*/post_max_size = 50M/' "$PHP_INI"
sed -i 's/^max_execution_time = .*/max_execution_time = 120/' "$PHP_INI"
sed -i "s|^;date.timezone =.*|date.timezone = ${APP_TIMEZONE}|" "$PHP_INI"

systemctl enable --now php8.3-fpm >/dev/null
log "PHP 8.3 installiert."

# ── Phase 4: Composer ──────────────────────────────────────────────────────
info "Phase 4/16: Composer..."
EXPECTED_SIG=$(curl -fsSL https://composer.github.io/installer.sig)
curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
ACTUAL_SIG=$(php -r "echo hash_file('sha384', '/tmp/composer-setup.php');")
if [[ "$EXPECTED_SIG" != "$ACTUAL_SIG" ]]; then
    err "Composer-Installer-Signatur stimmt nicht."
fi
php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer --quiet
rm -f /tmp/composer-setup.php
log "Composer installiert: $(COMPOSER_ALLOW_SUPERUSER=1 composer --version --no-ansi 2>/dev/null | head -n1)"

# ── Phase 5: Nginx ─────────────────────────────────────────────────────────
info "Phase 5/16: Nginx..."
apt-get install -y -qq nginx >/dev/null

cat > /etc/nginx/sites-available/freescout.conf <<EOF
server {
    listen 80;
    server_name ${DOMAIN};
    root /var/www/freescout/public;
    index index.php index.html;

    client_max_body_size 50M;

    # Real-IP von NPMPlus (passe Trusted-Subnetz bei Bedarf an)
    set_real_ip_from 10.0.0.0/8;
    set_real_ip_from 172.16.0.0/12;
    set_real_ip_from 192.168.0.0/16;
    real_ip_header X-Forwarded-For;
    real_ip_recursive on;

    gzip on;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \\.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
        fastcgi_param HTTPS on;
        fastcgi_read_timeout 120;
    }

    location ~ /\\.(?!well-known).* {
        deny all;
    }

    # FreeScout: Storage-Symlink für public
    location ^~ /storage/ {
        alias /var/www/freescout/storage/app/public/;
        access_log off;
    }

    access_log /var/log/nginx/freescout-access.log;
    error_log  /var/log/nginx/freescout-error.log;
}
EOF

rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/freescout.conf /etc/nginx/sites-enabled/freescout.conf
nginx -t
systemctl enable --now nginx >/dev/null
systemctl reload nginx
log "Nginx konfiguriert."

# ── Phase 6: FreeScout-Files ───────────────────────────────────────────────
info "Phase 6/16: FreeScout-Files (git clone + composer)..."
mkdir -p /var/www
[[ -d /var/www/freescout ]] && rm -rf /var/www/freescout
cd /var/www
git clone -b dist https://github.com/freescout-help-desk/freescout.git freescout >/dev/null 2>&1
cd /var/www/freescout

# Ownership VOR composer setzen — sonst deaktiviert Composer alle Plugins
# (Auto-Disable als root, was FreeScout-Post-Install-Hooks bricht).
chown -R www-data:www-data /var/www/freescout

# Composer als www-data; HOME=/tmp damit composer-Cache schreibbar ist.
# Zweiphasig: erst Pakete installieren ohne Autoloader-Generierung (--no-autoloader),
# dann Stub-Verzeichnis anlegen und dump-autoload separat ausführen.
# Hintergrund: rap2hpoutre/laravel-log-viewer entfernte src/controllers/ in neuerer Version;
# FreeScout's composer.json hat "optimize-autoloader":true → ClassMapGenerator schlägt auf
# dem nicht mehr existierenden Pfad fehl. Stub-Dir löst das ohne Änderung an composer.json.
info "  composer install --no-autoloader (kann dauern)..."
if ! runuser -u www-data -- env HOME=/tmp COMPOSER_HOME=/tmp/.composer-www \
    composer install --no-dev --no-interaction --ignore-platform-reqs --no-autoloader 2>&1 | tail -20; then
    err "composer install fehlgeschlagen"
fi

# Stub-Verzeichnis für defekten Classmap-Eintrag anlegen (muss NACH composer install sein,
# da composer das vendor/-Paketverzeichnis beim Extrahieren überschreibt)
mkdir -p /var/www/freescout/vendor/rap2hpoutre/laravel-log-viewer/src/controllers

info "  composer dump-autoload..."
if ! runuser -u www-data -- env HOME=/tmp COMPOSER_HOME=/tmp/.composer-www \
    composer dump-autoload --optimize --no-scripts --no-interaction 2>&1 | tail -10; then
    warn "  dump-autoload --optimize fehlgeschlagen; fallback ohne Optimierung..."
    runuser -u www-data -- env HOME=/tmp COMPOSER_HOME=/tmp/.composer-www \
        composer dump-autoload --no-scripts --no-interaction 2>&1 | tail -10 || \
        err "dump-autoload fehlgeschlagen"
fi

# .env vorbefüllen — KEIN DB-Block, KEIN Mail-Block
cp .env.example .env
sed -i "s|^APP_URL=.*|APP_URL=https://${DOMAIN}|" .env
grep -q "^APP_TIMEZONE=" .env && sed -i "s|^APP_TIMEZONE=.*|APP_TIMEZONE=${APP_TIMEZONE}|" .env || echo "APP_TIMEZONE=${APP_TIMEZONE}" >> .env
grep -q "^APP_LOCALE=" .env && sed -i "s|^APP_LOCALE=.*|APP_LOCALE=${APP_LOCALE}|" .env || echo "APP_LOCALE=${APP_LOCALE}" >> .env
grep -q "^APP_TRUSTED_HOSTS=" .env \
    && sed -i "s|^APP_TRUSTED_HOSTS=.*|APP_TRUSTED_HOSTS='${DOMAIN}'|" .env \
    || echo "APP_TRUSTED_HOSTS='${DOMAIN}'" >> .env
chown www-data:www-data .env

# APP_KEY als www-data
runuser -u www-data -- env HOME=/tmp php artisan key:generate --force >/dev/null

chmod -R 755 /var/www/freescout/storage /var/www/freescout/bootstrap/cache
log "FreeScout-Files installiert."

# ── Phase 7: Supervisor ────────────────────────────────────────────────────
info "Phase 7/16: Supervisor (Queue-Worker)..."
cat > /etc/supervisor/conf.d/freescout-worker.conf <<EOF
[program:freescout-worker]
process_name=%(program_name)s_%(process_num)02d
command=/usr/bin/php /var/www/freescout/artisan queue:work --queue=default,emails --sleep=5 --tries=1
autostart=false
autorestart=true
user=www-data
numprocs=1
redirect_stderr=true
stdout_logfile=/var/log/freescout-worker.log
stopwaitsecs=120
EOF

systemctl enable --now supervisor >/dev/null
supervisorctl reread >/dev/null
supervisorctl update >/dev/null
log "Supervisor konfiguriert (Worker autostart=false — nach Web-Install starten)."

# ── Phase 8: Cron ──────────────────────────────────────────────────────────
info "Phase 8/16: Cron (FreeScout-Scheduler)..."
crontab -u www-data -l 2>/dev/null > /tmp/cron.www-data || true
grep -q "artisan schedule:run" /tmp/cron.www-data || \
    echo "* * * * * /usr/bin/php /var/www/freescout/artisan schedule:run >/dev/null 2>&1" >> /tmp/cron.www-data
crontab -u www-data /tmp/cron.www-data
rm -f /tmp/cron.www-data
log "Cron für www-data eingerichtet."

# ── Phase 9: rclone ────────────────────────────────────────────────────────
info "Phase 9/16: rclone (R2)..."
apt-get install -y -qq rclone >/dev/null
mkdir -p /root/.config/rclone
cat > /root/.config/rclone/rclone.conf <<EOF
[r2]
type = s3
provider = Cloudflare
access_key_id = ${R2_ACCESS_KEY}
secret_access_key = ${R2_SECRET_KEY}
endpoint = ${R2_ENDPOINT}
acl = private
EOF
chmod 600 /root/.config/rclone/rclone.conf
# Test
if rclone lsd "r2:${R2_BUCKET}" --max-depth 1 >/dev/null 2>&1; then
    log "rclone Verbindung zu r2:${R2_BUCKET} OK."
else
    warn "rclone-Test fehlgeschlagen — Credentials/Bucket prüfen (Backups ggf. später)."
fi

# ── Phase 10: Konfig-Files für Helper-Scripts ──────────────────────────────
info "Phase 10/16: /etc/freescout/* konfigurieren..."
mkdir -p /etc/freescout
chmod 700 /etc/freescout

cat > /etc/freescout/config <<EOF
# FreeScout-Setup — von Helper-Scripts gesourced
DOMAIN="${DOMAIN}"
APP_HOSTNAME="$(hostname)"
DB_NAME="${DB_NAME}"
DB_USER="${DB_USER}"
INSTALL_DIR="/var/www/freescout"
R2_BUCKET="${R2_BUCKET}"
R2_PREFIX="${R2_PREFIX}"
WEBHOOK_URL="${WEBHOOK_URL}"
EOF
chmod 600 /etc/freescout/config

cat > /etc/freescout/db-credentials.txt <<EOF
DB_HOST=127.0.0.1
DB_PORT=3306
DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
DB_PASS=${DB_PASS}
EOF
chmod 600 /etc/freescout/db-credentials.txt

# ── Phase 11: age-Setup ────────────────────────────────────────────────────
if [[ -n "$AGE_RECIPIENT" ]]; then
    info "Phase 11/16: age-Recipient..."
    echo "$AGE_RECIPIENT" > /etc/freescout/backup-recipient.txt
    chmod 600 /etc/freescout/backup-recipient.txt
    log "age-Recipient gespeichert."
else
    info "Phase 11/16: age übersprungen (nicht konfiguriert)."
fi

# ── Phase 12: OIDC-Stub ────────────────────────────────────────────────────
if [[ -n "$OIDC_ISSUER" ]]; then
    info "Phase 12/16: OIDC-Stub..."
    cat > /etc/freescout/oidc.env <<EOF
# Werte für FreeScout-OAuth/OIDC-Modul (kostenpflichtig)
# Nach Modul-Kauf: im UI unter Modules → OAuth → Configure übernehmen
OIDC_ISSUER=${OIDC_ISSUER}
OIDC_CLIENT_ID=${OIDC_CLIENT_ID}
OIDC_CLIENT_SECRET=${OIDC_CLIENT_SECRET}
OIDC_REDIRECT_URI=https://${DOMAIN}/oauth/callback
EOF
    chmod 600 /etc/freescout/oidc.env
    log "OIDC-Stub abgelegt."
else
    info "Phase 12/16: OIDC übersprungen (nicht konfiguriert)."
fi

# ── Phase 13: Fail2ban ─────────────────────────────────────────────────────
info "Phase 13/16: Fail2ban..."
cat > /etc/fail2ban/jail.d/freescout.conf <<'EOF'
[freescout-login]
enabled = true
filter = freescout-login
port = http,https
logpath = /var/log/nginx/freescout-access.log
maxretry = 5
findtime = 600
bantime = 3600
EOF

cat > /etc/fail2ban/filter.d/freescout-login.conf <<'EOF'
[Definition]
failregex = ^<HOST> .* "POST /login HTTP/.*" 4\d\d
ignoreregex =
EOF

systemctl enable --now fail2ban >/dev/null
systemctl restart fail2ban
log "Fail2ban konfiguriert."

# ── Phase 14: UFW ──────────────────────────────────────────────────────────
info "Phase 14/16: UFW..."
ufw --force reset >/dev/null
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw allow 22/tcp >/dev/null
ufw allow 80/tcp >/dev/null
ufw allow 443/tcp >/dev/null
ufw --force enable >/dev/null
log "UFW aktiv (22, 80, 443)."

# ── Phase 15: Helper-Scripts installieren ──────────────────────────────────
info "Phase 15/16: Helper-Scripts nach /usr/local/sbin/..."
REPO_BASE="https://git.janzin.net/djanzin/freescout-scripts/raw/branch/main"
for script in db-backup.sh storage-backup.sh backup-verify.sh update-freescout.sh restore.sh status.sh health-check.sh; do
    if [[ -f "$(dirname "$0")/${script}" ]]; then
        cp "$(dirname "$0")/${script}" "/usr/local/sbin/${script}"
    else
        curl -fsSL "${REPO_BASE}/${script}" -o "/usr/local/sbin/${script}" 2>/dev/null || true
    fi
    chmod +x "/usr/local/sbin/${script}" 2>/dev/null || true
done

# Backup-Crons (root)
crontab -l 2>/dev/null > /tmp/cron.root || true
grep -q "db-backup.sh"      /tmp/cron.root || echo "0 2 * * * /usr/bin/flock -n /var/lock/freescout-db-backup.lock      /usr/local/sbin/db-backup.sh" >> /tmp/cron.root
grep -q "storage-backup.sh" /tmp/cron.root || echo "0 3 * * * /usr/bin/flock -n /var/lock/freescout-storage-backup.lock /usr/local/sbin/storage-backup.sh" >> /tmp/cron.root
grep -q "backup-verify.sh"  /tmp/cron.root || echo "0 4 * * 0 /usr/local/sbin/backup-verify.sh" >> /tmp/cron.root
crontab /tmp/cron.root
rm -f /tmp/cron.root
log "Backup-Crons gesetzt."

# ── Phase 16: Permissions ──────────────────────────────────────────────────
info "Phase 16/16: Permissions..."
chown -R www-data:www-data /var/www/freescout
chmod -R 755 /var/www/freescout/storage /var/www/freescout/bootstrap/cache
log "Permissions gesetzt."

# Cleanup-Trap abschalten (Erfolg)
CLEANUP_ENABLED=false

# ── Summary ────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   FreeScout-Stack ist bereit                 ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BOLD}Web-Installer (Fresh-Install):${NC}"
echo "  → https://${DOMAIN}/install"
echo ""
echo -e "${BOLD}DB-Credentials für Web-Installer:${NC}"
echo "  Host:     127.0.0.1"
echo "  Port:     3306"
echo "  DB-Name:  ${DB_NAME}"
echo "  DB-User:  ${DB_USER}"
echo "  DB-Pass:  ${DB_PASS}"
echo "  (auch in /etc/freescout/db-credentials.txt)"
echo ""
echo -e "${BOLD}Nach Web-Install:${NC}"
echo "  supervisorctl start freescout-worker:*"
echo ""
echo -e "${BOLD}Migration aus Cloudron:${NC}"
echo "  → migrate-import.sh /root/freescout-import/"
echo "  (überspringt Web-Installer)"
echo ""
echo -e "${BOLD}NPMPlus-Proxy:${NC}"
echo "  Host: ${DOMAIN} → http://$(hostname -I | awk '{print $1}'):80"
echo "  WebSocket-Support aktivieren, X-Forwarded-Proto setzen."
echo ""
[[ -n "$OIDC_ISSUER" ]] && echo "OIDC-Stub: /etc/freescout/oidc.env (Modul kostenpflichtig — manuell aktivieren)" && echo ""
