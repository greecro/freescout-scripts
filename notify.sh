#!/bin/bash
# Zentrale Benachrichtigung für die FreeScout-Helper-Scripts. Wird von den
# Scripts gesourct (nicht direkt ausgeführt) und stellt notify() + den
# healthchecks.io Dead-Man's-Switch (hc_start/hc_report) bereit.
#
# notify() postet NUR bei Fehlern nach Slack. Die Incoming-Webhook-URL kommt aus
# SLACK_WEBHOOK_URL (in /etc/freescout/config, das die Scripts bereits sourcen);
# fehlt sie, ist notify() ein No-Op — die Scripts laufen unverändert weiter.
#
# hc_start/hc_report = Dead-Man's-Switch: schlägt Alarm, wenn ein Job gar nicht
# mehr läuft (Cron kaputt, CT down, Abbruch vor dem Ende) — die Lücke, die die
# reinen Fehler-Alerts von notify() nicht abdecken. Ping-URLs (Secret) liegen in
# /etc/freescout/healthchecks.env (chmod 600), eine Variable je Job. Verwendung:
#
#     hc_start "${HC_URL_DB_BACKUP:-}"    # /start-Ping, merkt sich die URL
#     trap 'hc_report $?' EXIT            # success (rc 0) bzw. /fail am Ende
#
# hc_report läuft im EXIT-Trap und deckt damit auch vorzeitige exits ab. Fehlt
# Datei/URL, sind beide No-Ops. curl schluckt eigene Fehler (--retry, || true),
# damit ein Ping-Ausfall das Script (set -e) nie abbricht.

# notify <titel> <details> — Slack-POST, nur im Fehlerfall aufrufen.
notify() {
    local title="${1:-FreeScout}" body="${2:-}"
    [[ -n "${SLACK_WEBHOOK_URL:-}" ]] || return 0
    local text payload
    text=":rotating_light: *${title}* auf \`$(hostname)\`"$'\n'"${body}"
    if command -v jq >/dev/null 2>&1; then
        payload=$(jq -nc --arg t "$text" '{text: $t}') || return 0
    else
        # Fallback ohne jq: Quotes/Newlines JSON-safe machen
        local safe; safe=$(printf '%s' "$text" | tr '\n' ' ' | sed 's/"/'"'"'/g')
        payload="{\"text\": \"${safe}\"}"
    fi
    curl -fsS --max-time 15 -X POST -H 'Content-Type: application/json' \
        --data "$payload" "$SLACK_WEBHOOK_URL" >/dev/null 2>&1 || true
    return 0
}

# ── healthchecks.io Dead-Man's-Switch ──────────────────────────────────────
HC_ENV_FILE="${HC_ENV_FILE:-/etc/freescout/healthchecks.env}"
[[ -r "$HC_ENV_FILE" ]] && source "$HC_ENV_FILE"

_HC_URL=""

# hc_start <check-url> — /start-Ping, merkt sich die URL für hc_report.
hc_start() {
    _HC_URL="${1:-}"
    [[ -n "$_HC_URL" ]] || return 0
    curl -fsS --max-time 10 --retry 2 -o /dev/null "${_HC_URL}/start" >/dev/null 2>&1 || true
    return 0
}

# hc_report <exit-code> — success bei 0, sonst /fail. Für den EXIT-Trap.
hc_report() {
    [[ -n "$_HC_URL" ]] || return 0
    local rc="${1:-0}" suffix=""
    [[ "$rc" -ne 0 ]] && suffix="/fail"
    curl -fsS --max-time 10 --retry 2 -o /dev/null "${_HC_URL}${suffix}" >/dev/null 2>&1 || true
    return 0
}
