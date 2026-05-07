# Scripts de validation — Migration LibreNMS Docker → Kubernetes

## Vue d'ensemble

| Script | Description | Exécution depuis |
|--------|-------------|-----------------|
| `01_check_cluster.sh` | État du cluster K8s (nœuds, CNI, metrics-server, MetalLB) | Bastion / CP |
| `02_check_application.sh` | État applicatif (pods, HPA, PVC, UI, variables DB) | Bastion / CP |
| `03_check_database.sh` | Connectivité et intégrité MariaDB | Bastion / VM Docker |
| `04_check_snmp.sh` | Polling SNMP depuis les pods K8s | Bastion / CP |
| `05_check_rrd_migration.sh` | Migration données RRD (source → NFS → rrdcached) | VM Docker / Bastion |
| `06_check_full_migration.sh` | Orchestrateur — exécute tous les scripts | Bastion / CP |
| `migration.env.template` | Template de configuration | — |

## Démarrage rapide

```bash
# 1. Rendre les scripts exécutables
chmod +x *.sh

# 2. Copier et adapter le fichier .env
cp migration.env.template migration.env
nano migration.env  # Adapter les valeurs

# 3. Lancer la validation complète
./06_check_full_migration.sh --env-file migration.env

# 4. Consulter le rapport
cat migration_report_*.txt
```

## Utilisation individuelle

```bash
# Cluster seulement
./01_check_cluster.sh --context my-cluster

# Application avec namespace custom
./02_check_application.sh \
  --namespace monitoring \
  --app-label librenms \
  --ingress-ip 192.168.1.240

# Base de données
./03_check_database.sh \
  --db-host 192.168.1.131 \
  --db-password 'MonMotDePasse' \
  --use-docker  # Si mysql non disponible localement

# SNMP sur plusieurs cibles
./04_check_snmp.sh \
  --community CPAreport \
  --targets "192.168.1.10,192.168.1.11,192.168.1.12"

# RRD avec NFS
./05_check_rrd_migration.sh \
  --nfs-server 192.168.1.131 \
  --rrdcached-host 192.168.1.131

# Complet avec tous les paramètres
./06_check_full_migration.sh \
  --namespace librenms \
  --db-host 192.168.1.131 \
  --db-password 'MonMotDePasse' \
  --targets "192.168.1.128,192.168.1.129,192.168.1.130" \
  --nfs-server 192.168.1.131 \
  --rrdcached-host 192.168.1.131 \
  --ingress-ip 192.168.1.240 \
  --verbose
```

## Intégration CI/CD

```yaml
# Exemple GitHub Actions
- name: Validate K8s migration
  run: |
    ./06_check_full_migration.sh \
      --env-file migration.env \
      --report-file ci_report.txt
  env:
    DB_PASSWORD: ${{ secrets.DB_PASSWORD }}
    SNMP_COMMUNITY: ${{ secrets.SNMP_COMMUNITY }}
```

## Erreurs fréquentes et remédiations

### SNMP Timeout depuis les pods
```
Cause : agentaddress sur loopback ou communauté non autorisée depuis subnet pods
Fix   : agentaddress udp:0.0.0.0:161
        rocommunity <COMMUNITY> 10.0.0.0/8  # subnet Cilium
```

### DB_USERNAME absent (LibreNMS)
```
Cause : variable nommée DB_USER au lieu de DB_USERNAME dans le deployment
Fix   : sed -i 's/name: DB_USER$/name: DB_USERNAME/' deployment.yaml
        kubectl rollout restart deployment/librenms -n librenms
```

### PVC en Pending
```
Cause : NFS provisioner non configuré ou NFS inaccessible
Fix   : kubectl logs -n kube-system -l app=nfs-subdir-external-provisioner
        Vérifier showmount -e <IP_NFS>
```

### Metrics Server erreur x509
```
Cause : Certificats kubelet auto-signés (env VMware/lab)
Fix   : kubectl patch deployment metrics-server -n kube-system \
          --type=json \
          -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
```

### Import DB Access Denied
```
Cause 1 : Utilisateur créé avec host '%' → utiliser -h 127.0.0.1
Cause 2 : Caractères spéciaux dans le mot de passe → utiliser guillemets simples
Cause 3 : Container Docker sans accès réseau hôte → utiliser --network host
Fix     : cat dump.sql | docker run --rm -i --network host mariadb:10.5 \
            mysql -h <IP> -u librenms -p'MotDePasse' librenms
```
