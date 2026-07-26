# Gateway API — CRDs et GatewayClass (Cilium 1.15.6)

## 1. CRDs — 6 requises, pas 4 (fiche #18)

Cilium 1.15.6 avec gatewayAPI.enabled=true vérifie SIX CRDs au démarrage de son
operator. standard-install.yaml v1.0.0 n'en fournit QUE quatre (gatewayclasses,
gateways, httproutes, referencegrants). Il manque grpcroutes et tlsroutes
(canal experimental) — sans elles, l'operator refuse de créer la moindre
ressource Gateway API et log :
  "Required GatewayAPI resources are not found ... grpcroutes ... tlsroutes not found"

Appliquer les 6 (exception bootstrap kubectl, AVANT Cilium) :

    kubectl apply -f gateway-api/crds-v1.0.0.yaml            # 4 standard, figées dans le dépôt
    kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.0.0/config/crd/experimental/gateway.networking.k8s.io_grpcroutes.yaml
    kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.0.0/config/crd/experimental/gateway.networking.k8s.io_tlsroutes.yaml
    kubectl get crd | grep -i gateway                        # attendu : 6 lignes

Puis relancer l'operator pour qu'il re-scanne :

    kubectl -n kube-system delete pods -l name=cilium-operator

Régénérer le fichier figé des 4 standard :

    curl -fsSL -o crds-v1.0.0.yaml https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.0.0/standard-install.yaml

## 2. GatewayClass — non auto-provisionnée (fiche #18)

Cilium 1.15.x NE crée PAS l'objet GatewayClass de lui-même ; l'operator ne fait
que réconcilier les GatewayClass existantes. Elle est donc déclarée comme un
manifest versionné : k8s/00-gatewayclass.yaml (sync-wave 0). Vérification :

    kubectl get gatewayclass        # cilium  ACCEPTED=True
