#!/usr/bin/env bash
# =============================================================================
# Script      : 02_check_application.sh
# Description : Validation de l'état applicatif LibreNMS sur Kubernetes
# Exécution   : Bastion / nœud control plane / poste local avec kubectl configuré
# Prérequis   : kubectl configuré, accès cluster, curl disponible
# Usage       : ./02_check_application.sh [OPTIONS]
#   --namespace NS       Namespace de l'application (défaut: librenms)
#   --app-label LABEL    Label selector app (défaut: librenms)
#   --ingress-ip IP      IP du LoadBalancer Ingress (auto-détection si absent)
#   --ingress-host HOST  Hostname Ingress (défaut: librenms.local)
#   --login-path PATH    Chemin de la page de login (défaut: /login)
#   --context CTX        Contexte kubectl
#   --verbose            Mode debug
#   --dry-run            Simulation
#   --env-file FILE      Fichier .env
# Compatible  : CI/CD
# =============================================================================

set -euo pipefail

# ─── Valeurs par défaut ───────────────────────────────────────────────────────
NAMESPACE="${NAMESPACE:-librenms}"
APP_LABEL="${APP_LABEL:-librenms}"
POLLER_LABEL="${POLLER_LABEL:-librenms-poller}"
INGRESS_IP="${INGRESS_IP:-}"
INGRESS_HOST="${INGRESS_HOST:-librenms.local}"
LOGIN_PATH="${LOGIN_PATH:-/login}"
KUBECONTEXT="${KUBECONTEXT:-}"
VERBOSE="${VERBOSE:-false}"
DRY_RUN="${DRY_RUN:-false}"
ENV_FILE="${ENV_FILE:-.env}"
HTTP_TIMEOUT="${HTTP_TIMEOUT:-10}"
MIN_REPLICAS="${MIN_REPLICAS:-1}"
MAX_RESTART_WARN="${MAX_RESTART_WARN:-5}"

# ─── Couleurs ────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'; BOLD='\033[1m'

CHECKS_OK=0; CHECKS_WARN=0; CHECKS_FAIL=0

# ─── Fonctions utilitaires ───────────────────────────────────────────────────
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
      --namespace)    NAMESPACE="$2";     shift 2 ;;
      --app-label)    APP_LABEL="$2";     shift 2 ;;
      --ingress-ip)   INGRESS_IP="$2";    shift 2 ;;
      --ingress-host) INGRESS_HOST="$2";  shift 2 ;;
      --login-path)   LOGIN_PATH="$2";    shift 2 ;;
      --context)      KUBECONTEXT="$2";   shift 2 ;;
      --verbose)      VERBOSE="true";     shift ;;
      --dry-run)      DRY_RUN="true";     shift ;;
      --env-file)     ENV_FILE="$2";      shift 2 ;;
      --min-replicas) MIN_REPLICAS="$2";  shift 2 ;;
      -h|--help)      usage; exit 0 ;;
      *) echo "Argument inconnu: $1"; usage; exit 1 ;;
    esac
  done
}

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]
  --namespace NS       Namespace (défaut: librenms)
  --app-label LABEL    Label app (défaut: librenms)
  --ingress-ip IP      IP Ingress LoadBalancer
  --ingress-host HOST  Hostname Ingress (défaut: librenms.local)
  --context CTX        Contexte kubectl
  --min-replicas N     Réplicas minimum attendus (défaut: 1)
  --verbose / --dry-run / --env-file FILE
EOF
}

kctl() {
  if [[ -n "$KUBECONTEXT" ]]; then
    kubectl --context="$KUBECONTEXT" "$@"
  else
    kubectl "$@"
  fi
}

# Auto-détecter l'IP Ingress si non fournie
auto_detect_ingress_ip() {
  if [[ -z "$INGRESS_IP" ]]; then
    # Chercher d'abord dans ingress-nginx
    INGRESS_IP=$(kctl get svc -n ingress-nginx ingress-nginx-controller \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)

    if [[ -z "$INGRESS_IP" ]]; then
      # Fallback : chercher un ingress dans le namespace applicatif
      INGRESS_IP=$(kctl get ingress -n "$NAMESPACE" \
        -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    fi

    if [[ -n "$INGRESS_IP" ]]; then
      log_info "IP Ingress auto-détectée : $INGRESS_IP"
    else
      log_warn "Impossible d'auto-détecter l'IP Ingress — test HTTP ignoré"
    fi
  fi
}

# ─── Vérifications ───────────────────────────────────────────────────────────

check_namespace() {
  log_section "Namespace $NAMESPACE"
  if kctl get ns "$NAMESPACE" &>/dev/null; then
    log_success "Namespace $NAMESPACE existe"
  else
    log_error "Namespace $NAMESPACE introuvable"
    echo "  → Créer : kubectl create namespace $NAMESPACE"
    exit 1
  fi
}

check_app_pods() {
  log_section "Pods applicatifs (app=$APP_LABEL)"
  local pods running_count total_count restart_warn
  pods=$(kctl get pods -n "$NAMESPACE" -l "app=$APP_LABEL" --no-headers 2>/dev/null || true)

  if [[ -z "$pods" ]]; then
    log_error "Aucun pod trouvé pour app=$APP_LABEL dans $NAMESPACE"
    echo "  → Vérifier : kubectl get deployments -n $NAMESPACE"
    return
  fi

  total_count=$(echo "$pods" | wc -l | tr -d ' ')
  running_count=$(echo "$pods" | grep -c " Running " || true)

  log_info "$running_count/$total_count pods Running"
  log_debug "$pods"

  if [[ "$running_count" -ge "$MIN_REPLICAS" ]]; then
    log_success "Pods $APP_LABEL : $running_count/$total_count Running (min: $MIN_REPLICAS)"
  else
    log_error "Pods $APP_LABEL insuffisants : $running_count/$total_count Running (min: $MIN_REPLICAS)"
    echo "$pods" | grep -v " Running " | while read -r line; do
      local pod_name
      pod_name=$(echo "$line" | awk '{print $1}')
      echo "  → Pod en anomalie : $pod_name"
      echo "  → Diagnostic : kubectl describe pod $pod_name -n $NAMESPACE"
      echo "  → Logs : kubectl logs $pod_name -n $NAMESPACE --tail=50"
    done
  fi

  # Vérifier les restarts élevés
  restart_warn=$(echo "$pods" | awk -v max="$MAX_RESTART_WARN" '{
    gsub(/[^0-9]/, "", $5)
    if ($5+0 > max+0) print $0
  }' || true)

  if [[ -n "$restart_warn" ]]; then
    log_warn "Pods avec restarts > $MAX_RESTART_WARN (peut indiquer crash loop ou OOM) :"
    echo "$restart_warn" | while read -r line; do
      echo "  → $line"
    done
    echo "  → Vérifier RAM disponible : kubectl top nodes"
    echo "  → Logs récents : kubectl logs -n $NAMESPACE <pod> --previous"
  fi
}

check_poller_pods() {
  log_section "Pods pollers (app=$POLLER_LABEL)"
  local pods running_count
  pods=$(kctl get pods -n "$NAMESPACE" -l "app=$POLLER_LABEL" --no-headers 2>/dev/null || true)

  if [[ -z "$pods" ]]; then
    log_warn "Aucun pod poller trouvé pour app=$POLLER_LABEL"
    return
  fi

  running_count=$(echo "$pods" | grep -c " Running " || true)
  total_count=$(echo "$pods" | wc -l | tr -d ' ')

  if [[ "$running_count" -eq "$total_count" ]]; then
    log_success "Pollers : $running_count/$total_count Running"
  else
    log_error "Pollers dégradés : $running_count/$total_count Running"
  fi

  # Vérifier les logs du premier poller pour des erreurs DB
  local first_poller db_errors
  first_poller=$(echo "$pods" | grep " Running " | head -1 | awk '{print $1}')
  if [[ -n "$first_poller" ]]; then
    db_errors=$(kctl logs -n "$NAMESPACE" "$first_poller" --tail=50 2>/dev/null \
      | grep -iE "error|exception|unreachable|denied" | grep -iv "^#" || true)
    if [[ -n "$db_errors" ]]; then
      log_warn "Erreurs dans les logs du poller $first_poller :"
      echo "$db_errors" | head -5
    else
      log_success "Logs poller $first_poller : aucune erreur critique"
    fi
  fi
}

check_hpa() {
  log_section "HorizontalPodAutoscaler"
  local hpas
  hpas=$(kctl get hpa -n "$NAMESPACE" --no-headers 2>/dev/null || true)

  if [[ -z "$hpas" ]]; then
    log_warn "Aucun HPA trouvé dans $NAMESPACE"
    return
  fi

  log_debug "$hpas"

  # Vérifier que le HPA n'est pas en erreur
  local hpa_errors
  hpa_errors=$(kctl get events -n "$NAMESPACE" 2>/dev/null \
    | grep -i "FailedGetResourceMetric\|FailedComputeMetricsReplicas" | tail -3 || true)

  if [[ -n "$hpa_errors" ]]; then
    log_warn "HPA en erreur de métriques (metrics-server absent ou pod sans ressources déclarées) :"
    echo "$hpa_errors"
    echo "  → Vérifier metrics-server : kubectl top pods -n $NAMESPACE"
    echo "  → Vérifier resources dans le deployment"
  else
    log_success "HPA opérationnel (aucune erreur de métriques récente)"
  fi

  # Afficher l'état détaillé de chaque HPA
  echo "$hpas" | while read -r line; do
    local hpa_name min max current
    hpa_name=$(echo "$line" | awk '{print $1}')
    min=$(echo "$line" | awk '{print $5}')
    max=$(echo "$line" | awk '{print $6}')
    current=$(echo "$line" | awk '{print $7}')
    log_info "HPA $hpa_name : replicas=$current min=$min max=$max"
  done
}

check_services() {
  log_section "Services"
  local services
  services=$(kctl get svc -n "$NAMESPACE" --no-headers 2>/dev/null || true)

  if [[ -z "$services" ]]; then
    log_warn "Aucun service dans $NAMESPACE"
    return
  fi

  log_debug "$services"

  # Vérifier les services LoadBalancer sans IP
  local pending_lb
  pending_lb=$(echo "$services" | grep LoadBalancer | grep "<pending>" || true)
  if [[ -n "$pending_lb" ]]; then
    log_warn "Services LoadBalancer sans IP externe (MetalLB non configuré ?) :"
    echo "$pending_lb"
  else
    local lb_count
    lb_count=$(echo "$services" | grep -c LoadBalancer || true)
    [[ "$lb_count" -gt 0 ]] && log_success "$lb_count service(s) LoadBalancer avec IP attribuée"
  fi

  # Vérifier que les endpoints sont peuplés
  local svc_name
  echo "$services" | awk '{print $1}' | while read -r svc_name; do
    local endpoints
    endpoints=$(kctl get endpoints "$svc_name" -n "$NAMESPACE" \
      -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true)
    if [[ -z "$endpoints" ]]; then
      log_warn "Service $svc_name n'a pas d'endpoints — aucun pod prêt ?"
    else
      log_debug "Service $svc_name endpoints : $endpoints"
    fi
  done
}

check_ingress_http() {
  log_section "Accessibilité UI via Ingress HTTP"
  auto_detect_ingress_ip

  if [[ -z "$INGRESS_IP" ]]; then
    log_warn "IP Ingress inconnue — test HTTP ignoré"
    return
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    log_warn "DRY-RUN : curl -s -o /dev/null -w '%{http_code}' -H 'Host: $INGRESS_HOST' http://$INGRESS_IP$LOGIN_PATH"
    return
  fi

  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    --connect-timeout "$HTTP_TIMEOUT" \
    -H "Host: $INGRESS_HOST" \
    "http://$INGRESS_IP$LOGIN_PATH" 2>/dev/null || echo "000")

  case "$http_code" in
    200) log_success "UI accessible : HTTP $http_code (Host: $INGRESS_HOST → $INGRESS_IP$LOGIN_PATH)" ;;
    301|302) log_warn "Redirection HTTP $http_code — HTTPS configuré ?" ;;
    404) log_error "HTTP 404 — Ingress mal configuré ou service introuvable"
         echo "  → Vérifier : kubectl get ingress -n $NAMESPACE"
         echo "  → Note : tester avec -H 'Host: $INGRESS_HOST' (obligatoire si Ingress basé hostname)" ;;
    000) log_error "Pas de réponse — IP incorrecte ou service non joignable"
         echo "  → Vérifier : curl -v -H 'Host: $INGRESS_HOST' http://$INGRESS_IP$LOGIN_PATH" ;;
    *)   log_warn "HTTP $http_code inattendu" ;;
  esac
}

check_pvcs() {
  log_section "Volumes persistants (PVC)"
  local pvcs
  pvcs=$(kctl get pvc -n "$NAMESPACE" --no-headers 2>/dev/null || true)

  if [[ -z "$pvcs" ]]; then
    log_warn "Aucun PVC dans $NAMESPACE"
    return
  fi

  log_debug "$pvcs"

  local pending_pvcs bound_count total_count
  pending_pvcs=$(echo "$pvcs" | grep -v "Bound" || true)
  bound_count=$(echo "$pvcs" | grep -c "Bound" || true)
  total_count=$(echo "$pvcs" | wc -l | tr -d ' ')

  if [[ -z "$pending_pvcs" ]]; then
    log_success "Tous les PVC sont Bound ($bound_count/$total_count)"
  else
    log_error "PVC non Bound :"
    echo "$pending_pvcs" | while read -r line; do
      local pvc_name
      pvc_name=$(echo "$line" | awk '{print $1}')
      echo "  → $line"
      echo "  → Diagnostic : kubectl describe pvc $pvc_name -n $NAMESPACE"
      echo "  → Vérifier NFS provisioner : kubectl logs -n kube-system -l app=nfs-subdir-external-provisioner"
    done
  fi
}

check_db_env() {
  log_section "Variables DB dans les pods applicatifs"
  local running_pod
  running_pod=$(kctl get pods -n "$NAMESPACE" -l "app=$APP_LABEL" --no-headers 2>/dev/null \
    | grep " Running " | head -1 | awk '{print $1}' || true)

  if [[ -z "$running_pod" ]]; then
    log_warn "Aucun pod Running pour tester les variables DB"
    return
  fi

  local db_username
  db_username=$(kctl exec -n "$NAMESPACE" "$running_pod" -- \
    env 2>/dev/null | grep "DB_USERNAME" || true)

  if [[ -n "$db_username" ]]; then
    log_success "Variable DB_USERNAME présente dans $running_pod"
    log_debug "$db_username"
  else
    log_error "Variable DB_USERNAME absente dans $running_pod"
    echo "  → LibreNMS attend DB_USERNAME (pas DB_USER)"
    echo "  → Corriger dans le manifest deployment :"
    echo "    sed -i 's/name: DB_USER\$/name: DB_USERNAME/' <deployment.yaml>"
    echo "  → Puis : kubectl apply -f <deployment.yaml> && kubectl rollout restart deployment/$APP_LABEL -n $NAMESPACE"
  fi

  # Vérifier DB_HOST
  local db_host
  db_host=$(kctl exec -n "$NAMESPACE" "$running_pod" -- \
    env 2>/dev/null | grep "^DB_HOST=" || true)
  if [[ -n "$db_host" ]]; then
    log_info "DB_HOST configuré : $(echo "$db_host" | cut -d= -f2)"
  else
    log_warn "DB_HOST non trouvé dans les variables d'environnement"
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
    echo -e "${YELLOW}${BOLD}RÉSULTAT : AVERTISSEMENT — Application fonctionnelle avec $CHECKS_WARN alerte(s)${NC}"
    exit 0
  else
    echo -e "${GREEN}${BOLD}RÉSULTAT : SUCCÈS — Application entièrement opérationnelle${NC}"
    exit 0
  fi
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
  load_env
  parse_args "$@"

  echo -e "${BOLD}${BLUE}"
  echo "╔══════════════════════════════════════════════════════╗"
  echo "║      02_check_application.sh — Validation App        ║"
  echo "╚══════════════════════════════════════════════════════╝"
  echo -e "${NC}"

  [[ "$DRY_RUN" == "true" ]] && log_warn "MODE DRY-RUN"
  log_info "Namespace : $NAMESPACE | App : $APP_LABEL | Poller : $POLLER_LABEL"

  check_namespace
  check_app_pods
  check_poller_pods
  check_hpa
  check_services
  check_pvcs
  check_db_env
  check_ingress_http
  print_summary
}

main "$@"
