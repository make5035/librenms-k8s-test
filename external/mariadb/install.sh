#!/bin/bash
# ==============================================================================
# external/mariadb/install.sh
# Installation reproductible de MariaDB 10.5.29 sur VM Debian 12
# ==============================================================================
# Usage : sudo bash install.sh
# Pré-requis : Debian 12, accès sudo, réseau K8s accessible
# ==============================================================================

set -euo pipefail

MARIADB_VERSION="10.5"
DB_NAME="librenms"
DB_USER="librenms"
DB_PASSWORD="${DB_PASSWORD:-CHANGER_CE_MOT_DE_PASSE}"
K8S_SUBNET="192.168.98.%"
BIND_ADDRESS=$(hostname -I | awk '{print $1}')

echo "==> Installation MariaDB ${MARIADB_VERSION} sur Debian 12"

apt-get update -qq
apt-get install -y mariadb-server

systemctl enable mariadb
systemctl start mariadb

echo "==> Configuration réseau (bind-address = ${BIND_ADDRESS})"
cat > /etc/mysql/mariadb.conf.d/50-server.cnf << EOF
[mysqld]
innodb_file_per_table    = 1
lower_case_table_names   = 0
character-set-server     = utf8mb4
collation-server         = utf8mb4_unicode_ci
max_connections          = 1000
bind-address             = ${BIND_ADDRESS}
EOF

systemctl restart mariadb

echo "==> Création base et utilisateur LibreNMS"
mysql -e "CREATE DATABASE IF NOT EXISTS ${DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
mysql -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'${K8S_SUBNET}' IDENTIFIED BY '${DB_PASSWORD}';"
mysql -e "GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'${K8S_SUBNET}';"
mysql -e "FLUSH PRIVILEGES;"

echo "==> Vérification"
mysql -e "SHOW DATABASES;" | grep "${DB_NAME}"
mysql -e "SELECT user, host FROM mysql.user WHERE user='${DB_USER}';"

echo "✓ MariaDB ${MARIADB_VERSION} installé et configuré"
echo "  Bind address : ${BIND_ADDRESS}"
echo "  Base         : ${DB_NAME}"
echo "  Utilisateur  : ${DB_USER}@${K8S_SUBNET}"
