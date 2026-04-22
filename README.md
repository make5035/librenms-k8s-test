# LibreNMS — Migration Docker Compose → Kubernetes

Dépôt de travail pour la migration de l'infrastructure de supervision **LibreNMS**
depuis Docker Compose de production vers un cluster Kubernetes.

---

## Contexte

- **6 536 équipements** supervisés via SNMP v2c
- Infrastructure actuelle : Docker Compose sur serveur physique
- Cible : cluster Kubernetes bare metal (production) / VMs VMware (test)

**Ce repo ne contient aucune donnée de production.** Les secrets sont chiffrés via SOPS.

---

## Environnements

| Environnement | Infrastructure | Réseau |
|---|---|---|
| Production Docker Compose | Serveur physique | LAN entreprise |
| Test Docker | VM VMware — `192.168.98.134` | VMnet8 NAT `192.168.98.0/24` |
| Test K8s | Cluster VMs VMware | VMnet8 NAT `192.168.98.0/24` |
| Production K8s cible | Bare metal dédié | LAN physique entreprise |

### Nœuds cluster K8s test

| Rôle | IP |
|---|---|
| Control Plane (cp1) | 192.168.98.128 |
| Worker 1 (w1) | 192.168.98.129 |
| Worker 2 (w2) | 192.168.98.130 |
| Worker 3 (w3) | 192.168.98.132 |
| VM DB externe (MariaDB + RRDcached) | 192.168.98.131 |
| VM Docker test | 192.168.98.134 |

---

## Versions du stack

| Composant | Version | Image Docker | Localisation |
|---|---|---|---|
| LibreNMS | 26.2.0 | `librenms/librenms:26.2.0` | Cluster K8s |
| PHP | 8.3.29 | inclus dans LibreNMS | Cluster K8s |
| Zend Engine | 4.3.29 | inclus dans LibreNMS | Cluster K8s |
| syslog-ng | 4.8.3 | inclus dans LibreNMS | Cluster K8s |
| snmptrapd | 5.9.4 | inclus dans LibreNMS | Cluster K8s |
| MariaDB | 10.5.29 | `mariadb:10.5` | **VM externe** |
| Redis | 5.0.14 | `redis:5.0-alpine` | Cluster K8s |
| Memcached | 1.6.41 | `memcached:1.6.41` | Cluster K8s |
| RRDcached | 1.9.0 | `crazymax/rrdcached:1.9.0` | **VM externe** |

---

## Arborescence

```
librenms-k8s/
│
├── README.md
├── .gitignore
├── .sops.yaml
│
├── docker/                              ← Stack Docker Compose de test
│   ├── README.md
│   ├── .env.example
│   ├── librenms.env.example
│   ├── docker-compose-strict.yml        ← Réplique fidèle prod (versions épinglées)
│   └── docker-compose-improved.yml      ← Améliorations (healthchecks, probes)
│
├── namespaces/
│   ├── librenms-namespace.yaml
│   └── argocd-namespace.yaml
│
├── secrets/                             ← Chiffrés SOPS — jamais en clair
│   └── librenms-secret.yaml
│
├── librenms/
│   ├── librenms-deployment.yaml         ← Frontend web (2 replicas)
│   ├── librenms-service.yaml
│   ├── librenms-pvc.yaml                ← PVCs : data, weathermap-output, menu
│   ├── ingress-librenms.yaml
│   ├── statefulset-librenms-poller.yaml ← Pollers SNMP (scalables, HPA)
│   ├── service-librenms-poller.yaml     ← Headless service StatefulSet
│   ├── hpa-librenms-poller.yaml         ← Autoscaling 3→10 replicas
│   └── librenms-poller-secret.yaml      ← Chiffré SOPS
│
├── redis/
│   └── redis-deployment.yaml            ← Redis 5.0.14 + PVC AOF + Service
│
# memcached retiré
│   └── memcached-deployment.yaml        ← Memcached 1.6.41 + Service
│
├── syslogng/
│   └── syslogng-deployment.yaml         ← syslog-ng 4.8.3 + Services MetalLB TCP/UDP
│
├── snmptrapd/
│   └── snmptrapd-deployment.yaml        ← snmptrapd 5.9.4 + Services MetalLB TCP/UDP
│
├── metallb/
│   ├── namespace-metallb.yaml
│   ├── ip-pool-metallb.yaml             ← Pool 192.168.98.200-210
│   └── deploy-metallb.yaml              ← (lien vers install Helm)
│
├── ingress/
│   ├── nginx-deploy.yaml                ← Helm values NGINX Ingress
│   └── argocd-ingress.yaml
│
├── argocd/
│   ├── install/
│   │   └── install.yaml
│   └── librenms-app.yaml                ← Application ArgoCD GitOps
│
├── external/                            ← Services hors cluster (non gérés K8s)
│   ├── README.md
│   ├── k8s-services/
│   │   └── external-services.yaml       ← Endpoints + Services MariaDB/RRDcached
│   ├── mariadb/
│   │   ├── 50-server.cnf                ← Config versionnée
│   │   └── install.sh                   ← Installation reproductible
│   └── rrdcached/
│       └── install.sh                   ← Installation reproductible
│
└── migration/
    ├── README.md
    ├── 01-flush-rrdcached.sh
    ├── 02-dump-mariadb.sh
    ├── 03-import-mariadb.sh
    └── 04-rsync-rrd.sh
```

---

## IPs MetalLB réservées (environnement test)

| IP | Service | Port(s) |
|---|---|---|
| 192.168.98.200 | NGINX Ingress (LibreNMS web + ArgoCD) | 80, 443 |
| 192.168.98.201 | syslog-ng | 514/TCP + 514/UDP |
| 192.168.98.202 | snmptrapd | 162/TCP + 162/UDP |
| 192.168.98.203-210 | Réservé | — |

---

## Ordre de déploiement

```bash
# 1. Namespaces
kubectl apply -f namespaces/

# 2. MetalLB (déjà installé via Helm — appliquer uniquement le pool)
kubectl apply -f metallb/ip-pool-metallb.yaml

# 3. Secrets (après chiffrement SOPS)
kubectl apply -f secrets/
kubectl apply -f librenms/librenms-poller-secret.yaml

# 4. PVCs
kubectl apply -f librenms/librenms-pvc.yaml
kubectl apply -f redis/redis-deployment.yaml   # PVC Redis inclus

# 5. Services externes (Endpoints MariaDB + RRDcached)
kubectl apply -f external/k8s-services/

# 6. Backends
kubectl apply -f redis/
kubectl apply -f memcached/

# 7. Application LibreNMS
kubectl apply -f librenms/librenms-deployment.yaml
kubectl apply -f librenms/librenms-service.yaml
kubectl apply -f librenms/ingress-librenms.yaml

# 8. Pollers
kubectl apply -f librenms/statefulset-librenms-poller.yaml
kubectl apply -f librenms/service-librenms-poller.yaml
kubectl apply -f librenms/hpa-librenms-poller.yaml

# 9. Sidecars réseau
kubectl apply -f syslogng/
kubectl apply -f snmptrapd/

# 10. Vérification globale
kubectl get all -n librenms
kubectl get pvc -n librenms
kubectl get ingress -n librenms
```

---

## Sécurité

- Fichiers `.env` et `librenms.env` exclus du versionnement (`.gitignore`)
- Secrets chiffrés via **SOPS + age** avant tout commit
- Répertoire `docker/data/` exclu (données locales)
- Aucun certificat (`.cer`, `.crt`, `.key`, `.pem`) versionné

---

## Données RRD production (référence dimensionnement)

| Métrique | Valeur |
|---|---|
| Devices actifs | 6 536 |
| Fichiers .rrd | 592 289 |
| Dossiers | 7 701 (dont 1 165 orphelins) |
| Volume total | 664 Go |
| Plus gros device | invnms-pxg01 — 25 Go |

---

## Statut du projet

- [x] Stack Docker Compose de test (versions épinglées)
- [x] Namespace LibreNMS K8s
- [x] Redis Deployment K8s (5.0.14 — corrigé v2)
- [ ] Memcached — NON déployé (inactif en prod, CACHE_DRIVER=redis)
- [x] LibreNMS frontend Deployment K8s (v2 — weathermap + menu custom)
- [x] StatefulSet pollers K8s (v2 — RRDCACHED_SERVER + MIBs)
- [x] HPA pollers K8s (v2 — minReplicas 3, metric mémoire)
- [x] MetalLB LoadBalancer (v2 — IPs documentées)
- [x] Ingress NGINX (v2 — timeouts, ssl-passthrough ArgoCD)
- [x] ArgoCD Application manifest (nouveau)
- [x] syslog-ng Deployment K8s (nouveau)
- [x] snmptrapd Deployment K8s (nouveau)
- [x] PVCs LibreNMS (nouveau — data, weathermap-output, menu)
- [x] Services externes MariaDB + RRDcached (Endpoints K8s)
- [x] Scripts install MariaDB + RRDcached reproductibles
- [ ] Migration données effectuée (DB + RRD)
- [ ] Validation complète sur K8s
- [ ] Basculement production
