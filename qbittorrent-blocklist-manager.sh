#!/usr/bin/env bash
# ============================================================
# qbittorrent-blocklist-manager.sh
# Gestione completa del filtro IP per qBittorrent
# Versione: 3.0.4
#
# FIX 3.0.4: eliminati i pattern "condizione && azione" come ultimi
# comandi di funzioni/loop che, con set -e, causavano un'uscita
# silenziosa in write_config (il motivo per cui l'installazione
# moriva dopo il wizard senza creare config, updater e cron).
# FIX: conteggio righe con grep -c che restituiva doppio "0".
# ============================================================

set -euo pipefail
trap 'echo "" >&2; echo "❌ ERRORE alla riga $LINENO: operazione interrotta." >&2; exit 1' ERR

VERSION="3.0.4"
REMOTE_URL="https://raw.githubusercontent.com/xunil89/qbittorrent-blocklist-manager/refs/heads/main/qbittorrent-blocklist-manager.sh"
INSTALL_DIR="/usr/local/bin"

MANAGER_NAME="qbittorrent-blocklist-manager"
LIST_APP="qbittorrent-blocklist-list-update"
CHECK_APP="qbittorrent-blocklist-script-check"
MANAGER_PATH="${INSTALL_DIR}/${MANAGER_NAME}.sh"
LIST_SCRIPT="${INSTALL_DIR}/${LIST_APP}.sh"
CHECK_SCRIPT="${INSTALL_DIR}/${CHECK_APP}.sh"

CRON_TAG_LIST="# ${LIST_APP}"
CRON_TAG_CHECK="# ${CHECK_APP}"
CRON_SCHEDULE="0 * * * *"

if [[ -n "${SUDO_USER:-}" ]]; then
    REAL_USER="${SUDO_USER}"
    REAL_HOME="$(getent passwd "${SUDO_USER}" | cut -d: -f6)"
else
    REAL_USER="${USER:-$(id -un)}"
    REAL_HOME="${HOME}"
fi

CONFIG_DIR="${REAL_HOME}/.config/qBittorrent"
BLOCKLIST_DIR="${CONFIG_DIR}/blocklists"
OUTPUT_FILE="${CONFIG_DIR}/ipfilter.dat"
META_FILE="${CONFIG_DIR}/.blocklist-meta"
CONF_FILE="${CONFIG_DIR}/blocklist.conf"
STATE_FILE="${CONFIG_DIR}/.blocklist-state"
SCRIPT_STATE_FILE="${CONFIG_DIR}/.blocklist-script-state"
LOG_FILE="${CONFIG_DIR}/blocklist.log"

DEFAULT_BLOCKLISTS=(
    "https://raw.githubusercontent.com/Naunter/BT_BlockLists/master/bt_blocklists.gz|Naunter BT Blocklists"
    "https://www.biglybt.com/blocklist/level1.gz|BiglyBT Level1"
    "https://github.com/ttgapers/transmission-blocklist/releases/latest/download/blocklist.gz|Transmission Blocklist"
    "https://blocklistproject.github.io/Lists/torrent.txt|BlocklistProject Torrent"
    "https://raw.githubusercontent.com/firehol/blocklist-ipsets/master/firehol_level1.netset|FireHOL Level1"
    "https://raw.githubusercontent.com/firehol/blocklist-ipsets/master/firehol_level2.netset|FireHOL Level2"
    "https://www.spamhaus.org/drop/drop.txt|Spamhaus DROP"
    "https://www.spamhaus.org/drop/edrop.txt|Spamhaus EDROP"
    "https://isc.sans.edu/feeds/block.txt|DShield SANS"
    "https://feodotracker.abuse.ch/downloads/ipblocklist.txt|Abuse.ch Feodo"
    "https://feodotracker.abuse.ch/downloads/ipblocklist_recommended.txt|Abuse.ch Feodo Recommended"
    "https://sslbl.abuse.ch/blacklist/sslipblacklist.txt|Abuse.ch SSLBL"
    "https://urlhaus.abuse.ch/downloads/text/|Abuse.ch URLhaus"
    "http://rules.emergingthreats.net/blockrules/compromised-ips.txt|Emerging Threats"
    "https://www.team-cymru.com/Services/Bogons/fullbogons-ipv4.txt|Team Cymru Bogons"
    "http://www.ipdeny.com/ipblocks/data/countries/cn.zone|IPDeny China"
    "http://www.ipdeny.com/ipblocks/data/countries/ru.zone|IPDeny Russia"
    "http://www.ipdeny.com/ipblocks/data/countries/ir.zone|IPDeny Iran"
    "http://www.ipdeny.com/ipblocks/data/countries/kp.zone|IPDeny North Korea"
)

ask() {
    local prompt="$1" answer
    if [[ -t 0 ]]; then
        read -rp "$prompt" answer
    else
        read -rp "$prompt" answer < /dev/tty
    fi
    echo "$answer"
}

generate_topic() {
    local adjectives=(crimson silent frozen dark swift iron ghost neon vivid amber cobalt ember frost lunar onyx pixel quartz raven solar void)
    local animals=(otter falcon wolf heron lynx mantis cobra badger shark viper moose crane wren stoat puma moth newt vole crow fox)
    local adj="${adjectives[$((RANDOM % ${#adjectives[@]}))]}"
    local ani="${animals[$((RANDOM % ${#animals[@]}))]}"
    local num=$((RANDOM % 9000 + 1000))
    echo "${adj}-${ani}-${num}"
}

check_deps() {
    local missing=()
    local cmd
    for cmd in curl flock python3 crontab sha256sum getent; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "❌ Dipendenze mancanti: ${missing[*]}"
        echo "   Installale con il gestore pacchetti della tua distribuzione e riprova."
        exit 1
    fi
    return 0
}

version_compare() {
    local v1="$1" v2="$2"
    if [[ "$v1" == "$v2" ]]; then CMP_RESULT="same"; return 0; fi
    local IFS='.'
    local -a a1=($v1) a2=($v2)
    local i
    for i in 0 1 2; do
        local n1="${a1[$i]:-0}" n2="${a2[$i]:-0}"
        if (( n1 > n2 )); then CMP_RESULT="newer"; return 0; fi
        if (( n1 < n2 )); then CMP_RESULT="older"; return 0; fi
    done
    CMP_RESULT="same"
    return 0
}

sudox() {
    if ! sudo "$@"; then
        echo "❌ Comando sudo fallito: sudo $*"
        echo "   Serve una password o permessi adeguati per scrivere in ${INSTALL_DIR}."
        exit 1
    fi
}

running_installed_manager() {
    if [[ ! -f "$0" || ! -r "$0" ]]; then return 1; fi
    local resolved
    resolved="$(readlink -f "$0")" || return 1
    if [[ "$resolved" == "$(readlink -f "$MANAGER_PATH")" ]]; then return 0; fi
    return 1
}

SRC_FILE=""

resolve_source() {
    if running_installed_manager; then
        SRC_FILE="$MANAGER_PATH"
        echo "→ Stai eseguendo il manager installato: nessuna copia necessaria."
        return 0
    fi

    if [[ -f "$0" && -r "$0" && ! "$0" =~ ^(bash|-bash|/bin/bash|/usr/bin/bash)$ ]]; then
        SRC_FILE="$(readlink -f "$0")"
        echo "→ Sorgente: ${SRC_FILE}"
        return 0
    fi

    echo "→ Esecuzione da pipe: scarico la versione remota..."
    local tmpfile remote_version
    tmpfile=$(mktemp)
    if ! curl -fsSL --connect-timeout 15 --max-time 60 -o "$tmpfile" "$REMOTE_URL"; then
        rm -f "$tmpfile"
        echo "❌ Download fallito: $REMOTE_URL"
        echo "   Alternativa: scarica lo script con 'curl -o' e lancialo con 'bash script.sh install'."
        exit 1
    fi
    if ! head -1 "$tmpfile" | grep -q "bash"; then
        rm -f "$tmpfile"
        echo "❌ Il file remoto non è uno script bash valido."
        exit 1
    fi
    remote_version=$(grep -m1 '^VERSION=' "$tmpfile" | cut -d= -f2 | tr -d '"' || true)
    if [[ -z "$remote_version" ]]; then
        rm -f "$tmpfile"
        echo "❌ Il file remoto non contiene un numero di versione valido."
        echo "   Probabilmente il repository non è aggiornato: scarica lo script manualmente."
        exit 1
    fi
    echo "   Versione remota: v${remote_version} (eseguita: v${VERSION})"
    version_compare "$remote_version" "$VERSION"
    if [[ "$CMP_RESULT" == "older" ]]; then
        rm -f "$tmpfile"
        echo "❌ ATTENZIONE: il repository contiene una versione PIÙ VECCHIA (v${remote_version}) di quella eseguita (v${VERSION})."
        echo "   Installazione annullata per non sovrascrivere con codice obsoleto."
        exit 1
    fi
    SRC_FILE="$tmpfile"
    return 0
}

install_manager() {
    if [[ -n "$SRC_FILE" && "$(readlink -f "$SRC_FILE")" == "$(readlink -f "$MANAGER_PATH")" ]]; then
        echo "  ✓ Manager già presente in $MANAGER_PATH (versione corrente)"
        return 0
    fi

    echo "→ Copia del manager in ${MANAGER_PATH}..."
    sudox mkdir -p "$INSTALL_DIR"
    sudox cp "$SRC_FILE" "$MANAGER_PATH"
    sudox chmod 755 "$MANAGER_PATH"
    if [[ ! -f "$MANAGER_PATH" ]]; then
        echo "❌ Il manager NON è stato copiato: $MANAGER_PATH"
        exit 1
    fi
    echo "  ✓ Manager installato: $MANAGER_PATH"
    return 0
}

set_config_defaults() {
    NTFY_URL="https://ntfy.sh"
    NTFY_TOPIC="${1:-}"
    NTFY_PRIORITY=3
    NOTIFY_MODE="changes"
    NOTIFY_SCRIPT_UPDATE="yes"
    LIST_UPDATE_INTERVAL=24
    SCRIPT_UPDATE_INTERVAL=48
    declare -gA BLOCK_STATE=()
    local entry
    for entry in "${DEFAULT_BLOCKLISTS[@]}"; do
        BLOCK_STATE["${entry%%|*}"]=1
    done
    declare -ga CUSTOM_BLOCKLISTS=()
    return 0
}

ensure_custom_array() {
    if [[ -z "${CUSTOM_BLOCKLISTS+x}" ]]; then
        declare -ga CUSTOM_BLOCKLISTS=()
    fi
    return 0
}

load_config() {
    if [[ ! -f "$CONF_FILE" ]]; then
        echo "❌ Config non trovata: $CONF_FILE"
        echo "   Esegui prima: ${MANAGER_NAME} install"
        exit 1
    fi
    # shellcheck disable=SC1090
    source "$CONF_FILE"
    if [[ "${#BLOCK_STATE[@]}" -eq 0 ]]; then
        set_config_defaults "${NTFY_TOPIC:-}"
    fi
    ensure_custom_array
    declare -ga BLOCKLISTS=()
    return 0
}

build_active_blocklists() {
    BLOCKLISTS=()
    local entry url
    for entry in "${DEFAULT_BLOCKLISTS[@]}"; do
        url="${entry%%|*}"
        if [[ "${BLOCK_STATE[$url]:-0}" == "1" ]]; then
            BLOCKLISTS+=("$entry")
        fi
    done
    if [[ "${#CUSTOM_BLOCKLISTS[@]}" -gt 0 ]]; then
        for entry in "${CUSTOM_BLOCKLISTS[@]}"; do
            if [[ -n "$entry" ]]; then
                BLOCKLISTS+=("$entry")
            fi
        done
    fi
    return 0
}

write_config() {
    build_active_blocklists
    {
        echo "# qbittorrent-blocklist-manager - file di configurazione"
        echo "NTFY_URL=\"${NTFY_URL}\""
        echo "NTFY_TOPIC=\"${NTFY_TOPIC}\""
        echo "NTFY_PRIORITY=${NTFY_PRIORITY}"
        echo "NOTIFY_MODE=\"${NOTIFY_MODE}\""
        echo "NOTIFY_SCRIPT_UPDATE=\"${NOTIFY_SCRIPT_UPDATE}\""
        echo "LIST_UPDATE_INTERVAL=${LIST_UPDATE_INTERVAL}"
        echo "SCRIPT_UPDATE_INTERVAL=${SCRIPT_UPDATE_INTERVAL}"
        echo "declare -A BLOCK_STATE=("
        local entry url
        for entry in "${DEFAULT_BLOCKLISTS[@]}"; do
            url="${entry%%|*}"
            echo "    [\"${url}\"]=\"${BLOCK_STATE[$url]:-0}\""
        done
        echo ")"
        echo "declare -ga CUSTOM_BLOCKLISTS=("
        if [[ "${#CUSTOM_BLOCKLISTS[@]}" -gt 0 ]]; then
            for entry in "${CUSTOM_BLOCKLISTS[@]}"; do
                if [[ -n "$entry" ]]; then
                    printf '    "%s"\n' "$entry"
                fi
            done
        fi
        echo ")"
        echo "# --- array attivo generato (non modificare) ---"
        echo "ACTIVE_BLOCKLISTS=("
        if [[ "${#BLOCKLISTS[@]}" -gt 0 ]]; then
            for entry in "${BLOCKLISTS[@]}"; do
                printf '    "%s"\n' "$entry"
            done
        fi
        echo ")"
    } > "$CONF_FILE"
    if [[ ! -s "$CONF_FILE" ]]; then
        echo "❌ Config non scritta: $CONF_FILE"
        exit 1
    fi
    echo "  ✓ Config salvata: $CONF_FILE"
    return 0
}

wizard_notify_mode() {
    echo ""
    echo "┌─ Notifiche ────────────────────────────────┐"
    echo "│ Cosa notificare?                           │"
    echo "│  1) tutto            → ogni aggiornamento  │"
    echo "│  2) cambi di stato   → liste cambiate,     │"
    echo "│                        fallite, aggiorn.   │"
    echo "│  3) solo errori      → solo liste fallite  │"
    echo "└────────────────────────────────────────────┘"
    local sel; sel=$(ask "Scelta [2]: ")
    case "$sel" in
        1) NOTIFY_MODE="all" ;;
        3) NOTIFY_MODE="errors" ;;
        *) NOTIFY_MODE="changes" ;;
    esac
    echo "  → Modalità notifiche: $NOTIFY_MODE"

    local prio; prio=$(ask "Priorità ntfy 1-5 (1=min, 5=max/urgente) [${NTFY_PRIORITY}]: ")
    if [[ "$prio" =~ ^[1-5]$ ]]; then NTFY_PRIORITY="$prio"; fi
    echo "  → Priorità: $NTFY_PRIORITY"
    return 0
}

wizard_script_update_notify() {
    echo ""
    echo "Notificare quando è disponibile un aggiornamento dello script?"
    local sel; sel=$(ask "  [S/n]: ")
    if [[ "$sel" =~ ^[Nn]$ ]]; then
        NOTIFY_SCRIPT_UPDATE="no"
    else
        NOTIFY_SCRIPT_UPDATE="yes"
    fi
    echo "  → Notifica aggiornamento script: $NOTIFY_SCRIPT_UPDATE"
    return 0
}

wizard_intervals() {
    echo ""
    echo "┌─ Intervalli (ore) ─────────────────────────┐"
    echo "│ Lascia vuoto per mantenere il valore.      │"
    echo "└────────────────────────────────────────────┘"
    local in_l in_s
    in_l=$(ask "  Aggiornamento liste [${LIST_UPDATE_INTERVAL}h]: ")
    if [[ -n "$in_l" ]]; then
        if [[ "$in_l" =~ ^[0-9]+$ ]] && (( in_l >= 1 )); then
            LIST_UPDATE_INTERVAL="$in_l"
        else
            echo "  Valore non valido, mantengo ${LIST_UPDATE_INTERVAL}h"
        fi
    fi
    in_s=$(ask "  Controllo aggiornamenti script [${SCRIPT_UPDATE_INTERVAL}h]: ")
    if [[ -n "$in_s" ]]; then
        if [[ "$in_s" =~ ^[0-9]+$ ]] && (( in_s >= 1 )); then
            SCRIPT_UPDATE_INTERVAL="$in_s"
        else
            echo "  Valore non valido, mantengo ${SCRIPT_UPDATE_INTERVAL}h"
        fi
    fi
    echo "  → Liste ogni ${LIST_UPDATE_INTERVAL}h, script ogni ${SCRIPT_UPDATE_INTERVAL}h"
    return 0
}

wizard_toggle_lists() {
    local i entry url name mark sel num
    while true; do
        echo ""
        echo "┌─ Liste predefinite ────────────────────────┐"
        echo "│ Digita uno o più numeri per ATTIVARE/      │"
        echo "│ DISATTIVARE (es: 1 5 7).                   │"
        echo "│ 'a' = tutte, 'n' = nessuna, 'k' = conferma │"
        echo "└────────────────────────────────────────────┘"
        i=1
        for entry in "${DEFAULT_BLOCKLISTS[@]}"; do
            url="${entry%%|*}"; name="${entry##*|}"
            mark=" "
            if [[ "${BLOCK_STATE[$url]:-0}" == "1" ]]; then mark="x"; fi
            printf "  [%s] %2d) %s\n" "$mark" "$i" "$name"
            i=$((i+1))
        done
        sel=$(ask "Selezione [k]: ")
        if [[ -z "$sel" || "$sel" == "k" ]]; then
            echo "  → Checklist confermata"
            return 0
        elif [[ "$sel" == "a" ]]; then
            for entry in "${DEFAULT_BLOCKLISTS[@]}"; do BLOCK_STATE["${entry%%|*}"]=1; done
        elif [[ "$sel" == "n" ]]; then
            for entry in "${DEFAULT_BLOCKLISTS[@]}"; do BLOCK_STATE["${entry%%|*}"]=0; done
        else
            for num in $sel; do
                if [[ "$num" =~ ^[0-9]+$ ]] && (( num >= 1 && num <= ${#DEFAULT_BLOCKLISTS[@]} )); then
                    entry="${DEFAULT_BLOCKLISTS[$((num-1))]}"
                    url="${entry%%|*}"
                    if [[ "${BLOCK_STATE[$url]:-0}" == "1" ]]; then
                        BLOCK_STATE["$url"]=0
                    else
                        BLOCK_STATE["$url"]=1
                    fi
                fi
            done
        fi
    done
}

wizard_custom_lists() {
    local i entry url name sel test tmp size keep
    while true; do
        echo ""
        echo "┌─ Liste personalizzate ─────────────────────┐"
        echo "│  1) Aggiungi lista                         │"
        echo "│  2) Rimuovi lista                          │"
        echo "│  k) Torna al menu                          │"
        echo "└────────────────────────────────────────────┘"
        if [[ "${#CUSTOM_BLOCKLISTS[@]}" -gt 0 ]]; then
            i=1
            for entry in "${CUSTOM_BLOCKLISTS[@]}"; do
                if [[ -n "$entry" ]]; then
                    echo "   $i) ${entry##*|}"
                    i=$((i+1))
                fi
            done
        else
            echo "   (nessuna lista personalizzata)"
        fi
        sel=$(ask "Scelta [k]: ")
        case "$sel" in
            1)
                url=$(ask "  URL lista (vuoto per annullare): ")
                if [[ -z "$url" ]]; then continue; fi
                name=$(ask "  Nome descrittivo: ")
                if [[ -z "$name" ]]; then name="$url"; fi
                test=$(ask "  Testare il download? [S/n]: ")
                if [[ ! "$test" =~ ^[Nn]$ ]]; then
                    tmp=$(mktemp)
                    if curl -fsSL --connect-timeout 20 --max-time 60 -o "$tmp" "$url" 2>/dev/null; then
                        size=$(wc -c < "$tmp"); echo "    ✓ OK (${size} byte)"
                    else
                        echo "    ⚠️  Download fallito, la lista potrebbe non funzionare"
                    fi
                    rm -f "$tmp"
                fi
                CUSTOM_BLOCKLISTS+=("${url}|${name}")
                echo "    ✓ Aggiunta: $name"
                ;;
            2)
                if [[ "${#CUSTOM_BLOCKLISTS[@]}" -eq 0 ]]; then
                    echo "  Nessuna lista da rimuovere"
                    continue
                fi
                sel=$(ask "  Numero della lista da rimuovere (vuoto per annullare): ")
                if [[ -z "$sel" ]]; then continue; fi
                if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#CUSTOM_BLOCKLISTS[@]} )); then
                    local -a kept=()
                    i=1
                    for entry in "${CUSTOM_BLOCKLISTS[@]}"; do
                        if (( i != sel )) && [[ -n "$entry" ]]; then
                            kept+=("$entry")
                        fi
                        i=$((i+1))
                    done
                    if [[ "${#kept[@]}" -gt 0 ]]; then
                        CUSTOM_BLOCKLISTS=("${kept[@]}")
                    else
                        CUSTOM_BLOCKLISTS=()
                    fi
                    echo "  ✓ Rimossa"
                else
                    echo "  Numero non valido"
                fi
                ;;
            *) return 0 ;;
        esac
    done
}

run_wizard() {
    echo ""
    echo "╔══════════════════════════════════════════════════╗"
    echo "║   Configurazione                                 ║"
    echo "╚══════════════════════════════════════════════════╝"
    wizard_notify_mode
    wizard_script_update_notify
    wizard_intervals
    wizard_toggle_lists
    wizard_custom_lists
    return 0
}

run_settings_menu() {
    local sel
    while true; do
        echo ""
        echo "╔══════════════════════════════════════════════════╗"
        echo "║   Impostazioni                                   ║"
        echo "╚══════════════════════════════════════════════════╝"
        echo "  1) Notifiche (modalità: ${NOTIFY_MODE}, priorità: ${NTFY_PRIORITY})"
        echo "  2) Notifica aggiornamenti script: ${NOTIFY_SCRIPT_UPDATE}"
        echo "  3) Intervalli (liste: ${LIST_UPDATE_INTERVAL}h, script: ${SCRIPT_UPDATE_INTERVAL}h)"
        echo "  4) Liste predefinite (checklist)"
        echo "  5) Liste personalizzate"
        echo "  s) Salva ed esci"
        echo "  q) Esci senza salvare"
        sel=$(ask "Scelta: ")
        case "$sel" in
            1) wizard_notify_mode ;;
            2) wizard_script_update_notify ;;
            3) wizard_intervals ;;
            4) wizard_toggle_lists ;;
            5) wizard_custom_lists ;;
            s|S)
                write_config
                write_updater_scripts
                echo " ✅ Impostazioni salvate."
                return 0
                ;;
            q|Q) echo " Uscito senza salvare."; return 0 ;;
            *) echo " Scelta non valida" ;;
        esac
    done
}

write_updater_scripts() {
    local dir
    dir=$(mktemp -d)

    # ---------- 1) LIST UPDATER ----------
    cat > "${dir}/${LIST_APP}.sh" << 'LIST_UPDATER'
#!/usr/bin/env bash
set -euo pipefail
trap 'echo "" >&2; echo "❌ ERRORE list-update alla riga $LINENO" >&2; exit 1' ERR

CONFIG_DIR="__CONFIG_DIR__"
CONF_FILE="${CONFIG_DIR}/blocklist.conf"
BLOCKLIST_DIR="${CONFIG_DIR}/blocklists"
OUTPUT_FILE="${CONFIG_DIR}/ipfilter.dat"
STATE_FILE="${CONFIG_DIR}/.blocklist-state"
LOCK_FILE="/tmp/qbittorrent-blocklist-list.lock"
LOG_FILE="${CONFIG_DIR}/blocklist.log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

notify() {
    local title="$1" message="$2" kind="${3:-info}"
    local priority="${NTFY_PRIORITY:-3}"
    case "${NOTIFY_MODE:-changes}" in
        all) ;;
        changes)
            if [[ "$kind" != "changes" && "$kind" != "error" && "$kind" != "update" ]]; then
                return 0
            fi
            ;;
        errors)
            if [[ "$kind" != "error" ]]; then return 0; fi
            ;;
        *) return 0 ;;
    esac
    curl -s -o /dev/null --connect-timeout 10 --max-time 30 \
        -X POST "${NTFY_URL}/${NTFY_TOPIC}" \
        -H "Title: ${title}" -H "Priority: ${priority}" -H "Tags: shield" \
        -d "${message}" || true
    return 0
}

exec 200>"$LOCK_FILE"
flock -n 200 || { log "Skipped: another list update is running"; exit 0; }

if [[ ! -f "$CONF_FILE" ]]; then
    log "Config non trovata: $CONF_FILE"
    exit 1
fi
# shellcheck disable=SC1090
source "$CONF_FILE"
if [[ "${#ACTIVE_BLOCKLISTS[@]}" -eq 0 ]]; then
    ACTIVE_BLOCKLISTS=()
fi

mkdir -p "$CONFIG_DIR" "$BLOCKLIST_DIR"
if [[ ! -f "$STATE_FILE" ]]; then
    { echo "LIST_HASH="; echo "LAST_LIST_UPDATE=0"; echo "LAST_LIST_RULES=0"; } > "$STATE_FILE"
fi

now=$(date +%s)
last=$(grep '^LAST_LIST_UPDATE=' "$STATE_FILE" | cut -d= -f2 || true)
if [[ -z "$last" ]]; then last=0; fi
if (( now - last < LIST_UPDATE_INTERVAL * 3600 )); then
    remaining=$(( (last + LIST_UPDATE_INTERVAL*3600 - now) / 60 ))
    log "List update: non ancora ora (prossimo tra ${remaining} min)"
    exit 0
fi

log "=== List update started ==="
TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT

{
    echo "# ============================================================"
    echo "# qBittorrent IP Filter - Auto-generated"
    echo "# Updated: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "# Sources: Multiple threat intelligence feeds"
    echo "# ============================================================"
} > "$OUTPUT_FILE"

cat > "${TMPD}/convert.py" << 'PYEOF'
import sys, io, gzip, zipfile, ipaddress, re

def lines_from(path):
    with open(path, 'rb') as raw:
        head = raw.read(2)
    if head == b'\x1f\x8b':
        with gzip.open(path, 'rt', errors='ignore') as f:
            for line in f:
                yield line
    elif head[:2] == b'PK':
        with zipfile.ZipFile(path) as z:
            for n in z.namelist():
                with z.open(n) as member:
                    for line in io.TextIOWrapper(member, errors='ignore'):
                        yield line
    else:
        with open(path, 'r', errors='ignore') as f:
            for line in f:
                yield line

IP = r'\d{1,3}(?:\.\d{1,3}){3}'
re_range  = re.compile(rf'^({IP})\s*[-\u2013]\s*({IP})$')
re_pair   = re.compile(rf'^({IP})\s*,\s*({IP})')
re_cidr   = re.compile(rf'^({IP})(?:/(\d{{1,2}}))?')

def emit(line, name, out):
    for sep in ('#', ';', '//'):
        line = line.split(sep)[0]
    line = line.strip()
    if not line:
        return
    m = re_range.match(line)
    if m:
        out.write(f"{m.group(1)},{m.group(2)} - {name}\n"); return
    m = re_pair.match(line)
    if m:
        out.write(f"{m.group(1)},{m.group(2)} - {name}\n"); return
    m = re_cidr.match(line)
    if m:
        prefix = m.group(2) if m.group(2) else '32'
        try:
            net = ipaddress.ip_network(f"{m.group(1)}/{prefix}", strict=False)
            out.write(f"{net.network_address},{net.broadcast_address} - {name}\n")
        except ValueError:
            pass

def main():
    src, name, dst = sys.argv[1], sys.argv[2], sys.argv[3]
    with open(dst, 'a') as out:
        for line in lines_from(src):
            emit(line, name, out)

main()
PYEOF

TOTAL=0 SUCCESS=0 FAILED=0 FAILED_LISTS=""
count_lines() { wc -l < "$OUTPUT_FILE" | tr -d ' '; }

for entry in "${ACTIVE_BLOCKLISTS[@]}"; do
    if [[ -z "$entry" || "$entry" == \#* ]]; then continue; fi
    url="${entry%%|*}"; name="${entry##*|}"
    log "Downloading: $name"
    tmpfile="${TMPD}/$(echo "$name" | tr -c 'A-Za-z0-9._' '_')"
    if curl -fsSL --connect-timeout 30 --max-time 120 --retry 2 -o "$tmpfile" "$url" 2>/dev/null; then
        before=$(count_lines)
        python3 "${TMPD}/convert.py" "$tmpfile" "$name" "$OUTPUT_FILE" || true
        after=$(count_lines)
        added=$((after - before))
        TOTAL=$((TOTAL + added)); SUCCESS=$((SUCCESS + 1))
        log "  + $name: +$added regole"
    else
        FAILED=$((FAILED + 1)); FAILED_LISTS+="$name, "
        log "  X FAILED: $name"
    fi
done

if [[ $SUCCESS -eq 0 ]]; then
    log "!!! NESSUNA lista scaricata: ipfilter.dat NON aggiornato."
    notify "qBittorrent Blocklist" "❌ Nessuna lista scaricata: filtro NON aggiornato." "error"
    exit 1
fi

new_hash=$(grep -v '^# Updated:' "$OUTPUT_FILE" | sha256sum | cut -d' ' -f1)
old_hash=$(grep '^LIST_HASH=' "$STATE_FILE" 2>/dev/null | cut -d= -f2 || true)

kind="info"; status="Aggiornamento completato"
if [[ $FAILED -gt 0 ]]; then kind="error"; status="Aggiornamento parziale"; fi

changes_msg=""
if [[ -n "$old_hash" && "$old_hash" != "$new_hash" ]]; then
    kind="changes"; changes_msg="• Nuove regole IP caricate (lista modificata)"
elif [[ -z "$old_hash" ]]; then
    changes_msg="• Primo aggiornamento"
fi

{
    echo "LIST_HASH=${new_hash}"
    echo "LAST_LIST_UPDATE=${now}"
    echo "LAST_LIST_RULES=${TOTAL}"
} > "$STATE_FILE"

MSG="${status}
• Liste scaricate: ${SUCCESS}/${#ACTIVE_BLOCKLISTS[@]}
• Regole totali: ${TOTAL}
• Fallite: ${FAILED}"
if [[ -n "$changes_msg" ]]; then MSG+=$'\n'"${changes_msg}"; fi
if [[ -n "$FAILED_LISTS" ]]; then MSG+=$'\n'"• Fallite: ${FAILED_LISTS%, }"; fi

log "$MSG"
notify "qBittorrent Blocklist" "$MSG" "$kind"
log "=== List update finished ==="
LIST_UPDATER

    # ---------- 2) SCRIPT CHECK UPDATER ----------
    cat > "${dir}/${CHECK_APP}.sh" << 'CHECK_UPDATER'
#!/usr/bin/env bash
set -euo pipefail
trap 'echo "" >&2; echo "❌ ERRORE script-check alla riga $LINENO" >&2; exit 1' ERR

MANAGER_NAME="__MANAGER_NAME__"
CONFIG_DIR="__CONFIG_DIR__"
CONF_FILE="${CONFIG_DIR}/blocklist.conf"
STATE_FILE="${CONFIG_DIR}/.blocklist-script-state"
LOCK_FILE="/tmp/qbittorrent-blocklist-check.lock"
LOG_FILE="${CONFIG_DIR}/blocklist.log"
SCRIPT_LOCAL_VERSION="__VERSION__"
SCRIPT_REMOTE_URL="__REMOTE_URL__"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [check] $*" | tee -a "$LOG_FILE"; }

notify() {
    local title="$1" message="$2" kind="${3:-info}"
    local priority="${NTFY_PRIORITY:-3}"
    case "${NOTIFY_MODE:-changes}" in
        all) ;;
        changes)
            if [[ "$kind" != "changes" && "$kind" != "error" && "$kind" != "update" ]]; then
                return 0
            fi
            ;;
        errors)
            if [[ "$kind" != "error" ]]; then return 0; fi
            ;;
        *) return 0 ;;
    esac
    if [[ "$kind" == "update" && "${NOTIFY_SCRIPT_UPDATE:-yes}" != "yes" ]]; then
        return 0
    fi
    curl -s -o /dev/null --connect-timeout 10 --max-time 30 \
        -X POST "${NTFY_URL}/${NTFY_TOPIC}" \
        -H "Title: ${title}" -H "Priority: ${priority}" -H "Tags: arrow_up" \
        -d "${message}" || true
    return 0
}

exec 201>"$LOCK_FILE"
flock -n 201 || exit 0

if [[ ! -f "$CONF_FILE" ]]; then exit 1; fi
# shellcheck disable=SC1090
source "$CONF_FILE"

mkdir -p "$CONFIG_DIR"
if [[ ! -f "$STATE_FILE" ]]; then
    { echo "LAST_SCRIPT_CHECK=0"; echo "NOTIFIED_VERSION="; } > "$STATE_FILE"
fi

now=$(date +%s)
last=$(grep '^LAST_SCRIPT_CHECK=' "$STATE_FILE" | cut -d= -f2 || true)
if [[ -z "$last" ]]; then last=0; fi
if (( now - last < SCRIPT_UPDATE_INTERVAL * 3600 )); then
    remaining=$(( (last + SCRIPT_UPDATE_INTERVAL*3600 - now) / 60 ))
    log "Script check: non ancora ora (prossimo tra ${remaining} min)"
    exit 0
fi

log "=== Script update check started ==="
remote_version=$(curl -fsSL --connect-timeout 10 --max-time 30 "${SCRIPT_REMOTE_URL}" 2>/dev/null | grep -m1 '^VERSION=' | sed 's/VERSION=//' | tr -d '"' | tr -d "'" | xargs) || true

nv=$(grep '^NOTIFIED_VERSION=' "$STATE_FILE" 2>/dev/null | cut -d= -f2 || true)
{ echo "LAST_SCRIPT_CHECK=${now}"; echo "NOTIFIED_VERSION=${nv}"; } > "$STATE_FILE"

if [[ -z "$remote_version" ]]; then
    log "  Remoto non raggiungibile"
    log "=== Script update check finished ==="
    exit 0
fi

log "  Remoto: v${remote_version} (locale v${SCRIPT_LOCAL_VERSION})"

if [[ "$remote_version" == "$SCRIPT_LOCAL_VERSION" ]]; then
    log "  Nessun aggiornamento"
    log "=== Script update check finished ==="
    exit 0
fi

cmp="same"
IFS='.' read -ra a1 <<< "$remote_version"
IFS='.' read -ra a2 <<< "$SCRIPT_LOCAL_VERSION"
for i in 0 1 2; do
    n1="${a1[$i]:-0}"; n2="${a2[$i]:-0}"
    if (( n1 > n2 )); then cmp="newer"; break; fi
    if (( n1 < n2 )); then cmp="older"; break; fi
done

if [[ "$cmp" == "newer" && "$nv" != "$remote_version" ]]; then
    notify "qBittorrent Manager" "🔄 Nuovo aggiornamento disponibile: v${SCRIPT_LOCAL_VERSION} → v${remote_version}
Esegui: ${MANAGER_NAME} update" "update"
    log "  Notifica aggiornamento script inviata (v${remote_version})"
    { echo "LAST_SCRIPT_CHECK=${now}"; echo "NOTIFIED_VERSION=${remote_version}"; } > "$STATE_FILE"
else
    log "  Nessun nuovo aggiornamento da notificare"
fi
log "=== Script update check finished ==="
CHECK_UPDATER

    sed -i "s|__CONFIG_DIR__|${CONFIG_DIR}|g" "${dir}/${LIST_APP}.sh" "${dir}/${CHECK_APP}.sh"
    sed -i "s|__VERSION__|${VERSION}|g" "${dir}/${CHECK_APP}.sh"
    sed -i "s|__REMOTE_URL__|${REMOTE_URL}|g" "${dir}/${CHECK_APP}.sh"
    sed -i "s|__MANAGER_NAME__|${MANAGER_NAME}|g" "${dir}/${CHECK_APP}.sh"

    if grep -q '__CONFIG_DIR__\|__VERSION__\|__REMOTE_URL__\|__MANAGER_NAME__' \
        "${dir}/${LIST_APP}.sh" "${dir}/${CHECK_APP}.sh"; then
        echo "❌ Placeholder non sostituiti negli updater: installazione annullata."
        rm -rf "$dir"
        exit 1
    fi

    sudox mkdir -p "$INSTALL_DIR"
    sudox cp "${dir}/${LIST_APP}.sh" "$LIST_SCRIPT"
    sudox cp "${dir}/${CHECK_APP}.sh" "$CHECK_SCRIPT"
    sudox chmod 755 "$LIST_SCRIPT" "$CHECK_SCRIPT"
    if [[ ! -f "$LIST_SCRIPT" || ! -f "$CHECK_SCRIPT" ]]; then
        echo "❌ Updater non copiati in ${INSTALL_DIR}"
        rm -rf "$dir"
        exit 1
    fi
    rm -rf "$dir"
    echo "  ✓ Updater generati: ${LIST_SCRIPT}, ${CHECK_SCRIPT}"
    return 0
}

add_cron_line() {
    local tag="$1" script="$2"
    (crontab -l 2>/dev/null | grep -vF "$tag" | crontab -) || true
    if ! (crontab -l 2>/dev/null; echo "${CRON_SCHEDULE} ${script} >> ${LOG_FILE} 2>&1 ${tag}") | crontab -; then
        echo "❌ Impossibile scrivere il crontab per ${script}."
        exit 1
    fi
    if ! crontab -l 2>/dev/null | grep -qF "$tag"; then
        echo "❌ La voce cron per ${script} non risulta nel crontab."
        exit 1
    fi
    return 0
}

verify_install() {
    local problems=0 label path
    local lines=(
        "manager|$MANAGER_PATH"
        "updater liste|$LIST_SCRIPT"
        "updater check|$CHECK_SCRIPT"
        "config|$CONF_FILE"
        "stato liste|$STATE_FILE"
        "log|$LOG_FILE"
        "ipfilter.dat|$OUTPUT_FILE"
    )

    for item in "${lines[@]}"; do
        label="${item%%|*}"; path="${item##*|}"
        if [[ -f "$path" ]]; then
            echo "  ✓ ${label}: ${path}"
        else
            echo "  ❌ MANCA ${label}: ${path}"
            problems=$((problems+1))
        fi
    done

    if crontab -l 2>/dev/null | grep -qF "$CRON_TAG_LIST"; then
        echo "  ✓ cron liste: presente"
    else
        echo "  ❌ cron liste ASSENTE"
        problems=$((problems+1))
    fi
    if crontab -l 2>/dev/null | grep -qF "$CRON_TAG_CHECK"; then
        echo "  ✓ cron check: presente"
    else
        echo "  ❌ cron check ASSENTE"
        problems=$((problems+1))
    fi

    echo ""
    if (( problems > 0 )); then
        echo " ❌ INSTALLAZIONE INCOMPLETA: ${problems} problema/i. Correggili e riesegui '${MANAGER_NAME} install'."
        exit 1
    fi
    echo " ✅ Verifica installazione: tutti i componenti presenti."
    return 0
}

cmd_install() {
    echo ""
    echo "╔══════════════════════════════════════════════════╗"
    echo "║   qBittorrent Blocklist Manager - Installazione  ║"
    echo "╚══════════════════════════════════════════════════╝"
    echo ""
    echo " Utente configurazione: ${REAL_USER} (${CONFIG_DIR})"

    echo "→ Verifica dipendenze..."
    check_deps
    echo "  ✓ OK"

    echo "→ Determinazione sorgente..."
    resolve_source

    echo "→ Installazione manager..."
    install_manager

    if ! running_installed_manager; then
        echo ""
        echo "→ Relaunch dal manager installato..."
        exec "$MANAGER_PATH" install
    fi

    if [[ -f "$CONF_FILE" ]]; then
        echo "⚠️  Installazione già presente."
        local overwrite; overwrite=$(ask "   Sovrascrivere? [y/N] ")
        if [[ ! "$overwrite" =~ ^[Yy]$ ]]; then
            echo "Annullato."
            exit 0
        fi
        echo ""
    fi

    mkdir -p "$CONFIG_DIR" "$BLOCKLIST_DIR"
    touch "$LOG_FILE"
    echo "  ✓ Directory create in ${CONFIG_DIR}"

    echo "→ Generazione topic ntfy..."
    local topic; topic=$(generate_topic)
    echo "  ✓ Topic: $topic"

    set_config_defaults "$topic"
    run_wizard
    write_config

    echo "→ Installazione updater (liste + check script)..."
    write_updater_scripts

    echo "→ Configurazione cron (due voci, tick orario)..."
    add_cron_line "$CRON_TAG_LIST" "$LIST_SCRIPT"
    add_cron_line "$CRON_TAG_CHECK" "$CHECK_SCRIPT"
    echo "  ✓ Cron liste attivo  (agg. ogni ${LIST_UPDATE_INTERVAL}h)"
    echo "  ✓ Cron script attivo (check ogni ${SCRIPT_UPDATE_INTERVAL}h)"

    cat > "$META_FILE" << METAEOF
topic=${topic}
installed=$(date -Iseconds)
list_script=${LIST_SCRIPT}
check_script=${CHECK_SCRIPT}
output=${OUTPUT_FILE}
version=${VERSION}
METAEOF

    echo ""
    echo "→ Esecuzione primo aggiornamento liste..."
    if ! "$LIST_SCRIPT"; then
        echo "  ⚠️  Primo aggiornamento con problemi: controlla il log (${LOG_FILE}). Il cron riproverà."
    fi

    echo ""
    echo "→ VERIFICA FINALE DELL'INSTALLAZIONE"
    verify_install

    echo ""
    echo "════════════════════════════════════════════════════"
    echo " ✅ INSTALLAZIONE COMPLETATA"
    echo "════════════════════════════════════════════════════"
    echo ""
    echo " 📋 Riepilogo:"
    echo "   • Versione:       $VERSION"
    echo "   • Manager:        $MANAGER_PATH"
    echo "   • Config:         $CONF_FILE"
    echo "   • Liste:          ogni ${LIST_UPDATE_INTERVAL}h"
    echo "   • Check script:   ogni ${SCRIPT_UPDATE_INTERVAL}h"
    echo "   • Notifiche:      ${NOTIFY_MODE} (priorità ${NTFY_PRIORITY})"
    echo "   • Ntfy topic:     $topic"
    echo ""
    echo " 📱 Notifiche: iscriviti al topic \"$topic\""
    echo "   Browser: https://ntfy.sh/$topic"
    echo ""
    echo " ⚙️  qBittorrent: Strumenti → Opzioni → BitTorrent → Filtro IP"
    echo "   Percorso: $OUTPUT_FILE"
    echo ""
    echo " 🛠️  Per modificare le preferenze: ${MANAGER_NAME} settings"
    echo ""
    return 0
}

cmd_settings() {
    load_config
    run_settings_menu
    return 0
}

cmd_uninstall() {
    echo ""
    echo "→ Rimozione cron..."
    local removed=0
    if crontab -l 2>/dev/null | grep -qF "$CRON_TAG_LIST"; then
        (crontab -l 2>/dev/null | grep -vF "$CRON_TAG_LIST" | crontab -) || true
        echo "  ✓ Cron liste rimosso"
        removed=1
    fi
    if crontab -l 2>/dev/null | grep -qF "$CRON_TAG_CHECK"; then
        (crontab -l 2>/dev/null | grep -vF "$CRON_TAG_CHECK" | crontab -) || true
        echo "  ✓ Cron script rimosso"
        removed=1
    fi
    if [[ $removed -eq 0 ]]; then
        echo "  – Nessun cron presente"
    fi

    echo "→ Rimozione updater..."
    if [[ -f "$LIST_SCRIPT" ]]; then sudox rm -f "$LIST_SCRIPT"; echo "  ✓ $LIST_SCRIPT rimosso"; else echo "  – Non trovato"; fi
    if [[ -f "$CHECK_SCRIPT" ]]; then sudox rm -f "$CHECK_SCRIPT"; echo "  ✓ $CHECK_SCRIPT rimosso"; else echo "  – Non trovato"; fi

    echo ""
    local confirm; confirm=$(ask "→ Rimuovere ipfilter.dat, config, stati e liste? [y/N] ")
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        rm -f "$OUTPUT_FILE" "$CONF_FILE" "$STATE_FILE" "$SCRIPT_STATE_FILE"
        rm -rf "$BLOCKLIST_DIR"
        echo "  ✓ File rimossi"
    else
        echo "  – Conservati"
    fi

    rm -f "$META_FILE"

    local confirm_log; confirm_log=$(ask "→ Rimuovere il log (${LOG_FILE})? [y/N] ")
    if [[ "$confirm_log" =~ ^[Yy]$ ]]; then
        rm -f "$LOG_FILE"; echo "  ✓ Log rimosso"
    else
        echo "  – Log conservato"
    fi

    echo ""
    local confirm_self; confirm_self=$(ask "→ Rimuovere anche il manager (${MANAGER_PATH})? [y/N] ")
    if [[ "$confirm_self" =~ ^[Yy]$ ]]; then
        sudox rm -f "$MANAGER_PATH"; echo "  ✓ Manager rimosso"
    else
        echo "  – Manager conservato"
    fi

    echo ""
    echo " ✅ DISINSTALLAZIONE COMPLETATA"
    echo " ⚠️  Disabilita il filtro IP in qBittorrent."
    echo ""
    return 0
}

cmd_status() {
    load_config
    build_active_blocklists
    echo ""
    echo "╔══════════════════════════════════════════════════╗"
    echo "║   qBittorrent Blocklist Manager - Stato          ║"
    echo "╚══════════════════════════════════════════════════╝"
    echo ""
    echo " ✓ Versione manager:    v${VERSION}"
    echo " ✓ Agg. liste:          ogni ${LIST_UPDATE_INTERVAL}h"
    echo " ✓ Check script:        ogni ${SCRIPT_UPDATE_INTERVAL}h"
    echo " ✓ Notifiche:           ${NOTIFY_MODE} (priorità ${NTFY_PRIORITY})"
    echo " ✓ Notifica agg. script: ${NOTIFY_SCRIPT_UPDATE}"
    echo " ✓ Ntfy topic:          ${NTFY_TOPIC}"
    echo " ✓ Liste attive:        ${#BLOCKLISTS[@]} (${#CUSTOM_BLOCKLISTS[@]} custom)"
    echo ""

    if [[ -f "$OUTPUT_FILE" ]]; then
        local lines size
        lines=$(awk '/^[0-9]/{n++} END{print n+0}' "$OUTPUT_FILE" 2>/dev/null || echo 0)
        size=$(du -h "$OUTPUT_FILE" | cut -f1)
        echo " ✓ ipfilter.dat: ${lines} regole (${size})"
    else
        echo " ✗ ipfilter.dat: NON PRESENTE"
    fi

    if [[ -f "$STATE_FILE" ]]; then
        local lru
        lru=$(grep '^LAST_LIST_UPDATE=' "$STATE_FILE" | cut -d= -f2 || true)
        if [[ -n "$lru" && "$lru" != "0" ]]; then
            echo " ✓ Ultimo agg. liste:   $(date -d "@${lru}" '+%Y-%m-%d %H:%M')"
        fi
    fi
    if [[ -f "$SCRIPT_STATE_FILE" ]]; then
        local lsc
        lsc=$(grep '^LAST_SCRIPT_CHECK=' "$SCRIPT_STATE_FILE" | cut -d= -f2 || true)
        if [[ -n "$lsc" && "$lsc" != "0" ]]; then
            echo " ✓ Ultimo check script: $(date -d "@${lsc}" '+%Y-%m-%d %H:%M')"
        fi
    fi

    if crontab -l 2>/dev/null | grep -qF "$CRON_TAG_LIST"; then
        echo " ✓ Cron liste: attivo"
    else
        echo " ✗ Cron liste: NON configurato"
    fi
    if crontab -l 2>/dev/null | grep -qF "$CRON_TAG_CHECK"; then
        echo " ✓ Cron script: attivo"
    else
        echo " ✗ Cron script: NON configurato"
    fi

    if [[ -f "$LOG_FILE" ]]; then
        echo ""
        echo " 📄 Ultimo log:"
        tail -5 "$LOG_FILE" | sed 's/^/   /'
    fi
    echo ""
    return 0
}

cmd_run() {
    if [[ ! -f "$LIST_SCRIPT" ]]; then
        echo "❌ Non installato. Esegui: ${MANAGER_NAME} install"
        exit 1
    fi
    echo "→ Forzo aggiornamento liste (ignora intervallo)..."
    if [[ -f "$STATE_FILE" ]]; then
        local lh lr
        lh=$(grep '^LIST_HASH=' "$STATE_FILE" | cut -d= -f2 || true)
        lr=$(grep '^LAST_LIST_RULES=' "$STATE_FILE" | cut -d= -f2 || true)
        { echo "LIST_HASH=${lh}"; echo "LAST_LIST_UPDATE=0"; echo "LAST_LIST_RULES=${lr}"; } > "$STATE_FILE"
    fi
    "$LIST_SCRIPT"
}

cmd_update() {
    echo ""
    echo "→ Verifica aggiornamenti..."
    echo "  Locale:  v${VERSION}"
    local remote_version=""
    remote_version=$(curl -fsSL --connect-timeout 10 --max-time 30 "$REMOTE_URL" 2>/dev/null | grep -m1 '^VERSION=' | sed 's/VERSION=//' | tr -d '"' | tr -d "'" | xargs) || true
    if [[ -z "$remote_version" ]]; then
        echo "  Remoto: NON RAGGIUNGIBILE"
        echo "❌ Impossibile verificare."
        exit 1
    fi
    echo "  Remoto:  v${remote_version}"
    echo ""
    version_compare "$remote_version" "$VERSION"
    if [[ "$CMP_RESULT" != "newer" ]]; then
        echo "✅ Sei già all'ultima versione (v${VERSION})."
        echo ""
        return 0
    fi
    echo "🔄 Aggiornamento: v${VERSION} → v${remote_version}"
    echo ""
    local confirm; confirm=$(ask "→ Procedere? [Y/n] ")
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        echo "Annullato."
        return 0
    fi

    local tmpfile; tmpfile=$(mktemp)
    if ! curl -fsSL --connect-timeout 30 --max-time 60 -o "$tmpfile" "$REMOTE_URL"; then
        rm -f "$tmpfile"
        echo "❌ Download fallito."
        exit 1
    fi
    if ! head -1 "$tmpfile" | grep -q "bash"; then
        rm -f "$tmpfile"
        echo "❌ File non valido."
        exit 1
    fi
    sudox cp "$tmpfile" "$MANAGER_PATH"
    sudox chmod 755 "$MANAGER_PATH"
    rm -f "$tmpfile"
    echo "  ✓ Aggiornato a v${remote_version}"
    echo ""
    echo " ⚠️  Per rigenerare gli updater con la nuova versione:"
    echo "   ${MANAGER_NAME} settings  →  s (salva)"
    echo ""
    return 0
}

cmd_help() {
    cat << EOF

╔══════════════════════════════════════════════════════════╗
║   qBittorrent Blocklist Manager  v${VERSION}              ║
╚══════════════════════════════════════════════════════════╝

Uso: ${MANAGER_NAME} <comando>

  install    Installa e configura tutto (wizard TUI interattivo)
  settings   Menu impostazioni TUI (notifiche, intervalli, liste)
  uninstall  Rimuove tutto (cron, updater, file, manager)
  status     Mostra stato, config, topic, log
  run        Forza un aggiornamento liste immediato
  update     Verifica e installa aggiornamenti dello script
  version    Mostra la versione installata
  help       Mostra questa guida

Installazione da pipe:
  curl -fsSL ${REMOTE_URL} | bash
Oppure (consigliato, usa il file scaricato senza ri-download):
  curl -fsSL ${REMOTE_URL} -o qbbm.sh && bash qbbm.sh install

EOF
    return 0
}

case "${1:-help}" in
    install)
        if [[ ! -f "$0" ]] || [[ "$0" == "bash" || "$0" == "-bash" || "$0" == "/bin/bash" || "$0" == "/usr/bin/bash" ]]; then
            check_deps
            resolve_source
            install_manager
            exec "$MANAGER_PATH" install
        fi
        cmd_install
        ;;
    settings)  cmd_settings ;;
    uninstall) cmd_uninstall ;;
    status)    cmd_status ;;
    run)       cmd_run ;;
    update)    cmd_update ;;
    version|--version|-v) echo "qbittorrent-blocklist-manager v${VERSION}" ;;
    help|--help|-h) cmd_help ;;
    *)
        echo "❌ Comando sconosciuto: $1"
        echo ""
        cmd_help
        exit 1
        ;;
esac
