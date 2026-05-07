#!/usr/bin/env bash
# =============================================================================
# Script      : 01_check_cluster.sh
# Description : Validation complète de l'état d'un cluster Kubernetes
# Exécution   : Bastion / nœud control plane / poste local avec kubectl configuré
# Prérequis   : kubectl configuré, accès cluster
# Usage       : ./01_check_cluster.sh [OPTIONS]
#   --context  KUBECONTEXT  Contexte kubectl à utiliser
#   --verbose               Mode debug
#   --dry-run               Simulation sans action
#   --env-file FILE         Charger un fichier .env
# Compatible  : CI/CD (exit code non-nul si une vérification échoue)
# =============================================================================

set -euo pipefail

# ─── Valeurs par défaut ───────────────────────────────────────────────────────
KUBECONTEXT="${KUBECONTEXT:-}"
VERBOSE="${VERBOSE:-false}"
DRY_RUN="${DRY_RUN:-false}"
ENV_FILE="${ENV_FILE:-.env}"

# Seuils
MAX_RESTARTS="${MAX_RESTARTS:-10}"          # Seuil restarts considéré anormal
METRICS_TIMEOUT="${METRICS_TIMEOUT:-120}"   # Secondes d'attente metrics-server

# ─── Couleurs ────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'; BOLD='\033[1m'

# ─── Compteurs ───────────────────────────────────────────────────────────────
CHECKS_OK=0; CHECKS_WARN=0; CHECKS_FAIL=0

# ─── Fonctions utilitaires ───────────────────────────────────────────────────
log_info()    { echo -e "${BLUE}[INFO]${NC}    $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; ((CHECKS_OK++)); }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}    $*"; ((CHECKS_WARN++)); }
log_error()   { echo -e "${RED}[ERROR]${NC}   $*"; ((CHECKS_FAIL++)); }
log_debug()   { [[ "$VERBOSE" == "true" ]] && echo -e "${BOLD}[DEBUG]${NC}   $*" || true; }
log_section() { echo -e "\n${BOLD}${BLUE}══════════════════════════════════════${NC}"; echo -e "${BOLD}  $*${NC}"; echo -e "${BOLD}${BLUE}══════════════════════════════════════${NC}"; }

# Charger le fichier .env si présent
load_env() {
  if [[ -f "$ENV_FILE" ]]; then
    log_info "Chargement de $ENV_FILE"
    set -a; source "$ENV_FILE"; set +a
  fi
}

# Parser les arguments CLI
parse_args() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      --context)    KUBECONTEXT="$2";  shift 2 ;;
      --verbose)    VERBOSE="true";    shift ;;
      --dry-run)    DRY_RUN="true";    shift ;;
      --env-file)   ENV_FILE="$2";     shift 2 ;;
      --max-restarts) MAX_RESTARTS="$2"; shift 2 ;;
      -h|--help)    usage; exit 0 ;;
      *) echo "Argument inconnu: $1"; usage; exit 1 ;;
    esac
  done
}

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]
  --context  CTX   Contexte kubectl
  --verbose        Mode debug
  --dry-run        Simulation
  --env-file FILE  Fichier .env (défaut: .env)
  --max-restarts N Seuil restarts (défaut: 10)
EOF
}

# Construire la commande kubectl avec contexte optionnel
kctl() {
  if [[ -n "$KUBECONTEXT" ]]; then
    kubectl --context="$KUBECONTEXT" "$@"
  else
    kubectl "$@"
  fi
}

# ─── Vérifications ───────────────────────────────────────────────────────────

check_kubectl_connectivity() {
  log_section "Connectivité kubectl"
  if kctl cluster-info &>/dev/null; then
    local server
    server=$(kctl cluster-info | grep "control plane" | grep -oP 'https://[^\s]+' || echo "inconnu")
    log_success "API server joignable : $server"
  else
    log_error "Impossible de joindre l'API server. Vérifier kubeconfig et réseau."
    echo "  → Vérifier : kubectl config current-context"
    echo "  → Vérifier : kubectl config view"
    exit 1
  fi
}

check_nodes() {
  log_section "État des nœuds"
  local nodes not_ready node_count
  nodes=$(kctl get nodes -o wide --no-headers 2>/dev/null)
  node_count=$(echo "$nodes" | wc -l)
  not_ready=$(echo "$nodes" | grep -v " Ready " || true)

  log_info "$node_count nœud(s) détecté(s)"
  log_debug "$nodes"

  if [[ -z "$not_ready" ]]; then
    log_success "Tous les nœuds sont en état Ready"
  else
    log_error "Nœuds NON Ready détectés :"
    echo "$not_ready" | while read -r line; do
      echo "  → $line"
      local node_name
      node_name=$(echo "$line" | awk '{print $1}')
      echo "  → Diagnostic : kubectl describe node $node_name | grep -A10 Conditions"
      echo "  → Remédiation : ssh <node> 'sudo systemctl restart kubelet'"
    done
  fi

  # Détail par nœud
  echo "$nodes" | while read -r line; do
    local name status roles age version
    name=$(echo "$line" | awk '{print $1}')
    status=$(echo "$line" | awk '{print $2}')
    roles=$(echo "$line" | awk '{print $3}')
    age=$(echo "$line" | awk '{print $4}')
    version=$(echo "$line" | awk '{print $5}')
    log_debug "  Nœud=$name Status=$status Roles=$roles Age=$age Version=$version"
  done
}

check_system_pods() {
  log_section "Pods système (kube-system)"
  local failing_pods
  failing_pods=$(kctl get pods -n kube-system --no-headers 2>/dev/null \
    | grep -vE "Running|Completed" || true)

  if [[ -z "$failing_pods" ]]; then
    log_success "Tous les pods kube-system sont Running/Completed"
  else
    log_error "Pods kube-system en anomalie :"
    echo "$failing_pods" | while read -r line; do
      echo "  → $line"
    done
  fi

  # Vérifier les restarts élevés
  local high_restart_pods
  high_restart_pods=$(kctl get pods -A --no-headers 2>/dev/null \
    | awk -v max="$MAX_RESTARTS" '{if ($5 > max) print $0}' || true)

  if [[ -n "$high_restart_pods" ]]; then
    log_warn "Pods avec restarts > $MAX_RESTARTS :"
    echo "$high_restart_pods" | while read -r line; do
      echo "  → $line"
    done
  else
    log_success "Aucun pod avec restarts excessifs (seuil: $MAX_RESTARTS)"
  fi
}

check_cilium() {
  log_section "CNI — Cilium"
  if ! kctl get ds -n kube-system cilium &>/dev/null; then
    log_warn "DaemonSet Cilium non trouvé — CNI différent ou non installé"
    return
  fi

  local desired ready
  desired=$(kctl get ds -n kube-system cilium -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo "0")
  ready=$(kctl get ds -n kube-system cilium -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")

  log_debug "Cilium desired=$desired ready=$ready"

  if [[ "$desired" == "$ready" ]] && [[ "$desired" -gt 0 ]]; then
    log_success "Cilium opérationnel : $ready/$desired pods ready"
  else
    log_error "Cilium dégradé : $ready/$desired pods ready"
    echo "  → Diagnostic : kubectl get pods -n kube-system -l k8s-app=cilium"
    echo "  → Logs : kubectl logs -n kube-system -l k8s-app=cilium --tail=50"
  fi

  # Vérifier les events Cilium récents
  local cilium_events
  cilium_events=$(kctl get events -n kube-system --field-selector reason=Unhealthy 2>/dev/null \
    | grep -i cilium | tail -5 || true)
  if [[ -n "$cilium_events" ]]; then
    log_warn "Events Cilium Unhealthy récents :"
    echo "$cilium_events"
  fi
}

check_metrics_server() {
  log_section "Metrics Server (requis pour HPA)"
  if kctl top nodes &>/dev/null; then
    log_success "Metrics Server opérationnel — kubectl top nodes répond"
    log_debug "$(kctl top nodes 2>/dev/null || true)"
  else
    log_error "Metrics Server non disponible"
    echo "  → Installation :"
    echo "    kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml"
    echo "  → Patch pour env sans TLS valide (VMware/lab) :"
    echo "    kubectl patch deployment metrics-server -n kube-system \\"
    echo "      --type=json \\"
    echo "      -p='[{\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/args/-\",\"value\":\"--kubelet-insecure-tls\"}]'"
    echo "  → Attendre ~60s puis retester"
  fi
}

check_storageclass() {
  log_section "StorageClass"
  local storageclasses default_sc
  storageclasses=$(kctl get storageclass --no-headers 2>/dev/null || true)
  default_sc=$(echo "$storageclasses" | grep "(default)" || true)

  if [[ -z "$storageclasses" ]]; then
    log_error "Aucune StorageClass trouvée"
    return
  fi

  log_info "StorageClasses disponibles :"
  echo "$storageclasses" | while read -r line; do
    log_debug "  $line"
  done

  if [[ -n "$default_sc" ]]; then
    local sc_name
    sc_name=$(echo "$default_sc" | awk '{print $1}')
    log_success "StorageClass par défaut : $sc_name"
  else
    log_warn "Aucune StorageClass définie comme (default)"
    echo "  → Remédiation : kubectl patch storageclass <nom> -p '{\"metadata\":{\"annotations\":{\"storageclass.kubernetes.io/is-default-class\":\"true\"}}}'"
  fi
}

check_metallb() {
  log_section "MetalLB"
  if ! kctl get ns metallb-system &>/dev/null; then
    log_warn "Namespace metallb-system non trouvé — MetalLB non installé ou namespace différent"
    return
  fi

  local failing
  failing=$(kctl get pods -n metallb-system --no-headers 2>/dev/null \
    | grep -vE "Running|Completed" || true)

  if [[ -z "$failing" ]]; then
    log_success "Pods MetalLB Running"
  else
    log_error "Pods MetalLB en anomalie :"
    echo "$failing"
  fi
}

check_ingress() {
  log_section "NGINX Ingress Controller"
  if ! kctl get ns ingress-nginx &>/dev/null; then
    log_warn "Namespace ingress-nginx non trouvé"
    return
  fi

  local controller_svc external_ip
  controller_svc=$(kctl get svc -n ingress-nginx ingress-nginx-controller \
    --no-headers 2>/dev/null || true)
  external_ip=$(echo "$controller_svc" | awk '{print $4}')

  if [[ "$external_ip" == "<pending>" ]] || [[ -z "$external_ip" ]]; then
    log_warn "Ingress controller sans IP externe (MetalLB non attribuée ?)"
    echo "  → Vérifier : kubectl get svc -n ingress-nginx"
    echo "  → Vérifier MetalLB IPAddressPool configuré"
  else
    log_success "Ingress controller IP externe : $external_ip"
  fi
}

check_recent_events() {
  log_section "Events récents (anomalies)"
  local warning_events
  warning_events=$(kctl get events -A --sort-by='.lastTimestamp' 2>/dev/null \
    | grep -i "warning" | tail -10 || true)

  if [[ -z "$warning_events" ]]; then
    log_success "Aucun event Warning récent"
  else
    log_warn "Events Warning récents :"
    echo "$warning_events"
  fi
}

print_summary() {
  log_section "Résumé"
  echo -e "  ${GREEN}✅ OK     : $CHECKS_OK${NC}"
  echo -e "  ${YELLOW}⚠️  WARN   : $CHECKS_WARN${NC}"
  echo -e "  ${RED}❌ FAIL   : $CHECKS_FAIL${NC}"
  echo ""
  if [[ $CHECKS_FAIL -gt 0 ]]; then
    echo -e "${RED}${BOLD}RÉSULTAT : ÉCHEC — $CHECKS_FAIL vérification(s) en erreur${NC}"
    exit 1
  elif [[ $CHECKS_WARN -gt 0 ]]; then
    echo -e "${YELLOW}${BOLD}RÉSULTAT : AVERTISSEMENT — Cluster fonctionnel avec $CHECKS_WARN alerte(s)${NC}"
    exit 0
  else
    echo -e "${GREEN}${BOLD}RÉSULTAT : SUCCÈS — Cluster entièrement opérationnel${NC}"
    exit 0
  fi
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
  load_env
  parse_args "$@"

  echo -e "${BOLD}${BLUE}"
  echo "╔══════════════════════════════════════════════════════╗"
  echo "║         01_check_cluster.sh — Validation K8s         ║"
  echo "╚══════════════════════════════════════════════════════╝"
  echo -e "${NC}"

  [[ "$DRY_RUN" == "true" ]] && log_warn "MODE DRY-RUN — aucune action effectuée"
  [[ -n "$KUBECONTEXT" ]] && log_info "Contexte kubectl : $KUBECONTEXT"

  check_kubectl_connectivity
  check_nodes
  check_system_pods
  check_cilium
  check_metrics_server
  check_storageclass
  check_metallb
  check_ingress
  check_recent_events
  print_summary
}

main "$@"
