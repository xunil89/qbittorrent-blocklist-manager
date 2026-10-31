#!/usr/bin/env bash
# Disinstallazione rapida senza passare dal manager
set -e
echo "→ Rimozione cron..."
crontab -l 2>/dev/null | grep -vF "# qbittorrent-blocklist-updater" | crontab - || true
echo "→ Rimozione file..."
sudo rm -f /usr/local/bin/qbittorrent-blocklist-updater.sh
sudo rm -f /usr/local/bin/qbittorrent-blocklist-manager.sh
sudo rm -f /var/log/qbittorrent-blocklist.log
rm -f "${HOME}/.config/qBittorrent/ipfilter.dat"
rm -f "${HOME}/.config/qBittorrent/.blocklist-meta"
rm -rf "${HOME}/.config/qBittorrent/blocklists"
echo "✅ Disinstallazione completata."
echo "⚠️  Ricorda di disabilitare il filtro IP in qBittorrent."
