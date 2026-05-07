#!/usr/bin/env bash
# =============================================================================
# Script      : 05_check_rrd_migration.sh
# Description : Validation de la migration des données RRD (source → cible)
# Exécution   : VM Docker source / Bastion avec accès NFS et kubectl
# Prérequis   : rsync, nfs-common, accès réseau NFS, kubectl
# Usage       : ./05_check_rrd_migration.sh [OPTIONS]
#   --source-path PATH    Chemin RRD source (défaut: auto-détection Docker)
#   --source-container    Container rrdcached source (défaut: librenms_test_rrdcached)
#   --nfs-server IP       IP du serveur NFS
#   --nfs-path PATH       Chemin exporté NFS (défaut: /exports/librenms)
#   --nfs-mount PATH      Point de montage local (défaut: /mnt/rrd-check)
#   --pvc-name NAME       Nom du PVC rrdcached K8s (auto-détection si absent)
#   --rrdcached-dir PATH  Répertoire rrdcached sur la VM cible
#   --rrdcached-host IP   IP de la VM rrdcached cible
#   --namespace NS        Namespace K8s (défaut: librenms)
#   --context CTX         Contexte kubectl
#   --verbose             Mode debug
#   --dry-run             Simulation
#   --env-file FILE       Fichier .env
# Compatible  : CI/CD
# =============================================================================

set -euo pipefail

# ─── Valeurs par défaut ───────────────────────────────────────────────────────
SOURCE_PATH="${SOURCE_PATH:-}"
SOURCE_CONTAINER="${SOURCE_CONTAINER:-librenms_test_rrdcached}"
NFS_SERVER="${NFS_SERVER:-}"
NFS_PATH="${NFS_PATH:-/exports/librenms}"
NFS_MOUNT="${NFS_MOUNT:-/mnt/rrd-check}"
PVC_NAME="${PVC_NAME:-}"
RRDCACHED_DIR="${RRDCACHED_DIR:-/var/lib/rrdcached/db}"
RRDCACHED_HOST="${RRDCACHED_HOST:-}"
NAMESPACE="${NAMESPACE:-librenms}"
KUBECONTEXT="${KUBECONTEXT:-}"
VERBOSE="${VERBOSE:-false}"
DRY_RUN="${DRY_RUN:-false}"
ENV_FILE="${ENV_FILE:-.env}"

# Tolérance de différence de taille (%)
SIZE_TOLERANCE="${SIZE_TOLERANCE:-5}"

# ─── Couleurs ────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'; BOLD='\033[1m'

CHECKS_OK=0; CHECKS_WARN=0; CHECKS_FAIL=0
NFS_MOUNTED=false

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
      --source-path)      SOURCE_PATH="$2";      shift 2 ;;
      --source-container) SOURCE_CONTAINER="$2"; shift 2 ;;
      --nfs-server)       NFS_SERVER="$2";       shift 2 ;;
      --nfs-path)         NFS_PATH="$2";         shift 2 ;;
      --nfs-mount)        NFS_MOUNT="$2";        shift 2 ;;
      --pvc-name)         PVC_NAME="$2";         shift 2 ;;
      --rrdcached-dir)    RRDCACHED_DIR="$2";    shift 2 ;;
      --rrdcached-host)   RRDCACHED_HOST="$2";   shift 2 ;;
      --namespace)        NAMESPACE="$2";        shift 2 ;;
      --context)          KUBECONTEXT="$2";      shift 2 ;;
      --size-tolerance)   SIZE_TOLERANCE="$2";   shift 2 ;;
      --verbose)          VERBOSE="true";        shift ;;
      --dry-run)          DRY_RUN="true";        shift ;;
      --env-file)         ENV_FILE="$2";         shift 2 ;;
      -h|--help)          usage; exit 0 ;;
      *) echo "Argument inconnu: $1"; usage; exit 1 ;;
    esac
  done
}

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]
  --source-path PATH      Chemin RRD source
  --source-container NAME Container rrdcached Docker source
  --nfs-server IP         Serveur NFS
  --nfs-path PATH         Export NFS (défaut: /exports/librenms)
  --nfs-mount PATH        Point montage local (défaut: /mnt/rrd-check)
  --pvc-name NAME         Nom PVC K8s (auto-détection)
  --rrdcached-dir PATH    Répertoire rrdcached cible (défaut: /var/lib/rrdcached/db)
  --rrdcached-host IP     IP VM rrdcached cible
  --size-tolerance N      Tolérance taille en % (défaut: 5)
  --namespace / --context / --verbose / --dry-run / --env-file
EOF
}

kctl() {
  [[ -n "$KUBECONTEXT" ]] && kubectl --context="$KUBECONTEXT" "$@" || kubectl "$@"
}

# Nettoyage au exit
cleanup() {
  if [[ "$NFS_MOUNTED" == "true" ]]; then
    log_info "Démontage NFS $NFS_MOUNT"
    sudo umount "$NFS_MOUNT" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# ─── Auto-détection ───────────────────────────────────────────────────────────

auto_detect_source_path() {
  if [[ -n "$SOURCE_PATH" ]]; then return; fi

  # Essayer depuis le container Docker
  if command -v docker &>/dev/null; then
    local container_source
    container_source=$(docker inspect "$SOURCE_CONTAINER" 2>/dev/null \
      | python3 -c "import json,sys; d=json.load(sys.stdin); \
        [print(m['Source']) for c in d for m in c.get('Mounts',[]) \
         if 'rrd' in m.get('Destination','').lower() or 'db' in m.get('Destination','').lower()]" \
      2>/dev/null | head -1 || true)

    if [[ -n "$container_source" ]]; then
      SOURCE_PATH="$container_source"
      log_info "Source RRD auto-détectée depuis Docker : $SOURCE_PATH"
      return
    fi
  fi

  log_warn "Impossible d'auto-détecter SOURCE_PATH — utiliser --source-path"
}

auto_detect_pvc_name() {
  if [[ -n "$PVC_NAME" ]]; then return; fi

  PVC_NAME=$(kctl get pvc -n "$NAMESPACE" --no-headers 2>/dev/null \
    | grep -i "rrd" | awk '{print $1}' | head -1 || true)

  if [[ -n "$PVC_NAME" ]]; then
    log_info "PVC RRD auto-détecté : $PVC_NAME"
  else
    log_warn "PVC RRD non trouvé dans $NAMESPACE — utiliser --pvc-name"
  fi
}

auto_detect_nfs_folder() {
  # Trouver le dossier NFS correspondant au PVC
  if [[ -z "$PVC_NAME" ]]; then return; fi
  if [[ ! -d "$NFS_MOUNT" ]]; then return; fi

  local nfs_folder
  nfs_folder=$(ls "$NFS_MOUNT" 2>/dev/null | grep -i "$PVC_NAME\|rrdcached" | head -1 || true)

  if [[ -n "$nfs_folder" ]]; then
    NFS_PVC_FOLDER="$NFS_MOUNT/$nfs_folder"
    log_info "Dossier NFS PVC détecté : $NFS_PVC_FOLDER"
  else
    NFS_PVC_FOLDER=""
    log_warn "Dossier PVC non trouvé dans $NFS_MOUNT"
  fi
}

# ─── Vérifications ───────────────────────────────────────────────────────────

check_rrdcached_stopped() {
  log_section "État du container rrdcached source"
  if ! command -v docker &>/dev/null; then
    log_warn "Docker non disponible — vérification container ignorée"
    return
  fi

  local status
  status=$(docker inspect "$SOURCE_CONTAINER" --format '{{.State.Status}}' 2>/dev/null || echo "not_found")

  case "$status" in
    "running")
      log_warn "Container $SOURCE_CONTAINER encore Running"
      echo "  → ⚠️  Arrêter avant la copie pour éviter des fichiers RRD corrompus"
      echo "  → Arrêt propre (flush automatique) :"
      echo "    docker compose -f <compose.yaml> stop rrdcached"
      echo "  → Ou directement :"
      echo "    docker stop $SOURCE_CONTAINER"
      ;;
    "exited")
      log_success "Container $SOURCE_CONTAINER arrêté (flush automatique effectué)"
      ;;
    "not_found")
      log_info "Container $SOURCE_CONTAINER non trouvé — ignoré"
      ;;
    *)
      log_warn "État container $SOURCE_CONTAINER : $status"
      ;;
  esac
}

check_source_rrd() {
  log_section "Données RRD source"
  auto_detect_source_path

  if [[ -z "$SOURCE_PATH" ]]; then
    log_warn "Chemin source RRD non défini — vérification ignorée"
    return
  fi

  if [[ ! -d "$SOURCE_PATH" ]]; then
    log_error "Répertoire source RRD introuvable : $SOURCE_PATH"
    return
  fi

  local size file_count dir_count
  size=$(du -sh "$SOURCE_PATH" 2>/dev/null | cut -f1 || echo "?")
  file_count=$(find "$SOURCE_PATH" -name "*.rrd" 2>/dev/null | wc -l | tr -d ' ')
  dir_count=$(find "$SOURCE_PATH" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')

  log_success "Source RRD : $size | $file_count fichiers .rrd | $dir_count dossiers devices"
  log_info "Chemin : $SOURCE_PATH"

  # Stocker pour comparaison
  SOURCE_SIZE="$size"
  SOURCE_FILES="$file_count"
}

check_pvc_exists() {
  log_section "PVC rrdcached K8s"
  auto_detect_pvc_name

  if [[ -z "$PVC_NAME" ]]; then
    log_warn "PVC RRD non défini — utiliser --pvc-name"
    return
  fi

  local pvc_status pvc_size
  pvc_status=$(kctl get pvc "$PVC_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
  pvc_size=$(kctl get pvc "$PVC_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.spec.resources.requests.storage}' 2>/dev/null || echo "?")

  if [[ "$pvc_status" == "Bound" ]]; then
    log_success "PVC $PVC_NAME : Bound ($pvc_size)"
  elif [[ "$pvc_status" == "NotFound" ]]; then
    log_error "PVC $PVC_NAME introuvable dans $NAMESPACE"
    echo "  → Créer : kubectl apply -f librenms-pvc.yaml"
  else
    log_error "PVC $PVC_NAME en état : $pvc_status"
    echo "  → Diagnostic : kubectl describe pvc $PVC_NAME -n $NAMESPACE"
    echo "  → Logs provisioner : kubectl logs -n kube-system -l app=nfs-subdir-external-provisioner"
  fi
}

check_nfs_mount() {
  log_section "Montage NFS pour vérification"
  if [[ -z "$NFS_SERVER" ]]; then
    log_warn "NFS_SERVER non défini — montage ignoré"
    return
  fi

  if ! command -v mount &>/dev/null; then
    log_warn "mount non disponible"
    return
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    log_warn "DRY-RUN : sudo mount -t nfs $NFS_SERVER:$NFS_PATH $NFS_MOUNT"
    return
  fi

  # Vérifier si déjà monté
  if mount | grep -q "$NFS_MOUNT"; then
    log_info "NFS déjà monté sur $NFS_MOUNT"
    NFS_MOUNTED=true
    return
  fi

  # Installer nfs-common si absent
  if ! command -v showmount &>/dev/null; then
    log_info "Installation de nfs-common..."
    sudo apt install -y nfs-common &>/dev/null || true
  fi

  sudo mkdir -p "$NFS_MOUNT"

  if sudo mount -t nfs "$NFS_SERVER:$NFS_PATH" "$NFS_MOUNT" 2>/dev/null; then
    NFS_MOUNTED=true
    local nfs_size
    nfs_size=$(df -h "$NFS_MOUNT" | tail -1 | awk '{print "Total="$2" Dispo="$4}')
    log_success "NFS monté : $NFS_SERVER:$NFS_PATH → $NFS_MOUNT ($nfs_size)"
    auto_detect_nfs_folder
  else
    log_error "Échec montage NFS $NFS_SERVER:$NFS_PATH"
    echo "  → Vérifier : showmount -e $NFS_SERVER"
    echo "  → Vérifier exports NFS : cat /etc/exports sur $NFS_SERVER"
    echo "  → Vérifier nfs-server : systemctl status nfs-server sur $NFS_SERVER"
  fi
}

check_nfs_rrd_content() {
  log_section "Contenu RRD dans le PVC NFS"
  if [[ "$NFS_MOUNTED" != "true" ]]; then
    log_warn "NFS non monté — vérification contenu ignorée"
    return
  fi

  local target_dir="${NFS_PVC_FOLDER:-$NFS_MOUNT}"
  if [[ ! -d "$target_dir" ]]; then
    log_warn "Dossier cible NFS non trouvé : $target_dir"
    return
  fi

  local size file_count
  size=$(du -sh "$target_dir" 2>/dev/null | cut -f1 || echo "?")
  file_count=$(find "$target_dir" -name "*.rrd" 2>/dev/null | wc -l | tr -d ' ')

  log_info "Contenu NFS PVC : $size | $file_count fichiers .rrd"

  if [[ "${SOURCE_FILES:-0}" -gt 0 ]]; then
    if [[ "$file_count" -ge "${SOURCE_FILES:-0}" ]]; then
      log_success "Fichiers RRD dans NFS ($file_count) ≥ source (${SOURCE_FILES:-?}) ✓"
    else
      log_error "Fichiers RRD insuffisants : NFS=$file_count source=${SOURCE_FILES:-?}"
      echo "  → Copie incomplète — relancer rsync :"
      echo "    rsync -av --progress $SOURCE_PATH/ $target_dir/"
    fi
  else
    if [[ "$file_count" -gt 0 ]]; then
      log_success "$file_count fichiers .rrd présents dans le PVC NFS"
    else
      log_error "Aucun fichier .rrd dans le PVC NFS"
      echo "  → Le PVC est vide — effectuer la migration RRD"
    fi
  fi
}

check_rrdcached_target() {
  log_section "Données RRD sur la VM rrdcached cible"
  if [[ -z "$RRDCACHED_HOST" ]]; then
    log_warn "RRDCACHED_HOST non défini — vérification cible ignorée"
    return
  fi

  local size file_count
  size=$(ssh -o ConnectTimeout=5 "matt@$RRDCACHED_HOST" \
    "du -sh $RRDCACHED_DIR 2>/dev/null | cut -f1" 2>/dev/null || echo "?")
  file_count=$(ssh -o ConnectTimeout=5 "matt@$RRDCACHED_HOST" \
    "find $RRDCACHED_DIR -name '*.rrd' 2>/dev/null | wc -l" 2>/dev/null || echo "0")

  log_info "VM rrdcached $RRDCACHED_HOST : $size | $file_count fichiers .rrd"

  if [[ "$file_count" -gt 0 ]]; then
    log_success "Données RRD présentes sur $RRDCACHED_HOST ($RRDCACHED_DIR)"
  else
    log_error "Aucun fichier .rrd sur $RRDCACHED_HOST:$RRDCACHED_DIR"
    echo "  → Copier depuis le NFS :"
    echo "    ssh matt@$RRDCACHED_HOST 'sudo rsync -av <NFS_MOUNT>/ $RRDCACHED_DIR/'"
  fi

  # Vérifier que rrdcached tourne
  local rrdcached_status
  rrdcached_status=$(ssh -o ConnectTimeout=5 "matt@$RRDCACHED_HOST" \
    "sudo systemctl is-active rrdcached" 2>/dev/null || echo "unknown")

  if [[ "$rrdcached_status" == "active" ]]; then
    log_success "rrdcached service actif sur $RRDCACHED_HOST"
  else
    log_error "rrdcached service NON actif sur $RRDCACHED_HOST : $rrdcached_status"
    echo "  → Démarrer : ssh matt@$RRDCACHED_HOST 'sudo systemctl start rrdcached'"
  fi
}

check_rrdcached_port() {
  log_section "Connectivité rrdcached TCP"
  if [[ -z "$RRDCACHED_HOST" ]]; then
    log_warn "RRDCACHED_HOST non défini — test port ignoré"
    return
  fi

  local port=42217
  if command -v nc &>/dev/null; then
    if nc -zv -w 5 "$RRDCACHED_HOST" "$port" &>/dev/null; then
      log_success "Port $port joignable sur $RRDCACHED_HOST (rrdcached écoute)"
    else
      log_error "Port $port inaccessible sur $RRDCACHED_HOST"
      echo "  → Vérifier rrdcached : systemctl status rrdcached"
      echo "  → Vérifier bind dans /etc/default/rrdcached :"
      echo "    NETWORK_OPTIONS=\"-l $RRDCACHED_HOST:$port\""
    fi
  else
    log_warn "nc non disponible — test port TCP ignoré"
  fi
}

print_summary() {
  log_section "Résumé Migration RRD"
  echo -e "  ${GREEN}✅ OK     : $CHECKS_OK${NC}"
  echo -e "  ${YELLOW}⚠️  WARN   : $CHECKS_WARN${NC}"
  echo -e "  ${RED}❌ FAIL   : $CHECKS_FAIL${NC}"
  echo ""
  if [[ $CHECKS_FAIL -gt 0 ]]; then
    echo -e "${RED}${BOLD}RÉSULTAT : ÉCHEC migration RRD${NC}"; exit 1
  elif [[ $CHECKS_WARN -gt 0 ]]; then
    echo -e "${YELLOW}${BOLD}RÉSULTAT : Migration RRD partielle — vérifier les avertissements${NC}"; exit 0
  else
    echo -e "${GREEN}${BOLD}RÉSULTAT : Migration RRD validée${NC}"; exit 0
  fi
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
  load_env
  parse_args "$@"

  echo -e "${BOLD}${BLUE}"
  echo "╔══════════════════════════════════════════════════════╗"
  echo "║      05_check_rrd_migration.sh — Validation RRD      ║"
  echo "╚══════════════════════════════════════════════════════╝"
  echo -e "${NC}"

  check_rrdcached_stopped
  check_source_rrd
  check_pvc_exists
  check_nfs_mount
  check_nfs_rrd_content
  check_rrdcached_target
  check_rrdcached_port
  print_summary
}

main "$@"
