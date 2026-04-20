# LibreNMS — Migration Docker Compose → Kubernetes

Dépôt de travail pour la migration de l'infrastructure de supervision **LibreNMS** depuis un environnement Docker Compose de production vers un cluster Kubernetes de test.

---

## Contexte

L'infrastructure de supervision actuelle tourne en production sous Docker Compose et supervise plusieurs milliers d'équipements réseau via SNMP v2c. L'objectif de ce projet est de reproduire fidèlement cet environnement dans un cluster Kubernetes de test, valider la migration des données (base de données MariaDB + fichiers RRD), puis préparer un déploiement K8s production-ready.

**Ce repo ne contient aucune donnée de production.** Les secrets sont chiffrés via SOPS ou fournis sous forme de templates `.example`.

---

## Environnement

| Environnement | Infrastructure | Réseau |
|---|---|---|
| Production | Docker Compose (serveur physique) | LAN interne |
| Test Docker | VM VMware Workstation | VMnet8 NAT — `192.168.98.0/24` |
| Test K8s | Cluster multi-nœuds VMware Workstation | VMnet8 NAT — `192.168.98.0/24` |

---

## Versions du stack supervisé

| Composant | Version | Image Docker |
|---|---|---|
| LibreNMS | 26.2.0 | `librenms/librenms:26.2.0` |
| PHP | 8.3.x | inclus dans l'image LibreNMS |
| MariaDB | 10.5.29 | `mariadb:10.5` |
| Redis | 5.0.14 | `redis:5.0-alpine` |
| Memcached | 1.6.41 | `memcached:1.6.41` |
| RRDcached | 1.9.0 | `crazymax/rrdcached:1.9.0` |
| syslog-ng | 4.8.3 | inclus dans l'image LibreNMS |
| snmptrapd | 5.9.4 | inclus dans l'image LibreNMS |

---

## Arborescence du repo

```
librenms-k8s/
│
├── README.md                          ← ce fichier
├── .gitignore
├── .sops.yaml                         ← configuration chiffrement SOPS
│
├── docker/                            ← environnement de test Docker Compose
│   ├── README.md                      ← procédure de démarrage détaillée
│   ├── .env.example                   ← template variables d'environnement
│   ├── librenms.env.example           ← template configuration LibreNMS
│   ├── docker-compose-strict.yml      ← réplique fidèle de la prod (versions épinglées)
│   └── docker-compose-improved.yml    ← améliorations documentées (healthchecks, etc.)
│
├── migration/                         ← scripts de migration Docker → K8s
│   ├── README.md                      ← plan de migration étape par étape
│   ├── 01-flush-rrdcached.sh          ← flush du cache RRD avant copie
│   ├── 02-dump-mariadb.sh             ← export de la base de données
│   ├── 03-import-mariadb.sh           ← import vers K8s
│   └── 04-rsync-rrd.sh                ← copie des fichiers RRD vers PVC
│
├── argocd/                            ← déploiement ArgoCD
│   └── install/
│       └── install.yaml
│
├── ingress/                           ← contrôleur Ingress NGINX
│   ├── argocd-ingress.yaml
│   └── nginx-deploy.yaml
│
├── librenms/                          ← manifests Kubernetes LibreNMS
│   ├── librenms-deployment.yaml       ← frontend web
│   ├── librenms-service.yaml
│   ├── ingress-librenms.yaml
│   ├── statefulset-librenms-poller.yaml  ← pollers SNMP scalables
│   ├── service-librenms-poller.yaml
│   ├── hpa-librenms-poller.yaml       ← autoscaling horizontal des pollers
│   └── librenms-poller-secret.yaml
│
├── metallb/                           ← LoadBalancer MetalLB
│   ├── deploy-metallb.yaml
│   ├── ip-pool-metallb.yaml
│   └── namespace-metallb.yaml
│
├── namespaces/                        ← namespaces Kubernetes
│   ├── librenms-namespace.yaml
│   └── argocd-namespace.yaml
│
├── redis/                             ← déploiement Redis
│   └── redis-deployment.yaml
│
└── secrets/                           ← secrets Kubernetes (chiffrés SOPS)
    └── librenms-secret.yaml
```

---

## Démarrage rapide

### Prérequis

- Docker + Docker Compose v2 installés sur la VM de test Docker
- Accès réseau à `192.168.98.0/24` (cluster K8s) depuis la VM Docker
- `kubectl` configuré sur la VM K8s
- `git` installé sur les deux VMs

### Cloner le repo

```bash
git clone https://github.com/make5035/librenms-k8s.git
cd librenms-k8s
```

### Démarrer l'environnement Docker de test

Depuis la **VM Docker** :

```bash
cd docker/

# Créer les répertoires de données locaux (jamais versionnés)
mkdir -p data/{db,librenms,rrdcached/{db,journal}}

# Préparer les fichiers de configuration
cp .env.example .env
cp librenms.env.example librenms.env

# Adapter les valeurs (credentials, timezone, PUID/PGID)
vi .env
vi librenms.env

# Démarrer les backends en premier
docker compose -f docker-compose-strict.yml up -d mariadb redis memcached rrdcached

# Attendre que MariaDB soit prêt (vérifier le statut)
docker compose -f docker-compose-strict.yml ps

# Démarrer le frontend
docker compose -f docker-compose-strict.yml up -d librenms

# Démarrer les sidecars
docker compose -f docker-compose-strict.yml up -d syslogng snmptrapd
```

Interface web accessible sur : `http://<IP-VM-DOCKER>:8000`

### Appliquer les manifests Kubernetes

Depuis la **VM K8s** :

```bash
cd librenms-k8s/

# Namespaces
kubectl apply -f namespaces/

# MetalLB
kubectl apply -f metallb/

# Ingress NGINX
kubectl apply -f ingress/

# ArgoCD
kubectl apply -f argocd/install/install.yaml
kubectl apply -f ingress/argocd-ingress.yaml

# LibreNMS
kubectl apply -f secrets/
kubectl apply -f redis/
kubectl apply -f librenms/
```

---

## Plan de migration

La migration des données s'effectue en deux temps, **après** une période de validation de l'environnement Docker de test.

```
Phase 1 — Validation (quelques jours)
  └── Stack Docker de test opérationnelle
  └── Polling SNMP fonctionnel
  └── Graphes RRD générés correctement
  └── Syslog et traps SNMP reçus

Phase 2 — Migration des données
  ├── 1. Flush RRDcached (scripts/01-flush-rrdcached.sh)
  ├── 2. Export MariaDB  (scripts/02-dump-mariadb.sh)
  ├── 3. Import MariaDB  (scripts/03-import-mariadb.sh)
  └── 4. Copie RRD       (scripts/04-rsync-rrd.sh)

Phase 3 — Bascule
  └── Vérification des graphes et du polling sur K8s
  └── Validation des alertes et syslog
  └── Arrêt de la stack Docker de test
```

Voir [`migration/README.md`](migration/README.md) pour la procédure détaillée étape par étape.

---

## Sécurité

- Les fichiers `.env` et `librenms.env` ne sont **jamais committés** (listés dans `.gitignore`)
- Seuls les fichiers `.env.example` et `librenms.env.example` sont versionnés
- Les secrets Kubernetes sont chiffrés via **SOPS** (voir `.sops.yaml`)
- Le répertoire `docker/data/` est exclu du versionning (données locales)
- Aucun certificat (`.cer`, `.crt`, `.key`, `.pem`) n'est versionné

---

## Réseau

```
VMware Workstation — VMnet8 (NAT)
┌─────────────────────────────────────────────────────┐
│  192.168.98.0/24                                    │
│                                                     │
│  ┌──────────────┐     ┌─────────────────────────┐  │
│  │  VM Docker   │     │  Cluster K8s (3 nœuds)  │  │
│  │  .xx         │◄───►│  .x  master             │  │
│  │              │     │  .x  worker-1           │  │
│  └──────────────┘     │  .x  worker-2           │  │
│                        └─────────────────────────┘  │
│                                                     │
│  NAT sortant → LAN physique → équipements SNMP      │
└─────────────────────────────────────────────────────┘

Réseau interne Docker Compose : 10.200.0.0/24
  (isolé — pas de chevauchement avec K8s ni production)
```

---

## Ports exposés (VM Docker)

| Port | Protocole | Service | Usage |
|---|---|---|---|
| 8000 | TCP | LibreNMS web | Interface d'administration |
| 3306 | TCP | MariaDB | Migration DB → K8s |
| 42217 | TCP | RRDcached | Migration RRD → K8s |
| 6379 | TCP | Redis | Debug / inspection |
| 514 | TCP+UDP | syslog-ng | Réception syslog réseau |
| 162 | TCP+UDP | snmptrapd | Réception traps SNMP |

---

## Statut du projet

- [x] Stack Docker Compose de test (versions épinglées)
- [x] Namespace LibreNMS K8s
- [x] Déploiement Redis K8s
- [x] Déploiement LibreNMS frontend K8s
- [x] StatefulSet pollers K8s (scalable)
- [x] HPA pollers K8s
- [x] MetalLB LoadBalancer
- [x] Ingress NGINX
- [x] ArgoCD
- [ ] MariaDB StatefulSet K8s
- [ ] RRDcached Deployment K8s
- [ ] Memcached Deployment K8s
- [ ] Scripts de migration finalisés
- [ ] Migration des données effectuée
- [ ] Validation complète sur K8s
