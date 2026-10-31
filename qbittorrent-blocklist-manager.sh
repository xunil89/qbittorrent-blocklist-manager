#!/usr/bin/env bash
# ============================================================
# qbittorrent-blocklist-manager.sh
# Gestione completa del filtro IP per qBittorrent
# Uso: ./qbittorrent-blocklist-manager.sh <comando>
#
# Versione: 1.0.4
# ============================================================

set -euo pipefail

# --- VERSIONE ---
VERSION="1.0.3"
REMOTE_URL="https://raw.githubusercontent.com/xunil89/qbittorrent-blocklist-manager/main/qbittorrent-blocklist-manager.sh"
INSTALL_DIR="/usr/local/bin"
SELF_INSTALL_PATH="${INSTALL_DIR}/qbittorrent-blocklist-manager.sh"

# --- COSTANTI ---
APP_NAME="qbittorrent-blocklist-updater"
SCRIPT_PATH="${INSTALL_DIR}/${APP_NAME}.sh"
CONFIG_DIR="${HOME}/.config/qBittorrent"
BLOCKLIST_DIR="${CONFIG_DIR}/blocklists"
OUTPUT_FILE="${CONFIG_DIR}/ipfilter.dat"
META_FILE="${CONFIG_DIR}/.blocklist-meta"
LOG_FILE="/var/log/${APP_NAME}.log"
CRON_TAG="# qbittorrent-blocklist-updater"
CRON_SCHEDULE="0 */4 * * *"
CRON_CMD="${SCRIPT_PATH} >> ${LOG_FILE} 2>&1 ${CRON_TAG}"

# --- BOOTSTRAP: auto-installazione SOLO per "install" da pipe ---
bootstrap_if_piped() {
    local cmd="${1:-install}"
    if [[ "$cmd" == "install" ]] && { [[ ! -f "$0" ]] || [[ "$0" == "bash" || "$0" == "-bash" ]]; }; then
        echo "→ Installazione da remoto..."
        echo "  Download: $REMOTE_URL"

        local tmpfile
        tmpfile=$(mktemp)
        if ! curl -fsSL --connect-timeout 30 --max-time 60 -o "$tmpfile" "$REMOTE_URL"; then
            rm -f "$tmpfile"
            echo "❌ Download fallito: $REMOTE_URL"
            exit 1
        fi
        if ! head -1 "$tmpfile" | grep -q "bash"; then
            rm -f "$tmpfile"
            echo "❌ File scaricato non valido."
            exit 1
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

# --- HELP ---
cmd_help() {
    cat << EOF

╔══════════════════════════════════════════════════════════╗
║   QBittorrent Blocklist Manager  v${VERSION}              ║
╚══════════════════════════════════════════════════════════╝

Uso: qbittorrent-blocklist-manager.sh <comando>

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 COMANDI
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  install    Installa e configura tutto
  uninstall  Rimuove tutto (cron, script, file, manager)
  status     Mostra stato, topic, log
  run        Aggiornamento manuale immediato
  update     Verifica e installa aggiornamenti dello script
  version    Mostra la versione installata
  help       Mostra questa guida

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

EOF
}

# --- GENERA TOPIC NTFY ---
generate_topic() {
    local adjectives=(
        "crimson" "silent" "frozen" "dark" "swift"
        "iron" "ghost" "neon" "vivid" "amber"
        "cobalt" "ember" "frost" "lunar" "onyx"
        "pixel" "quartz" "raven" "solar" "void"
        "blaze" "drift" "echo" "flux" "glow"
    )
    local animals=(
        "otter" "falcon" "wolf" "heron" "lynx"
        "mantis" "cobra" "badger" "shark" "viper"
        "moose" "crane" "wren" "stoat" "puma"
        "moth" "newt" "vole" "crow" "fox"
        "hawk" "ibis" "kiwi" "lark" "mule"
    )
    local adj="${adjectives[$((RANDOM % ${#adjectives[@]}))]}"
    local ani="${animals[$((RANDOM % ${#animals[@]}))]}"
    local num=$((RANDOM % 9000 + 1000))
    echo "${adj}-${ani}-${num}"
}

# --- LETTURA INTERATTIVA ROBUSTA (funziona anche da pipe) ---
ask() {
    local prompt="$1"
    local answer
    if [[ -t 0 ]]; then
        read -rp "$prompt" answer
    else
        read -rp "$prompt" answer < /dev/tty
    fi
    echo "$answer"
}

# --- VERIFICA DIPENDENZE ---
check_deps() {
    local missing=()
    for cmd in curl flock gunzip unzip python3 file; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "❌ Dipendenze mancanti: ${missing[*]}"
        echo "   Installa con: sudo apt install ${missing[*]}"
        exit 1
    fi
}

# --- CONFRONTA VERSIONI (semver) ---
version_compare() {
    local v1="$1" v2="$2"
    if [[ "$v1" == "$v2" ]]; then CMP_RESULT="same"; return; fi
    local IFS='.'
    local -a a1=($v1) a2=($v2)
    for i in 0 1 2; do
        local n1="${a1[$i]:-0}" n2="${a2[$i]:-0}"
        if (( n1 > n2 )); then CMP_RESULT="newer"; return; fi
        if (( n1 < n2 )); then CMP_RESULT="older"; return; fi
    done
    CMP_RESULT="same"
}

# --- INSTALLA SCRIPT UPDATER ---
write_updater_script() {
    local topic="$1"
    cat > "$SCRIPT_PATH" << 'UPDATER_SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

BLOCKLIST_DIR="${HOME}/.config/qBittorrent/blocklists"
OUTPUT_FILE="${HOME}/.config/qBittorrent/ipfilter.dat"
LOCK_FILE="/tmp/qbittorrent-blocklist.lock"
NTFY_TOPIC="__NTFY_TOPIC__"
NTFY_URL="https://ntfy.sh"
LOG_FILE="/var/log/qbittorrent-blocklist.log"

BLOCKLISTS=(
    "https://raw.githubusercontent.com/Naunter/BT_BlockLists/master/bt_blocklists.gz|Naunter BT Blocklists"
    # "https://www.biglybt.com/blocklist/level1.gz|BiglyBT Level1"
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
    # "https://urlhaus.abuse.ch/downloads/text/|Abuse.ch URLhaus"
    "http://rules.emergingthreats.net/blockrules/compromised-ips.txt|Emerging Threats"
    # "https://www.team-cymru.com/Services/Bogons/fullbogons-ipv4.txt|Team Cymru Bogons"
    # "http://www.ipdeny.com/ipblocks/data/countries/cn.zone|IPDeny China"
    # "http://www.ipdeny.com/ipblocks/data/countries/ru.zone|IPDeny Russia"
    # "http://www.ipdeny.com/ipblocks/data/countries/ir.zone|IPDeny Iran"
    # "http://www.ipdeny.com/ipblocks/data/countries/kp.zone|IPDeny North Korea"
)

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

notify() {
    curl -s -o /dev/null -X POST "${NTFY_URL}/${NTFY_TOPIC}" \
        -H "Title: $1" -H "Priority: ${3:-3}" -H "Tags: shield" -d "$2"
}

download_list() {
    curl -fsSL --connect-timeout 30 --max-time 120 --retry 2 -o "$2" "$1"
}

convert_to_ipfilter() {
    local input="$1" output="$2" name="$3"
    if [[ "$input" == *.gz ]]; then
        gunzip -c "$input" >> "$output" 2>/dev/null || true; return
    fi
    if [[ "$input" == *.zip ]]; then
        unzip -p "$input" >> "$output" 2>/dev/null || true; return
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" == \#* || "$line" == //* ]] && continue
        line="${line%%#*}"; line="${line%%//*}"; line="$(echo "$line" | xargs)"
        [[ -z "$line" ]] && continue
        if [[ "$line" =~ ^([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3})/([0-9]{1,2})$ ]]; then
            python3 -c "
import ipaddress
net = ipaddress.ip_network('${BASH_REMATCH[1]}/${BASH_REMATCH[2]}', strict=False)
print(f'{net[0]},{net.netmask} - ${name}')
" >> "$output" 2>/dev/null || continue
        elif [[ "$line" =~ ^([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3})- ]]; then
            echo "${BASH_REMATCH[1]},255.255.255.255 - ${name}" >> "$output"
        elif [[ "$line" =~ ^([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}),([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}) ]]; then
            echo "${line} - ${name}" >> "$output"
        elif [[ "$line" =~ ^([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}) ]]; then
            echo "${BASH_REMATCH[1]},255.255.255.255 - ${name}" >> "$output"
        fi
    done < "$input"
}

exec 200>"$LOCK_FILE"
flock -n 200 || { log "Skipped: another instance is running"; exit 0; }

log "=== Update started ==="
mkdir -p "$BLOCKLIST_DIR"
TMPDIR=$(mktemp -d); trap 'rm -rf "$TMPDIR"' EXIT

cat > "$OUTPUT_FILE" << 'EOF'
# ============================================================
# qBittorrent IP Filter - Auto-generated
# Updated: AUTO
# Sources: Multiple threat intelligence feeds
# ============================================================
EOF

TOTAL_IPS=0; SUCCESS=0; FAILED=0; FAILED_LISTS=""

for entry in "${BLOCKLISTS[@]}"; do
    [[ -z "$entry" || "$entry" == \#* ]] && continue
    url="${entry%%|*}"; name="${entry##*|}"
    log "Downloading: $name"
    tmpfile="${TMPDIR}/$(echo "$name" | tr ' /' '__')"
    if download_list "$url" "$tmpfile" 2>/dev/null; then
        if file "$tmpfile" | grep -q "gzip"; then
            mv "$tmpfile" "${tmpfile}.gz"; tmpfile="${tmpfile}.gz"
        elif file "$tmpfile" | grep -q "Zip archive"; then
            mv "$tmpfile" "${tmpfile}.zip"; tmpfile="${tmpfile}.zip"
        fi
        before=$(wc -l < "$OUTPUT_FILE")
        convert_to_ipfilter "$tmpfile" "$OUTPUT_FILE" "$name"
        after=$(wc -l < "$OUTPUT_FILE")
        added=$((after - before)); TOTAL_IPS=$((TOTAL_IPS + added)); SUCCESS=$((SUCCESS + 1))
        log "  + $name: +$added entries"
    else
        FAILED=$((FAILED + 1)); FAILED_LISTS+="$name, "; log "  X FAILED: $name"
    fi
done

sed -i "s/Updated: AUTO/Updated: $(date '+%Y-%m-%d %H:%M:%S')/" "$OUTPUT_FILE"

STATUS="Aggiornamento completato"; [[ $FAILED -gt 0 ]] && STATUS="Aggiornamento parziale"
MSG="${STATUS}
• Liste scaricate: ${SUCCESS}/${#BLOCKLISTS[@]}
• Entrate totali: ${TOTAL_IPS}
• Fallite: ${FAILED}"
[[ -n "$FAILED_LISTS" ]] && MSG+=$'\n'"• Fallite: ${FAILED_LISTS%, }"
log "$MSG"
notify "qBittorrent Blocklist" "$MSG" 3
log "=== Update finished ==="
UPDATER_SCRIPT

    sed -i "s|__NTFY_TOPIC__|${topic}|" "$SCRIPT_PATH"
    chmod 755 "$SCRIPT_PATH"
}

# --- INSTALL ---
cmd_install() {
    echo ""
    echo "╔══════════════════════════════════════════════════╗"
    echo "║   QBittorrent Blocklist Updater - Installazione  ║"
    echo "╚══════════════════════════════════════════════════╝"
    echo ""

    if [[ -f "$SCRIPT_PATH" ]]; then
        echo "⚠️  Script già presente: $SCRIPT_PATH"
        local overwrite; overwrite=$(ask "   Sovrascrivere? la sovrascrittura cambierà il topic ntfy [y/N] ")
        [[ ! "$overwrite" =~ ^[Yy]$ ]] && { echo "Annullato."; exit 0; }
        echo ""
    fi

    echo "→ Verifica dipendenze..."
    check_deps
    echo "  ✓ curl, flock, gunzip, unzip, python3, file"

    echo "→ Creazione directory..."
    mkdir -p "$CONFIG_DIR" "$BLOCKLIST_DIR"
    echo "  ✓ $CONFIG_DIR"

    echo "→ Generazione topic ntfy..."
    TOPIC=$(generate_topic)
    echo "  ✓ Topic: $TOPIC"

    echo "→ Installazione script updater..."
    sudo mkdir -p "$INSTALL_DIR"
    write_updater_script "$TOPIC"
    echo "  ✓ $SCRIPT_PATH"

    echo "→ Configurazione log..."
    sudo touch "$LOG_FILE"
    sudo chmod 666 "$LOG_FILE"
    echo "  ✓ $LOG_FILE"

    echo "→ Configurazione cron (ogni 4 ore)..."
    if crontab -l 2>/dev/null | grep -qF "$CRON_TAG"; then
        crontab -l 2>/dev/null | grep -vF "$CRON_TAG" | crontab -
    fi
    (crontab -l 2>/dev/null; echo "${CRON_SCHEDULE} ${CRON_CMD}") | crontab -
    echo "  ✓ ${CRON_SCHEDULE}"

    cat > "$META_FILE" << METAEOF
topic=${TOPIC}
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
    echo "   • Script:     $SCRIPT_PATH"
    echo "   • Output:     $OUTPUT_FILE"
    echo "   • Log:        $LOG_FILE"
    echo "   • Cron:       $CRON_SCHEDULE"
    echo "   • Ntfy topic: $TOPIC"
    echo ""
    echo " 📱 Notifiche: iscriviti al topic \"$TOPIC\""
    echo "   Browser: https://ntfy.sh/$TOPIC"
    echo ""
    echo " ⚙️  qBittorrent: Strumenti → Opzioni → BitTorrent → Filtro IP"
    echo "   Percorso: $OUTPUT_FILE"
    echo ""
    echo " 🔄 Aggiornare: $SELF_INSTALL_PATH update"
    echo " 🗑️  Disinstallare: $SELF_INSTALL_PATH uninstall"
    echo ""
}

# --- UNINSTALL ---
cmd_uninstall() {
    echo ""
    echo "╔════════════════════════════════════════════════════╗"
    echo "║   QBittorrent Blocklist Updater - Disinstallazione ║"
    echo "╚════════════════════════════════════════════════════╝"
    echo ""

    echo "→ Rimozione cron..."
    if crontab -l 2>/dev/null | grep -qF "$CRON_TAG"; then
        crontab -l 2>/dev/null | grep -vF "$CRON_TAG" | crontab -
        echo "  ✓ Cron rimosso"
    else
        echo "  – Nessun cron trovato"
    fi

    echo "→ Rimozione script updater..."
    if [[ -f "$SCRIPT_PATH" ]]; then
        sudo rm -f "$SCRIPT_PATH"; echo "  ✓ Rimosso"
    else
        echo "  – Non trovato"
    fi

    echo ""
    local confirm; confirm=$(ask "→ Rimuovere ipfilter.dat e le liste? [y/N] ")
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        rm -f "$OUTPUT_FILE"; rm -rf "$BLOCKLIST_DIR"; echo "  ✓ File qBittorrent rimossi"
    else
        echo "  – Conservati"
    fi

    rm -f "$META_FILE"

    local confirm_log; confirm_log=$(ask "→ Rimuovere il log? [y/N] ")
    if [[ "$confirm_log" =~ ^[Yy]$ ]]; then
        sudo rm -f "$LOG_FILE"; echo "  ✓ Log rimosso"
    else
        echo "  – Log conservato"
    fi

    # Rimuove anche il manager stesso (per ultimo)
    echo ""
    local confirm_self; confirm_self=$(ask "→ Rimuovere anche il manager ($SELF_INSTALL_PATH)? [y/N] ")
    if [[ "$confirm_self" =~ ^[Yy]$ ]]; then
        sudo rm -f "$SELF_INSTALL_PATH"; echo "  ✓ Manager rimosso"
    else
        echo "  – Manager conservato"
    fi

    echo ""
    echo "════════════════════════════════════════════════════"
    echo " ✅ DISINSTALLAZIONE COMPLETATA"
    echo "════════════════════════════════════════════════════"
    echo ""
    echo " ⚠️  Disabilita il filtro IP in qBittorrent."
    echo ""
}

# --- STATUS ---
cmd_status() {
    echo ""
    echo "╔══════════════════════════════════════════════════╗"
    echo "║   QBittorrent Blocklist Updater - Stato          ║"
    echo "╚══════════════════════════════════════════════════╝"
    echo ""
    echo " ✓ Versione:     $VERSION"

    if [[ -f "$SCRIPT_PATH" ]]; then
        echo " ✓ Script:       $SCRIPT_PATH"
    else
        echo " ✗ Script:       NON INSTALLATO"
        echo ""; echo "   Esegui: $0 install"; echo ""; return 1
    fi

    if crontab -l 2>/dev/null | grep -qF "$CRON_TAG"; then
        echo " ✓ Cron:         $CRON_SCHEDULE"
    else
        echo " ✗ Cron:         NON CONFIGURATO"
    fi

    if [[ -f "$OUTPUT_FILE" ]]; then
        local lines size
        lines=$(grep -c "^[0-9]" "$OUTPUT_FILE" 2>/dev/null || echo 0)
        size=$(du -h "$OUTPUT_FILE" | cut -f1)
        echo " ✓ ipfilter.dat: ${lines} regole (${size})"
    else
        echo " ✗ ipfilter.dat: NON PRESENTE"
    fi

    if [[ -f "$META_FILE" ]]; then
        local topic installed
        topic=$(grep "^topic=" "$META_FILE" | cut -d= -f2)
        installed=$(grep "^installed=" "$META_FILE" | cut -d= -f2)
        echo " ✓ Ntfy topic:   $topic"
        echo " ✓ Installato:   $installed"
    fi

    if [[ -f "$LOG_FILE" ]]; then
        echo ""; echo " 📄 Ultimo log:"
        tail -5 "$LOG_FILE" | sed 's/^/   /'
    fi
    echo ""
}

# --- RUN ---
cmd_run() {
    if [[ ! -f "$SCRIPT_PATH" ]]; then
        echo "❌ Script non installato. Esegui: $0 install"; exit 1
    fi
    echo "→ Esecuzione aggiornamento manuale..."; echo ""
    "$SCRIPT_PATH"
}

# --- VERSION ---
cmd_version() {
    echo "qbittorrent-blocklist-manager v${VERSION}"
}

# --- UPDATE ---
cmd_update() {
    echo ""
    echo "→ Verifica aggiornamenti..."
    echo "  Locale:  v${VERSION}"

    local remote_version=""
    remote_version=$(curl -fsSL --connect-timeout 10 --max-time 30 "$REMOTE_URL" 2>/dev/null \
        | grep -m1 '^VERSION=' | sed 's/VERSION=//' | tr -d '"' | tr -d "'" | xargs) || true

    if [[ -z "$remote_version" ]]; then
        echo "  Remoto: NON RAGGIUNGIBILE"
        echo ""; echo "❌ Impossibile verificare la versione remota."
        echo "   URL: $REMOTE_URL"; exit 1
    fi

    echo "  Remoto:  v${remote_version}"
    echo ""

    version_compare "$remote_version" "$VERSION"
    if [[ "$CMP_RESULT" != "newer" ]]; then
        echo "✅ Sei già all'ultima versione (v${VERSION})."; echo ""; return 0
    fi

    echo "🔄 Aggiornamento disponibile: v${VERSION} → v${remote_version}"
    echo ""
    local confirm; confirm=$(ask "→ Procedere? [Y/n] ")
    if [[ "$confirm" =~ ^[Nn]$ ]]; then echo "Annullato."; return 0; fi

    echo ""
    echo "→ Download nuova versione..."
    local tmpfile; tmpfile=$(mktemp)
    if ! curl -fsSL --connect-timeout 30 --max-time 60 -o "$tmpfile" "$REMOTE_URL"; then
        rm -f "$tmpfile"; echo "❌ Download fallito."; exit 1
    fi
    if ! head -1 "$tmpfile" | grep -q "bash"; then
        rm -f "$tmpfile"; echo "❌ File non valido."; exit 1
    fi

    echo "→ Aggiornamento script manager..."
    sudo cp "$tmpfile" "$SELF_INSTALL_PATH"
    sudo chmod 755 "$SELF_INSTALL_PATH"
    rm -f "$tmpfile"
    echo "  ✓ Aggiornato a v${remote_version}"

    echo ""
    echo "════════════════════════════════════════════════════"
    echo " ✅ AGGIORNAMENTO COMPLETATO"
    echo "   v${VERSION} → v${remote_version}"
    echo "════════════════════════════════════════════════════"
    echo ""
    echo " ⚠️  Per aggiornare anche l'updater alle nuove liste:"
    echo "   $SELF_INSTALL_PATH install"
    echo ""
}

# --- ENTRY POINT ---
bootstrap_if_piped "${1:-install}"

case "${1:-help}" in
    install)
        cmd_install
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
