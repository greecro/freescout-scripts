#!/bin/bash
# Erstellt einen Debian-13-LXC für FreeScout auf Proxmox.
# Ausführen auf dem Proxmox-Host als root.

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
info() { echo -e "${BLUE}[i]${NC} $1"; }

[[ $EUID -ne 0 ]] && err "Als root ausführen."
command -v pct &>/dev/null || err "pct nicht gefunden — Script muss auf dem Proxmox-Host laufen."

# ── Argument-Parser (non-interactive Mode) ─────────────────────────────────
NON_INTERACTIVE=false
ARG_CT_ID=""
ARG_HOSTNAME=""
ARG_IP=""
ARG_GATEWAY=""
ARG_STORAGE=""
ARG_CORES=""
ARG_RAM=""
ARG_DISK=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ct-id)     ARG_CT_ID="$2"; shift 2 ;;
        --hostname)  ARG_HOSTNAME="$2"; shift 2 ;;
        --ip)        ARG_IP="$2"; shift 2 ;;
        --gateway)   ARG_GATEWAY="$2"; shift 2 ;;
        --storage)   ARG_STORAGE="$2"; shift 2 ;;
        --cores)     ARG_CORES="$2"; shift 2 ;;
        --ram)       ARG_RAM="$2"; shift 2 ;;
        --disk)      ARG_DISK="$2"; shift 2 ;;
        --yes|-y)    NON_INTERACTIVE=true; shift ;;
        -h|--help)
            cat <<EOF
Usage: $0 [OPTIONS]

Erstellt einen Debian-13-LXC für FreeScout.

Optionen:
  --ct-id <id>        Container-ID (Default: nächste freie)
  --hostname <name>   Hostname (Default: freescout)
  --ip <addr/cidr>    IP-Adresse inkl. CIDR (z.B. 192.168.1.50/24)
  --gateway <ip>      Gateway-IP
  --storage <name>    Proxmox-Storage für Rootfs
  --cores <n>         vCPU-Cores (Default: 2)
  --ram <mb>          RAM in MB (Default: 2048)
  --disk <gb>         Disk-Größe in GB (Default: 20)
  --yes               Skip-Confirmation (non-interactive)
  -h, --help          Diese Hilfe
EOF
            exit 0 ;;
        *) err "Unbekannte Option: $1" ;;
    esac
done

clear
echo -e "${BOLD}"
echo "╔══════════════════════════════════════════════╗"
echo "║   Proxmox LXC erstellen — FreeScout          ║"
echo "╚══════════════════════════════════════════════╝"
echo -e "${NC}"

# ── CT-ID ──────────────────────────────────────────────────────────────────
NEXT_ID=$(pvesh get /cluster/nextid 2>/dev/null || echo "200")
if [[ -n "$ARG_CT_ID" ]]; then
    CT_ID="$ARG_CT_ID"
else
    read -rp "Container-ID [Standard: ${NEXT_ID}]: " CT_ID
    CT_ID=${CT_ID:-$NEXT_ID}
fi

if pct status "$CT_ID" &>/dev/null; then
    err "Container-ID ${CT_ID} existiert bereits."
fi

# ── Hostname ───────────────────────────────────────────────────────────────
if [[ -n "$ARG_HOSTNAME" ]]; then
    CT_HOSTNAME="$ARG_HOSTNAME"
else
    read -rp "Hostname [Standard: freescout]: " CT_HOSTNAME
    CT_HOSTNAME=${CT_HOSTNAME:-freescout}
fi
[[ ! "$CT_HOSTNAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*$ ]] && err "Ungültiger Hostname: ${CT_HOSTNAME}"

# ── Template ───────────────────────────────────────────────────────────────
info "Suche Debian-13-Template..."
TEMPLATE=$(pveam list local 2>/dev/null | awk '/debian-13/ {print $1}' | head -n1 || true)

if [[ -z "$TEMPLATE" ]]; then
    warn "Kein Debian-13-Template gefunden."
    if $NON_INTERACTIVE; then
        info "Lade Debian-13-Template automatisch..."
        DEBIAN_TEMPLATE=$(pveam available --section system | awk '/debian-13-standard/ {print $2}' | sort -r | head -n1)
        [[ -z "$DEBIAN_TEMPLATE" ]] && err "Kein Debian-13-Template im pveam-Index gefunden."
        pveam download local "$DEBIAN_TEMPLATE"
        TEMPLATE="local:vztmpl/${DEBIAN_TEMPLATE}"
    else
        read -rp "Debian-13-Template jetzt herunterladen? [j/N]: " dl
        if [[ "$dl" == "j" || "$dl" == "J" ]]; then
            DEBIAN_TEMPLATE=$(pveam available --section system | awk '/debian-13-standard/ {print $2}' | sort -r | head -n1)
            [[ -z "$DEBIAN_TEMPLATE" ]] && err "Kein Debian-13-Template im pveam-Index gefunden."
            pveam download local "$DEBIAN_TEMPLATE"
            TEMPLATE="local:vztmpl/${DEBIAN_TEMPLATE}"
        else
            err "Template benötigt — bitte vorher 'pveam download local debian-13-...' ausführen."
        fi
    fi
fi
log "Template: ${TEMPLATE}"

# ── Storage ────────────────────────────────────────────────────────────────
if [[ -n "$ARG_STORAGE" ]]; then
    CT_STORAGE="$ARG_STORAGE"
else
    echo ""
    echo "Verfügbare Storages für Rootfs:"
    pvesm status -content rootdir 2>/dev/null | awk 'NR>1 {printf "  %s (%s)\n", $1, $2}'
    DEFAULT_STORAGE=$(pvesm status -content rootdir 2>/dev/null | awk 'NR==2 {print $1}')
    read -rp "Storage [Standard: ${DEFAULT_STORAGE}]: " CT_STORAGE
    CT_STORAGE=${CT_STORAGE:-$DEFAULT_STORAGE}
fi
[[ -z "$CT_STORAGE" ]] && err "Storage darf nicht leer sein."

# ── Resources ──────────────────────────────────────────────────────────────
if [[ -z "$ARG_CORES" ]]; then
    read -rp "vCPU-Cores [Standard: 2]: " CT_CORES
    CT_CORES=${CT_CORES:-2}
else
    CT_CORES="$ARG_CORES"
fi

if [[ -z "$ARG_RAM" ]]; then
    read -rp "RAM in MB [Standard: 2048]: " CT_RAM
    CT_RAM=${CT_RAM:-2048}
else
    CT_RAM="$ARG_RAM"
fi

read -rp "Swap in MB [Standard: 512]: " CT_SWAP
CT_SWAP=${CT_SWAP:-512}

if [[ -z "$ARG_DISK" ]]; then
    read -rp "Disk-Größe in GB [Standard: 20]: " CT_DISK
    CT_DISK=${CT_DISK:-20}
else
    CT_DISK="$ARG_DISK"
fi

# ── Network ────────────────────────────────────────────────────────────────
echo ""
if [[ -n "$ARG_IP" ]]; then
    CT_IP_CIDR="$ARG_IP"
else
    read -rp "IP-Adresse inkl. CIDR (z.B. 192.168.1.50/24): " CT_IP_CIDR
fi
[[ ! "$CT_IP_CIDR" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]] && err "Ungültige IP/CIDR: ${CT_IP_CIDR}"

if [[ -n "$ARG_GATEWAY" ]]; then
    CT_GW="$ARG_GATEWAY"
else
    read -rp "Gateway (z.B. 192.168.1.1): " CT_GW
fi
[[ ! "$CT_GW" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && err "Ungültiges Gateway: ${CT_GW}"

read -rp "DNS-Server [Standard: 1.1.1.1]: " CT_DNS
CT_DNS=${CT_DNS:-1.1.1.1}

read -rp "Netzwerk-Bridge [Standard: vmbr0]: " CT_BRIDGE
CT_BRIDGE=${CT_BRIDGE:-vmbr0}

# ── SSH-Key ────────────────────────────────────────────────────────────────
DEFAULT_SSH_KEY="/root/.ssh/authorized_keys"
read -rp "SSH-Pubkey-Datei [Standard: ${DEFAULT_SSH_KEY}, '-' = ohne SSH-Key]: " SSH_KEY_FILE
SSH_KEY_FILE=${SSH_KEY_FILE:-$DEFAULT_SSH_KEY}

if [[ "$SSH_KEY_FILE" == "-" ]]; then
    SSH_KEY_FILE=""
    warn "Kein SSH-Key — Login nur via root-Passwort (siehe Ende)."
elif [[ ! -f "$SSH_KEY_FILE" ]]; then
    warn "SSH-Key-Datei nicht gefunden: ${SSH_KEY_FILE}"
    read -rp "Anderen Pfad eingeben oder leer für 'ohne SSH-Key': " ALT_KEY
    if [[ -z "$ALT_KEY" ]]; then
        SSH_KEY_FILE=""
        warn "Kein SSH-Key — Login nur via root-Passwort."
    else
        SSH_KEY_FILE="$ALT_KEY"
        [[ ! -f "$SSH_KEY_FILE" ]] && err "Datei nicht gefunden: ${SSH_KEY_FILE}"
    fi
fi

# ── Root-Passwort ──────────────────────────────────────────────────────────
# head-first verhindert SIGPIPE auf tr (würde mit pipefail das Script killen)
ROOT_PW=$(head -c 256 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | head -c 20)
[[ ${#ROOT_PW} -lt 16 ]] && err "Konnte kein Passwort generieren (urandom?)."

# ── Summary ────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}Zusammenfassung:${NC}"
echo "  Container-ID:   ${CT_ID}"
echo "  Hostname:       ${CT_HOSTNAME}"
echo "  Template:       ${TEMPLATE}"
echo "  Storage:        ${CT_STORAGE}"
echo "  Resources:      ${CT_CORES} vCPU, ${CT_RAM} MB RAM, ${CT_SWAP} MB Swap, ${CT_DISK} GB Disk"
echo "  Network:        ${CT_IP_CIDR}  GW ${CT_GW}  DNS ${CT_DNS}  Bridge ${CT_BRIDGE}"
echo "  SSH-Key:        ${SSH_KEY_FILE}"
echo ""

if ! $NON_INTERACTIVE; then
    read -rp "Erstellen? [j/N]: " confirm
    [[ "$confirm" != "j" && "$confirm" != "J" ]] && err "Abgebrochen."
fi

# ── Container erstellen ────────────────────────────────────────────────────
info "Erstelle Container..."
PCT_ARGS=(
    --hostname "$CT_HOSTNAME"
    --cores "$CT_CORES"
    --memory "$CT_RAM"
    --swap "$CT_SWAP"
    --rootfs "${CT_STORAGE}:${CT_DISK}"
    --net0 "name=eth0,bridge=${CT_BRIDGE},ip=${CT_IP_CIDR},gw=${CT_GW}"
    --nameserver "$CT_DNS"
    --password "$ROOT_PW"
    --features "nesting=1"
    --unprivileged 1
    --onboot 1
    --start 1
)
[[ -n "$SSH_KEY_FILE" ]] && PCT_ARGS+=( --ssh-public-keys "$SSH_KEY_FILE" )

pct create "$CT_ID" "$TEMPLATE" "${PCT_ARGS[@]}" >/dev/null

log "Container ${CT_ID} erstellt."

# ── Auf SSH warten ─────────────────────────────────────────────────────────
CT_IP=${CT_IP_CIDR%/*}
info "Warte auf SSH (${CT_IP}:22)..."
for i in $(seq 1 24); do
    if timeout 2 bash -c "</dev/tcp/${CT_IP}/22" 2>/dev/null; then
        log "SSH erreichbar."
        break
    fi
    sleep 5
    if [[ $i -eq 24 ]]; then
        warn "SSH nach 120 s nicht erreichbar — Container läuft aber, prüfe manuell."
    fi
done

# ── curl + ca-certificates vorinstallieren ─────────────────────────────────
info "Installiere curl im Container (Debian-Minimal hat kein curl)..."
if pct exec "$CT_ID" -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl ca-certificates" >/dev/null 2>&1; then
    log "curl installiert."
else
    warn "curl-Install fehlgeschlagen — manuell im LXC nachholen: apt-get install -y curl"
fi

# ── Fertig ─────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   Fertig                                     ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Connect:${NC}     ssh root@${CT_IP}"
echo -e "  ${BOLD}Root-PW:${NC}     ${ROOT_PW}"
echo ""
echo -e "  ${BOLD}Nächster Schritt:${NC}"
echo "    ssh root@${CT_IP}"
echo "    curl -sO https://git.janzin.net/djanzin/freescout-scripts/raw/branch/main/setup-freescout.sh"
echo "    bash setup-freescout.sh"
echo ""
