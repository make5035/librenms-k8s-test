# ArgoCD — Architecture externe (Hub and Spoke simplifié)

## Principe
ArgoCD est déployé sur une VM externe au cluster K8s via Docker Compose.
Il gère les manifests du repo GitHub vers le cluster distant.

## Versions
- ArgoCD : v2.10.6
- install.yaml : v2.10.6 (aligné avec le Docker Compose)

## Composants sur la VM Docker (docker_compose_test_improved_v2.yaml)
- argocd-server        : UI + API (port 8080)
- argocd-repo-server   : Gestion des repos Git
- argocd-application-controller : Réconciliation K8s
- argocd-dex           : Auth OIDC
- argocd-redis         : État interne ArgoCD (dédié, isolé du Redis LibreNMS)

## Composants sur le cluster K8s (namespace argocd)
- ConfigMaps, Secrets, RBAC, CRDs uniquement
- Aucun workload ArgoCD ne tourne dans le cluster

## Fichiers
- argocd/install/install.yaml     : Manifests K8s (ConfigMaps, RBAC, CRDs)
- argocd/librenms-app.yaml        : Application ArgoCD — stack LibreNMS
- docker/docker_compose_test_improved_v2.yaml : Stack Docker ArgoCD + LibreNMS

## Prérequis
- /opt/argocd/kubeconfig : kubeconfig pointant vers cp1 (chmod 644)
- /opt/argocd/dex-config.yaml : Config Dex OIDC
- Port 6443 ouvert entre la VM Docker et cp1

## Bootstrap
# Sur cp1 :
kubectl apply -n argocd -f argocd/install/install.yaml --server-side --force-conflicts

# Sur la VM Docker :
docker compose -f docker/docker_compose_test_improved_v2.yaml up -d \
  argocd-redis argocd-repo-server argocd-application-controller argocd-server argocd-dex
