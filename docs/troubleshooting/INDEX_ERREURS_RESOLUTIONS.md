# Index Unifié — Erreurs et Résolutions
## Migration LibreNMS Docker Compose → Kubernetes + ArgoCD Externe

---

## 📋 Table de Recherche Rapide

| # | Titre | Catégorie | Composant | Statut |
|---|-------|-----------|-----------|--------|
| 1 | Kubeconfig inaccessible (Permission denied) | ArgoCD | Permissions | ✅ Résolu |
| 2 | Kubeconfig créé comme répertoire | ArgoCD | Docker Compose | ✅ Résolu |
| 3 | ConfigMaps non trouvées (Hub and Spoke) | ArgoCD | Cluster K8s | ✅ Résolu |
| 4 | Mauvais namespace par défaut | ArgoCD | Docker Compose | ✅ Résolu |
| 5 | Version incompatible (v3.3.6 vs v2.10.6) | ArgoCD | Versions CRD | ✅ Résolu |
| 6 | server.secretkey missing | ArgoCD | Secrets | ✅ Résolu |
| 7 | RRDcached inaccessible | Stockage/Réseau | RRDcached | ✅ Résolu |
| 8 | initContainer wait-for-redis | Kubernetes | Démarrage | ✅ Résolu |
| 9 | DNS intermittent (ndots:5) | Réseau/DNS | CoreDNS | ✅ Résolu |
| 10 | Session Loss (Sticky sessions) | Kubernetes/Session | Ingress | ✅ Résolu |
| 11 | Liveness/Readiness Probe Timeout | Kubernetes | Health Check | ✅ Résolu |
| 12 | Authentification échoue | Application | LibreNMS | ✅ Résolu |

---

## 🔍 Index par Catégorie

### ArgoCD (6 erreurs)
- **#1** Kubeconfig inaccessible (Permission denied)
- **#2** Kubeconfig créé comme répertoire
- **#3** ConfigMaps non trouvées (Hub and Spoke)
- **#4** Mauvais namespace par défaut
- **#5** Version incompatible (v3.3.6 vs v2.10.6)
- **#6** server.secretkey missing

### Kubernetes (2 erreurs)
- **#8** initContainer wait-for-redis
- **#11** Liveness/Readiness Probe Timeout

### Réseau / DNS (2 erreurs)
- **#9** DNS intermittent (ndots:5 + CoreDNS saturation)

### Session / Load Balancing (1 erreur)
- **#10** Multi-Replica Session Loss (Sticky sessions requis)

### Stockage / Infrastructure (1 erreur)
- **#7** RRDcached inaccessible (Ancien IP binding)

### Application / Authentification (1 erreur)
- **#12** Authentification échoue (Hash mot de passe invalide)

---

## 📊 Statistiques

| Métrique | Valeur |
|----------|--------|
| **Total d'erreurs documentées** | 12 |
| **Taux de résolution** | 100% ✅ |
| **Catégories** | 6 |
| **Commandes documentées** | 30+ |
| **Date de compilation** | 7 Mai 2026 |

---

## 🎯 Recherche par Mots-Clés

### ArgoCD / GitOps
- `#1` `#2` `#3` `#4` `#5` `#6`
- Keywords: kubeconfig, ConfigMaps, namespace, CRD, secrets, server.secretkey

### Kubernetes Core
- `#8` `#11`
- Keywords: initContainer, probe, health check, liveness, readiness, CrashLoopBackOff

### Réseau / DNS
- `#9` `#10`
- Keywords: CoreDNS, ndots, session, sticky, FQDN, DNS resolution

### Stockage / Données
- `#7`
- Keywords: RRDcached, binding, IP, port, network

### Application / LibreNMS
- `#12`
- Keywords: authentication, password, bcrypt, hash, login

---

## 🔧 Commandes Critiques (Copy-Paste Ready)

### ArgoCD Setup
```bash
# #1 - Permissions kubeconfig
chmod 644 /opt/argocd/kubeconfig

# #3 - Recréer les ConfigMaps
kubectl apply -n argocd -f argocd/install/install.yaml --server-side --force-conflicts

# #6 - Injecter server.secretkey
kubectl -n argocd patch secret argocd-secret \
  -p '{"stringData": {"server.secretkey": "'$(openssl rand -base64 32)'"}}'
```

### Kubernetes Deployments
```bash
# #8 - Déployer avec initContainer
kubectl apply -f librenms/librenms-deployment.yaml

# #10 - Configurer sticky sessions
kubectl patch svc librenms -n librenms -p '{"spec":{"sessionAffinity":"ClientIP"}}'

# #11 - Redémarrer après probe fix
kubectl rollout restart deployment/librenms -n librenms
```

### RRDcached / Infra
```bash
# #7 - Vérifier RRDcached
sudo systemctl status rrdcached
sudo nano /etc/default/rrdcached

# Tester depuis K8s
kubectl run -it --rm test --image=busybox --restart=Never -- nc -zv 192.168.98.131 42217
```

### LibreNMS / Application
```bash
# #12 - Réinitialiser mot de passe
kubectl exec -n librenms $(kubectl get pod -n librenms -l app=librenms -o name | head -1) \
  -- su -s /bin/bash librenms -c "php /tmp/resetpw.php"
```

---

## 📝 Méthodologie de Résolution

Chaque erreur suit ce schéma structuré :

1. **Contexte** → Situation et composants impliqués
2. **Symptômes** → Signes observables dans les logs/UI
3. **Cause** → Analyse technique de la racine du problème
4. **Résolution** → Étapes de correction applicables
5. **Commandes** → Exécutables directement (copy-paste)
6. **Notes** → Bonnes pratiques et pièges à éviter

---

## ⚙️ Architecture Impactée

```
┌─────────────────────────────────────────────────────────────┐
│                    Docker Compose VM                         │
│  ┌──────────┬──────────┬──────────┬────────────────────┐    │
│  │ ArgoCD   │ ArgoCD   │ ArgoCD   │ Dex (Auth)         │    │
│  │ Server   │ AppCtrl  │ RepoSrv  │                    │    │
│  └──────────┴──────────┴──────────┴────────────────────┘    │
│        ↓ kubeconfig (#1, #2, #3, #4, #5, #6)               │
└─────────────────────────────────────────────────────────────┘
         ↓ API Server
┌─────────────────────────────────────────────────────────────┐
│               Kubernetes Cluster (cp1, w1-w3)                │
│  ┌──────────────────────────────────────────────────────┐   │
│  │  LibreNMS Pods (#8, #9, #10, #11, #12)             │   │
│  │  ├─ Pod A (Deployment replica 1)                    │   │
│  │  └─ Pod B (Deployment replica 2)                    │   │
│  │     ├─ initContainer: wait-for-redis (#8)           │   │
│  │     ├─ Liveness/Readiness Probes (#11)             │   │
│  │     └─ Session Affinity (#10)                       │   │
│  │     │                                                │   │
│  │     ├─ Redis (queue) → DNS (#9)                     │   │
│  │     └─ RRDcached (storage) → Network (#7)           │   │
│  └──────────────────────────────────────────────────────┘   │
│  ┌──────────────────────────────────────────────────────┐   │
│  │  Ingress NGINX (sticky sessions #10)                │   │
│  └──────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
         ↓
┌─────────────────────────────────────────────────────────────┐
│             Infrastructure External                          │
│  • MariaDB VM (Authentification #12)                        │
│  • RRDcached VM (#7)                                        │
│  • NFS Storage (RRD data)                                   │
└─────────────────────────────────────────────────────────────┘
```

---

## 🚀 Prochaines Étapes

Après résolution de ces 12 erreurs :

1. **Validation** → Exécuter les scripts de test (`lnms device:discover`)
2. **Migration RRD** → Flush RRDcached + copie données vers PVC
3. **Tests de Charge** → Vérifier scalabilité des pollers
4. **Documentation** → Mettre à jour procédures de déploiement
5. **Production** → Cutover sur infrastructure bare-metal

---

## 📚 Documents Associés

- `LibreNMS_Kubernetes_Erreurs_Resolutions_UNIFIED.docx` — Document complet avec détails
- `README_TROUBLESHOOTING.md` — Procédures de diagnostic rapide
- GitHub Repo : `make5035/librenms-k8s-test`

---

## 👤 Auteur & Support

**Matt** — Administrateur Systèmes et Réseaux (ASR)
- Projet : Migration LibreNMS K8s
- Status : ✅ Complet et documenté
- Dernière mise à jour : 7 mai 2026

---

*Document généré automatiquement à partir des contenus de troubleshooting unifiés et dédupliqués.*
