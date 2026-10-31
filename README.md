```markdown
# 🛡️ qBittorrent Blocklist Manager

Script bash per la gestione automatica di liste IP bloccate in qBittorrent. Aggiorna periodicamente liste di threat intelligence, nodi TOR, peer malevoli e sorgenti governative note per attività anti-P2P.

---

## ⚡ Caratteristiche

- **Aggiornamento automatico** ogni 4 ore via cron
- **Notifiche ntfy** a ogni aggiornamento completato
- **Topic ntfy randomizzato** ad ogni installazione (nessuna sovrapposizione)
- **30+ fonti** di threat intelligence integrate
- **Multi-formato** supporta `.gz`, `.zip`, CIDR, range, IP singoli
- **Facilmente estendibile** aggiungi/rimuovi liste in un array
- **Gestione completa** install / uninstall / status / run

---

## 📦 Requisiti

| Dipendenza | Uso |
|------------|-----|
| `bash` ≥ 4.0 | Script principale |
| `curl` | Download liste |
| `flock` | Lock anti-concorrenza |
| `gunzip` | Decompressione .gz |
| `unzip` | Decompressione .zip |
| `python3` | Conversione CIDR → netmask |
| `file` | Rilevamento formato file |

```bash
sudo apt install curl python3 file unzip
```

---

## 🚀 Installazione

### One-liner (consigliato)

```bash
curl -fsSL https://raw.githubusercontent.com/TUO_USERNAME/qbittorrent-blocklist-manager/main/qbittorrent-blocklist-manager.sh | bash
```

Oppure con `wget`:

```bash
wget -qO- https://raw.githubusercontent.com/TUO_USERNAME/qbittorrent-blocklist-manager/main/qbittorrent-blocklist-manager.sh | bash
```

### Installazione manuale

```bash
# Clona il repository
git clone https://github.com/TUO_USERNAME/qbittorrent-blocklist-manager.git
cd qbittorrent-blocklist-manager

# Rendi eseguibile e installa
chmod +x qbittorrent-blocklist-manager.sh
sudo ./qbittorrent-blocklist-manager.sh install
```

### Aggiornamento

```bash
curl -fsSL https://raw.githubusercontent.com/TUO_USERNAME/qbittorrent-blocklist-manager/main/qbittorrent-blocklist-manager.sh | bash -s -- install
```

Rieseguire `install` sovrascrive lo script updater con l'ultima versione, mantenendo topic e configurazioni esistenti.

### Disinstallazione

```bash
curl -fsSL https://raw.githubusercontent.com/TUO_USERNAME/qbittorrent-blocklist-manager/main/qbittorrent-blocklist-manager.sh | bash -s -- uninstall
```

> **Nota:** sostituisci `TUO_USERNAME` con il tuo username GitHub e `main` con il nome del branch principale se diverso. Se il repo è privato, il one-liner non funziona — serve il clone con autenticazione.

---

## 📱 Configurazione qBittorrent

```
Strumenti → Opzioni → BitTorrent → Filtro IP
```

| Campo | Valore |
|-------|--------|
| Percorso | `~/.config/qBittorrent/ipfilter.dat` |
| Abilita filtro IP | ✅ Spuntato |

---

## 📋 Comandi

| Comando | Descrizione |
|---------|-------------|
| `install` | Installa e configura tutto |
| `uninstall` | Rimuove tutto |
| `status` | Mostra stato, topic, log |
| `run` | Aggiornamento manuale immediato |
| `help` | Mostra la guida |

---

## 📡 Notifiche NTFY

Ad ogni aggiornamento riceverai una notifica con:
- Liste scaricate con successo / totali
- Numero di regole generate
- Eventuali liste fallite

**Per ricevere le notifiche:**
- **App**: cerca il topic generato nell'app ntfy
- **Browser**: `https://ntfy.sh/<topic>`
- **CLI**: `ntfy subscribe <topic>`

---

## 📚 Liste Incluse

### Anti-Torrent Specific

| Fonte | Descrizione |
|-------|-------------|
| Naunter BT Blocklists | Community-curata, specifica P2P |
| BiglyBT Level1 | Fork di Vuze, ben mantenuta |
| Transmission Blocklist | GitHub attivo, formato eMule |
| BlocklistProject Torrent | Tracker e fonti torrent malevole |

### Threat Intelligence

| Fonte | Descrizione |
|-------|-------------|
| FireHOL Level 1-2 | Aggregatore, aggiornamenti frequenti |
| Spamhaus DROP/EDROP | Standard di settore, reti abusive |
| DShield (SANS) | Top attacker IP |
| Abuse.ch Feodo | Trojan bancari |
| Abuse.ch SSLBL | Certificati SSL malevoli |
| Abuse.ch URLhaus | Malware distribution |
| Emerging Threats | IP compromessi |

### Bogons

| Fonte | Descrizione |
|-------|-------------|
| Team Cymru | IP non assegnati / riservati |

### Geographic (opzionale, commentato)

| Fonte | Descrizione |
|-------|-------------|
| IPDeny CN | Cina |
| IPDeny RU | Russia |
| IPDeny IR | Iran |
| IPDeny KP | Corea del Nord |

> ⚠️ **Attenzione:** i blocchi geografici sono molto aggressivi. Se usi tracker con peer in quei paesi, perderai molti seed.

---

## ✏️ Personalizzare le Liste

```bash
sudo nano /usr/local/bin/qbittorrent-blocklist-updater.sh
```

Trova l'array `BLOCKLISTS()` all'inizio dello script:

```bash
BLOCKLISTS=(
    # === Anti-Torrent specific ===
    "https://raw.githubusercontent.com/Naunter/BT_BlockLists/master/bt_blocklists.gz|Naunter BT Blocklists"
    "https://www.biglybt.com/blocklist/level1.gz|BiglyBT Level1"

    # === Aggiungi la tua lista qui ===
    "https://example.com/my-list.txt|La Mia Lista"

    # === Geographic (commentati) ===
    # "http://www.ipdeny.com/ipblocks/data/countries/cn.zone|IPDeny China"
)
```

**Formato**: `"URL|Nome descrittivo"`

---

## 📁 File Creati

| Percorso | Descrizione |
|----------|-------------|
| `/usr/local/bin/qbittorrent-blocklist-updater.sh` | Script updater |
| `~/.config/qBittorrent/ipfilter.dat` | Liste IP bloccate |
| `~/.config/qBittorrent/.blocklist-meta` | Metadati installazione |
| `/var/log/qbittorrent-blocklist.log` | Log operativo |

---

## 🗑️ Disinstallazione

```bash
./qbittorrent-blocklist-manager.sh uninstall
```

Chiede conferma prima di rimuovere `ipfilter.dat` e il log.

---

## 🔧 Troubleshooting

| Problema | Soluzione |
|----------|-----------|
| `flock: command not found` | `sudo apt install util-linux` |
| `python3: command not found` | `sudo apt install python3` |
| Liste che falliscono sempre | Controlla il log: `cat /var/log/qbittorrent-blocklist.log` |
| qBittorrent non carica il file | Verifica il percorso nelle impostazioni |
| Troppe regole (lento) | Rimuovi FireHOL Level2 o le liste geografiche |

---

## 📊 Formato Output (`ipfilter.dat`)

```
# ============================================================
# qBittorrent IP Filter - Auto-generated
# Updated: 2025-01-15 04:00:12
# Sources: Multiple threat intelligence feeds
# ============================================================
1.0.0.0,255.255.255.255 - Spamhaus DROP
1.0.4.0,255.255.255.0 - FireHOL Level1
2.56.219.0,255.255.255.0 - Naunter BT Blocklists
...
```

---

## ⚖️ Note Legali

- Questo script blocca **peer in entrata** su qBittorrent. Non impedisce al tuo IP di essere bloccato da altri.
- Le liste geografiche sono **opzionali** e commentate di default.
- L'uso di qBittorrent per scaricare materiale protetto da copyright è responsabilità dell'utente.

---

## 📄 Licenza

MIT — usa, modifica, distribuisci liberamente.
```

Copia tutto il blocco e salvalo come `README.md` nella root del repo.
