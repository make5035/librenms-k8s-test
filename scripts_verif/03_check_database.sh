#!/usr/bin/env bash
# =============================================================================
# Script      : 03_check_database.sh
# Description : Validation connectivité et intégrité base de données MariaDB
# Exécution   : Bastion / VM Docker / nœud avec accès réseau à la VM DB
# Prérequis   : mysql CLI OU Docker disponible, accès réseau au port DB
# Usage       : ./03_check_database.sh [OPTIONS]
#   --db-host HOST        IP/hostname de la VM MariaDB (obligatoire)
#   --db-port PORT        Port (défaut: 3306)
#   --db-name NAME        Base de données (défaut: librenms)
#   --db-user USER        Utilisateur (défaut: librenms)
#   --db-password PASS    Mot de passe (ou via DB_PASSWORD env)
#   --docker-image IMG    Image Docker pour mysql CLI (défaut: mariadb:10.5)
#   --use-docker          Forcer l'utilisation de Docker même si mysql disponible
#   --source-host HOST    VM Docker source pour comparaison (optionnel)
#   --verbose             Mode debug
#   --dry-run             Simulation
#   --env-file FILE       Fichier .env
# Compatible  : CI/CD
# =============================================================================

set -euo pipefail

# ─── Valeurs par défaut ───────────────────────────────────────────────────────
DB_HOST="${DB_HOST:-}"
DB_PORT="${DB_PORT:-3306}"
DB_NAME="${DB_NAME:-librenms}"
DB_USER="${DB_USER:-librenms}"
DB_PASSWORD="${DB_PASSWORD:-}"
DOCKER_IMAGE="${DOCKER_IMAGE:-mariadb:10.5}"
USE_DOCKER="${USE_DOCKER:-false}"
SOURCE_CONTAINER="${SOURCE_CONTAINER:-}"   # Nom du container source Docker (pour comparaison)
MIN_TABLES="${MIN_TABLES:-100}"            # Nombre minimum de tables attendu
KUBECONTEXT="${KUBECONTEXT:-}"
VERBOSE="${VERBOSE:-false}"
DRY_RUN="${DRY_RUN:-false}"
ENV_FILE="${ENV_FILE:-.env}"

# ─── Couleurs ────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'; BOLD='\033[1m'

CHECKS_OK=0; CHECKS_WARN=0; CHECKS_FAIL=0

log_info()    { echo -e "${BLUE}[INFO]${NC}    $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; ((CHECKS_OK++)); }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}    $*"; ((CHECKS_WARN++)); }
log_error()   { echo -e "${RED}[ERROR]${NC}   $*"; ((CHECKS_FAIL++)); }
log_debug()   { [[ "$VERBOSE" == "true" ]] && echo -e "${BOLD}[DEBUG]${NC}   $*" || true; }
log_section() { echo -e "\n${BOLD}${BLUE}══════════════════════════════════════${NC}"; echo -e "${BOLD}  $*${NC}"; echo -e "${BOLD}${BLUE}══════════════════════════════════════${NC}"; }

load_env() {
  [[ -f "$ENV_FILE" ]] && { log_info "Chargement $ENV_FILE"; set -a; source "$ENV_FILE"; set +a; }
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      --db-host)       DB_HOST="$2";          shift 2 ;;
      --db-port)       DB_PORT="$2";          shift 2 ;;
      --db-name)       DB_NAME="$2";          shift 2 ;;
      --db-user)       DB_USER="$2";          shift 2 ;;
      --db-password)   DB_PASSWORD="$2";      shift 2 ;;
      --docker-image)  DOCKER_IMAGE="$2";     shift 2 ;;
      --use-docker)    USE_DOCKER="true";     shift ;;
      --source-container) SOURCE_CONTAINER="$2"; shift 2 ;;
      --min-tables)    MIN_TABLES="$2";       shift 2 ;;
      --verbose)       VERBOSE="true";        shift ;;
      --dry-run)       DRY_RUN="true";        shift ;;
      --env-file)      ENV_FILE="$2";         shift 2 ;;
      -h|--help)       usage; exit 0 ;;
      *) echo "Argument inconnu: $1"; usage; exit 1 ;;
    esac
  done
}

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]
  --db-host HOST        IP MariaDB (OBLIGATOIRE ou DB_HOST env)
  --db-port PORT        Port (défaut: 3306)
  --db-name NAME        Base (défaut: librenms)
  --db-user USER        Utilisateur (défaut: librenms)
  --db-password PASS    Mot de passe (ou DB_PASSWORD env)
  --docker-image IMG    Image mysql (défaut: mariadb:10.5)
  --use-docker          Forcer Docker pour mysql CLI
  --source-container    Container source pour comparaison counts
  --min-tables N        Tables minimum attendues (défaut: 100)
  --verbose / --dry-run / --env-file FILE
EOF
}

# ─── Résolution du client MySQL ───────────────────────────────────────────────
resolve_mysql_client() {
  if [[ "$USE_DOCKER" == "true" ]]; then
    MYSQL_CLIENT="docker"
    log_info "Client MySQL : Docker ($DOCKER_IMAGE)"
    return
  fi

  if command -v mysql &>/dev/null; then
    MYSQL_CLIENT="mysql"
    log_info "Client MySQL : mysql natif ($(mysql --version 2>/dev/null | head -1))"
  elif command -v docker &>/dev/null; then
    MYSQL_CLIENT="docker"
    log_info "Client MySQL : Docker ($DOCKER_IMAGE) — mysql non disponible localement"
  else
    log_error "Ni mysql ni docker disponible — impossible de tester la DB"
    echo "  → Installer mysql-client : sudo apt install -y default-mysql-client"
    echo "  → Ou Docker : https://docs.docker.com/get-docker/"
    exit 1
  fi
}

# Exécuter une requête SQL
run_query() {
  local query="$1"
  local db="${2:-$DB_NAME}"

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY-RUN] mysql -h $DB_HOST -P $DB_PORT -u $DB_USER $db -e \"$query\""
    return 0
  fi

  if [[ "$MYSQL_CLIENT" == "mysql" ]]; then
    mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASSWORD" \
      "$db" -e "$query" --silent 2>/dev/null
  else
    # Via Docker --network host pour accès au réseau local
    cat <<<"$query" | docker run --rm -i \
      --network host \
      "$DOCKER_IMAGE" \
      mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASSWORD" \
      "$db" --silent 2>/dev/null
  fi
}

# ─── Vérifications ───────────────────────────────────────────────────────────

check_prerequisites() {
  log_section "Prérequis"
  resolve_mysql_client

  if [[ -z "$DB_HOST" ]]; then
    log_error "DB_HOST non défini — utiliser --db-host ou la variable d'env DB_HOST"
    exit 1
  fi
  if [[ -z "$DB_PASSWORD" ]]; then
    log_warn "DB_PASSWORD non défini — la connexion risque d'échouer"
  fi
  log_info "Cible : $DB_USER@$DB_HOST:$DB_PORT/$DB_NAME"
}

check_network_connectivity() {
  log_section "Connectivité réseau TCP $DB_HOST:$DB_PORT"
  if [[ "$DRY_RUN" == "true" ]]; then
    log_warn "DRY-RUN : nc -zv $DB_HOST $DB_PORT"
    return
  fi

  if command -v nc &>/dev/null; then
    if nc -zv -w 5 "$DB_HOST" "$DB_PORT" &>/dev/null; then
      log_success "Port $DB_PORT joignable sur $DB_HOST"
    else
      log_error "Port $DB_PORT inaccessible sur $DB_HOST"
      echo "  → Vérifier : ping $DB_HOST"
      echo "  → Vérifier firewall : ufw status / iptables -L"
      echo "  → Vérifier MariaDB : systemctl status mariadb"
      echo "  → Vérifier bind-address dans /etc/mysql/mariadb.conf.d/50-server.cnf"
    fi
  else
    log_warn "nc non disponible — test TCP ignoré"
  fi
}

check_db_connection() {
  log_section "Connexion DB ($DB_USER@$DB_HOST)"
  local result
  result=$(run_query "SELECT 1" "$DB_NAME" 2>&1 || true)

  if echo "$result" | grep -q "^1$"; then
    log_success "Connexion DB réussie"
  else
    log_error "Connexion DB échouée"
    echo "  → Erreur : $result"
    echo ""
    echo "  Causes fréquentes et remédiations :"
    echo "  1. Access denied for user 'X'@'localhost'"
    echo "     → L'utilisateur est créé avec host '%' (TCP only)"
    echo "     → Utiliser -h 127.0.0.1 ou changer host dans mysql.user"
    echo "     → Ou utiliser root : --db-user root --db-password ''"
    echo ""
    echo "  2. Access denied for user ''@'IP'"
    echo "     → Variable DB_USER vide — LibreNMS attend DB_USERNAME (pas DB_USER)"
    echo "     → Corriger le deployment : name: DB_USERNAME"
    echo ""
    echo "  3. Can't connect to MySQL server (115)"
    echo "     → Container Docker sans accès réseau hôte"
    echo "     → Utiliser --use-docker (active --network host)"
    echo ""
    echo "  4. Connection refused"
    echo "     → MariaDB n'écoute pas sur $DB_HOST:$DB_PORT"
    echo "     → Vérifier bind-address dans my.cnf"
  fi
}

check_database_exists() {
  log_section "Existence base de données $DB_NAME"
  local result
  result=$(run_query "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='$DB_NAME'" \
    "information_schema" 2>/dev/null || true)

  if echo "$result" | grep -q "$DB_NAME"; then
    log_success "Base $DB_NAME existe"
  else
    log_error "Base $DB_NAME introuvable"
    echo "  → Créer : CREATE DATABASE $DB_NAME CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
  fi
}

check_table_count() {
  log_section "Nombre de tables (min attendu: $MIN_TABLES)"
  local count
  count=$(run_query "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$DB_NAME'" \
    "information_schema" 2>/dev/null | grep -oE '[0-9]+' || echo "0")

  log_info "Tables trouvées : $count"

  if [[ "$count" -ge "$MIN_TABLES" ]]; then
    log_success "$count tables présentes (min: $MIN_TABLES)"
  else
    log_error "Seulement $count tables (min: $MIN_TABLES) — import DB incomplet ?"
    echo "  → Vérifier le dump : tail -3 dump.sql  # doit finir par '-- Dump completed'"
    echo "  → Réimporter : cat dump.sql | docker run --rm -i --network host $DOCKER_IMAGE mysql -h $DB_HOST -u $DB_USER -p'PASS' $DB_NAME"
  fi
}

check_critical_tables() {
  log_section "Tables critiques LibreNMS"
  local critical_tables=("devices" "ports" "sensors" "alerts" "alert_transports" "users")

  for table in "${critical_tables[@]}"; do
    local exists
    exists=$(run_query "SELECT COUNT(*) FROM information_schema.tables \
      WHERE table_schema='$DB_NAME' AND table_name='$table'" \
      "information_schema" 2>/dev/null | grep -oE '[0-9]+' || echo "0")

    if [[ "$exists" -eq 1 ]]; then
      local count
      count=$(run_query "SELECT COUNT(*) FROM $table" "$DB_NAME" \
        2>/dev/null | grep -oE '[0-9]+' || echo "?")
      log_success "Table $table : $count enregistrements"
    else
      log_error "Table $table manquante"
    fi
  done
}

check_charset() {
  log_section "Charset / Collation"
  local charset collation
  charset=$(run_query "SELECT DEFAULT_CHARACTER_SET_NAME FROM information_schema.SCHEMATA \
    WHERE SCHEMA_NAME='$DB_NAME'" "information_schema" 2>/dev/null | tail -1 || true)
  collation=$(run_query "SELECT DEFAULT_COLLATION_NAME FROM information_schema.SCHEMATA \
    WHERE SCHEMA_NAME='$DB_NAME'" "information_schema" 2>/dev/null | tail -1 || true)

  if [[ "$charset" == "utf8mb4" ]]; then
    log_success "Charset : $charset (correct)"
  else
    log_warn "Charset : $charset (attendu: utf8mb4)"
    echo "  → Risque d'incompatibilité avec LibreNMS"
  fi

  if echo "$collation" | grep -q "utf8mb4_unicode_ci"; then
    log_success "Collation : $collation (correct)"
  else
    log_warn "Collation : $collation (attendu: utf8mb4_unicode_ci)"
  fi
}

check_mariadb_version() {
  log_section "Version MariaDB"
  local version
  version=$(run_query "SELECT VERSION()" "$DB_NAME" 2>/dev/null | tail -1 || true)

  log_info "Version détectée : $version"

  if echo "$version" | grep -qE "^10\.5"; then
    log_success "MariaDB 10.5.x — version validée avec LibreNMS"
  elif echo "$version" | grep -qE "^10\.[0-4]"; then
    log_warn "MariaDB version < 10.5 — peut manquer de fonctionnalités"
  elif echo "$version" | grep -qE "^10\.[6-9]|^11"; then
    log_warn "MariaDB version > 10.5 — des incompatibilités ont été identifiées avec LibreNMS 26.x"
    echo "  → Recommandé : MariaDB 10.5.x pour LibreNMS"
  fi
}

compare_with_source() {
  log_section "Comparaison source → cible"
  if [[ -z "$SOURCE_CONTAINER" ]]; then
    log_info "Pas de container source défini — comparaison ignorée (--source-container)"
    return
  fi

  if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${SOURCE_CONTAINER}$"; then
    log_warn "Container source $SOURCE_CONTAINER non trouvé — comparaison ignorée"
    return
  fi

  local tables=("devices" "ports")
  for table in "${tables[@]}"; do
    local src_count dst_count
    src_count=$(docker exec "$SOURCE_CONTAINER" mysql -u root "$DB_NAME" \
      -e "SELECT COUNT(*) FROM $table" --silent 2>/dev/null | grep -oE '[0-9]+' || echo "?")
    dst_count=$(run_query "SELECT COUNT(*) FROM $table" "$DB_NAME" \
      2>/dev/null | grep -oE '[0-9]+' || echo "?")

    if [[ "$src_count" == "$dst_count" ]] || [[ "$dst_count" -ge "$src_count" ]]; then
      log_success "Table $table : source=$src_count cible=$dst_count ✓"
    else
      log_warn "Table $table : source=$src_count cible=$dst_count (écart — polling actif normal)"
    fi
  done
}

print_summary() {
  log_section "Résumé"
  echo -e "  ${GREEN}✅ OK     : $CHECKS_OK${NC}"
  echo -e "  ${YELLOW}⚠️  WARN   : $CHECKS_WARN${NC}"
  echo -e "  ${RED}❌ FAIL   : $CHECKS_FAIL${NC}"
  echo ""
  if [[ $CHECKS_FAIL -gt 0 ]]; then
    echo -e "${RED}${BOLD}RÉSULTAT : ÉCHEC DB${NC}"; exit 1
  elif [[ $CHECKS_WARN -gt 0 ]]; then
    echo -e "${YELLOW}${BOLD}RÉSULTAT : DB fonctionnelle avec avertissements${NC}"; exit 0
  else
    echo -e "${GREEN}${BOLD}RÉSULTAT : DB entièrement validée${NC}"; exit 0
  fi
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
  load_env
  parse_args "$@"

  echo -e "${BOLD}${BLUE}"
  echo "╔══════════════════════════════════════════════════════╗"
  echo "║        03_check_database.sh — Validation DB          ║"
  echo "╚══════════════════════════════════════════════════════╝"
  echo -e "${NC}"

  check_prerequisites
  check_network_connectivity
  check_db_connection
  check_database_exists
  check_mariadb_version
  check_charset
  check_table_count
  check_critical_tables
  compare_with_source
  print_summary
}

main "$@"
