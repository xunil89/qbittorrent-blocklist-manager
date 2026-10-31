#!/usr/bin/env bash
# ============================================================
# qbittorrent-blocklist-manager.sh
# Gestione completa del filtro IP per qBittorrent
# Uso: ./qbittorrent-blocklist-manager.sh <comando>
#
# Versione: 1.0.0
# ============================================================

set -euo pipefail

# --- VERSIONE ---
VERSION="1.0.0"
REMOTE_URL="https://raw.githubusercontent.com/xunil89/qbittorrent-blocklist-manager/main/qbittorrent-blocklist-manager.sh"

# --- COSTANTI ---
APP_NAME="qbittorrent-blocklist-updater"
INSTALL_DIR="/usr/local/bin"
SCRIPT_PATH="${INSTALL_DIR}/${APP_NAME}.sh"
SELF_PATH="$(readlink -f "$0")"
CONFIG_DIR="${HOME}/.config/qBittorrent"
BLOCKLIST_DIR="${CONFIG_DIR}/blocklists"
OUTPUT_FILE="${CONFIG_DIR}/ipfilter.dat"
META_FILE="${CONFIG_DIR}/.blocklist-meta"
LOG_FILE="/var/log/${APP_NAME}.log"
CRON_TAG="# qbittorrent-blocklist-updater"
CRON_SCHEDULE="0 */4 * * *"
CRON_CMD="${SCRIPT_PATH} >> ${LOG_FILE} 2>&1 ${CRON_TAG}"

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

  install
    Installa e configura tutto:
    • Verifica dipendenze (curl, flock, gunzip, unzip, python3)
    • Genera un topic ntfy randomizzato
    • Crea lo script updater in /usr/local/bin/
    • Configura cron (aggiornamento ogni 4 ore)
    • Esegue il primo download delle liste

  uninstall
    Rimuove tutto:
    • Rimuove la entry cron
    • Elimina lo script updater
    • Chiede se rimuovere ipfilter.dat e le liste scaricate
    • Chiede se rimuovere il file di log

  status
    Mostra lo stato:
    • Presenza di script, cron e ipfilter.dat
    • Topic ntfy attivo
    • Ultime 5 righe di log

  run
    Esegue un aggiornamento manuale immediato
    (indipendente dalla schedulazione cron)

  update
    Verifica e installa aggiornamenti dello script:
    • Confronta la versione locale con quella remota
    • Se disponibile, scarica e sostituisce lo script
    • Esegue automaticamente il reinstall

  version
    Mostra la versione installata

  help
    Mostra questa guida

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 CONFIGURAZIONE qBITTORRENT
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Strumenti → Opzioni → BitTorrent → Filtro IP
  Percorso: ~/.config/qBittorrent/ipfilter.dat
  Spunta: "Abilita filtro IP"

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 NOTIFICHE NTFY
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Dopo l'installazione il topic generato viene mostrato
  a schermo e salvato in:
  ~/.config/qBittorrent/.blocklist-meta

  • App: cerca il topic nell'app ntfy
  • Browser: https://ntfy.sh/<topic>

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 FILE COINVOLTI
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  /usr/local/bin/qbittorrent-blocklist-updater.sh   Script updater
  ~/.config/qBittorrent/ipfilter.dat                Liste IP bloccate
  ~/.config/qBittorrent/.blocklist-meta             Metadati installazione
  /var/log/qbittorrent-blocklist.log                Log operativo

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 MODIFICARE LE LISTE
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  sudo nano /usr/local/bin/qbittorrent-blocklist-updater.sh
  → Array BLOCKLISTS() all'inizio dello script
  → Formato: "URL|Nome descrittivo"

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
# Ritorna 0 se $1 > $2, 1 se uguali, 2 se $1 < $2
version_compare() {
    local v1="$1"
    local v2="$2"

    if [[ "$v1" == "$v2" ]]; then
        return 0
    fi

    local IFS='.'
    local -a a1=($v1) a2=($v2)

    for i in 0 1 2; do
        local n1="${a1[$i]:-0}"
        local n2="${a2[$i]:-0}"
        if (( n1 > n2 )); then
            return 1
        elif (( n1 < n2 )); then
            return 2
        fi
    done
    return 0
}

# --- INSTALLA SCRIPT UPDATER ---
write_updater_script() {
    local topic="$1"
    cat > "$SCRIPT_PATH" << 'UPDATER_SCRIPT'
#!/usr/bin/env bash
# ============================================================
# qbittorrent-blocklist-updater.sh
# Aggiorna le liste IP bloccate per qBittorrent
# Generato automaticamente - non modificare qui, usa il manager
# ============================================================

set -euo pipefail

# --- CONFIGURAZIONE ---
BLOCKLIST_DIR="${HOME}/.config/qBittorrent/blocklists"
OUTPUT_FILE="${HOME}/.config/qBittorrent/ipfilter.dat"
LOCK_FILE="/tmp/qbittorrent-blocklist.lock"
NTFY_TOPIC="__NTFY_TOPIC__"
NTFY_URL="https://ntfy.sh"
LOG_FILE="/var/log/qbittorrent-blocklist.log"

# --- LISTE ---
# Formato: "URL|Nome descrittivo"
# Aggiungi o rimuovi righe liberamente.
# I commenti con # vengono ignorati.
BLOCKLISTS=(
    # === Anti-Torrent specific ===
    "https://raw.githubusercontent.com/Naunter/BT_BlockLists/master/bt_blocklists.gz|Naunter BT Blocklists"
    "https://www.biglybt.com/blocklist/level1.gz|BiglyBT Level1"
    "https://github.com/ttgapers/transmission-blocklist/releases/latest/download/blocklist.gz|Transmission Blocklist"
    "https://blocklistproject.github.io/Lists/torrent.txt|BlocklistProject Torrent"

    # === Threat Intelligence ===
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

    # === Bogons (IP non assegnati / riservati) ===
    "https://www.team-cymru.com/Services/Bogons/fullbogons-ipv4.txt|Team Cymru Bogons"

    # === Geographic / Government (commentati di default) ===
    # Decommenta per bloccare interi paesi noti per sorveglianza anti-P2P
    # "http://www.ipdeny.com/ipblocks/data/countries/cn.zone|IPDeny China"
    # "http://www.ipdeny.com/ipblocks/data/countries/ru.zone|IPDeny Russia"
    # "http://www.ipdeny.com/ipblocks/data/countries/ir.zone|IPDeny Iran"
    # "http://www.ipdeny.com/ipblocks/data/countries/kp.zone|IPDeny North Korea"
)

# --- FUNZIONI ---

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

notify() {
    local title="$1"
    local message="$2"
    local priority="${3:-3}"
    curl -s -o /dev/null -X POST "${NTFY_URL}/${NTFY_TOPIC}" \
        -H "Title: ${title}" \
        -H "Priority: ${priority}" \
        -H "Tags: shield" \
        -d "${message}"
}

download_list() {
    local url="$1"
    local tmpfile="$2"
    curl -fsSL --connect-timeout 30 --max-time 120 --retry 2 -o "$tmpfile" "$url"
}

convert_to_ipfilter() {
    local input="$1"
    local output="$2"
    local name="$3"

    # File gzip (formato eMule/ipfilter)
    if [[ "$input" == *.gz ]]; then
        gunzip -c "$input" >> "$output" 2>/dev/null || true
        return
    fi

    # File zip
    if [[ "$input" == *.zip ]]; then
        unzip -p "$input" >> "$output" 2>/dev/null || true
        return
    fi

    # File di testo: converte vari formati in "IP,netmask - description"
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Salta commenti e righe vuote
        [[ -z "$line" || "$line" == \#* || "$line" == //* ]] && continue

        # Rimuovi commenti inline
        line="${line%%#*}"
        line="${line%%//*}"
        line="$(echo "$line" | xargs)"
        [[ -z "$line" ]] && continue

        # Formato CIDR (es. 1.2.3.0/24)
        if [[ "$line" =~ ^([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3})/([0-9]{1,2})$ ]]; then
            local ip="${BASH_REMATCH[1]}"
            local prefix="${BASH_REMATCH[2]}"
            local result
            result=$(python3 -c "
import ipaddress
net = ipaddress.ip_network('${ip}/${prefix}', strict=False)
print(f'{net[0]},{net.netmask}')
" 2>/dev/null) || continue
            echo "${result} - ${name}" >> "$output"

        # Formato range (es. 1.2.3.4-5.6.7.8)
        elif [[ "$line" =~ ^([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3})- ]]; then
            echo "${BASH_REMATCH[1]},255.255.255.255 - ${name}" >> "$output"

        # Formato IP singolo
        elif [[ "$line" =~ ^([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3})$ ]]; then
            echo "${BASH_REMATCH[1]},255.255.255.255 - ${name}" >> "$output"

        # Formato "IP,netmask" (già compatibile)
        elif [[ "$line" =~ ^([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}),([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}) ]]; then
            echo "${line} - ${name}" >> "$output"

        # Formato IP con descrizione o altro testo dopo
        elif [[ "$line" =~ ^([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}) ]]; then
            echo "${BASH_REMATCH[1]},255.255.255.255 - ${name}" >> "$output"
        fi
    done < "$input"
}

# --- MAIN ---
exec 200>"$LOCK_FILE"
flock -n 200 || { log "Skipped: another instance is running"; exit 0; }

log "=== Update started ==="
mkdir -p "$BLOCKLIST_DIR"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Header
cat > "$OUTPUT_FILE" << 'EOF'
# ============================================================
# qBittorrent IP Filter - Auto-generated
# Updated: AUTO
# Sources: Multiple threat intelligence feeds
# ============================================================
EOF

TOTAL_IPS=0
SUCCESS=0
FAILED=0
FAILED_LISTS=""

for entry in "${BLOCKLISTS[@]}"; do
    # Salta righe vuote o commenti
    [[ -z "$entry" || "$entry" == \#* ]] && continue

    url="${entry%%|*}"
    name="${entry##*|}"

    log "Downloading: $name"
    tmpfile="${TMPDIR}/$(echo "$name" | tr ' /' '__')"

    if download_list "$url" "$tmpfile" 2>/dev/null; then
        # Rileva tipo file
        if file "$tmpfile" | grep -q "gzip"; then
            mv "$tmpfile" "${tmpfile}.gz"
            tmpfile="${tmpfile}.gz"
        elif file "$tmpfile" | grep -q "Zip archive"; then
            mv "$tmpfile" "${tmpfile}.zip"
            tmpfile="${tmpfile}.zip"
        fi

        before=$(wc -l < "$OUTPUT_FILE")
        convert_to_ipfilter "$tmpfile" "$OUTPUT_FILE" "$name"
        after=$(wc -l < "$OUTPUT_FILE")
        added=$((after - before))
        TOTAL_IPS=$((TOTAL_IPS + added))
        SUCCESS=$((SUCCESS + 1))
        log "  + $name: +$added entries"
    else
        FAILED=$((FAILED + 1))
        FAILED_LISTS+="$name, "
        log "  ✗ FAILED: $name ($url)"
    fi
done

# Timestamp
sed -i "s/Updated: AUTO/Updated: $(date '+%Y-%m-%d %H:%M:%S')/" "$OUTPUT_FILE"

# Notifica
STATUS="✅ Aggiornamento completato"
[[ $FAILED -gt 0 ]] && STATUS="⚠️ Aggiornamento parziale"

MSG="${STATUS}
• Liste scaricate: ${SUCCESS}/${#BLOCKLISTS[@]}
• Entrate totali: ${TOTAL_IPS}
• Fallite: ${FAILED}"
[[ -n "$FAILED_LISTS" ]] && MSG+=$'\n'"• Fallite: ${FAILED_LISTS%, }"

log "$MSG"
notify "qBittorrent Blocklist" "$MSG" 3
log "=== Update finished ==="
UPDATER_SCRIPT

    # Inietta il topic reale
    sed -i "s|__NTFY_TOPIC__|${topic}|" "$SCRIPT_PATH"
    chmod 755 "$SCRIPT_PATH"
}

# --- INSTALL ---
cmd_install() {
    echo ""
    echo "╔══════════════════════════════════════════════════╗"
    echo "║   QBittorrent Blocklist Updater - Installazione  ║"
    echo "║   v${VERSION}                                      ║"
    echo "╚══════════════════════════════════════════════════╝"
    echo ""

    # Verifica se già installato
    if [[ -f "$SCRIPT_PATH" ]]; then
        echo "⚠️  Script già presente: $SCRIPT_PATH"
        read -rp "   Sovrascrivere? [y/N] " overwrite
        [[ ! "$overwrite" =~ ^[Yy]$ ]] && { echo "Annullato."; exit 0; }
        echo ""
    fi

    # Dipendenze
    echo "→ Verifica dipendenze..."
    check_deps
    echo "  ✓ curl, flock, gunzip, unzip, python3, file"

    # Directory
    echo "→ Creazione directory..."
    mkdir -p "$CONFIG_DIR"
    mkdir -p "$BLOCKLIST_DIR"
    echo "  ✓ $CONFIG_DIR"

    # Topic
    echo "→ Generazione topic ntfy..."
    TOPIC=$(generate_topic)
    echo "  ✓ Topic: $TOPIC"

    # Script updater
    echo "→ Installazione script updater..."
    sudo mkdir -p "$INSTALL_DIR"
    write_updater_script "$TOPIC"
    echo "  ✓ $SCRIPT_PATH"

    # Log
    echo "→ Configurazione log..."
    sudo touch "$LOG_FILE"
    sudo chmod 666 "$LOG_FILE"
    echo "  ✓ $LOG_FILE"

    # Cron
    echo "→ Configurazione cron (ogni 4 ore)..."
    if crontab -l 2>/dev/null | grep -qF "$CRON_TAG"; then
        crontab -l 2>/dev/null | grep -vF "$CRON_TAG" | crontab -
    fi
    (crontab -l 2>/dev/null; echo "${CRON_SCHEDULE} ${CRON_CMD}") | crontab -
    echo "  ✓ ${CRON_SCHEDULE}"

    # Metadati
    cat > "$META_FILE" << METAEOF
topic=${TOPIC}
installed=$(date -Iseconds)
script=${SCRIPT_PATH}
output=${OUTPUT_FILE}
version=${VERSION}
METAEOF

    # Primo aggiornamento
    echo ""
    echo "→ Esecuzione primo aggiornamento..."
    echo ""
    "$SCRIPT_PATH"

    # Riepilogo
    echo ""
    echo "════════════════════════════════════════════════════"
    echo " ✅ INSTALLAZIONE COMPLETATA"
    echo "════════════════════════════════════════════════════"
    echo ""
    echo " 📋 Riepilogo:"
    echo "   • Versione:   $VERSION"
    echo "   • Script:     $SCRIPT_PATH"
    echo "   • Output:     $OUTPUT_FILE"
    echo "   • Log:        $LOG_FILE"
    echo "   • Cron:       $CRON_SCHEDULE"
    echo "   • Ntfy topic: $TOPIC"
    echo ""
    echo " 📱 Per ricevere le notifiche:"
    echo "   • App ntfy: iscriviti al topic \"$TOPIC\""
    echo "   • Browser:  https://ntfy.sh/$TOPIC"
    echo ""
    echo " ⚙️  Configura qBittorrent:"
    echo "   Strumenti → Opzioni → BitTorrent → Filtro IP"
    echo "   Percorso: $OUTPUT_FILE"
    echo "   Spunta: \"Abilita filtro IP\""
    echo ""
    echo " 🔄 Per verificare aggiornamenti: $0 update"
    echo " 🗑️  Per disinstallare: $0 uninstall"
    echo ""
}

# --- UNINSTALL ---
cmd_uninstall() {
    echo ""
    echo "╔════════════════════════════════════════════════════╗"
    echo "║   QBittorrent Blocklist Updater - Disinstallazione ║"
    echo "╚════════════════════════════════════════════════════╝"
    echo ""

    # Cron
    echo "→ Rimozione cron..."
    if crontab -l 2>/dev/null | grep -qF "$CRON_TAG"; then
        crontab -l 2>/dev/null | grep -vF "$CRON_TAG" | crontab -
        echo "  ✓ Cron rimosso"
    else
        echo "  – Nessun cron trovato"
    fi

    # Script
    echo "→ Rimozione script..."
    if [[ -f "$SCRIPT_PATH" ]]; then
        sudo rm -f "$SCRIPT_PATH"
        echo "  ✓ Script rimosso"
    else
        echo "  – Script non trovato"
    fi

    # File qBittorrent
    echo ""
    read -rp "→ Rimuovere ipfilter.dat e le liste scaricate? [y/N] " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        rm -f "$OUTPUT_FILE"
        rm -rf "$BLOCKLIST_DIR"
        echo "  ✓ File qBittorrent rimossi"
    else
        echo "  – File qBittorrent conservati"
    fi

    # Metadati
    rm -f "$META_FILE"

    # Log
    read -rp "→ Rimuovere il file di log? [y/N] " confirm_log
    if [[ "$confirm_log" =~ ^[Yy]$ ]]; then
        sudo rm -f "$LOG_FILE"
        echo "  ✓ Log rimosso"
    else
        echo "  – Log conservato"
    fi

    echo ""
    echo "════════════════════════════════════════════════════"
    echo " ✅ DISINSTALLAZIONE COMPLETATA"
    echo "════════════════════════════════════════════════════"
    echo ""
    echo " ⚠️  Disabilita il filtro IP in qBittorrent:"
    echo "   Strumenti → Opzioni → BitTorrent → Filtro IP"
    echo "   Deseleziona \"Abilita filtro IP\""
    echo ""
}

# --- STATUS ---
cmd_status() {
    echo ""
    echo "╔══════════════════════════════════════════════════╗"
    echo "║   QBittorrent Blocklist Updater - Stato          ║"
    echo "╚══════════════════════════════════════════════════╝"
    echo ""

    # Versione
    echo " ✓ Versione:     $VERSION"

    # Script
    if [[ -f "$SCRIPT_PATH" ]]; then
        echo " ✓ Script:       $SCRIPT_PATH"
    else
        echo " ✗ Script:       NON INSTALLATO"
        echo ""
        echo "   Esegui: $0 install"
        echo ""
        return 1
    fi

    # Cron
    if crontab -l 2>/dev/null | grep -qF "$CRON_TAG"; then
        echo " ✓ Cron:         $CRON_SCHEDULE"
    else
        echo " ✗ Cron:         NON CONFIGURATO"
    fi

    # ipfilter.dat
    if [[ -f "$OUTPUT_FILE" ]]; then
        local lines size
        lines=$(grep -c "^[0-9]" "$OUTPUT_FILE" 2>/dev/null || echo 0)
        size=$(du -h "$OUTPUT_FILE" | cut -f1)
        echo " ✓ ipfilter.dat: ${lines} regole (${size})"
    else
        echo " ✗ ipfilter.dat: NON PRESENTE"
    fi

    # Metadati
    if [[ -f "$META_FILE" ]]; then
        local topic installed
        topic=$(grep "^topic=" "$META_FILE" | cut -d= -f2)
        installed=$(grep "^installed=" "$META_FILE" | cut -d= -f2)
        echo " ✓ Ntfy topic:   $topic"
        echo " ✓ Installato:   $installed"
    fi

    # Log
    if [[ -f "$LOG_FILE" ]]; then
        echo ""
        echo " 📄 Ultimo log:"
        tail -5 "$LOG_FILE" | sed 's/^/   /'
    fi
    echo ""
}

# --- RUN ---
cmd_run() {
    if [[ ! -f "$SCRIPT_PATH" ]]; then
        echo "❌ Script non installato. Esegui: $0 install"
        exit 1
    fi
    echo "→ Esecuzione aggiornamento manuale..."
    echo ""
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

    # Scarica il remote header per estrarre la versione
    local remote_version=""
    remote_version=$(curl -fsSL --connect-timeout 10 --max-time 30 "$REMOTE_URL" 2>/dev/null \
        | grep -m1 '^VERSION=' \
        | sed 's/VERSION=//' \
        | tr -d '"' \
        | tr -d "'" \
        | xargs) || true

    if [[ -z "$remote_version" ]]; then
        echo "  Remoto: NON RAGGIUNGIBILE"
        echo ""
        echo "❌ Impossibile verificare la versione remota."
        echo "   URL: $REMOTE_URL"
        exit 1
    fi

    echo "  Remoto:  v${remote_version}"
    echo ""

    # Confronta
    version_compare "$remote_version" "$VERSION"
    local result=$?

    case $result in
        0)
            echo "✅ Sei già all'ultima versione (v${VERSION})."
            echo ""
            return 0
            ;;
        2)
            echo "✅ Sei già all'ultima versione (v${VERSION})."
            echo "   La versione remota (v${remote_version}) è più vecchia."
            echo ""
            return 0
            ;;
        1)
            echo "🔄 Aggiornamento disponibile: v${VERSION} → v${remote_version}"
            echo ""
            read -rp "→ Procedere con l'aggiornamento? [Y/n] " confirm
            if [[ "$confirm" =~ ^[Nn]$ ]]; then
                echo "Annullato."
                return 0
            fi
            ;;
    esac

    # Scarica la nuova versione
    echo ""
    echo "→ Download nuova versione..."
    local tmpfile
    tmpfile=$(mktemp)

    if ! curl -fsSL --connect-timeout 30 --max-time 60 -o "$tmpfile" "$REMOTE_URL"; then
        rm -f "$tmpfile"
        echo "❌ Download fallito."
        exit 1
    fi

    # Verifica che sia uno script bash valido
    if ! head -1 "$tmpfile" | grep -q "bash"; then
        rm -f "$tmpfile"
        echo "❌ Il file scaricato non sembra uno script bash valido."
        exit 1
    fi

    # Sostituisci lo script locale
    echo "→ Aggiornamento script manager..."
    if [[ "$SELF_PATH" == "$SCRIPT_PATH" ]]; then
        sudo cp "$tmpfile" "$SELF_PATH"
    else
        cp "$tmpfile" "$SELF_PATH"
    fi
    chmod +x "$SELF_PATH"
    rm -f "$tmpfile"
    echo "  ✓ Aggiornato a v${remote_version}"

    # Reinstalla lo script updater (mantieni topic esistente)
    if [[ -f "$META_FILE" ]]; then
        local existing_topic
        existing_topic=$(grep "^topic=" "$META_FILE" | cut -d= -f2)
        if [[ -n "$existing_topic" && -f "$SCRIPT_PATH" ]]; then
            echo "→ Reinstallazione updater con topic esistente..."
            # Riesegui il nuovo script con install, ma senza sovrascrivere il topic
            echo "  (il topic ntfy \"$existing_topic\" è stato mantenuto)"
        fi
    fi

    echo ""
    echo "════════════════════════════════════════════════════"
    echo " ✅ AGGIORNAMENTO COMPLETATO"
    echo "   v${VERSION} → v${remote_version}"
    echo "════════════════════════════════════════════════════"
    echo ""
    echo " ⚠️  Esegui di nuovo il comando per usare la nuova versione:"
    echo "   $0 status"
    echo ""
}

# --- ENTRY POINT ---
case "${1:-help}" in
    install)          cmd_install ;;
    uninstall)        cmd_uninstall ;;
    status)           cmd_status ;;
    run)              cmd_run ;;
    update)           cmd_update ;;
    version|--version|-v) cmd_version ;;
    help|--help|-h)   cmd_help ;;
    *)
        echo "❌ Comando sconosciuto: $1"
        echo ""
        cmd_help
        exit 1
        ;;
esac
