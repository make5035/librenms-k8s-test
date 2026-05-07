#!/usr/bin/env bash
# =============================================================================
# Script      : 04_check_snmp.sh
# Description : Validation du polling SNMP depuis les pods K8s
# Exécution   : Bastion / nœud control plane avec kubectl configuré
# Prérequis   : kubectl, accès cluster, pods pollers Running
# Usage       : ./04_check_snmp.sh [OPTIONS]
#   --namespace NS         Namespace (défaut: librenms)
#   --poller-label LABEL   Label selector poller (défaut: librenms-poller)
#   --community COMM       Communauté SNMP (défaut: public)
#   --snmp-version VER     Version SNMP (défaut: 2c)
#   --targets IP,IP,...    IPs à tester (séparées par virgules)
#   --targets-file FILE    Fichier avec une IP par ligne
#   --pod-subnet CIDR      Subnet des pods (pour info agentaddress)
#   --context CTX          Contexte kubectl
#   --verbose              Mode debug
#   --dry-run              Simulation
#   --env-file FILE        Fichier .env
# Compatible  : CI/CD
# =============================================================================

set -euo pipefail

# ─── Valeurs par défaut ───────────────────────────────────────────────────────
NAMESPACE="${NAMESPACE:-librenms}"
POLLER_LABEL="${POLLER_LABEL:-librenms-poller}"
SNMP_COMMUNITY="${SNMP_COMMUNITY:-public}"
SNMP_VERSION="${SNMP_VERSION:-2c}"
SNMP_TIMEOUT="${SNMP_TIMEOUT:-5}"
SNMP_RETRIES="${SNMP_RETRIES:-1}"
TARGETS="${TARGETS:-}"                     # Comma-separated IPs
TARGETS_FILE="${TARGETS_FILE:-}"
POD_SUBNET="${POD_SUBNET:-10.0.0.0/8}"   # Subnet Cilium par défaut
KUBECONTEXT="${KUBECONTEXT:-}"
VERBOSE="${VERBOSE:-false}"
DRY_RUN="${DRY_RUN:-false}"
ENV_FILE="${ENV_FILE:-.env}"

# ─── Couleurs ────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'; BOLD='\033[1m'

CHECKS_OK=0; CHECKS_WARN=0; CHECKS_FAIL=0
SNMP_SUCCESS=0; SNMP_FAIL=0

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
      --namespace)     NAMESPACE="$2";      shift 2 ;;
      --poller-label)  POLLER_LABEL="$2";   shift 2 ;;
      --community)     SNMP_COMMUNITY="$2"; shift 2 ;;
      --snmp-version)  SNMP_VERSION="$2";   shift 2 ;;
      --targets)       TARGETS="$2";        shift 2 ;;
      --targets-file)  TARGETS_FILE="$2";   shift 2 ;;
      --pod-subnet)    POD_SUBNET="$2";     shift 2 ;;
      --context)       KUBECONTEXT="$2";    shift 2 ;;
      --verbose)       VERBOSE="true";      shift ;;
      --dry-run)       DRY_RUN="true";      shift ;;
      --env-file)      ENV_FILE="$2";       shift 2 ;;
      -h|--help)       usage; exit 0 ;;
      *) echo "Argument inconnu: $1"; usage; exit 1 ;;
    esac
  done
}

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]
  --namespace NS        Namespace (défaut: librenms)
  --poller-label LABEL  Label poller (défaut: librenms-poller)
  --community COMM      Communauté SNMP (défaut: public)
  --snmp-version VER    Version (défaut: 2c)
  --targets IP,IP       IPs à tester
  --targets-file FILE   Fichier IPs (une par ligne)
  --pod-subnet CIDR     Subnet pods pour agentaddress check (défaut: 10.0.0.0/8)
  --context CTX / --verbose / --dry-run / --env-file FILE
EOF
}

kctl() {
  [[ -n "$KUBECONTEXT" ]] && kubectl --context="$KUBECONTEXT" "$@" || kubectl "$@"
}

# Récupérer le premier pod poller disponible
get_poller_pod() {
  kctl get pods -n "$NAMESPACE" -l "app=$POLLER_LABEL" --no-headers 2>/dev/null \
    | grep " Running " | head -1 | awk '{print $1}' || true
}

# Récupérer la liste des cibles
get_targets() {
  local targets_list=()

  # Depuis l'argument --targets
  if [[ -n "$TARGETS" ]]; then
    IFS=',' read -ra targets_list <<< "$TARGETS"
  fi

  # Depuis le fichier --targets-file
  if [[ -n "$TARGETS_FILE" ]] && [[ -f "$TARGETS_FILE" ]]; then
    while IFS= read -r line; do
      [[ -z "$line" || "$line" =~ ^# ]] && continue
      targets_list+=("$line")
    done < "$TARGETS_FILE"
  fi

  echo "${targets_list[@]:-}"
}

# ─── Vérifications ───────────────────────────────────────────────────────────

check_poller_pod_exists() {
  log_section "Disponibilité pod poller"
  local pod
  pod=$(get_poller_pod)

  if [[ -z "$pod" ]]; then
    log_error "Aucun pod poller Running (app=$POLLER_LABEL dans $NAMESPACE)"
    echo "  → Vérifier : kubectl get pods -n $NAMESPACE -l app=$POLLER_LABEL"
    exit 1
  fi

  log_success "Pod poller disponible : $pod"
  POLLER_POD="$pod"
}

check_snmpwalk_available() {
  log_section "Disponibilité snmpwalk dans le pod"
  local result
  result=$(kctl exec -n "$NAMESPACE" "$POLLER_POD" -- \
    which snmpwalk 2>/dev/null || true)

  if [[ -n "$result" ]]; then
    log_success "snmpwalk disponible dans $POLLER_POD : $result"
  else
    log_error "snmpwalk non disponible dans $POLLER_POD"
    echo "  → L'image LibreNMS devrait inclure net-snmp"
    echo "  → Tester manuellement : kubectl exec -it $POLLER_POD -n $NAMESPACE -- which snmpwalk"
    exit 1
  fi
}

snmp_test_target() {
  local pod="$1"
  local target_ip="$2"
  local community="$3"

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY-RUN] kubectl exec $pod -n $NAMESPACE -- snmpwalk -v$SNMP_VERSION -c $community -t $SNMP_TIMEOUT $target_ip sysDescr"
    return 0
  fi

  kctl exec -n "$NAMESPACE" "$pod" -- \
    snmpwalk -v"$SNMP_VERSION" -c "$community" \
    -t "$SNMP_TIMEOUT" -r "$SNMP_RETRIES" \
    "$target_ip" sysDescr 2>&1 | grep -v "Defaulted container" || true
}

check_snmp_targets() {
  log_section "Test SNMP sur les cibles (communauté: $SNMP_COMMUNITY)"
  local targets
  targets=$(get_targets)

  if [[ -z "$targets" ]]; then
    log_warn "Aucune cible SNMP définie — utiliser --targets ou --targets-file"
    echo "  → Exemple : --targets 192.168.1.1,192.168.1.2"
    return
  fi

  for target in $targets; do
    log_info "Test SNMP → $target"
    local result
    result=$(snmp_test_target "$POLLER_POD" "$target" "$SNMP_COMMUNITY")

    if echo "$result" | grep -q "sysDescr"; then
      local descr
      descr=$(echo "$result" | grep "sysDescr" | head -1)
      log_success "✓ $target répond SNMP : $descr"
      ((SNMP_SUCCESS++))
    elif echo "$result" | grep -q "Timeout"; then
      log_error "✗ $target — Timeout SNMP"
      ((SNMP_FAIL++))
      echo ""
      echo "  ┌─ Diagnostic Timeout SNMP ──────────────────────────────"
      echo "  │ Cause 1 : agentaddress configuré sur loopback uniquement"
      echo "  │   → Sur l'équipement : grep agentaddress /etc/snmp/snmpd.conf"
      echo "  │   → Corriger : agentaddress udp:0.0.0.0:161"
      echo "  │   → Redémarrer : systemctl restart snmpd"
      echo "  │"
      echo "  │ Cause 2 : communauté '$SNMP_COMMUNITY' non autorisée depuis $POD_SUBNET"
      echo "  │   → Sur l'équipement : grep rocommunity /etc/snmp/snmpd.conf"
      echo "  │   → Ajouter : rocommunity $SNMP_COMMUNITY $POD_SUBNET"
      echo "  │"
      echo "  │ Cause 3 : Firewall bloque UDP/161 depuis $POD_SUBNET"
      echo "  │   → Vérifier : iptables -L INPUT -n | grep 161"
      echo "  │"
      echo "  │ Tester avec communauté 'public' pour isoler le problème :"
      echo "  │   kubectl exec -n $NAMESPACE $POLLER_POD -- \\"
      echo "  │     snmpwalk -v2c -c public -t 5 $target sysDescr"
      echo "  └────────────────────────────────────────────────────────"
      echo ""
    elif echo "$result" | grep -q "No Such Object\|No Such Instance"; then
      log_warn "? $target — répond SNMP mais OID sysDescr absent"
      ((SNMP_SUCCESS++))
    else
      log_warn "? $target — réponse inattendue : $result"
      ((SNMP_WARN++)) 2>/dev/null || true
    fi
  done
}

check_snmp_config_on_targets() {
  log_section "Recommandations configuration snmpd"
  log_info "Les pods pollers émettent depuis le subnet : $POD_SUBNET"
  echo ""
  echo "  Pour que le polling fonctionne depuis K8s :"
  echo ""
  echo "  ┌─ Configuration snmpd minimale ─────────────────────────────"
  echo "  │ # /etc/snmp/snmpd.conf"
  echo "  │"
  echo "  │ # Écouter sur toutes les interfaces (OBLIGATOIRE)"
  echo "  │ agentaddress udp:0.0.0.0:161"
  echo "  │"
  echo "  │ # Autoriser la communauté depuis le LAN ET le subnet pods"
  echo "  │ rocommunity $SNMP_COMMUNITY <LAN_CIDR>"
  echo "  │ rocommunity $SNMP_COMMUNITY $POD_SUBNET"
  echo "  │"
  echo "  │ sudo systemctl restart snmpd"
  echo "  └────────────────────────────────────────────────────────────"
  echo ""
  echo "  Script de correction à appliquer sur chaque nœud supervisé :"
  cat <<'REMEDIATION'
  sudo sed -i 's/agentaddress.*udp:161.*/agentaddress udp:0.0.0.0:161/' /etc/snmp/snmpd.conf
  # Ajouter la ligne si absente :
  grep -q "rocommunity.*10.0.0.0" /etc/snmp/snmpd.conf || \
    echo "rocommunity CPAreport 10.0.0.0/8" | sudo tee -a /etc/snmp/snmpd.conf
  sudo systemctl restart snmpd
REMEDIATION
}

check_poller_logs() {
  log_section "Logs récents du poller"
  log_info "Analyse des 30 dernières lignes de logs de $POLLER_POD"

  local logs
  logs=$(kctl logs -n "$NAMESPACE" "$POLLER_POD" --tail=30 2>/dev/null \
    | grep -v "Defaulted" || true)

  # Vérifier qu'il y a des cycles de polling
  local poll_cycles
  poll_cycles=$(echo "$logs" | grep -c "Completed poller run" || true)

  if [[ "$poll_cycles" -gt 0 ]]; then
    log_success "$poll_cycles cycle(s) de polling complet(s) dans les logs récents"
  else
    log_warn "Aucun cycle de polling complet dans les logs récents"
    echo "  → Attendre 5 minutes et relancer"
  fi

  # Détecter les devices unreachable
  local unreachable
  unreachable=$(echo "$logs" | grep -i "unreachable" || true)
  if [[ -n "$unreachable" ]]; then
    log_warn "Devices unreachable détectés dans les logs :"
    echo "$unreachable"
    echo "  → Vérifier la connectivité SNMP avec ce script --targets <IP>"
  fi

  # Détecter erreurs DB
  local db_errors
  db_errors=$(echo "$logs" | grep -iE "DB Connection|SQLSTATE|Access denied" || true)
  if [[ -n "$db_errors" ]]; then
    log_error "Erreurs DB dans les logs poller :"
    echo "$db_errors"
    echo "  → Vérifier : 03_check_database.sh --db-host <IP>"
  fi

  log_debug "Derniers logs :\n$logs"
}

print_summary() {
  log_section "Résumé SNMP"
  echo -e "  ${GREEN}✅ Cibles SNMP OK  : $SNMP_SUCCESS${NC}"
  echo -e "  ${RED}❌ Cibles SNMP KO  : $SNMP_FAIL${NC}"
  echo ""
  echo -e "  ${GREEN}✅ Vérifications OK   : $CHECKS_OK${NC}"
  echo -e "  ${YELLOW}⚠️  Vérifications WARN : $CHECKS_WARN${NC}"
  echo -e "  ${RED}❌ Vérifications FAIL : $CHECKS_FAIL${NC}"
  echo ""

  if [[ $CHECKS_FAIL -gt 0 ]] || [[ $SNMP_FAIL -gt 0 ]]; then
    echo -e "${RED}${BOLD}RÉSULTAT : ÉCHEC SNMP${NC}"; exit 1
  elif [[ $CHECKS_WARN -gt 0 ]]; then
    echo -e "${YELLOW}${BOLD}RÉSULTAT : SNMP fonctionnel avec avertissements${NC}"; exit 0
  else
    echo -e "${GREEN}${BOLD}RÉSULTAT : SNMP entièrement validé${NC}"; exit 0
  fi
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
  load_env
  parse_args "$@"

  echo -e "${BOLD}${BLUE}"
  echo "╔══════════════════════════════════════════════════════╗"
  echo "║          04_check_snmp.sh — Validation SNMP          ║"
  echo "╚══════════════════════════════════════════════════════╝"
  echo -e "${NC}"

  check_poller_pod_exists
  check_snmpwalk_available
  check_snmp_config_on_targets
  check_snmp_targets
  check_poller_logs
  print_summary
}

main "$@"
