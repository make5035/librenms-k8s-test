# Manifests Kubernetes — LibreNMS (cible production)

Arborescence GitOps synchronisée par ArgoCD (Hub and Spoke, ArgoCD externe).

| Répertoire | Contenu | Sync-wave |
|---|---|---|
| namespaces/ | Namespace librenms | 0 |
| storage/ | PVC RRD (RWX, nfs-client) | 0 |
| librenms/secrets-templates.yaml | Gabarits Secrets (SOPS obligatoire) | 0 |
| redis/ | Deployment + Service Redis 7.2.14 | 1 |
| rrdcached/ | Option B uniquement (voir en-tête du manifest) | 1 |
| gateway/ | Gateway + HTTPRoute (GatewayClass cilium) | 1-2 |
| librenms/ | Deployment web, Service, StatefulSet pollers, Service headless, HPA | 2-3 |
| syslog-ng/, snmptrapd/ | Collecte passive, Services LoadBalancer MetalLB (IP fixes) | 4 |
| tools/ | Job de migration RRD (activé/retiré par commit + sync) | 5 |
| argocd/ | Application ArgoCD (à appliquer côté hub) | — |

Registre d'images : toutes les images pointent vers
`repos-nexus.cpa-sante.priv/docker-group-repo/...`.
Versions cibles production : LibreNMS 26.6.1, Redis 7.2.14, RRDtool 1.9.0,
MariaDB 10.5.29 (externe), snmptrapd 5.9.4, syslog-ng 4.8.3.
Memcached : exclu (composant inactif confirmé en production).

Règle d'or : aucune commande kubectl en écriture — le cycle est toujours
commit (Conventional Commits) → push → sync via l'interface web ArgoCD. kubectl sert au
diagnostic en lecture seule (get/describe/logs/top, alias k).

Avant commit : renseigner les placeholders `< >`, chiffrer les Secrets via
SOPS, supprimer toute métadonnée runtime. Conventional Commits obligatoires.
