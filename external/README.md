# Services externes au cluster Kubernetes

## Vue d'ensemble

MariaDB et RRDcached tournent sur une VM dédiée **hors du cluster K8s**.
Cette architecture est intentionnelle pour ce projet (VM `192.168.98.131`).

| Service    | VM IP           | Version              | Port  | Statut  |
|------------|-----------------|----------------------|-------|---------|
| MariaDB    | 192.168.98.131  | 10.5.29-MariaDB      | 3306  | Externe |
| RRDcached  | 192.168.98.131  | 1.9.0                | 42217 | Externe |

## Abstraction réseau K8s

Les fichiers `k8s-services/external-services.yaml` créent des Services K8s
sans selector qui pointent sur les Endpoints manuels de la VM externe.

Les pods référencent ces services par leur nom DNS interne :
- `mariadb-external.librenms.svc.cluster.local:3306`
- `rrdcached-external.librenms.svc.cluster.local:42217`

Note : les Deployments LibreNMS utilisent l'IP directe `192.168.98.131`
dans les variables d'environnement. Les services `external-services.yaml`
sont une couche d'abstraction optionnelle pour faciliter la migration future
vers un StatefulSet interne.

## Reproductibilité

Les scripts `mariadb/install.sh` et `rrdcached/install.sh` permettent de
reconstruire ces services à l'identique sur une nouvelle VM Debian 12.

Aucune donnée n'est versionnée ici — uniquement la configuration.

## Migration future vers K8s

Quand MariaDB et/ou RRDcached intègreront le cluster :
1. Créer le StatefulSet correspondant
2. Modifier uniquement le Service (`selector:` à la place des Endpoints)
3. Aucune modification des Deployments LibreNMS requise
