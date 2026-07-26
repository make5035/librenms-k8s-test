# librenms-k8s-test — structure du dépôt

    docker/
      compose.librenms-source.yml     # stack source LibreNMS (§4)
      compose.argocd-hub.yml          # hub ArgoCD, host mode (§6)
      .env.example                    # modèle interpolation (copier en .env, gitignoré)
      librenms.env.example            # modèle env_file (copier en librenms.env, gitignoré)
    gateway-api/
      crds-v1.0.0.yaml                # CRDs Gateway API figées (à régénérer, voir README)
      README.md
    metallb/
      ipaddresspool.yaml              # pool 192.168.98.240-250 + L2Advertisement
    argocd/
      librenms-app.yaml               # Application ArgoCD (créée via UI, §8)
    k8s/                              # manifests applicatifs, sync-waves 0->4
      00-namespace.yaml
      00-gatewayclass.yaml            # GatewayClass cilium (Cilium ne la cree pas)
      10-configmap.yaml
      10-secret.sops.yaml             # chiffré SOPS+age (modèle : *.example)
      20-pvc-rrd.yaml
      30-redis.yaml
      40-librenms.yaml
      40-poller-statefulset.yaml
      40-hpa.yaml
      40-gateway.yaml
      40-httproute.yaml

## Clone (sur chaque VM qui applique des manifests : cp1 pour le bootstrap)

    git clone git@github.com:make5035/librenms-k8s-test.git
    cd librenms-k8s-test

.gitignore doit contenir au minimum : .env, librenms.env, docker/data/, *.key, age.key
