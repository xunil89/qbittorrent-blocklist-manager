# qBittorrent Blocklist Manager

Gestione completa e automatizzata del **filtro IP (banlist) per qBittorrent**: scarica liste di indirizzi IP "ostili" da fonti di threat intelligence, le converte in `ipfilter.dat` e tiene tutto aggiornato con due cron separati, con notifiche push via **ntfy**.

![shell](https://img.shields.io/badge/language-bash-black) ![license](https://img.shields.io/badge/license-MIT-green) ![platform](https://img.shields.io/badge/platform-GNU%2FLinux-blue)

## Caratteristiche

- 🧙 **TUI interattiva** per installazione e impostazioni: niente editing manuale di file di configurazione
- ☑️ **Checklist interattiva** per attivare/disattivare le 19 liste predefinite
- ➕ **Gestione liste personalizzate**: aggiungi e rimuovi i tuoi URL direttamente dal menu
- 🔄 **Due updater separati** su **due cron distinti**:
  - aggiornamento **liste IP** (default: ogni **24h**)
  - controllo **nuove versioni dello script** (default: ogni **48h**)
- 🔔 **Notifiche ntfy configurabili**: scegli *cosa* notificare (tutto / solo cambi di stato / solo errori) e la **priorità** (1–5, default 3)
- ✅ **Conversione corretta** CIDR, range e IP singoli nel formato PeerGuardian (`inizio,fine`)
- 🔒 Lock con `flock` anti-concorrenza, hash delle regole per rilevare i cambiamenti, log dedicato
- 🧹 **Disinstallazione pulita** di tutto ciò che viene installato
- 🚀 Auto-update dello script manager dal repository remoto

## Come funziona

```
cron orario ──► qbittorrent-blocklist-list-update.sh   (rispetta LIST_UPDATE_INTERVAL, default 24h)
cron orario ──► qbittorrent-blocklist-script-check.sh  (rispetta SCRIPT_UPDATE_INTERVAL, default 48h)
                        │
                        ├─ Scarica le liste attive
                        ├─ Converte tutto in ipfilter.dat (formatoinizio,fine - nome)
                        ├─ Confronta l'hash → rileva cambiamenti
                        └─ Notifica via ntfy secondo modalità e priorità scelte
```

Gli updater vengono lanciati ogni ora da cron, ma decidono internamente se l'intervallo configurato è trascorso: così funziona con qualsiasi numero di ore, non solo con multipli di 24.

## Liste predefinite

Naunter BT Blocklists · BiglyBT Level1 · Transmission Blocklist · BlocklistProject Torrent · FireHOL Level1/Level2 · Spamhaus DROP/EDROP · DShield SANS · Abuse.ch Feodo / Feodo Recommended / SSLBL / URLhaus · Emerging Threats · Team Cymru Bogons · IPDeny (CN, RU, IR, KP)

Tutte attivabili/disattivabili dalla checklist; puoi aggiungerne altre in `settings → Liste personalizzate`.

## Installazione

```bash
curl -fsSL https://raw.githubusercontent.com/xunil89/qbittorrent-blocklist-manager/refs/heads/main/qbittorrent-blocklist-manager.sh | bash
```

Lo script si installa in `/usr/local/bin/qbittorrent-blocklist-manager` e lancia il wizard. Puoi anche scaricarlo ed eseguirlo direttamente:

```bash
chmod +x qbittorrent-blocklist-manager.sh
./qbittorrent-blocklist-manager.sh install
```

### Dipendenze

`curl`, `python3`, `crontab`, `flock`, `sha256sum` (verificate automaticamente all'installazione).

## Utilizzo

```bash
qbittorrent-blocklist-manager install    # installazione guidata (wizard TUI)
qbittorrent-blocklist-manager settings   # menu impostazioni (TUI)
qbittorrent-blocklist-manager status     # stato, topic ntfy, ultimo log
qbittorrent-blocklist-manager run        # forza l'aggiornamento liste adesso
qbittorrent-blocklist-manager update     # aggiorna lo script all'ultima versione
qbittorrent-blocklist-manager uninstall  # rimozione completa
```

### Il wizard in breve

All'installazione (e in `settings`) configuri:

1. **Notifiche** — cosa notificare:
   - `tutto`: ogni aggiornamento
   - `cambi di stato` (default): liste modificate, fallite, nuove versioni dello script
   - `solo errori`: solamente liste fallite
2. **Priorità ntfy** (1–5, default `3`)
3. **Intervallo aggiornamento liste** (default `24h`)
4. **Intervallo controllo aggiornamenti script** (default `48h`)
5. **Checklist liste predefinite** — digita i numeri per attivarle/disattivarle, `a` tutte, `n` nessuna, `k` conferma
6. **Liste personalizzate** — aggiungi (con test opzionale del download) o rimuovi i tuoi URL

### Notifiche

Al termine dell'installazione ricevi il **topic ntfy** (es. `silent-otter-4821`). Iscriviti:

- Browser: `https://ntfy.sh/<topic>`
- App: aggiungi il server `ntfy.sh` e il topic nel client [ntfy](https://ntfy.sh)

### Configurare qBittorrent

Strumenti → Opzioni → BitTorrent → **Filtro IP** → imposta il percorso:

```
~/.config/qBittorrent/ipfilter.dat
```

Riavvia qBittorrent (o ricarica il filtro) dopo il primo aggiornamento.

## File installati

| Percorso | Descrizione |
|---|---|
| `/usr/local/bin/qbittorrent-blocklist-manager.sh` | Manager (wizard, settings, update, uninstall) |
| `/usr/local/bin/qbittorrent-blocklist-list-update.sh` | Updater liste IP |
| `/usr/local/bin/qbittorrent-blocklist-script-check.sh` | Controllo nuove versioni |
| `~/.config/qBittorrent/blocklist.conf` | Configurazione |
| `~/.config/qBittorrent/ipfilter.dat` | Filtro generato per qBittorrent |
| `~/.config/qBittorrent/.blocklist-state` | Stato aggiornamenti liste |
| `~/.config/qBittorrent/.blocklist-script-state` | Stato controllo versione |
| `~/.config/qBittorrent/blocklist.log` | Log |
| crontab utente | 2 voci (tick orario con tag) |

## Note tecniche

- La conversione è delegata a **un unico processo Python** per lista (gzip/zip testuali riconosciuti automaticamente), quindi è veloce anche su liste enormi.
- Formati supportati in input: CIDR (`1.2.3.0/24`), range (`1.2.3.0-1.2.3.255`, anche con spazi), coppie DAT (`1.2.3.0,1.2.3.255`), IP singoli; commenti `#`, `;` e `//` rimossi.
- CIDR → `network,broadcast` (non netmask!), IP singolo → `ip,ip`: il file generato blocca **esattamente** ciò che deve bloccare.
- La home è risolta correttamente anche quando il manager viene avviato con `sudo` (usa `SUDO_USER`).
- Il topic ntfy è casuale; su server pubblici chi conosce il topic può leggere le notifiche: per privacy puoi impostare un `NTFY_URL` privato (self-hosted) in `blocklist.conf`.

## Disclaimer

Bloccare interi paesi o liste aggressive (es. FireHOL Level2, IPDeny) riduce drasticamente il pool di peer disponibili. Scegli le liste con criterio dalla checklist.

## Licenza

MIT
