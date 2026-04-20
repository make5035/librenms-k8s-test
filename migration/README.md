# Procédure de migration Docker → Kubernetes

## Ordre d'exécution

1. `01-flush-rrdcached.sh` — vider le cache RRD avant copie
2. `02-dump-mariadb.sh`    — exporter la base de données
3. `03-import-mariadb.sh`  — importer vers K8s
4. `04-rsync-rrd.sh`       — copier les fichiers RRD vers le PVC K8s

## Prérequis

- Stack Docker de test opérationnelle et validée
- Accès kubectl vers le cluster K8s
- PVC RRDcached et MariaDB créés dans K8s
