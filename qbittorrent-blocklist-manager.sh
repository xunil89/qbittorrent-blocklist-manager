#!/usr/bin/env bash
# ============================================================
# qbittorrent-blocklist-manager.sh
# Gestione completa del filtro IP per qBittorrent
# Versione: 3.0.1
#
# - TUI interattiva (install / settings)
# - Checklist per attivare/disattivare/aggiungere/rimuovere liste
# - Due updater separati (liste + check script) su due cron distinti
# - Conversione corretta CIDR/range/IP -> ipfilter.dat (Python)
# - Notifiche ntfy configurabili (modalità + priorità)
# ============================================================

set -euo pipefail

VERSION="3.0.1"
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
CRON_SCHEDULE="0 * * * *"   # tick orario: gli intervalli reali sono gestiti dagli updater

# --- Home reale anche quando lanciato con sudo ---
if [[ -n "${SUDO_USER:-}" ]]; then
    REAL_USER="${SUDO_USER}"
    REAL_HOME="$(getent passwd "${SUDO_USER}" | cut -d: -f6)"
else
    REAL_USER="${USER}"
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

# --- LISTE PREDEFINITE (formato "URL|Nome") ---
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

# --- UTILITÀ ---
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
    for cmd in curl flock python3 crontab sha256sum; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "❌ Dipendenze mancanti: ${missing[*]}"
        echo "   Installale con il gestore pacchetti della tua distribuzione."
        exit 1
    fi
}

version_compare() {
    local v1="$1" v2="$2"
    if [[ "$v1" == "$v2" ]]; then CMP_RESULT="same"; return; fi
    local IFS='.'
    local -a a1=($v1) a2=($v2)
    local i
    for i in 0 1 2; do
        local n1="${a1[$i]:-0}" n2="${a2[$i]:-0}"
        if (( n1 > n2 )); then CMP_RESULT="newer"; return; fi
        if (( n1 < n2 )); then CMP_RESULT="older"; return; fi
    done
    CMP_RESULT="same"
}

# --- CONFIG ---
set_config_defaults() {
    NTFY_URL="https://ntfy.sh"
    NTFY_TOPIC="${1:-}"
    NTFY_PRIORITY=3
    NOTIFY_MODE="changes"           # all | changes | errors
    NOTIFY_SCRIPT_UPDATE="yes"
    LIST_UPDATE_INTERVAL=24         # ore
    SCRIPT_UPDATE_INTERVAL=48       # ore
    declare -gA BLOCK_STATE=()
    local entry
    for entry in "${DEFAULT_BLOCKLISTS[@]}"; do
        BLOCK_STATE["${entry%%|*}"]=1
    done
    declare -ga CUSTOM_BLOCKLISTS=()
}

load_config() {
    if [[ ! -f "$CONF_FILE" ]]; then
        echo "❌ Config non trovata: $CONF_FILE"
        echo "   Esegui prima: ${MANAGER_NAME} install"
        exit 1
    fi
    # shellcheck disable=SC1090
    source "$CONF_FILE"
    [[ "${#BLOCK_STATE[@]}" -gt 0 ]] || set_config_defaults "${NTFY_TOPIC:-}"
    declare -ga CUSTOM_BLOCKLISTS=("${CUSTOM_BLOCKLISTS[@]:-}")
    declare -ga BLOCKLISTS=()
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
    for entry in "${CUSTOM_BLOCKLISTS[@]:-}"; do
        [[ -n "$entry" ]] && BLOCKLISTS+=("$entry")
    done
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
        for entry in "${CUSTOM_BLOCKLISTS[@]:-}"; do
            [[ -n "$entry" ]] && echo "    \"${entry}\""
        done
        echo ")"
        echo "# --- array attivo generato (non modificare) ---"
        echo "ACTIVE_BLOCKLISTS=("
        for entry in "${BLOCKLISTS[@]}"; do
            echo "    \"${entry}\""
        done
        echo ")"
    } > "$CONF_FILE"
}

# ============================================================
#   TUI - WIZARD
# ============================================================
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
        "") ;; # mantiene default "changes"
        *) NOTIFY_MODE="changes" ;;
    esac
    echo "  → Modalità notifiche: $NOTIFY_MODE"

    local prio; prio=$(ask "Priorità ntfy 1-5 (1=min, 5=max/urgente) [${NTFY_PRIORITY}]: ")
    if [[ "$prio" =~ ^[1-5]$ ]]; then NTFY_PRIORITY="$prio"; fi
    echo "  → Priorità: $NTFY_PRIORITY"
}

wizard_script_update_notify() {
    echo ""
    echo "Notificare quando è disponibile un aggiornamento dello script?"
    local sel; sel=$(ask "  [S/n]: ")
    if [[ "$sel" =~ ^[Nn]$ ]]; then NOTIFY_SCRIPT_UPDATE="no"; else NOTIFY_SCRIPT_UPDATE="yes"; fi
    echo "  → Notifica aggiornamento script: $NOTIFY_SCRIPT_UPDATE"
}

wizard_intervals() {
    echo ""
    echo "┌─ Intervalli (ore) ─────────────────────────┐"
    echo "│ Lascia vuoto per mantenere il valore.      │"
    echo "└────────────────────────────────────────────┘"
    local in_l in_s
    in_l=$(ask "  Aggiornamento liste [${LIST_UPDATE_INTERVAL}h]: ")
    if [[ -n "$in_l" ]]; then
        if [[ "$in_l" =~ ^[0-9]+$ ]] && (( in_l >= 1 )); then LIST_UPDATE_INTERVAL="$in_l"
        else echo "  Valore non valido, mantengo ${LIST_UPDATE_INTERVAL}h"; fi
    fi
    in_s=$(ask "  Controllo aggiornamenti script [${SCRIPT_UPDATE_INTERVAL}h]: ")
    if [[ -n "$in_s" ]]; then
        if [[ "$in_s" =~ ^[0-9]+$ ]] && (( in_s >= 1 )); then SCRIPT_UPDATE_INTERVAL="$in_s"
        else echo "  Valore non valido, mantengo ${SCRIPT_UPDATE_INTERVAL}h"; fi
    fi
    echo "  → Liste ogni ${LIST_UPDATE_INTERVAL}h, script ogni ${SCRIPT_UPDATE_INTERVAL}h"
}

# Checklist interattiva: i numeri attivano/disattivano, 'k' conferma
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
            [[ "${BLOCK_STATE[$url]:-0}" == "1" ]] && mark="x"
            printf "  [%s] %2d) %s\n" "$mark" "$i" "$name"
            ((i++)) || true
        done
        sel=$(ask "Selezione [k]: ")
        if [[ -z "$sel" || "$sel" == "k" ]]; then
            echo "  → Checklist confermata"
            return
        elif [[ "$sel" == "a" ]]; then
            for entry in "${DEFAULT_BLOCKLISTS[@]}"; do BLOCK_STATE["${entry%%|*}"]=1; done
        elif [[ "$sel" == "n" ]]; then
            for entry in "${DEFAULT_BLOCKLISTS[@]}"; do BLOCK_STATE["${entry%%|*}"]=0; done
        else
            for num in $sel; do
                [[ "$num" =~ ^[0-9]+$ ]] || continue
                if (( num >= 1 && num <= ${#DEFAULT_BLOCKLISTS[@]} )); then
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
    local i entry url name sel more test tmp size
    while true; do
        echo ""
        echo "┌─ Liste personalizzate ─────────────────────┐"
        echo "│  1) Aggiungi lista                         │"
        echo "│  2) Rimuovi lista                          │"
        echo "│  k) Torna al menu                          │"
        echo "└────────────────────────────────────────────┘"
        if [[ ${#CUSTOM_BLOCKLISTS[@]} -gt 0 ]]; then
            i=1
            for entry in "${CUSTOM_BLOCKLISTS[@]}"; do
                echo "   $i) ${entry##*|}"
                ((i++)) || true
            done
        else
            echo "   (nessuna lista personalizzata)"
        fi
        sel=$(ask "Scelta [k]: ")
        case "$sel" in
            1)
                more=$(ask "  URL lista (vuoto per annullare): ")
                [[ -z "$more" ]] && continue
                url="$more"
                name=$(ask "  Nome descrittivo: ")
                [[ -z "$name" ]] && name="$url"
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
                if [[ ${#CUSTOM_BLOCKLISTS[@]} -eq 0 ]]; then echo "  Nessuna lista da rimuovere"; continue; fi
                sel=$(ask "  Numero della lista da rimuovere (vuoto per annullare): ")
                [[ -z "$sel" ]] && continue
                if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#CUSTOM_BLOCKLISTS[@]} )); then
                    local -a new_custom=()
                    i=1
                    for entry in "${CUSTOM_BLOCKLISTS[@]}"; do
                        (( i != sel )) && new_custom+=("$entry")
                        ((i++)) || true
                    done
                    CUSTOM_BLOCKLISTS=("${new_custom[@]:-}")
                    echo "  ✓ Rimossa"
                else
                    echo "  Numero non valido"
                fi
                ;;
            *) return ;;
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
}

# Menu impostazioni TUI (settings)
run_settings_menu() {
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
        local sel; sel=$(ask "Scelta: ")
        case "$sel" in
            1) wizard_notify_mode ;;
            2) wizard_script_update_notify ;;
            3) wizard_intervals ;;
            4) wizard_toggle_lists ;;
            5) wizard_custom_lists ;;
            s|S) write_config; write_updater_scripts; echo " ✅ Impostazioni salvate."; return ;;
            q|Q) echo " Uscito senza salvare."; return ;;
            *) echo " Scelta non valida" ;;
        esac
    done
}

# ============================================================
#   UPDATER SCRIPTS (generati con placeholder sostituiti)
# ============================================================
write_updater_scripts() {
    local dir
    dir=$(mktemp -d)

    # ---------- 1) LIST UPDATER ----------
    cat > "${dir}/${LIST_APP}.sh" << 'LIST_UPDATER'
#!/usr/bin/env bash
# Aggiorna le liste IP e rigenera ipfilter.dat (gestione intervalli interna)
set -euo pipefail

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
        changes) [[ "$kind" == "changes" || "$kind" == "error" || "$kind" == "update" ]] || return 0 ;;
        errors)  [[ "$kind" == "error" ]] || return 0 ;;
        *) return 0 ;;
    esac
    curl -s -o /dev/null --connect-timeout 10 --max-time 30 \
        -X POST "${NTFY_URL}/${NTFY_TOPIC}" \
        -H "Title: ${title}" -H "Priority: ${priority}" -H "Tags: shield" \
        -d "${message}" || true
}

exec 200>"$LOCK_FILE"
flock -n 200 || { log "Skipped: another list update is running"; exit 0; }

[[ -f "$CONF_FILE" ]] || { log "Config non trovata: $CONF_FILE"; exit 1; }
# shellcheck disable=SC1090
source "$CONF_FILE"
[[ "${#ACTIVE_BLOCKLISTS[@]}" -gt 0 ]] || ACTIVE_BLOCKLISTS=()

mkdir -p "$CONFIG_DIR" "$BLOCKLIST_DIR"
if [[ ! -f "$STATE_FILE" ]]; then
    { echo "LIST_HASH="; echo "LAST_LIST_UPDATE=0"; echo "LAST_LIST_RULES=0"; } > "$STATE_FILE"
fi

now=$(date +%s)
last=$(grep '^LAST_LIST_UPDATE=' "$STATE_FILE" | cut -d= -f2 || echo 0)
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
            yield from f
    elif head[:2] == b'PK':
        with zipfile.ZipFile(path) as z:
            for n in z.namelist():
                with z.open(n) as member:
                    yield from io.TextIOWrapper(member, errors='ignore')
    else:
        with open(path, 'r', errors='ignore') as f:
            yield from f

IP = r'\d{1,3}(?:\.\d{1,3}){3}'
re_range  = re.compile(rf'^({IP})\s*[-\u2013]\s*({IP})$')
re_pair   = re.compile(rf'^({IP})\s*,\s*({IP})')
re_cidr   = re.compile(rf'^({IP})(?:/(\d{{1,2}}))?')

def emit(line, name, out):
    # rimuove commenti #, ;, // e spazi
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
for entry in "${ACTIVE_BLOCKLISTS[@]}"; do
    [[ -z "$entry" || "$entry" == \#* ]] && continue
    url="${entry%%|*}"; name="${entry##*|}"
    log "Downloading: $name"
    tmpfile="${TMPD}/$(echo "$name" | tr -c 'A-Za-z0-9._' '_')"
    if curl -fsSL --connect-timeout 30 --max-time 120 --retry 2 -o "$tmpfile" "$url" 2>/dev/null; then
        before=$(grep -c " - " "$OUTPUT_FILE" || echo 0)
        python3 "${TMPD}/convert.py" "$tmpfile" "$name" "$OUTPUT_FILE" || true
        after=$(grep -c " - " "$OUTPUT_FILE" || echo 0)
        added=$((after - before))
        TOTAL=$((TOTAL + added)); SUCCESS=$((SUCCESS + 1))
        log "  + $name: +$added regole"
    else
        FAILED=$((FAILED + 1)); FAILED_LISTS+="$name, "
        log "  X FAILED: $name"
    fi
done

new_hash=$(grep -v '^# Updated:' "$OUTPUT_FILE" | sha256sum | cut -d' ' -f1)
old_hash=$(grep '^LIST_HASH=' "$STATE_FILE" 2>/dev/null | cut -d= -f2 || echo "")

kind="info"; status="Aggiornamento completato"
[[ $FAILED -gt 0 ]] && { kind="error"; status="Aggiornamento parziale"; }

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
[[ -n "$changes_msg" ]] && MSG+=$'\n'"${changes_msg}"
[[ -n "$FAILED_LISTS" ]] && MSG+=$'\n'"• Fallite: ${FAILED_LISTS%, }"

log "$MSG"
notify "qBittorrent Blocklist" "$MSG" "$kind"
log "=== List update finished ==="
LIST_UPDATER

    # ---------- 2) SCRIPT CHECK UPDATER ----------
    cat > "${dir}/${CHECK_APP}.sh" << 'CHECK_UPDATER'
#!/usr/bin/env bash
# Controlla se esiste una nuova versione dello script manager (check orario, intervallo interno)
set -euo pipefail

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
        changes) [[ "$kind" == "changes" || "$kind" == "error" || "$kind" == "update" ]] || return 0 ;;
        errors)  [[ "$kind" == "error" ]] || return 0 ;;
        *) return 0 ;;
    esac
    if [[ "$kind" == "update" && "${NOTIFY_SCRIPT_UPDATE:-yes}" != "yes" ]]; then
        return 0
    fi
    curl -s -o /dev/null --connect-timeout 10 --max-time 30 \
        -X POST "${NTFY_URL}/${NTFY_TOPIC}" \
        -H "Title: ${title}" -H "Priority: ${priority}" -H "Tags: arrow_up" \
        -d "${message}" || true
}

exec 201>"$LOCK_FILE"
flock -n 201 || exit 0

[[ -f "$CONF_FILE" ]] || exit 1
# shellcheck disable=SC1090
source "$CONF_FILE"

mkdir -p "$CONFIG_DIR"
if [[ ! -f "$STATE_FILE" ]]; then
    { echo "LAST_SCRIPT_CHECK=0"; echo "NOTIFIED_VERSION="; } > "$STATE_FILE"
fi

now=$(date +%s)
last=$(grep '^LAST_SCRIPT_CHECK=' "$STATE_FILE" | cut -d= -f2 || echo 0)
if (( now - last < SCRIPT_UPDATE_INTERVAL * 3600 )); then
    remaining=$(( (last + SCRIPT_UPDATE_INTERVAL*3600 - now) / 60 ))
    log "Script check: non ancora ora (prossimo tra ${remaining} min)"
    exit 0
fi

log "=== Script update check started ==="
remote_version=$(curl -fsSL --connect-timeout 10 --max-time 30 "${SCRIPT_REMOTE_URL}" 2>/dev/null | grep -m1 '^VERSION=' | sed 's/VERSION=//' | tr -d '"' | tr -d "'" | xargs) || true

nv=$(grep '^NOTIFIED_VERSION=' "$STATE_FILE" 2>/dev/null | cut -d= -f2 || echo "")
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

    # Sostituzione placeholder
    sed -i "s|__CONFIG_DIR__|${CONFIG_DIR}|g" "${dir}/${LIST_APP}.sh" "${dir}/${CHECK_APP}.sh"
    sed -i "s|__VERSION__|${VERSION}|g" "${dir}/${CHECK_APP}.sh"
    sed -i "s|__REMOTE_URL__|${REMOTE_URL}|g" "${dir}/${CHECK_APP}.sh"
    sed -i "s|__MANAGER_NAME__|${MANAGER_NAME}|g" "${dir}/${CHECK_APP}.sh"

    sudo mkdir -p "$INSTALL_DIR"
    sudo cp "${dir}/${LIST_APP}.sh" "$LIST_SCRIPT"
    sudo cp "${dir}/${CHECK_APP}.sh" "$CHECK_SCRIPT"
    sudo chmod 755 "$LIST_SCRIPT" "$CHECK_SCRIPT"
    rm -rf "$dir"
}

# --- BOOTSTRAP (installazione via pipe) ---
# Scatta quando lo script è eseguito da pipe (es. curl | bash): $0 è "bash"
# e stdin non è un terminale. Anche senza argomento "install" procede.
bootstrap_if_piped() {
    local cmd="${1:-help}"
    local is_piped=0
    [[ ! -t 0 ]] && is_piped=1
    if { [[ "$cmd" == "install" ]] || { [[ "$cmd" == "help" ]] && (( is_piped )); }; } \
       && { [[ ! -f "$0" ]] || [[ "$0" == "bash" || "$0" == "-bash" || "$0" == "/usr/bin/bash" || "$0" == "/bin/bash" ]]; }; then
        echo "→ Installazione da remoto..."
        local tmpfile
        tmpfile=$(mktemp)
        if ! curl -fsSL --connect-timeout 30 --max-time 60 -o "$tmpfile" "$REMOTE_URL"; then
            rm -f "$tmpfile"; echo "❌ Download fallito: $REMOTE_URL"; exit 1
        fi
        if ! head -1 "$tmpfile" | grep -q "bash"; then
            rm -f "$tmpfile"; echo "❌ File scaricato non valido."; exit 1
        fi
        sudo mkdir -p "$INSTALL_DIR"
        sudo cp "$tmpfile" "$MANAGER_PATH"
        sudo chmod 755 "$MANAGER_PATH"
        rm -f "$tmpfile"
        echo "  ✓ Installato in: $MANAGER_PATH"
        echo ""
        exec "${MANAGER_PATH}" install
    fi
}

# ============================================================
#   COMANDI
# ============================================================
add_cron_line() {
    local tag="$1" script="$2"
    # rimuove eventuale riga precedente con lo stesso tag
    crontab -l 2>/dev/null | grep -vF "$tag" | crontab - || true
    (crontab -l 2>/dev/null; echo "${CRON_SCHEDULE} ${script} >> ${LOG_FILE} 2>&1 ${tag}") | crontab -
}

cmd_install() {
    echo ""
    echo "╔══════════════════════════════════════════════════╗"
    echo "║   qBittorrent Blocklist Manager - Installazione  ║"
    echo "╚══════════════════════════════════════════════════╝"
    echo ""
    echo " Utente configurazione: ${REAL_USER} (${CONFIG_DIR})"

    if [[ -f "$CONF_FILE" ]]; then
        echo "⚠️  Installazione già presente."
        local overwrite; overwrite=$(ask "   Sovrascrivere? [y/N] ")
        [[ ! "$overwrite" =~ ^[Yy]$ ]] && { echo "Annullato."; exit 0; }
        echo ""
    fi

    echo "→ Verifica dipendenze..."
    check_deps
    echo "  ✓ OK"

    mkdir -p "$CONFIG_DIR" "$BLOCKLIST_DIR"
    touch "$LOG_FILE"
    echo "  ✓ Directory create"

    echo "→ Generazione topic ntfy..."
    local topic; topic=$(generate_topic)
    echo "  ✓ Topic: $topic"

    set_config_defaults "$topic"
    run_wizard
    write_config
    echo ""
    echo "  ✓ Config salvata: $CONF_FILE"

    echo "→ Installazione updater (liste + check script)..."
    write_updater_scripts
    echo "  ✓ $LIST_SCRIPT"
    echo "  ✓ $CHECK_SCRIPT"

    echo "→ Configurazione cron (due voci, tick orario)..."
    add_cron_line "$CRON_TAG_LIST" "$LIST_SCRIPT"
    add_cron_line "$CRON_TAG_CHECK" "$CHECK_SCRIPT"
    echo "  ✓ Cron liste attivo  (ogni ${LIST_UPDATE_INTERVAL}h)"
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
    echo ""
    "$LIST_SCRIPT"

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
}

cmd_settings() {
    load_config
    run_settings_menu
}

cmd_uninstall() {
    echo ""
    echo "→ Rimozione cron..."
    local removed=0
    if crontab -l 2>/dev/null | grep -qF "$CRON_TAG_LIST"; then
        crontab -l 2>/dev/null | grep -vF "$CRON_TAG_LIST" | crontab -
        echo "  ✓ Cron liste rimosso"; removed=1
    fi
    if crontab -l 2>/dev/null | grep -qF "$CRON_TAG_CHECK"; then
        crontab -l 2>/dev/null | grep -vF "$CRON_TAG_CHECK" | crontab -
        echo "  ✓ Cron script rimosso"; removed=1
    fi
    [[ $removed -eq 0 ]] && echo "  – Nessun cron presente"

    echo "→ Rimozione updater..."
    if [[ -f "$LIST_SCRIPT" ]]; then sudo rm -f "$LIST_SCRIPT"; echo "  ✓ $LIST_SCRIPT rimosso"; else echo "  – Non trovato"; fi
    if [[ -f "$CHECK_SCRIPT" ]]; then sudo rm -f "$CHECK_SCRIPT"; echo "  ✓ $CHECK_SCRIPT rimosso"; else echo "  – Non trovato"; fi

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
    if [[ "$confirm_log" =~ ^[Yy]$ ]]; then rm -f "$LOG_FILE"; echo "  ✓ Log rimosso"; else echo "  – Log conservato"; fi

    echo ""
    local confirm_self; confirm_self=$(ask "→ Rimuovere anche il manager (${MANAGER_PATH})? [y/N] ")
    if [[ "$confirm_self" =~ ^[Yy]$ ]]; then sudo rm -f "$MANAGER_PATH"; echo "  ✓ Manager rimosso"; else echo "  – Manager conservato"; fi

    echo ""
    echo " ✅ DISINSTALLAZIONE COMPLETATA"
    echo " ⚠️  Disabilita il filtro IP in qBittorrent."
    echo ""
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
        lines=$(grep -c "^[0-9]" "$OUTPUT_FILE" 2>/dev/null || echo 0)
        size=$(du -h "$OUTPUT_FILE" | cut -f1)
        echo " ✓ ipfilter.dat: ${lines} regole (${size})"
    else
        echo " ✗ ipfilter.dat: NON PRESENTE"
    fi

    if [[ -f "$STATE_FILE" ]]; then
        local lru
        lru=$(grep '^LAST_LIST_UPDATE=' "$STATE_FILE" | cut -d= -f2 || echo 0)
        [[ "$lru" != "0" ]] && echo " ✓ Ultimo agg. liste:   $(date -d "@${lru}" '+%Y-%m-%d %H:%M')"
    fi
    if [[ -f "$SCRIPT_STATE_FILE" ]]; then
        local lsc
        lsc=$(grep '^LAST_SCRIPT_CHECK=' "$SCRIPT_STATE_FILE" | cut -d= -f2 || echo 0)
        [[ "$lsc" != "0" ]] && echo " ✓ Ultimo check script: $(date -d "@${lsc}" '+%Y-%m-%d %H:%M')"
    fi

    crontab -l 2>/dev/null | grep -qF "$CRON_TAG_LIST" && echo " ✓ Cron liste: attivo" || echo " ✗ Cron liste: NON configurato"
    crontab -l 2>/dev/null | grep -qF "$CRON_TAG_CHECK" && echo " ✓ Cron script: attivo" || echo " ✗ Cron script: NON configurato"

    if [[ -f "$LOG_FILE" ]]; then
        echo ""; echo " 📄 Ultimo log:"
        tail -5 "$LOG_FILE" | sed 's/^/   /'
    fi
    echo ""
}

cmd_run() {
    if [[ ! -f "$LIST_SCRIPT" ]]; then echo "❌ Non installato. Esegui: ${MANAGER_NAME} install"; exit 1; fi
    echo "→ Forzo aggiornamento liste (ignora intervallo)..."
    if [[ -f "$STATE_FILE" ]]; then
        local lh lr
        lh=$(grep '^LIST_HASH=' "$STATE_FILE" | cut -d= -f2 || echo "")
        lr=$(grep '^LAST_LIST_RULES=' "$STATE_FILE" | cut -d= -f2 || echo "0")
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
        echo "  Remoto: NON RAGGIUNGIBILE"; echo "❌ Impossibile verificare."; exit 1
    fi
    echo "  Remoto:  v${remote_version}"; echo ""
    version_compare "$remote_version" "$VERSION"
    if [[ "$CMP_RESULT" != "newer" ]]; then
        echo "✅ Sei già all'ultima versione (v${VERSION})."; echo ""; return 0
    fi
    echo "🔄 Aggiornamento: v${VERSION} → v${remote_version}"; echo ""
    local confirm; confirm=$(ask "→ Procedere? [Y/n] ")
    [[ "$confirm" =~ ^[Nn]$ ]] && { echo "Annullato."; return 0; }

    local tmpfile; tmpfile=$(mktemp)
    if ! curl -fsSL --connect-timeout 30 --max-time 60 -o "$tmpfile" "$REMOTE_URL"; then
        rm -f "$tmpfile"; echo "❌ Download fallito."; exit 1
    fi
    head -1 "$tmpfile" | grep -q "bash" || { rm -f "$tmpfile"; echo "❌ File non valido."; exit 1; }
    sudo cp "$tmpfile" "$MANAGER_PATH"; sudo chmod 755 "$MANAGER_PATH"; rm -f "$tmpfile"
    echo "  ✓ Aggiornato a v${remote_version}"
    echo ""
    echo " ⚠️  Per rigenerare gli updater con la nuova versione:"
    echo "   ${MANAGER_NAME} settings  →  salva"
    echo ""
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

EOF
}

# --- ENTRY POINT ---
bootstrap_if_piped "${1:-help}"

case "${1:-help}" in
    install)   cmd_install ;;
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
