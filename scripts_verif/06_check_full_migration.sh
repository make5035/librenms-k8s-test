#!/usr/bin/env bash
# =============================================================================
# Script      : 06_check_full_migration.sh
# Description : Orchestrateur complet — exécute tous les scripts de validation
#               dans l'ordre et produit un rapport de migration consolidé
# Exécution   : Bastion / nœud control plane / poste local avec kubectl configuré
# Prérequis   : Tous les scripts 01-05 présents dans le même répertoire
# Usage       : ./06_check_full_migration.sh [OPTIONS]
#   --scripts-dir DIR     Répertoire des scripts (défaut: répertoire courant)
#   --env-file FILE       Fichier .env commun à tous les scripts
#   --report-file FILE    Fichier de rapport de sortie (défaut: migration_report.txt)
#   --namespace NS        Namespace K8s (défaut: librenms)
#   --db-host IP          IP MariaDB
#   --db-password PASS    Mot de passe DB
#   --targets IP,IP       Cibles SNMP
#   --nfs-server IP       Serveur NFS
#   --rrdcached-host IP   VM rrdcached
#   --ingress-ip IP       IP Ingress
#   --context CTX         Contexte kubectl
#   --verbose             Mode debug (propagé aux sous-scripts)
#   --dry-run             Simulation (propagée aux sous-scripts)
#   --skip-rrd            Ignorer la validation RRD
#   --skip-snmp           Ignorer la validation SNMP
# Compatible  : CI/CD (exit code non-nul si migration en échec)
# =============================================================================

set -euo pipefail

# ─── Valeurs par défaut ───────────────────────────────────────────────────────
SCRIPTS_DIR="${SCRIPTS_DIR:-$(dirname "$(realpath "$0")")}"
ENV_FILE="${ENV_FILE:-.env}"
REPORT_FILE="${REPORT_FILE:-migration_report_$(date +%Y%m%d_%H%M%S).txt}"
NAMESPACE="${NAMESPACE:-librenms}"
DB_HOST="${DB_HOST:-}"
DB_PASSWORD="${DB_PASSWORD:-}"
SNMP_TARGETS="${SNMP_TARGETS:-}"
NFS_SERVER="${NFS_SERVER:-}"
RRDCACHED_HOST="${RRDCACHED_HOST:-}"
INGRESS_IP="${INGRESS_IP:-}"
KUBECONTEXT="${KUBECONTEXT:-}"
VERBOSE="${VERBOSE:-false}"
DRY_RUN="${DRY_RUN:-false}"
SKIP_RRD="${SKIP_RRD:-false}"
SKIP_SNMP="${SKIP_SNMP:-false}"

# ─── Couleurs ────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'; BOLD='\033[1m'

# Résultats de chaque phase
declare -A PHASE_RESULTS

log_info()    { echo -e "${BLUE}[INFO]${NC}    $*" | tee -a "$REPORT_FILE"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*" | tee -a "$REPORT_FILE"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}    $*" | tee -a "$REPORT_FILE"; }
log_error()   { echo -e "${RED}[ERROR]${NC}   $*" | tee -a "$REPORT_FILE"; }
log_section() { echo -e "\n${BOLD}${BLUE}══════════════════════════════════════${NC}" | tee -a "$REPORT_FILE"
                echo -e "${BOLD}  $*${NC}" | tee -a "$REPORT_FILE"
                echo -e "${BOLD}${BLUE}══════════════════════════════════════${NC}" | tee -a "$REPORT_FILE"; }

load_env() {
  [[ -f "$ENV_FILE" ]] && { log_info "Chargement $ENV_FILE"; set -a; source "$ENV_FILE"; set +a; }
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      --scripts-dir)    SCRIPTS_DIR="$2";     shift 2 ;;
      --env-file)       ENV_FILE="$2";        shift 2 ;;
      --report-file)    REPORT_FILE="$2";     shift 2 ;;
      --namespace)      NAMESPACE="$2";       shift 2 ;;
      --db-host)        DB_HOST="$2";         shift 2 ;;
      --db-password)    DB_PASSWORD="$2";     shift 2 ;;
      --targets)        SNMP_TARGETS="$2";    shift 2 ;;
      --nfs-server)     NFS_SERVER="$2";      shift 2 ;;
      --rrdcached-host) RRDCACHED_HOST="$2";  shift 2 ;;
      --ingress-ip)     INGRESS_IP="$2";      shift 2 ;;
      --context)        KUBECONTEXT="$2";     shift 2 ;;
      --verbose)        VERBOSE="true";       shift ;;
      --dry-run)        DRY_RUN="true";       shift ;;
      --skip-rrd)       SKIP_RRD="true";      shift ;;
      --skip-snmp)      SKIP_SNMP="true";     shift ;;
      -h|--help)        usage; exit 0 ;;
      *) echo "Argument inconnu: $1"; usage; exit 1 ;;
    esac
  done
}

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]
  --scripts-dir DIR     Répertoire scripts (défaut: répertoire courant)
  --env-file FILE       Fichier .env
  --report-file FILE    Fichier rapport de sortie
  --namespace NS        Namespace K8s (défaut: librenms)
  --db-host IP          IP MariaDB
  --db-password PASS    Mot de passe DB
  --targets IP,IP       Cibles SNMP à tester
  --nfs-server IP       Serveur NFS
  --rrdcached-host IP   VM rrdcached
  --ingress-ip IP       IP Ingress LoadBalancer
  --context CTX         Contexte kubectl
  --verbose             Mode debug
  --dry-run             Simulation
  --skip-rrd            Ignorer Phase 5 (RRD)
  --skip-snmp           Ignorer Phase 4 (SNMP)
EOF
}

# ─── Construction des arguments pour chaque script ───────────────────────────

build_common_args() {
  local args=()
  [[ -n "$KUBECONTEXT" ]] && args+=("--context" "$KUBECONTEXT")
  [[ "$VERBOSE" == "true" ]] && args+=("--verbose")
  [[ "$DRY_RUN" == "true" ]] && args+=("--dry-run")
  [[ -f "$ENV_FILE" ]] && args+=("--env-file" "$ENV_FILE")
  echo "${args[@]:-}"
}

# ─── Exécution d'un script avec capture du résultat ──────────────────────────

run_phase() {
  local phase_name="$1"
  local script_name="$2"
  shift 2
  local extra_args=("$@")

  log_section "PHASE : $phase_name"

  local script_path="$SCRIPTS_DIR/$script_name"
  if [[ ! -f "$script_path" ]]; then
    log_error "Script non trouvé : $script_path"
    PHASE_RESULTS["$phase_name"]="MISSING"
    return
  fi

  if [[ ! -x "$script_path" ]]; then
    chmod +x "$script_path"
  fi

  local common_args
  common_args=$(build_common_args)
  local start_time exit_code
  start_time=$(date +%s)

  set +e
  "$script_path" $common_args "${extra_args[@]}" 2>&1 | tee -a "$REPORT_FILE"
  exit_code=$?
  set -e

  local end_time elapsed
  end_time=$(date +%s)
  elapsed=$((end_time - start_time))

  if [[ $exit_code -eq 0 ]]; then
    PHASE_RESULTS["$phase_name"]="SUCCESS"
    log_success "Phase $phase_name terminée en ${elapsed}s — SUCCÈS"
  else
    PHASE_RESULTS["$phase_name"]="FAILURE"
    log_error "Phase $phase_name terminée en ${elapsed}s — ÉCHEC (exit=$exit_code)"
  fi
}

# ─── Rapport final ────────────────────────────────────────────────────────────

print_final_report() {
  log_section "RAPPORT FINAL DE MIGRATION"

  local total=0 success=0 failed=0 missing=0

  echo "" | tee -a "$REPORT_FILE"
  printf "%-40s %-15s\n" "Phase" "Résultat" | tee -a "$REPORT_FILE"
  printf "%-40s %-15s\n" "─────────────────────────────────────" "──────────────" | tee -a "$REPORT_FILE"

  for phase in "${!PHASE_RESULTS[@]}"; do
    local result="${PHASE_RESULTS[$phase]}"
    local symbol color
    ((total++))
    case "$result" in
      SUCCESS) symbol="✅"; color="$GREEN"; ((success++)) ;;
      FAILURE) symbol="❌"; color="$RED";   ((failed++)) ;;
      SKIPPED) symbol="⏭️ "; color="$YELLOW" ;;
      MISSING) symbol="⚠️ "; color="$YELLOW"; ((missing++)) ;;
    esac
    printf "${color}%-40s %-15s${NC}\n" "$phase" "$symbol $result" | tee -a "$REPORT_FILE"
  done

  echo "" | tee -a "$REPORT_FILE"
  echo "─────────────────────────────────────────────────" | tee -a "$REPORT_FILE"
  echo "  Total    : $total phases" | tee -a "$REPORT_FILE"
  echo -e "  ${GREEN}Succès   : $success${NC}" | tee -a "$REPORT_FILE"
  echo -e "  ${RED}Échecs   : $failed${NC}" | tee -a "$REPORT_FILE"
  echo -e "  ${YELLOW}Manquants: $missing${NC}" | tee -a "$REPORT_FILE"
  echo "" | tee -a "$REPORT_FILE"
  echo "Rapport complet : $REPORT_FILE" | tee -a "$REPORT_FILE"
  echo "" | tee -a "$REPORT_FILE"

  if [[ $failed -gt 0 ]] || [[ $missing -gt 0 ]]; then
    echo -e "${RED}${BOLD}╔══════════════════════════════════════════╗${NC}" | tee -a "$REPORT_FILE"
    echo -e "${RED}${BOLD}║  ❌ MIGRATION EN ÉCHEC — NE PAS BASCULER ║${NC}" | tee -a "$REPORT_FILE"
    echo -e "${RED}${BOLD}╚══════════════════════════════════════════╝${NC}" | tee -a "$REPORT_FILE"
    exit 1
  else
    echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════╗${NC}" | tee -a "$REPORT_FILE"
    echo -e "${GREEN}${BOLD}║  ✅ MIGRATION VALIDÉE — GO BASCULE       ║${NC}" | tee -a "$REPORT_FILE"
    echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════╝${NC}" | tee -a "$REPORT_FILE"
    exit 0
  fi
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
  load_env
  parse_args "$@"

  # Initialiser le rapport
  {
    echo "═══════════════════════════════════════════════════════════"
    echo "  RAPPORT DE MIGRATION LIBRENMS — $(date '+%Y-%m-%d %H:%M:%S')"
    echo "  Namespace : $NAMESPACE"
    echo "  Contexte  : ${KUBECONTEXT:-default}"
    echo "  Mode      : $([ "$DRY_RUN" == "true" ] && echo "DRY-RUN" || echo "RÉEL")"
    echo "═══════════════════════════════════════════════════════════"
  } > "$REPORT_FILE"

  echo -e "${BOLD}${BLUE}"
  echo "╔══════════════════════════════════════════════════════╗"
  echo "║    06_check_full_migration.sh — Validation Globale   ║"
  echo "╚══════════════════════════════════════════════════════╝"
  echo -e "${NC}"

  log_info "Rapport de sortie : $REPORT_FILE"

  # ── Phase 1 : Cluster ──────────────────────────────────────────────────────
  run_phase "01_Cluster_K8s" "01_check_cluster.sh"

  # ── Phase 2 : Application ─────────────────────────────────────────────────
  local app_args=("--namespace" "$NAMESPACE")
  [[ -n "$INGRESS_IP" ]] && app_args+=("--ingress-ip" "$INGRESS_IP")
  run_phase "02_Application" "02_check_application.sh" "${app_args[@]}"

  # ── Phase 3 : Base de données ─────────────────────────────────────────────
  if [[ -n "$DB_HOST" ]]; then
    local db_args=("--db-host" "$DB_HOST")
    [[ -n "$DB_PASSWORD" ]] && db_args+=("--db-password" "$DB_PASSWORD")
    run_phase "03_Database" "03_check_database.sh" "${db_args[@]}"
  else
    log_warn "DB_HOST non défini — Phase 03 ignorée (utiliser --db-host)"
    PHASE_RESULTS["03_Database"]="SKIPPED"
  fi

  # ── Phase 4 : SNMP ────────────────────────────────────────────────────────
  if [[ "$SKIP_SNMP" == "true" ]]; then
    log_warn "Phase SNMP ignorée (--skip-snmp)"
    PHASE_RESULTS["04_SNMP"]="SKIPPED"
  elif [[ -n "$SNMP_TARGETS" ]]; then
    run_phase "04_SNMP" "04_check_snmp.sh" \
      "--namespace" "$NAMESPACE" \
      "--targets" "$SNMP_TARGETS"
  else
    log_warn "SNMP_TARGETS non défini — Phase 04 SNMP sans cibles (--targets)"
    run_phase "04_SNMP" "04_check_snmp.sh" "--namespace" "$NAMESPACE"
  fi

  # ── Phase 5 : RRD ─────────────────────────────────────────────────────────
  if [[ "$SKIP_RRD" == "true" ]]; then
    log_warn "Phase RRD ignorée (--skip-rrd)"
    PHASE_RESULTS["05_RRD_Migration"]="SKIPPED"
  else
    local rrd_args=("--namespace" "$NAMESPACE")
    [[ -n "$NFS_SERVER" ]] && rrd_args+=("--nfs-server" "$NFS_SERVER")
    [[ -n "$RRDCACHED_HOST" ]] && rrd_args+=("--rrdcached-host" "$RRDCACHED_HOST")
    run_phase "05_RRD_Migration" "05_check_rrd_migration.sh" "${rrd_args[@]}"
  fi

  print_final_report
}

main "$@"
