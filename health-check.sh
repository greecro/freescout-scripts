#!/bin/bash
# Health-Check: HTTP, DB, Queue-Worker, Cron. Webhook bei Fehler.

set -euo pipefail

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()  { echo -e "${GREEN}[✓]${NC} $1"; }
nok() { echo -e "${RED}[✗]${NC} $1"; ERRORS+=("$1"); }
warn(){ echo -e "${YELLOW}[!]${NC} $1"; }

ERRORS=()

[[ -f /etc/freescout/config ]] || { echo "/etc/freescout/config fehlt."; exit 1; }
# shellcheck source=/dev/null
source /etc/freescout/config
DB_PASS=$(grep '^DB_PASS=' /etc/freescout/db-credentials.txt | cut -d= -f2-)

LXC_IP=$(hostname -I | awk '{print $1}')

# ── HTTP ───────────────────────────────────────────────────────────────────
HTTP_LOGIN=$(curl -sk -o /dev/null -w "%{http_code}" "http://${LXC_IP}/login" || echo "000")
case "$HTTP_LOGIN" in
    200|302) ok "HTTP /login: ${HTTP_LOGIN}" ;;
    *)       nok "HTTP /login: ${HTTP_LOGIN}" ;;
esac

# ── DB ─────────────────────────────────────────────────────────────────────
if mariadb -u"${DB_USER}" -p"${DB_PASS}" -e "SELECT 1 FROM \`${DB_NAME}\`.users LIMIT 1;" &>/dev/null; then
    ok "DB-Connection OK"
else
    # users-Tabelle existiert evtl. noch nicht (Fresh-Install) — try minimal
    if mariadb -u"${DB_USER}" -p"${DB_PASS}" -e "USE \`${DB_NAME}\`;" &>/dev/null; then
        warn "DB erreichbar, users-Tabelle fehlt (Web-Installer noch ausstehend?)"
    else
        nok "DB nicht erreichbar"
    fi
fi

# ── Queue-Worker ───────────────────────────────────────────────────────────
if supervisorctl status freescout-worker:* 2>/dev/null | grep -q RUNNING; then
    ok "Queue-Worker läuft"
else
    nok "Queue-Worker läuft NICHT"
fi

# ── Cron ───────────────────────────────────────────────────────────────────
if crontab -u www-data -l 2>/dev/null | grep -q "schedule:run"; then
    ok "Crontab für www-data OK"
else
    nok "Crontab fehlt"
fi

# ── Failed Jobs ────────────────────────────────────────────────────────────
FAILED=$(mariadb -u"${DB_USER}" -p"${DB_PASS}" -N -e "SELECT COUNT(*) FROM \`${DB_NAME}\`.failed_jobs;" 2>/dev/null || echo "0")
if [[ "$FAILED" -gt 0 ]]; then
    warn "Failed Jobs in DB: ${FAILED} (Manage → System → Logs prüfen)"
fi

# ── Slack-Alert bei Fehler ─────────────────────────────────────────────────
if [[ "${#ERRORS[@]}" -gt 0 ]] && [[ -n "${SLACK_WEBHOOK_URL:-}" ]]; then
    # Fehlertexte JSON-safe machen (Quotes/Newlines raus)
    MSG="$(IFS='; '; echo "${ERRORS[*]}" | tr '\n' ' ' | sed 's/"/'"'"'/g')"
    curl -fsS -X POST -H 'Content-type: application/json' \
        --data "{\"text\": \"🔴 FreeScout Health-Check auf ${APP_HOSTNAME:-?}: ${MSG}\"}" \
        "$SLACK_WEBHOOK_URL" >/dev/null || true
fi

exit "${#ERRORS[@]}"
