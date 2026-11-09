#!/usr/bin/env bash
# ============================================================
# qbittorrent-blocklist-manager.sh
# Gestione completa del filtro IP per qBittorrent
# Versione: 2.2.1
# ============================================================

set -euo pipefail

VERSION="2.2.1"
REMOTE_URL="https://raw.githubusercontent.com/xunil89/qbittorrent-blocklist-manager/refs/heads/main/qbittorrent-blocklist-manager.sh"
INSTALL_DIR="/usr/local/bin"
SELF_INSTALL_PATH="${INSTALL_DIR}/qbittorrent-blocklist-manager.sh"

APP_NAME="qbittorrent-blocklist-updater"
SCRIPT_PATH="${INSTALL_DIR}/${APP_NAME}.sh"
CONFIG_DIR="${HOME}/.config/qBittorrent"
BLOCKLIST_DIR="${CONFIG_DIR}/blocklists"
OUTPUT_FILE="${CONFIG_DIR}/ipfilter.dat"
META_FILE="${CONFIG_DIR}/.blocklist-meta"
CONF_FILE="${CONFIG_DIR}/blocklist.conf"
STATE_FILE="${CONFIG_DIR}/.blocklist-state"
LOG_FILE="/var/log/${APP_NAME}.log"
CRON_TAG="# qbittorrent-blocklist-updater"
CRON_SCHEDULE="0 * * * *"

# --- LISTE PREDEFINITE (usate come checklist) ---
# Formato: "URL|Nome"
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
    for cmd in curl flock gunzip unzip python3 file sha256sum; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "❌ Dipendenze mancanti: ${missing[*]}"
        echo "   Installa con: sudo apt install ${missing[*]}"
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

# --- CONFIG: default e caricamento ---
set_config_defaults() {
    NTFY_URL="https://ntfy.sh"
    NTFY_TOPIC="${1:-}"
    LIST_UPDATE_INTERVAL=4
    SCRIPT_UPDATE_INTERVAL=24
    NOTIFY_MODE="always"
    NOTIFY_SCRIPT_UPDATE="yes"
    # Stato delle liste predefinite: array associativo URL -> 1/0
    declare -gA BLOCK_STATE=()
    local entry
    for entry in "${DEFAULT_BLOCKLISTS[@]}"; do
        BLOCK_STATE["${entry%%|*}"]=1
    done
    # Liste personalizzate aggiunte dall'utente
    declare -ga CUSTOM_BLOCKLISTS=()
}

load_config() {
    if [[ ! -f "$CONF_FILE" ]]; then
        echo "❌ Config non trovata: $CONF_FILE"
        echo "   Esegui prima: $0 install"
        exit 1
    fi
    # shellcheck disable=SC1090
    source "$CONF_FILE"
    # Normalizza array se assenti
    [[ "${#BLOCKLISTS[@]}" -gt 0 ]] || BLOCKLISTS=()
}

# Costruisce l'array attivo BLOCKLISTS da stato + custom
build_active_blocklists() {
    BLOCKLISTS=()
    local entry url
    for entry in "${DEFAULT_BLOCKLISTS[@]}"; do
        url="${entry%%|*}"
        if [[ "${BLOCK_STATE[$url]:-0}" == "1" ]]; then
            BLOCKLISTS+=("$entry")
        fi
    done
    for entry in "${CUSTOM_BLOCKLISTS[@]}"; do
        BLOCKLISTS+=("$entry")
    done
}

# Scrive il config da memoria
write_config() {
    {
        echo "# qbittorrent-blocklist-manager - file di configurazione"
        echo "NTFY_URL=\"${NTFY_URL}\""
        echo "NTFY_TOPIC=\"${NTFY_TOPIC}\""
        echo "LIST_UPDATE_INTERVAL=${LIST_UPDATE_INTERVAL}"
        echo "SCRIPT_UPDATE_INTERVAL=${SCRIPT_UPDATE_INTERVAL}"
        echo "NOTIFY_MODE=\"${NOTIFY_MODE}\""
        echo "NOTIFY_SCRIPT_UPDATE=\"${NOTIFY_SCRIPT_UPDATE}\""
        # Stato liste predefinite
        echo "declare -A BLOCK_STATE=("
        local entry url
        for entry in "${DEFAULT_BLOCKLISTS[@]}"; do
            url="${entry%%|*}"
            echo "    [\"${url}\"]=\"${BLOCK_STATE[$url]:-0}\""
        done
        echo ")"
        # Liste custom
        echo "declare -ga CUSTOM_BLOCKLISTS=("
        for entry in "${CUSTOM_BLOCKLISTS[@]}"; do
            echo "    \"${entry}\""
        done
        echo ")"
    } > "$CONF_FILE"
    # Ricostruisce anche l'array attivo salvato (usato dall'updater)
    build_active_blocklists
    {
        echo "# --- array attivo generato (non modificare) ---"
        echo "ACTIVE_BLOCKLISTS=("
        for entry in "${BLOCKLISTS[@]}"; do
            echo "    \"${entry}\""
        done
        echo ")"
    } >> "$CONF_FILE"
}

# --- WIZARD INTERATTIVO ---
wizard_notify_mode() {
    echo ""
    echo "Modalità notifica aggiornamenti liste:"
    echo "  1) sempre           → notifica a ogni aggiornamento"
    echo "  2) solo errori      → notifica solo se qualche lista fallisce"
    echo "  3) modifiche+errori → notifica solo se cambiano gli IP o ci sono errori"
    local sel; sel=$(ask "Scelta [1]: ")
    [[ -z "$sel" ]] && sel=1
    case "$sel" in
        1) NOTIFY_MODE="always" ;;
        2) NOTIFY_MODE="errors" ;;
        3) NOTIFY_MODE="changes" ;;
        *) echo "  Scelta non valida, uso 'always'"; NOTIFY_MODE="always" ;;
    esac
    echo "  → Modalità: $NOTIFY_MODE"
}

wizard_script_update() {
    echo ""
    echo "Notificare quando è disponibile un nuovo aggiornamento dello script?"
    local sel; sel=$(ask "  [S/n]: ")
    if [[ "$sel" =~ ^[Nn]$ ]]; then
        NOTIFY_SCRIPT_UPDATE="no"
    else
        NOTIFY_SCRIPT_UPDATE="yes"
    fi
    echo "  → Notifica aggiornamento script: $NOTIFY_SCRIPT_UPDATE"
}

wizard_intervals() {
    echo ""
    echo "Imposta intervalli (in ore). Lascia vuoto per mantenere il valore attuale."
    local in_l in_s
    in_l=$(ask "  Aggiornamento liste [${LIST_UPDATE_INTERVAL}h]: ")
    [[ -n "$in_l" ]] && { [[ "$in_l" =~ ^[0-9]+$ ]] && LIST_UPDATE_INTERVAL="$in_l" || echo "  Valore non valido, mantengo ${LIST_UPDATE_INTERVAL}h"; }
    in_s=$(ask "  Controllo aggiornamenti script [${SCRIPT_UPDATE_INTERVAL}h]: ")
    [[ -n "$in_s" ]] && { [[ "$in_s" =~ ^[0-9]+$ ]] && SCRIPT_UPDATE_INTERVAL="$in_s" || echo "  Valore non valido, mantengo ${SCRIPT_UPDATE_INTERVAL}h"; }
    echo "  → Liste ogni ${LIST_UPDATE_INTERVAL}h, script ogni ${SCRIPT_UPDATE_INTERVAL}h"
}

wizard_lists() {
    echo ""
    echo "Seleziona le liste da attivare (predefinite)."
    echo "Digita i numeri separati da spazio, oppure 'a' per tutte, 'n' per nessuna."
    echo "Digita 'k' per mantenere la selezione attuale."
    echo ""
    local i=1 entry url name
    for entry in "${DEFAULT_BLOCKLISTS[@]}"; do
        url="${entry%%|*}"; name="${entry##*|}"
        local mark=" "
        [[ "${BLOCK_STATE[$url]:-0}" == "1" ]] && mark="x"
        printf "  [%s] %2d) %s\n" "$mark" "$i" "$name"
        ((i++)) || true
    done
    echo ""
    local sel; sel=$(ask "Selezione [k]: ")
    if [[ -z "$sel" || "$sel" == "k" ]]; then
        echo "  → Selezione attuale mantenuta"
    elif [[ "$sel" == "a" ]]; then
        for entry in "${DEFAULT_BLOCKLISTS[@]}"; do BLOCK_STATE["${entry%%|*}"]=1; done
        echo "  → Tutte attivate"
    elif [[ "$sel" == "n" ]]; then
        for entry in "${DEFAULT_BLOCKLISTS[@]}"; do BLOCK_STATE["${entry%%|*}"]=0; done
        echo "  → Nessuna attivata"
    else
        # resetta e attiva solo i numeri scelti
        for entry in "${DEFAULT_BLOCKLISTS[@]}"; do BLOCK_STATE["${entry%%|*}"]=0; done
        local num
        for num in $sel; do
            [[ "$num" =~ ^[0-9]+$ ]] || continue
            if (( num >= 1 && num <= ${#DEFAULT_BLOCKLISTS[@]} )); then
                entry="${DEFAULT_BLOCKLISTS[$((num-1))]}"
                BLOCK_STATE["${entry%%|*}"]=1
            fi
        done
        echo "  → Selezione aggiornata"
    fi
}

wizard_add_custom() {
    echo ""
    echo "Vuoi aggiungere link personalizzati? (le liste predefinite sono già gestite sopra)"
    local more; more=$(ask "  Aggiungi link? [s/N]: ")
    [[ ! "$more" =~ ^[Ss]$ ]] && return

    while true; do
        local url name test tmp size
        url=$(ask "  URL lista (vuoto per terminare): ")
        [[ -z "$url" ]] && break
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
        echo ""
    done
}

run_wizard() {
    echo ""
    echo "╔══════════════════════════════════════════════════╗"
    echo "║   Configurazione                                 ║"
    echo "╚══════════════════════════════════════════════════╝"
    wizard_notify_mode
    wizard_script_update
    wizard_intervals
    wizard_lists
    wizard_add_custom
}

# --- UPDATER (heredoc letterale) ---
write_updater_script() {
    cat > "$SCRIPT_PATH" << 'UPDATER_SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

CONFIG_DIR="${HOME}/.config/qBittorrent"
CONF_FILE="${CONFIG_DIR}/blocklist.conf"
BLOCKLIST_DIR="${CONFIG_DIR}/blocklists"
OUTPUT_FILE="${CONFIG_DIR}/ipfilter.dat"
STATE_FILE="${CONFIG_DIR}/.blocklist-state"
LOCK_FILE="/tmp/qbittorrent-blocklist.lock"
LOG_FILE="/var/log/qbittorrent-blocklist.log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

notify() {
    local title="$1" message="$2" priority="${3:-3}" kind="${4:-info}"
    case "${NOTIFY_MODE:-always}" in
        always) ;;
        errors) [[ "$kind" == "error" ]] || return 0 ;;
        changes) [[ "$kind" == "changes" || "$kind" == "error" || "$kind" == "update" ]] || return 0 ;;
        none) return 0 ;;
        *) ;;
    esac
    # La notifica di aggiornamento script rispetta il toggle dedicato
    if [[ "$kind" == "update" && "${NOTIFY_SCRIPT_UPDATE:-yes}" != "yes" ]]; then
        return 0
    fi
    curl -s -o /dev/null -X POST "${NTFY_URL}/${NTFY_TOPIC}" \
        -H "Title: ${title}" -H "Priority: ${priority}" -H "Tags: shield" -d "${message}"
}

download_list() { curl -fsSL --connect-timeout 30 --max-time 120 --retry 2 -o "$2" "$1"; }

convert_to_ipfilter() {
    local input="$1" output="$2" name="$3"
    if [[ "$input" == *.gz ]]; then gunzip -c "$input" >> "$output" 2>/dev/null || true; return; fi
    if [[ "$input" == *.zip ]]; then unzip -p "$input" >> "$output" 2>/dev/null || true; return; fi
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" == \#* || "$line" == //* ]] && continue
        line="${line%%#*}"; line="${line%%//*}"; line="$(echo "$line" | xargs)"
        [[ -z "$line" ]] && continue
        if [[ "$line" =~ ^([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3})/([0-9]{1,2})$ ]]; then
            python3 -c "import ipaddress; net = ipaddress.ip_network('${BASH_REMATCH[1]}/${BASH_REMATCH[2]}', strict=False); print(f'{net[0]},{net.netmask} - ${name}')" >> "$output" 2>/dev/null || continue
        elif [[ "$line" =~ ^([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3})- ]]; then
            echo "${BASH_REMATCH[1]},255.255.255.255 - ${name}" >> "$output"
        elif [[ "$line" =~ ^([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}),([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}) ]]; then
            echo "${line} - ${name}" >> "$output"
        elif [[ "$line" =~ ^([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}) ]]; then
            echo "${BASH_REMATCH[1]},255.255.255.255 - ${name}" >> "$output"
        fi
    done < "$input"
}

do_list_update() {
    log "=== List update started ==="
    mkdir -p "$BLOCKLIST_DIR"
    local TMPDIR
    TMPDIR=$(mktemp -d); trap 'rm -rf "$TMPDIR"' EXIT

    {
        echo "# ============================================================"
        echo "# qBittorrent IP Filter - Auto-generated"
        echo "# Updated: AUTO"
        echo "# Sources: Multiple threat intelligence feeds"
        echo "# ============================================================"
    } > "$OUTPUT_FILE"

    local TOTAL_IPS=0 SUCCESS=0 FAILED=0 FAILED_LISTS=""
    local entry url name tmpfile before after added
    for entry in "${ACTIVE_BLOCKLISTS[@]}"; do
        [[ -z "$entry" || "$entry" == \#* ]] && continue
        url="${entry%%|*}"; name="${entry##*|}"
        log "Downloading: $name"
        tmpfile="${TMPDIR}/$(echo "$name" | tr ' /' '__')"
        if download_list "$url" "$tmpfile" 2>/dev/null; then
            if file "$tmpfile" | grep -q "gzip"; then mv "$tmpfile" "${tmpfile}.gz"; tmpfile="${tmpfile}.gz"
            elif file "$tmpfile" | grep -q "Zip archive"; then mv "$tmpfile" "${tmpfile}.zip"; tmpfile="${tmpfile}.zip"; fi
            before=$(wc -l < "$OUTPUT_FILE")
            convert_to_ipfilter "$tmpfile" "$OUTPUT_FILE" "$name"
            after=$(wc -l < "$OUTPUT_FILE"); added=$((after - before))
            TOTAL_IPS=$((TOTAL_IPS + added)); SUCCESS=$((SUCCESS + 1))
            log "  + $name: +$added entries"
        else
            FAILED=$((FAILED + 1)); FAILED_LISTS+="$name, "; log "  X FAILED: $name"
        fi
    done

    sed -i "s/Updated: AUTO/Updated: $(date '+%Y-%m-%d %H:%M:%S')/" "$OUTPUT_FILE"

    local new_hash old_hash
    new_hash=$(grep -v '^# Updated:' "$OUTPUT_FILE" | sha256sum | cut -d' ' -f1)
    old_hash=$(grep '^LIST_HASH=' "$STATE_FILE" 2>/dev/null | cut -d= -f2 || echo "")

    local kind="info" status="Aggiornamento completato"
    [[ $FAILED -gt 0 ]] && { kind="error"; status="Aggiornamento parziale"; }

    local changes_msg=""
    if [[ -n "$old_hash" && "$old_hash" != "$new_hash" ]]; then
        kind="changes"; changes_msg="• Nuove regole IP caricate (lista modificata)"
    elif [[ -z "$old_hash" ]]; then
        changes_msg="• Primo aggiornamento"
    fi

    local now lsc nv
    now=$(date +%s)
    lsc=$(grep '^LAST_SCRIPT_CHECK=' "$STATE_FILE" 2>/dev/null | cut -d= -f2 || echo 0)
    nv=$(grep '^NOTIFIED_VERSION=' "$STATE_FILE" 2>/dev/null | cut -d= -f2 || echo "")
    {
        echo "LIST_HASH=${new_hash}"
        echo "LAST_LIST_UPDATE=${now}"
        echo "LAST_LIST_RULES=${TOTAL_IPS}"
        echo "LAST_SCRIPT_CHECK=${lsc}"
        echo "NOTIFIED_VERSION=${nv}"
    } > "$STATE_FILE"

    local MSG="${status}
• Liste scaricate: ${SUCCESS}/${#ACTIVE_BLOCKLISTS[@]}
• Entrate totali: ${TOTAL_IPS}
• Fallite: ${FAILED}"
    [[ -n "$changes_msg" ]] && MSG+=$'\n'"${changes_msg}"
    [[ -n "$FAILED_LISTS" ]] && MSG+=$'\n'"• Fallite: ${FAILED_LISTS%, }"

    log "$MSG"
    local prio=3; [[ $FAILED -gt 0 ]] && prio=4
    notify "qBittorrent Blocklist" "$MSG" "$prio" "$kind"
    log "=== List update finished ==="
}

do_script_check() {
    log "=== Script update check started ==="
    local remote_version
    remote_version=$(curl -fsSL --connect-timeout 10 --max-time 30 "${SCRIPT_REMOTE_URL}" 2>/dev/null | grep -m1 '^VERSION=' | sed 's/VERSION=//' | tr -d '"' | tr -d "'" | xargs) || true

    local now lh lru lrr nv
    now=$(date +%s)
    lh=$(grep '^LIST_HASH=' "$STATE_FILE" 2>/dev/null | cut -d= -f2 || echo "")
    lru=$(grep '^LAST_LIST_UPDATE=' "$STATE_FILE" 2>/dev/null | cut -d= -f2 || echo 0)
    lrr=$(grep '^LAST_LIST_RULES=' "$STATE_FILE" 2>/dev/null | cut -d= -f2 || echo 0)
    nv=$(grep '^NOTIFIED_VERSION=' "$STATE_FILE" 2>/dev/null | cut -d= -f2 || echo "")

    if [[ -z "$remote_version" ]]; then
        log "  Script check: remoto non raggiungibile"
        { echo "LIST_HASH=${lh}"; echo "LAST_LIST_UPDATE=${lru}"; echo "LAST_LIST_RULES=${lrr}"; echo "LAST_SCRIPT_CHECK=${now}"; echo "NOTIFIED_VERSION=${nv}"; } > "$STATE_FILE"
        log "=== Script update check finished ==="
        return 0
    fi

    log "  Remoto: v${remote_version} (locale v${SCRIPT_LOCAL_VERSION})"

    local cmp="same"
    if [[ "$remote_version" != "$SCRIPT_LOCAL_VERSION" ]]; then
        local IFS='.'
        local -a a1=($remote_version) a2=($SCRIPT_LOCAL_VERSION)
        local i
        for i in 0 1 2; do
            local n1="${a1[$i]:-0}" n2="${a2[$i]:-0}"
            if (( n1 > n2 )); then cmp="newer"; break; fi
            if (( n1 < n2 )); then cmp="older"; break; fi
        done
    fi

    if [[ "$cmp" == "newer" && "$nv" != "$remote_version" ]]; then
        notify "qBittorrent Manager" "🔄 Nuovo aggiornamento disponibile: v${SCRIPT_LOCAL_VERSION} → v${remote_version}
Esegui: qbittorrent-blocklist-manager.sh update" 4 "update"
        log "  Notifica aggiornamento script inviata (v${remote_version})"
        nv="$remote_version"
    else
        log "  Nessun nuovo aggiornamento da notificare"
    fi

    { echo "LIST_HASH=${lh}"; echo "LAST_LIST_UPDATE=${lru}"; echo "LAST_LIST_RULES=${lrr}"; echo "LAST_SCRIPT_CHECK=${now}"; echo "NOTIFIED_VERSION=${nv}"; } > "$STATE_FILE"
    log "=== Script update check finished ==="
}

exec 200>"$LOCK_FILE"
flock -n 200 || { log "Skipped: another instance is running"; exit 0; }

[[ -f "$CONF_FILE" ]] || { log "Config non trovata: $CONF_FILE"; exit 1; }
# shellcheck disable=SC1090
source "$CONF_FILE"

mkdir -p "$CONFIG_DIR"
if [[ ! -f "$STATE_FILE" ]]; then
    { echo "LIST_HASH="; echo "LAST_LIST_UPDATE=0"; echo "LAST_LIST_RULES=0"; echo "LAST_SCRIPT_CHECK=0"; echo "NOTIFIED_VERSION="; } > "$STATE_FILE"
fi

SCRIPT_LOCAL_VERSION="__LOCAL_VERSION__"
SCRIPT_REMOTE_URL="__REMOTE_URL__"

now=$(date +%s)
last_list=$(grep '^LAST_LIST_UPDATE=' "$STATE_FILE" | cut -d= -f2 || echo 0)
last_script=$(grep '^LAST_SCRIPT_CHECK=' "$STATE_FILE" | cut -d= -f2 || echo 0)

if (( now - last_list >= LIST_UPDATE_INTERVAL * 3600 )); then
    do_list_update
else
    log "List update: non ancora ora (prossimo tra $(( (last_list + LIST_UPDATE_INTERVAL*3600 - now)/60 )) min)"
fi

if (( now - last_script >= SCRIPT_UPDATE_INTERVAL * 3600 )); then
    do_script_check
else
    log "Script check: non ancora ora (prossimo tra $(( (last_script + SCRIPT_UPDATE_INTERVAL*3600 - now)/60 )) min)"
fi
UPDATER_SCRIPT

    sed -i "s|__LOCAL_VERSION__|${VERSION}|" "$SCRIPT_PATH"
    sed -i "s|__REMOTE_URL__|${REMOTE_URL}|" "$SCRIPT_PATH"
    chmod 755 "$SCRIPT_PATH"
}

# --- BOOTSTRAP ---
bootstrap_if_piped() {
    local cmd="${1:-help}"
    if [[ "$cmd" == "install" ]] && { [[ ! -f "$0" ]] || [[ "$0" == "bash" || "$0" == "-bash" ]]; }; then
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
        sudo cp "$tmpfile" "$SELF_INSTALL_PATH"
        sudo chmod 755 "$SELF_INSTALL_PATH"
        rm -f "$tmpfile"
        echo "  ✓ Installato in: $SELF_INSTALL_PATH"
        echo ""
        exec sudo "$SELF_INSTALL_PATH" install
    fi
}

# --- COMANDI ---
cmd_install() {
    echo ""
    echo "╔══════════════════════════════════════════════════╗"
    echo "║   QBittorrent Blocklist Updater - Installazione  ║"
    echo "╚══════════════════════════════════════════════════╝"
    echo ""

    if [[ -f "$SCRIPT_PATH" ]]; then
        echo "⚠️  Installazione già presente."
        local overwrite; overwrite=$(ask "   Sovrascrivere? [y/N] ")
        [[ ! "$overwrite" =~ ^[Yy]$ ]] && { echo "Annullato."; exit 0; }
        echo ""
    fi

    echo "→ Verifica dipendenze..."
    check_deps
    echo "  ✓ OK"

    mkdir -p "$CONFIG_DIR" "$BLOCKLIST_DIR"
    echo "  ✓ Directory create"

    echo "→ Generazione topic ntfy..."
    local topic; topic=$(generate_topic)
    echo "  ✓ Topic: $topic"

    # Inizializza config con default + topic, poi lancia il wizard
    set_config_defaults "$topic"
    run_wizard
    write_config

    echo ""
    echo "→ Installazione script updater..."
    sudo mkdir -p "$INSTALL_DIR"
    write_updater_script
    echo "  ✓ $SCRIPT_PATH"

    sudo touch "$LOG_FILE"; sudo chmod 666 "$LOG_FILE"
    echo "  ✓ Log: $LOG_FILE"

    echo "→ Configurazione cron (tick orario)..."
    if crontab -l 2>/dev/null | grep -qF "$CRON_TAG"; then
        crontab -l 2>/dev/null | grep -vF "$CRON_TAG" | crontab -
    fi
    (crontab -l 2>/dev/null; echo "${CRON_SCHEDULE} ${SCRIPT_PATH} >> ${LOG_FILE} 2>&1 ${CRON_TAG}") | crontab -
    echo "  ✓ Cron attivo (controlla intervalli ogni ora)"

    cat > "$META_FILE" << METAEOF
topic=${topic}
installed=$(date -Iseconds)
script=${SCRIPT_PATH}
output=${OUTPUT_FILE}
version=${VERSION}
METAEOF

    echo ""
    echo "→ Esecuzione primo aggiornamento..."
    echo ""
    "$SCRIPT_PATH"

    echo ""
    echo "════════════════════════════════════════════════════"
    echo " ✅ INSTALLAZIONE COMPLETATA"
    echo "════════════════════════════════════════════════════"
    echo ""
    echo " 📋 Riepilogo:"
    echo "   • Versione:   $VERSION"
    echo "   • Manager:    $SELF_INSTALL_PATH"
    echo "   • Config:     $CONF_FILE"
    echo "   • Ntfy topic: $topic"
    echo ""
    echo " 📱 Notifiche: iscriviti al topic \"$topic\""
    echo "   Browser: https://ntfy.sh/$topic"
    echo ""
    echo " ⚙️  qBittorrent: Strumenti → Opzioni → BitTorrent → Filtro IP"
    echo "   Percorso: $OUTPUT_FILE"
    echo ""
    echo " 🛠️  Per modificare le preferenze: $SELF_INSTALL_PATH settings"
    echo ""
}

cmd_settings() {
    load_config
    # Ricarica stato in memoria dal config
    [[ "${#BLOCK_STATE[@]}" -gt 0 ]] || set_config_defaults "${NTFY_TOPIC}"
    [[ "${#CUSTOM_BLOCKLISTS[@]}" -gt 0 ]] || declare -ga CUSTOM_BLOCKLISTS=()
    run_wizard
    write_config
    write_updater_script
    echo ""
    echo " ✅ Impostazioni salvate."
    echo ""
}

cmd_uninstall() {
    echo ""
    echo "→ Rimozione cron..."
    if crontab -l 2>/dev/null | grep -qF "$CRON_TAG"; then
        crontab -l 2>/dev/null | grep -vF "$CRON_TAG" | crontab -
        echo "  ✓ Cron rimosso"
    else
        echo "  – Nessun cron"
    fi

    echo "→ Rimozione updater..."
    if [[ -f "$SCRIPT_PATH" ]]; then sudo rm -f "$SCRIPT_PATH"; echo "  ✓ Rimosso"; else echo "  – Non trovato"; fi

    echo ""
    local confirm; confirm=$(ask "→ Rimuovere ipfilter.dat, config e liste? [y/N] ")
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        rm -f "$OUTPUT_FILE" "$CONF_FILE" "$STATE_FILE"
        rm -rf "$BLOCKLIST_DIR"
        echo "  ✓ File rimossi"
    else
        echo "  – Conservati"
    fi

    rm -f "$META_FILE"

    local confirm_log; confirm_log=$(ask "→ Rimuovere il log? [y/N] ")
    if [[ "$confirm_log" =~ ^[Yy]$ ]]; then sudo rm -f "$LOG_FILE"; echo "  ✓ Log rimosso"; else echo "  – Log conservato"; fi

    echo ""
    local confirm_self; confirm_self=$(ask "→ Rimuovere anche il manager ($SELF_INSTALL_PATH)? [y/N] ")
    if [[ "$confirm_self" =~ ^[Yy]$ ]]; then sudo rm -f "$SELF_INSTALL_PATH"; echo "  ✓ Manager rimosso"; else echo "  – Manager conservato"; fi

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
    echo "║   QBittorrent Blocklist Updater - Stato          ║"
    echo "╚══════════════════════════════════════════════════╝"
    echo ""
    echo " ✓ Versione manager: v${VERSION}"
    echo " ✓ Aggiornamenti liste:  ogni ${LIST_UPDATE_INTERVAL}h"
    echo " ✓ Controllo script:     ogni ${SCRIPT_UPDATE_INTERVAL}h"
    echo " ✓ Notifiche liste:      ${NOTIFY_MODE}"
    echo " ✓ Notifica agg. script: ${NOTIFY_SCRIPT_UPDATE}"
    echo " ✓ Ntfy topic:           ${NTFY_TOPIC}"
    echo ""

    if [[ -f "$OUTPUT_FILE" ]]; then
        local lines size
        lines=$(grep -c "^[0-9]" "$OUTPUT_FILE" 2>/dev/null || echo 0)
        size=$(du -h "$OUTPUT_FILE" | cut -f1)
        echo " ✓ ipfilter.dat: ${lines} regole (${size})"
    else
        echo " ✗ ipfilter.dat: NON PRESENTE"
    fi

    echo " ✓ Liste attive: ${#BLOCKLISTS[@]}"

    if [[ -f "$STATE_FILE" ]]; then
        local lru lsc
        lru=$(grep '^LAST_LIST_UPDATE=' "$STATE_FILE" | cut -d= -f2 || echo 0)
        lsc=$(grep '^LAST_SCRIPT_CHECK=' "$STATE_FILE" | cut -d= -f2 || echo 0)
        if [[ "$lru" != "0" ]]; then echo " ✓ Ultimo agg. liste:   $(date -d "@${lru}" '+%Y-%m-%d %H:%M')"; fi
        if [[ "$lsc" != "0" ]]; then echo " ✓ Ultimo check script: $(date -d "@${lsc}" '+%Y-%m-%d %H:%M')"; fi
    fi

    if crontab -l 2>/dev/null | grep -qF "$CRON_TAG"; then
        echo " ✓ Cron: attivo"
    else
        echo " ✗ Cron: NON configurato"
    fi

    if [[ -f "$LOG_FILE" ]]; then
        echo ""; echo " 📄 Ultimo log:"
        tail -5 "$LOG_FILE" | sed 's/^/   /'
    fi
    echo ""
}

cmd_run() {
    if [[ ! -f "$SCRIPT_PATH" ]]; then echo "❌ Non installato. Esegui: $0 install"; exit 1; fi
    echo "→ Forzo aggiornamento liste (ignora intervallo)..."
    if [[ -f "$STATE_FILE" ]]; then
        local lh lrr lsc nv
        lh=$(grep '^LIST_HASH=' "$STATE_FILE" | cut -d= -f2 || echo "")
        lrr=$(grep '^LAST_LIST_RULES=' "$STATE_FILE" | cut -d= -f2 || echo "0")
        lsc=$(grep '^LAST_SCRIPT_CHECK=' "$STATE_FILE" | cut -d= -f2 || echo "0")
        nv=$(grep '^NOTIFIED_VERSION=' "$STATE_FILE" | cut -d= -f2 || echo "")
        { echo "LIST_HASH=${lh}"; echo "LAST_LIST_UPDATE=0"; echo "LAST_LIST_RULES=${lrr}"; echo "LAST_SCRIPT_CHECK=${lsc}"; echo "NOTIFIED_VERSION=${nv}"; } > "$STATE_FILE"
    fi
    "$SCRIPT_PATH"
}

cmd_version() { echo "qbittorrent-blocklist-manager v${VERSION}"; }

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
    sudo cp "$tmpfile" "$SELF_INSTALL_PATH"; sudo chmod 755 "$SELF_INSTALL_PATH"; rm -f "$tmpfile"
    echo "  ✓ Aggiornato a v${remote_version}"
    echo ""
    echo " ⚠️  Per rigenerare l'updater con la nuova versione:"
    echo "   $SELF_INSTALL_PATH install"
    echo ""
}

cmd_help() {
    cat << EOF

╔══════════════════════════════════════════════════════════╗
║   QBittorrent Blocklist Manager  v${VERSION}              ║
╚══════════════════════════════════════════════════════════╝

Uso: qbittorrent-blocklist-manager.sh <comando>

  install    Installa e configura tutto (wizard interattivo)
  settings   Modifica preferenze (notifiche, intervalli, liste)
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
    install)
        cmd_install
        ;;
    settings)
        cmd_settings
        ;;
    uninstall)
        cmd_uninstall
        ;;
    status)
        cmd_status
        ;;
    run)
        cmd_run
        ;;
    update)
        cmd_update
        ;;
    version|--version|-v)
        cmd_version
        ;;
    help|--help|-h)
        cmd_help
        ;;
    *)
        echo "❌ Comando sconosciuto: $1"
        echo ""
        cmd_help
        exit 1
        ;;
esac
