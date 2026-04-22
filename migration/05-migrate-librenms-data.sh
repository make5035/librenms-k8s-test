#!/bin/bash
# ==============================================================================
# migration/05-migrate-librenms-data.sh
# Migration des données /data LibreNMS prod → PVC K8s
# ==============================================================================
# Ce script copie le contenu de /srv/librenms/librenms/ (prod Docker)
# vers le PVC librenms-data-pvc du cluster K8s.
#
# Contenu migré :
#   config/       ← SNMP.php, AD_auth.php, SMTP.php, Hook.php, Map.php,
#                    Oxidized.php, Custom_conf.php
#   weathermap/   ← MPLS.conf, Routeur_FW.conf, images/ (F5, firewall, Mikrotik...)
#   alert-templates/
#   syslog-ng/
#   .env          ← fichier d'environnement LibreNMS (adapter DB_HOST)
#
# NON migré (géré séparément) :
#   rrd/          ← géré par RRDcached externe (VM 192.168.98.131)
#   logs/         ← ne pas migrer les logs prod
#
# Prérequis :
#   - PVC librenms-data-pvc déjà créé et Bound
#   - Pod de migration temporaire créé (voir ci-dessous)
#   - Accès SSH au serveur de production
#   - kubectl configuré sur le cluster K8s test
#
# Usage :
#   PROD_HOST=<IP_SERVEUR_PROD> PROD_USER=root bash 05-migrate-librenms-data.sh
# ==============================================================================

set -euo pipefail

PROD_HOST="${PROD_HOST:-INVNMS-PXG01}"
PROD_USER="${PROD_USER:-root}"
PROD_DATA_PATH="/srv/librenms/librenms"
PROD_MENU_PATH="/srv/librenms/resources/views/menu"
NAMESPACE="librenms"
MIGRATION_POD="librenms-data-migration"
LOCAL_STAGING="/tmp/librenms-migration-staging"

echo "============================================================"
echo " Migration LibreNMS /data prod → PVC K8s"
echo " Source : ${PROD_USER}@${PROD_HOST}:${PROD_DATA_PATH}"
echo " Namespace K8s : ${NAMESPACE}"
echo "============================================================"

# ── Étape 1 : Vérification PVC ──────────────────────────────────────────────
echo ""
echo "[1/7] Vérification PVC librenms-data-pvc..."
PVC_STATUS=$(kubectl get pvc librenms-data-pvc -n "${NAMESPACE}" \
  -o jsonpath='{.status.phase}' 2>/dev/null || echo "NOT_FOUND")

if [ "${PVC_STATUS}" != "Bound" ]; then
  echo "✗ PVC librenms-data-pvc non trouvé ou non Bound (statut: ${PVC_STATUS})"
  echo "  Appliquer d'abord : kubectl apply -f librenms/librenms-pvc.yaml"
  exit 1
fi
echo "✓ PVC librenms-data-pvc : Bound"

# ── Étape 2 : Pod de migration temporaire ───────────────────────────────────
echo ""
echo "[2/7] Création du pod de migration temporaire..."
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${MIGRATION_POD}
  namespace: ${NAMESPACE}
spec:
  restartPolicy: Never
  containers:
  - name: migration
    image: busybox:1.36
    command: ["sh", "-c", "sleep 3600"]
    volumeMounts:
    - name: librenms-data
      mountPath: /data
    - name: weathermap-output
      mountPath: /weathermap-output
    - name: librenms-menu
      mountPath: /menu
  volumes:
  - name: librenms-data
    persistentVolumeClaim:
      claimName: librenms-data-pvc
  - name: weathermap-output
    persistentVolumeClaim:
      claimName: librenms-weathermap-output-pvc
  - name: librenms-menu
    persistentVolumeClaim:
      claimName: librenms-menu-pvc
EOF

echo "  Attente démarrage pod..."
kubectl wait --for=condition=Ready pod/${MIGRATION_POD} \
  -n "${NAMESPACE}" --timeout=60s
echo "✓ Pod ${MIGRATION_POD} prêt"

# ── Étape 3 : Staging local ─────────────────────────────────────────────────
echo ""
echo "[3/7] Copie depuis le serveur de production..."
mkdir -p "${LOCAL_STAGING}"

# Contenu à migrer — exclure rrd/ et logs/ (géré séparément)
rsync -avz --progress \
  --exclude='rrd/' \
  --exclude='logs/' \
  --exclude='*.log' \
  "${PROD_USER}@${PROD_HOST}:${PROD_DATA_PATH}/" \
  "${LOCAL_STAGING}/data/"

# Menu custom
rsync -avz --progress \
  "${PROD_USER}@${PROD_HOST}:${PROD_MENU_PATH}/" \
  "${LOCAL_STAGING}/menu/"

echo "✓ Données récupérées dans ${LOCAL_STAGING}"

# ── Étape 4 : Vérification contenu critique ─────────────────────────────────
echo ""
echo "[4/7] Vérification des fichiers critiques..."

CRITICAL_FILES=(
  "${LOCAL_STAGING}/data/config/SNMP.php"
  "${LOCAL_STAGING}/data/config/AD_auth.php"
  "${LOCAL_STAGING}/data/weathermap/MPLS.conf"
  "${LOCAL_STAGING}/menu/custom.blade.php"
)

for f in "${CRITICAL_FILES[@]}"; do
  if [ -f "$f" ]; then
    echo "  ✓ $(basename $f)"
  else
    echo "  ⚠ Absent : $f"
  fi
done

# ── Étape 5 : Adaptation .env pour K8s ──────────────────────────────────────
echo ""
echo "[5/7] Adaptation du fichier .env pour K8s..."
if [ -f "${LOCAL_STAGING}/data/.env" ]; then
  # Sauvegarder l'original
  cp "${LOCAL_STAGING}/data/.env" "${LOCAL_STAGING}/data/.env.prod-original"
  # Adapter les variables pointant sur des services K8s
  sed -i 's/^DB_HOST=.*/DB_HOST=192.168.98.131/' "${LOCAL_STAGING}/data/.env"
  sed -i 's/^REDIS_HOST=.*/REDIS_HOST=redis.librenms.svc.cluster.local/' \
    "${LOCAL_STAGING}/data/.env"
  echo "  ✓ .env adapté (DB_HOST + REDIS_HOST mis à jour)"
  echo "  ℹ .env.prod-original conservé pour référence"
fi

# ── Étape 6 : Injection dans les PVCs ───────────────────────────────────────
echo ""
echo "[6/7] Injection des données dans les PVCs K8s..."

# Données principales → librenms-data-pvc
kubectl cp "${LOCAL_STAGING}/data/." \
  "${NAMESPACE}/${MIGRATION_POD}:/data/"
echo "  ✓ /data copié → librenms-data-pvc"

# Menu custom → librenms-menu-pvc
kubectl cp "${LOCAL_STAGING}/menu/." \
  "${NAMESPACE}/${MIGRATION_POD}:/menu/"
echo "  ✓ menu/ copié → librenms-menu-pvc"

# ── Étape 7 : Nettoyage ─────────────────────────────────────────────────────
echo ""
echo "[7/7] Nettoyage..."
kubectl delete pod "${MIGRATION_POD}" -n "${NAMESPACE}"
rm -rf "${LOCAL_STAGING}"
echo "✓ Pod de migration supprimé"
echo "✓ Staging local nettoyé"

echo ""
echo "============================================================"
echo " ✓ Migration /data LibreNMS terminée"
echo ""
echo " Vérification recommandée :"
echo "   kubectl exec -n librenms deploy/librenms -- ls /data/config/"
echo "   kubectl exec -n librenms deploy/librenms -- ls /opt/librenms/html/plugins/Weathermap/"
echo "   kubectl exec -n librenms deploy/librenms -- cat /data/config/SNMP.php"
echo "============================================================"
