# Guide de Diagnostic Rapide
## Troubleshooting LibreNMS Kubernetes + ArgoCD

---

## 🔍 Diagnostic Rapide par Symptôme

### **Symptôme : "Whoops, looks like something went wrong."**
```bash
# Étape 1 : Vérifier les logs du pod LibreNMS
kubectl logs -n librenms deployment/librenms --tail=50

# Étape 2 : Exécuter validate.php
kubectl exec -n librenms $(kubectl get pod -n librenms -l app=librenms -o name | head -1) \
  -- php /opt/librenms/validate.php

# Probable : Erreur [FAIL] rrdcached → voir ERREUR #7
```

---

### **Symptôme : Pod librenms reste en "CrashLoopBackOff"**
```bash
# Étape 1 : Vérifier l'événement
kubectl describe pod -n librenms <pod-name>

# Étape 2 : Vérifier les logs
kubectl logs -n librenms <pod-name> --previous

# Problèmes possibles :
# • "permission denied" → voir ERREUR #1 (kubeconfig)
# • "DNS resolution failed" → voir ERREUR #8 (initContainer)
# • "Readiness probe failed" → voir ERREUR #11 (probe timeout)
```

---

### **Symptôme : GET /login OK, mais POST /login → 500**
```bash
# Étape 1 : Vérifier la connexion Redis
kubectl get svc -n librenms redis

# Étape 2 : Test DNS FQDN depuis le pod
kubectl exec -n librenms $(kubectl get pod -n librenms -l app=librenms -o name | head -1) \
  -- nslookup redis.librenms.svc.cluster.local.

# Étape 3 : Test netcat
kubectl exec -n librenms $(kubectl get pod -n librenms -l app=librenms -o name | head -1) \
  -- nc -zv redis.librenms.svc.cluster.local 6379

# Probable : Erreur #9 (DNS ndots) ou #10 (sticky sessions)
```

---

### **Symptôme : "No user () from IP" lors du login**
```bash
# Étape 1 : Vérifier les replicas
kubectl get pod -n librenms -l app=librenms

# Étape 2 : Vérifier sessionAffinity
kubectl get svc librenms -n librenms -o yaml | grep -A5 sessionAffinity

# Étape 3 : Vérifier les annotations Ingress
kubectl get ingress -n librenms librenms -o yaml | grep affinity

# Probable : Erreur #10 (sticky sessions non configurées)
```

---

### **Symptôme : ArgoCD ne démarre pas (Docker Compose VM)**
```bash
# Étape 1 : Vérifier les logs ArgoCD
docker logs -f argocd-server

# Étape 2 : Vérifier le kubeconfig
ls -la /opt/argocd/kubeconfig
cat /opt/argocd/kubeconfig | head -5

# Étape 3 : Tester la connexion à l'API Kubernetes
kubectl --kubeconfig=/opt/argocd/kubeconfig cluster-info

# Problèmes possibles :
# • "Permission denied" → voir ERREUR #1
# • "is a directory" → voir ERREUR #2
# • "configmap not found" → voir ERREUR #3
```

---

### **Symptôme : Login échoue (bad credentials)**
```bash
# Étape 1 : Vérifier l'utilisateur en DB
kubectl exec -n librenms $(kubectl get pod -n librenms -l app=librenms -o name | head -1) \
  -- mysql -h 192.168.98.131 -u librenms -p<PASSWORD> librenms -e \
  "SELECT username, password FROM users WHERE username='matt';"

# Étape 2 : Réinitialiser le mot de passe
# Utiliser la procédure ERREUR #12

# Probable : Erreur #12 (hash mot de passe invalide)
```

---

## 📋 Checklist de Vérification Complète

### ArgoCD (VM Docker Compose)

- [ ] **#1** Kubeconfig permissions : `ls -la /opt/argocd/kubeconfig` → `-rw-r--r--`
- [ ] **#2** Kubeconfig est un fichier : `file /opt/argocd/kubeconfig` → "ASCII text"
- [ ] **#3** ConfigMaps existent : `kubectl get cm -n argocd`
- [ ] **#4** Namespace spécifié : `docker logs argocd-server` | grep namespace
- [ ] **#5** Versions alignées : `docker inspect argocd-server:latest` | grep -i version
- [ ] **#6** server.secretkey présent : `kubectl get secret argocd-secret -n argocd -o yaml | grep server.secretkey`

### Kubernetes Cluster

- [ ] **#8** initContainer en place : `kubectl get deployment librenms -n librenms -o yaml | grep initContainer`
- [ ] **#9** REDIS_HOST avec point final : `kubectl get deployment librenms -n librenms -o yaml | grep REDIS_HOST`
- [ ] **#10** sessionAffinity ConfiguréE : `kubectl get svc librenms -n librenms -o yaml | grep sessionAffinity`
- [ ] **#10** Ingress affinity ConfiguréE : `kubectl get ingress librenms -n librenms -o yaml | grep affinity`
- [ ] **#11** Probe timeouts suffisants : `kubectl get deployment librenms -n librenms -o yaml | grep -A5 livenessProbe`

### Infrastructure Externe

- [ ] **#7** RRDcached accesible : `nc -zv 192.168.98.131 42217`
- [ ] **#7** Config IP correcte : `cat /etc/default/rrdcached | grep NETWORK_OPTIONS`
- [ ] **#7** WRITE_JITTER > 0 : `cat /etc/default/rrdcached | grep WRITE_JITTER`
- [ ] **#12** Utilisateur DB existe : `mysql ... -e "SELECT * FROM users WHERE username='matt';"`

---

## 🚨 Matrice de Risque et Priorités

| Erreur | Sévérité | Impact | Temps Fix | Priorité |
|--------|----------|--------|-----------|----------|
| #1 | Critique | ArgoCD inaccessible | 1 min | P0 |
| #2 | Critique | ArgoCD crash | 1 min | P0 |
| #3 | Critique | ArgoCD crash | 2 min | P0 |
| #4 | Haute | ArgoCD config échoue | 1 min | P1 |
| #5 | Haute | CRD incompatibles | 5 min | P1 |
| #6 | Moyenne | Sessions aléatoires | 1 min | P2 |
| #7 | Critique | Pas de monitoring | 5 min | P0 |
| #8 | Haute | Pod crash au démarrage | 2 min | P1 |
| #9 | Haute | Login instable | 1 min | P1 |
| #10 | Haute | Login intermittent | 2 min | P1 |
| #11 | Moyenne | Pod killing | 2 min | P2 |
| #12 | Haute | Authentification bloquée | 3 min | P1 |

---

## 🔧 Scripts de Vérification Automatisée

### Script 1 : Vérifier ArgoCD (à exécuter sur VM Docker)
```bash
#!/bin/bash
set -e

echo "=== Vérification ArgoCD ==="

# #1
echo "✓ Vérification kubeconfig permissions..."
PERM=$(stat -c %a /opt/argocd/kubeconfig)
if [ "$PERM" == "644" ]; then echo "  ✅ OK"; else echo "  ❌ FAIL: $PERM != 644"; fi

# #2
echo "✓ Vérification kubeconfig est un fichier..."
if [ -f /opt/argocd/kubeconfig ]; then echo "  ✅ OK"; else echo "  ❌ FAIL: pas un fichier"; fi

# Test de connexion
echo "✓ Test connexion API Kubernetes..."
if kubectl --kubeconfig=/opt/argocd/kubeconfig cluster-info > /dev/null 2>&1; then
  echo "  ✅ OK"
else
  echo "  ❌ FAIL: impossible de se connecter"
fi

# #3
echo "✓ Vérification ConfigMaps..."
if kubectl get cm argocd-cm -n argocd > /dev/null 2>&1; then
  echo "  ✅ OK"
else
  echo "  ❌ FAIL: argocd-cm non trouvée"
fi

echo ""
echo "=== Résumé ArgoCD OK ==="
```

### Script 2 : Vérifier LibreNMS (à exécuter sur cluster K8s)
```bash
#!/bin/bash
set -e

echo "=== Vérification LibreNMS ==="

# #8
echo "✓ Vérification initContainer..."
if kubectl get deployment librenms -n librenms -o yaml | grep -q "wait-for-redis"; then
  echo "  ✅ OK"
else
  echo "  ❌ FAIL: initContainer absent"
fi

# #9
echo "✓ Vérification REDIS_HOST FQDN..."
REDIS_HOST=$(kubectl get deployment librenms -n librenms -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="REDIS_HOST")].value}')
if [[ "$REDIS_HOST" == *"."* ]]; then
  echo "  ✅ OK: $REDIS_HOST"
else
  echo "  ❌ FAIL: Point final absent: $REDIS_HOST"
fi

# #10
echo "✓ Vérification sessionAffinity..."
AFFINITY=$(kubectl get svc librenms -n librenms -o jsonpath='{.spec.sessionAffinity}')
if [ "$AFFINITY" == "ClientIP" ]; then
  echo "  ✅ OK"
else
  echo "  ❌ FAIL: sessionAffinity = $AFFINITY"
fi

# #11
echo "✓ Vérification Probe timeouts..."
TIMEOUT=$(kubectl get deployment librenms -n librenms -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.timeoutSeconds}')
if [ "$TIMEOUT" -ge "10" ]; then
  echo "  ✅ OK: $TIMEOUT secondes"
else
  echo "  ❌ FAIL: Timeout trop court: $TIMEOUT secondes"
fi

# #7
echo "✓ Vérification RRDcached..."
if nc -zv 192.168.98.131 42217 2>/dev/null; then
  echo "  ✅ OK"
else
  echo "  ❌ FAIL: RRDcached inaccessible"
fi

echo ""
echo "=== Résumé LibreNMS OK ==="
```

---

## 📞 Contacts & Escalade

| Problème | Responsable | Contact |
|----------|-------------|---------|
| ArgoCD / GitOps | DevOps | Matt (ASR) |
| Kubernetes | SRE | Matt (ASR) |
| Réseau / Infrastructure | NetOps | Admin réseau |
| RRDcached / Stockage | Storage | Admin infra |
| LibreNMS / App | Monitoring | Matt (ASR) |

---

## 🔗 Ressources Additionnelles

- **Document Principal** : `LibreNMS_Kubernetes_Erreurs_Resolutions_UNIFIED.docx`
- **Index Détaillé** : `INDEX_ERREURS_RESOLUTIONS.md`
- **GitHub Repo** : `make5035/librenms-k8s-test`
- **Documentation K8s** : https://kubernetes.io/docs/
- **Documentation ArgoCD** : https://argo-cd.readthedocs.io/

---

**Dernier update** : 7 mai 2026
**Statut** : ✅ Production-ready
