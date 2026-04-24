#!/bin/bash
# ==============================================================================
# external/rrdcached/install.sh
# Installation reproductible de RRDcached 1.9.0 sur VM Debian 12
# ==============================================================================
# Usage : sudo bash install.sh
# ==============================================================================

set -euo pipefail

BIND_ADDRESS=$(hostname -I | awk '{print $1}')
RRD_BASE="/var/lib/rrdcached/db"
RRD_JOURNAL="/var/lib/rrdcached/journal"

echo "==> Installation rrdcached sur Debian 12"
apt-get update -qq
apt-get install -y rrdcached

echo "==> Création des répertoires"
mkdir -p "${RRD_BASE}" "${RRD_JOURNAL}"

# Récupérer l'utilisateur du service systemd
RRD_USER=$(systemctl cat rrdcached 2>/dev/null | grep -i "^User=" | cut -d= -f2 || echo "root")
echo "  Utilisateur rrdcached : ${RRD_USER}"
chown -R "${RRD_USER}:${RRD_USER}" /var/lib/rrdcached
chmod -R 755 /var/lib/rrdcached

echo "==> Configuration (valeurs production validées)"
cat > /etc/default/rrdcached << EOF
# RRDcached 1.9.0 — configuration production LibreNMS
# WRITE_TIMEOUT=1800 et WRITE_JITTER=1800 validés en prod
# Ne pas descendre à 300 : charge I/O excessive sur 592k fichiers .rrd
BASE_PATH=${RRD_BASE}/
JOURNAL_PATH=${RRD_JOURNAL}/
WRITE_TIMEOUT=1800
WRITE_JITTER=1800
WRITE_THREADS=4
FLUSH_DEAD_DATA_INTERVAL=3600
NETWORK_OPTIONS="-l ${BIND_ADDRESS}:42217"
EOF

systemctl enable rrdcached
systemctl restart rrdcached

echo "==> Vérification"
systemctl is-active rrdcached
ss -tlnp | grep 42217

echo "✓ RRDcached installé et configuré"
echo "  Écoute : ${BIND_ADDRESS}:42217"
echo "  Base   : ${RRD_BASE}"
echo "  Journal: ${RRD_JOURNAL}"
